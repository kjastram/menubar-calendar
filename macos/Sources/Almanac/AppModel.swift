import AlmanacAuth
import AlmanacData
import AlmanacKit
import AlmanacUI
import AppKit
import Observation

/// Everything the app needs once it is set up.
@MainActor
struct AppServices {
    let repository: any CalendarRepository
    let source: any ItemSource
    let sync: any SyncControl
    let store: CalendarStore
    /// Nil with `--preview-data`.
    let auth: AuthService?
    /// Nil with `--preview-data`.
    let database: AppDatabase?
    /// Nil with `--preview-data`.
    let engine: SyncEngine?
}

/// Composition root and app-level actions (accounts, sync). One per process.
@MainActor @Observable
final class AppModel {
    static let shared = AppModel(previewData: CommandLine.arguments.contains("--preview-data"))

    let previewData: Bool
    let menu = MenuBarModel()
    private(set) var services: AppServices?
    /// Set when the app can't start (no OAuth client file, database error). The setup window shows it.
    private(set) var setupProblem: String?
    private(set) var lastSynced: Date?
    private(set) var isSyncing = false
    private(set) var isSigningIn = false
    /// Last account or quick-add error, shown in the popover and settings.
    var lastError: String?

    @ObservationIgnored private var lastSyncRequest: Date?
    /// The browser step of the running sign-in, so it can be cancelled.
    @ObservationIgnored private var signInTask: Task<String, any Error>?
    @ObservationIgnored private var signInTimedOut = false

    /// Gives up waiting for the browser after this long.
    static let signInTimeout: Duration = .seconds(5 * 60)

    private init(previewData: Bool) {
        self.previewData = previewData
        AppSettings.register()
    }

    var canManageAccounts: Bool { services?.auth != nil }

    // MARK: - Startup

    func start() {
        guard services == nil else { return }
        do {
            let services = try previewData ? makePreviewServices() : makeLiveServices()
            self.services = services
            setupProblem = nil
            services.store.defaultCalendarID = UserDefaults.standard.string(forKey: AppSettings.defaultCalendarID)
            services.store.start()
            if let engine = services.engine {
                Task {
                    // Reserve the plugin's colors before the first pass adds accounts, so a new
                    // account can't take a color the plugin gave to another one.
                    if let database = services.database, let plugin = try? PluginConfig.load() {
                        try? await database.reserveColors(Array(plugin.accountColors.values))
                    }
                    // Timed syncs move the "Synced" time too, not only the ones started here.
                    await engine.setOnPassFinished { [weak self] in await self?.passFinished() }
                    await engine.start()
                }
            }
            var signInCheck: (@Sendable () async -> Set<String>)?
            if let auth = services.auth {
                signInCheck = { await auth.emailsNeedingSignIn() }
            }
            var calendarErrors: (@Sendable () async -> [String: String])?
            if let database = services.database {
                calendarErrors = { (try? await database.calendarErrors()) ?? [:] }
            }
            menu.attach(repository: services.repository, needsSignIn: signInCheck, calendarErrors: calendarErrors)
            Task { await prepareAccounts() }
        } catch {
            setupProblem = Self.describe(error)
        }
    }

    /// Tries again after the person added the OAuth client file.
    func retrySetup() {
        services = nil
        start()
    }

    private func makeLiveServices() throws -> AppServices {
        let config = try OAuthClientConfig.load()
        let auth = AuthService(config: config, keychain: KeychainStore(service: "com.kjastram.almanac"))
        let database = try AppDatabase.open(at: AppDatabase.defaultURL())
        let session = URLSession.shared
        let source = GoogleCalendarSource(tokens: auth, database: database, session: session)
        let engine = SyncEngine(tokens: auth, database: database, session: session, interval: .seconds(120))
        let store = CalendarStore(repository: database, source: source, sync: engine)
        return AppServices(repository: database, source: source, sync: engine, store: store,
                           auth: auth, database: database, engine: engine)
    }

    private func makePreviewServices() throws -> AppServices {
        let repository = PreviewData.Repository()
        let source = PreviewData.Source(repository: repository)
        let sync = PreviewData.Sync(repository: repository)
        let store = CalendarStore(repository: repository, source: source, sync: sync)
        return AppServices(repository: repository, source: source, sync: sync, store: store,
                           auth: nil, database: nil, engine: nil)
    }

    /// Makes sure every signed-in account has a row, and runs the one-time plugin import.
    private func prepareAccounts() async {
        guard let services, let auth = services.auth, let database = services.database else { return }
        let plugin = try? PluginConfig.load()
        let emails = await auth.signedInEmails()
        do {
            var known = Set(try await database.accounts().map(\.email))
            for email in emails where !known.contains(email) {
                try await addAccountRow(email, plugin: plugin, database: database)
                known.insert(email)
            }
            if !UserDefaults.standard.bool(forKey: AppSettings.importedPluginConfig) {
                if let plugin {
                    try await importPlugin(plugin, signedIn: emails, database: database)
                }
                UserDefaults.standard.set(true, forKey: AppSettings.importedPluginConfig)
            }
        } catch {
            lastError = Self.describe(error)
        }
        await syncNow()
    }

    /// One-time import of the plugin's settings.
    private func importPlugin(_ plugin: PluginConfig, signedIn: [String], database: AppDatabase) async throws {
        if let minutes = plugin.lookaheadMinutes {
            UserDefaults.standard.set(minutes, forKey: AppSettings.lookaheadMinutes)
        }
        if !plugin.exclude.isEmpty {
            try await database.setExcludedCalendars(plugin.exclude)
        }
        for email in signedIn {
            if let color = plugin.accountColors[email] {
                try await database.setAccountColor(email, color: color)
            }
            if plugin.hiddenAccounts.contains(email) {
                try await database.setAccountHidden(email, hidden: true)
            }
        }
    }

    /// New account: the plugin's color and hidden state if it lists the email, else the next unused palette color.
    private func addAccountRow(_ email: String, plugin: PluginConfig?, database: AppDatabase) async throws {
        let hidden = plugin?.hiddenAccounts.contains(email) ?? false
        if let color = plugin?.accountColors[email] {
            try await database.ensureAccount(email, color: color, hidden: hidden)
        } else {
            try await database.ensureAccount(email, color: nil, hidden: false)
            if hidden { try await database.setAccountHidden(email, hidden: true) }
        }
    }

    // MARK: - Actions

    func syncNow() async {
        guard let services else { return }
        lastSyncRequest = Date()
        isSyncing = true
        await services.sync.syncNow()
        isSyncing = false
        await passFinished()
    }

    /// After any sync pass. Only moves the "Synced" time when at least one account actually
    /// fetched; failed accounts keep their error status.
    private func passFinished() async {
        guard let services else { return }
        if let accounts = try? await services.repository.accounts(), accounts.contains(where: { $0.status == .ok }) {
            lastSynced = Date()
        }
        await menu.reload()
    }

    /// Sync when the app becomes active or the main window gets focus, at most every 30 seconds.
    func syncSoon() {
        if let last = lastSyncRequest, Date().timeIntervalSince(last) < 30 { return }
        Task { await syncNow() }
    }

    /// Opens the browser for Google sign-in. Also used for "Sign in again".
    /// Stops waiting after `signInTimeout` or when `cancelSignIn()` is called.
    func addAccount() async {
        guard let services, let auth = services.auth, let database = services.database, !isSigningIn else { return }
        isSigningIn = true
        signInTimedOut = false
        // Cancelling this task makes AuthService close the loopback listener.
        let signIn = Task { try await auth.signIn() }
        signInTask = signIn
        let timeout = Task { [weak self] in
            try await Task.sleep(for: Self.signInTimeout)
            self?.signInTimedOut = true
            signIn.cancel()
        }
        defer {
            timeout.cancel()
            signIn.cancel()
            signInTask = nil
            isSigningIn = false
        }
        do {
            let known = Set(try await database.accounts().map(\.email))
            let email = try await signIn.value
            if known.contains(email) {
                try await database.setAccountStatus(email, .ok)
            } else {
                // Sync may have inserted the row already with a palette color, so set the plugin's values explicitly.
                try await addAccountRow(email, plugin: try? PluginConfig.load(), database: database)
            }
            lastError = nil
            await syncNow()
        } catch where signIn.isCancelled {
            lastError = signInTimedOut ? "Sign-in timed out. Try again." : nil
        } catch {
            lastError = Self.describe(error)
        }
    }

    /// Stops waiting for the browser.
    func cancelSignIn() {
        signInTask?.cancel()
    }

    func removeAccount(_ email: String) async {
        guard let services, let auth = services.auth, let database = services.database else { return }
        await auth.signOut(email)
        do {
            try await database.removeAccount(email)
        } catch {
            lastError = Self.describe(error)
        }
        await menu.reload()
    }

    func setAccountColor(_ email: String, _ color: String) async {
        guard let services else { return }
        do { try await services.repository.setAccountColor(email, color: color) } catch { lastError = Self.describe(error) }
    }

    func setAccountHidden(_ email: String, _ hidden: Bool) async {
        guard let services else { return }
        do { try await services.repository.setAccountHidden(email, hidden: hidden) } catch { lastError = Self.describe(error) }
    }

    func setCalendarVisible(_ calendarID: String, _ visible: Bool) async {
        guard let services else { return }
        do { try await services.repository.setCalendarVisible(calendarID, visible: visible) } catch {
            lastError = Self.describe(error)
        }
    }

    /// Where quick add goes: the Settings default, then the last used, then the first primary writable calendar.
    var defaultCalendar: CalendarInfo? {
        guard let store = services?.store, let id = store.quickAddCalendarID else { return nil }
        return store.calendarInfo(id: id)
    }

    func setDefaultCalendar(_ id: String) {
        UserDefaults.standard.set(id, forKey: AppSettings.defaultCalendarID)
        services?.store.defaultCalendarID = id
    }

    /// Google's quick add. Returns true on success.
    func quickAdd(_ text: String) async -> Bool {
        guard let store = services?.store else { return false }
        guard let calendar = defaultCalendar else {
            lastError = "No calendar you can add events to."
            return false
        }
        switch await store.quickAdd(text, calendarID: calendar.id) {
        case .success:
            lastError = nil
            await menu.reload()
            return true
        case .failure(let error):
            lastError = error.message
            return false
        }
    }

    static func describe(_ error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
