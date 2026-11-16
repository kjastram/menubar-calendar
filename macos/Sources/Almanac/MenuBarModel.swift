import AlmanacKit
import Foundation
import Observation

/// What the menu bar item shows. Same rules as `render()` in calendar.1m.py.
enum MenuBarTitle: Equatable {
    /// Countdown or time-left text, with the account color and whether the event has a meeting link.
    case event(text: String, color: String, hasMeetLink: Bool)
    case icon(warning: Bool)
}

/// Text helpers matching the plugin's `clean`, `short`, `delta` and `hm`.
enum MenuText {
    static func clean(_ text: String) -> String {
        let joined = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return joined.isEmpty ? "(No title)" : joined
    }

    static func short(_ text: String, max: Int) -> String {
        let text = clean(text)
        guard max > 1, text.count > max else { return text }
        let cut = String(text.prefix(max - 1))
        return cut.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) + "…"
    }

    /// "12m", "1h", "1h 5m". Never less than 1m.
    static func delta(_ seconds: TimeInterval) -> String {
        let mins = Swift.max(1, Int((seconds / 60).rounded()))
        if mins < 60 { return "\(mins)m" }
        let (h, m) = mins.quotientAndRemainder(dividingBy: 60)
        return m == 0 ? "\(h)h" : "\(h)h \(m)m"
    }

    static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }
}

/// Live data for the menu bar label and popover: today's and tomorrow's items, accounts and their problems.
/// Re-reads the cache when it changes and ticks every minute for the countdown.
@MainActor @Observable
final class MenuBarModel {
    private(set) var now = Date()
    private(set) var items: [CalendarItem] = []
    private(set) var accounts: [Account] = []
    private(set) var calendars: [CalendarInfo] = []
    /// From the auth service: accounts whose refresh token is missing or rejected.
    private(set) var needsSignIn: Set<String> = []
    /// Calendar id → last sync error, for visible calendars ("Couldn't load <calendar>" like the plugin).
    private(set) var calendarErrors: [String: String] = [:]
    /// False until the first read finished, so the label doesn't flash a warning at launch.
    private(set) var loaded = false

    @ObservationIgnored private var repository: (any CalendarRepository)?
    @ObservationIgnored private var signInCheck: (@Sendable () async -> Set<String>)?
    @ObservationIgnored private var errorCheck: (@Sendable () async -> [String: String])?
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []

    func attach(repository: any CalendarRepository, needsSignIn: (@Sendable () async -> Set<String>)?,
                calendarErrors: (@Sendable () async -> [String: String])? = nil) {
        tasks.forEach { $0.cancel() }
        self.repository = repository
        self.signInCheck = needsSignIn
        self.errorCheck = calendarErrors
        tasks = [
            Task { [weak self] in
                for await _ in repository.changes() {
                    await self?.reload()
                }
            },
            Task { [weak self] in
                while !Task.isCancelled {
                    // Wake just after the next whole minute so the countdown matches the clock.
                    let seconds = 60 - Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 60) + 0.5
                    try? await Task.sleep(for: .seconds(seconds))
                    guard let self else { return }
                    self.now = Date()
                    await self.reload()
                }
            },
        ]
    }

    func detach() {
        tasks.forEach { $0.cancel() }
        tasks = []
        repository = nil
        signInCheck = nil
        errorCheck = nil
        calendarErrors = [:]
        items = []
        accounts = []
        calendars = []
        needsSignIn = []
        loaded = false
    }

    func reload() async {
        guard let repository else { return }
        now = Date()
        let start = Calendar.current.startOfDay(for: now)
        let end = Calendar.current.date(byAdding: .day, value: 2, to: start) ?? start.addingTimeInterval(172_800)
        do {
            async let items = repository.items(in: DateInterval(start: start, end: end))
            async let accounts = repository.accounts()
            async let calendars = repository.calendars()
            (self.items, self.accounts, self.calendars) = try await (items, accounts, calendars)
        } catch {
            // Keep the last good data; the account rows show sync errors.
        }
        if let signInCheck { needsSignIn = await signInCheck() }
        if let errorCheck { calendarErrors = await errorCheck() }
        loaded = true
    }

    // MARK: - Derived

    var activeAccounts: [Account] { accounts.filter { !$0.hidden } }

    /// Visible accounts that need sign-in or failed their last sync.
    var problems: [(email: String, needsSignIn: Bool, message: String?)] {
        activeAccounts.compactMap { account in
            if needsSignIn.contains(account.email) || account.status == .needsSignIn {
                return (account.email, true, nil)
            }
            if case .error(let message) = account.status { return (account.email, false, message) }
            return nil
        }
    }

    /// Visible calendars whose last sync failed, by name.
    var failedCalendars: [(id: String, name: String, message: String)] {
        calendars.compactMap { calendar in
            calendarErrors[calendar.id].map { (calendar.id, calendar.name, $0) }
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func color(for item: CalendarItem) -> String {
        accounts.first { $0.email == item.accountEmail }?.color ?? item.color
    }

    func calendarName(for item: CalendarItem) -> String {
        calendars.first { $0.id == item.calendarID }?.name ?? item.accountEmail
    }

    var timed: [CalendarItem] { items.filter { !$0.isAllDay }.sorted { $0.start < $1.start } }
    var ongoing: [CalendarItem] { timed.filter { $0.start <= now && now < $0.end } }
    var upcoming: [CalendarItem] { timed.filter { $0.start > now } }
    /// All events that share the earliest upcoming start time.
    var next: [CalendarItem] {
        let upcoming = upcoming
        guard let first = upcoming.first else { return [] }
        return upcoming.filter { $0.start == first.start }
    }

    func allDay(on day: Date) -> [CalendarItem] {
        let start = Calendar.current.startOfDay(for: day)
        return items.filter { $0.isAllDay && $0.start <= start && start < $0.end }
    }

    func timed(on day: Date) -> [CalendarItem] {
        timed.filter { Calendar.current.isDate($0.start, inSameDayAs: day) }
    }

    var tomorrow: Date { Calendar.current.date(byAdding: .day, value: 1, to: now) ?? now.addingTimeInterval(86_400) }

    func title(lookaheadMinutes: Int, titleLength: Int, showNextEvent: Bool, setupNeeded: Bool) -> MenuBarTitle {
        if showNextEvent && !setupNeeded {
            if let event = next.first, event.start.timeIntervalSince(now) <= TimeInterval(lookaheadMinutes * 60) {
                let text = "\(MenuText.short(event.title, max: titleLength)) in \(MenuText.delta(event.start.timeIntervalSince(now)))"
                return .event(text: text, color: color(for: event), hasMeetLink: event.meetURL != nil)
            }
            if let event = ongoing.min(by: { $0.end < $1.end }) {
                let text = "\(MenuText.short(event.title, max: titleLength)) · \(MenuText.delta(event.end.timeIntervalSince(now))) left"
                return .event(text: text, color: color(for: event), hasMeetLink: event.meetURL != nil)
            }
        }
        return .icon(warning: setupNeeded || (loaded && (accounts.isEmpty || !problems.isEmpty)))
    }
}
