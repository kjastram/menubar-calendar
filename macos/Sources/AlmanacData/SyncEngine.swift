import AlmanacKit
import Foundation

/// Polls Google for every signed-in account and applies the changes to the cache.
public actor SyncEngine: SyncControl {
    private let api: GoogleAPI
    private let database: AppDatabase
    private let interval: Duration
    /// The pass in progress, and at most one pass waiting to start after it.
    private var running: (id: Int, task: Task<Bool, Never>)?
    private var queued: (id: Int, task: Task<Bool, Never>)?
    private var passCount = 0
    private var loop: Task<Void, Never>?
    private var failures = 0
    private var onPassFinished: (@Sendable () async -> Void)?

    /// A calendar is fully synced again when its last full sync is older than this,
    /// so the 3-months-back / 12-months-ahead window moves forward.
    static let fullSyncMaxAge: TimeInterval = 7 * 86_400

    public init(tokens: any TokenProvider, database: AppDatabase, session: URLSession = .shared,
                interval: Duration = .seconds(120)) {
        self.api = GoogleAPI(tokens: tokens, session: session)
        self.database = database
        self.interval = interval
    }

    /// Syncs now, then every `interval`. After failed syncs the wait doubles, up to 30 minutes.
    public func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let delay = await self.syncAndNextDelay()
                try? await Task.sleep(for: delay)
            }
        }
    }

    /// Called after every pass, including the timed ones, e.g. to update a "synced at" time.
    public func setOnPassFinished(_ handler: (@Sendable () async -> Void)?) {
        onPassFinished = handler
    }

    public func stop() {
        loop?.cancel()
        loop = nil
    }

    /// Returns after a pass that started after this call, so it sees accounts added just before.
    /// If a pass is running, one more pass runs after it; all callers meanwhile share that pass.
    public func syncNow() async {
        if let running {
            let next = queued?.task ?? startPass(after: running.task)
            _ = await next.value
        } else {
            _ = await startPass(after: nil).value
        }
    }

    /// True while a follow-up pass is waiting for the running one. For tests.
    var hasQueuedPass: Bool { queued != nil }

    private func syncAndNextDelay() async -> Duration {
        let ok = await runSync()
        failures = ok ? 0 : failures + 1
        guard failures > 0 else { return interval }
        let backoff = interval * (1 << min(failures, 4))
        return min(backoff, .seconds(30 * 60))
    }

    /// Joins the running pass or starts one. Returns false if any account hit an error other than needing sign-in.
    private func runSync() async -> Bool {
        if let running { return await running.task.value }
        return await startPass(after: nil).value
    }

    private func startPass(after previous: Task<Bool, Never>?) -> Task<Bool, Never> {
        passCount += 1
        let id = passCount
        let task = Task { [api, database] () -> Bool in
            if let previous { _ = await previous.value }
            let ok = await Self.syncAll(api: api, database: database)
            await self.finishPass(id)
            return ok
        }
        if previous == nil { running = (id, task) } else { queued = (id, task) }
        return task
    }

    /// The waiting pass becomes the running one as soon as the current one ends.
    private func finishPass(_ id: Int) async {
        if running?.id == id {
            running = queued
            queued = nil
        }
        await onPassFinished?()
    }

    private static func syncAll(api: GoogleAPI, database: AppDatabase) async -> Bool {
        let emails = await api.tokens.signedInEmails()
        for email in emails where await isSignedIn(email, api: api) {
            try? await database.ensureAccount(email)
        }
        let ok = await withTaskGroup(of: Bool.self) { group in
            for email in emails {
                group.addTask { await syncAccount(email, api: api, database: database) }
            }
            var allOK = true
            for await ok in group { allOK = allOK && ok }
            return allOK
        }
        // An account removed during the pass may have been written again; drop what's left of it.
        for email in emails where !(await isSignedIn(email, api: api)) {
            try? await database.removeAccount(email)
        }
        return ok
    }

    static func isSignedIn(_ email: String, api: GoogleAPI) async -> Bool {
        await api.tokens.signedInEmails().contains(email)
    }

    /// Syncs one account and records its status. Cached events are kept on failure.
    /// A failing calendar only records its own error; the account is marked as failed (and the
    /// engine backs off) only when the account-wide calls fail or the network is down.
    static func syncAccount(_ email: String, api: GoogleAPI, database: AppDatabase) async -> Bool {
        do {
            let palette = try await api.eventPalette(account: email)
            let entries = try await api.calendarList(account: email)
            guard await isSignedIn(email, api: api) else { return true }
            try await database.savePalette(palette)
            let calendars = try await database.applyCalendarList(account: email, entries: entries)
            for calendar in calendars {
                do {
                    try await syncCalendar(calendar, api: api, database: database)
                    try await database.setCalendarError(calendar.id, nil)
                } catch let error as AlmanacError {
                    if case .needsSignIn = error { throw error }
                    // Rate limits and server errors aren't about this calendar: fail the account so the engine backs off.
                    if isAccountLevel(error) { throw error }
                    try await database.setCalendarError(calendar.id, message(for: error))
                } catch let error as URLError {
                    throw error
                } catch {
                    try await database.setCalendarError(calendar.id, message(for: error))
                }
            }
            guard await isSignedIn(email, api: api) else { return true }
            try? await database.setAccountStatus(email, .ok)
            return true
        } catch AlmanacError.needsSignIn {
            try? await database.setAccountStatus(email, .needsSignIn)
            return true
        } catch {
            try? await database.setAccountStatus(email, .error(message(for: error)))
            return false
        }
    }

    /// 429, 5xx and 403 rate-limit errors.
    static func isAccountLevel(_ error: AlmanacError) -> Bool {
        guard case .api(let status, let message) = error else { return false }
        if status == 429 || status >= 500 { return true }
        return status == 403 && message.localizedCaseInsensitiveContains("rate limit")
    }

    static func message(for error: Error) -> String {
        if case AlmanacError.api(let status, let message) = error {
            return message.isEmpty ? "Google returned error \(status)" : message
        }
        return error.localizedDescription
    }

    /// Full sync the first time, after 410 and once a week; otherwise only the sync token.
    static func syncCalendar(_ calendar: CalendarRecord, api: GoogleAPI, database: AppDatabase,
                             now: Date = Date()) async throws {
        let state = try await database.syncState(calendarID: calendar.id)
        let fresh = state?.lastFullSync.map { now.timeIntervalSince1970 - $0 < fullSyncMaxAge } ?? false
        if let token = state?.syncToken, fresh {
            do {
                let started = Date()
                let result = try await api.listEvents(account: calendar.accountEmail, calendarID: calendar.externalID,
                                                      query: [("syncToken", token), ("singleEvents", "true")])
                try await database.applyChanges(calendarID: calendar.id, accountEmail: calendar.accountEmail,
                                                 events: result.events, syncToken: result.syncToken,
                                                 fetchStartedAt: started)
                return
            } catch AlmanacError.api(status: 410, _) {
                // Token expired: sync fully again. The cached events stay until that succeeds.
                try await database.clearSyncToken(calendar.id)
            }
        }
        let cal = Calendar.current
        let timeMin = cal.date(byAdding: .month, value: -3, to: now) ?? now
        let timeMax = cal.date(byAdding: .month, value: 12, to: now) ?? now
        let started = Date()
        let result = try await api.listEvents(account: calendar.accountEmail, calendarID: calendar.externalID, query: [
            ("singleEvents", "true"),
            ("timeMin", GoogleDates.formatDateTime(timeMin, timeZone: .gmt)),
            ("timeMax", GoogleDates.formatDateTime(timeMax, timeZone: .gmt)),
        ])
        try await database.replaceEvents(calendarID: calendar.id, accountEmail: calendar.accountEmail,
                                          events: result.events, syncToken: result.syncToken, fetchStartedAt: started)
    }
}
