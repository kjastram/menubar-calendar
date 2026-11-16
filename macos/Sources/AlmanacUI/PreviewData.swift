import Foundation
import AlmanacKit

/// In-memory fake data for launching the window without Google or the database.
///
///     let store = PreviewData.makeStore()
///     MainWindowView(store: store)
public enum PreviewData {
    public static let personalEmail = "kyle@example.com"
    public static let workEmail = "kyle@work.example.com"
    public static let oldEmail = "old@example.com"

    public static let accounts: [Account] = [
        Account(email: personalEmail, color: accountPalette[0]),
        Account(email: workEmail, color: accountPalette[1]),
        Account(email: oldEmail, color: accountPalette[2], hidden: true, status: .needsSignIn),
    ]

    public static let calendars: [CalendarInfo] = [
        calendar(personalEmail, personalEmail, "Personal", "#2F6FEB", "owner", primary: true),
        calendar(personalEmail, "birthdays", "Birthdays", "#8B5CF6", "reader"),
        calendar(personalEmail, "holidays", "Holidays in US", "#2E9E5B", "reader"),
        calendar(personalEmail, "gym", "Gym", "#2CC6C6", "owner", visible: false),
        calendar(workEmail, workEmail, "Work", "#E8782A", "owner", primary: true),
        calendar(workEmail, "ooo", "Team out-of-office", "#C2410C", "writer"),
        calendar(oldEmail, oldEmail, "Old personal", "#3FB950", "owner", primary: true),
    ]

    private static func calendar(_ email: String, _ googleID: String, _ name: String, _ color: String,
                                 _ role: String, visible: Bool = true, primary: Bool = false) -> CalendarInfo {
        CalendarInfo(id: CalendarInfo.localID(accountEmail: email, googleID: googleID), accountEmail: email,
                     googleID: googleID, name: name, color: color, accessRole: role, visible: visible, isPrimary: primary)
    }

    /// Sample items spread around `reference`'s month: holidays, a birthday, a 3-day trip,
    /// weekday standups (recurring, with Meet), a busy reference day for "+N more", a tentative
    /// event and one that crosses midnight.
    public static func sampleItems(around reference: Date = Date(), calendar: Calendar = .current) -> [CalendarItem] {
        let today = calendar.startOfDay(for: reference)
        var result: [CalendarItem] = []
        var counter = 0

        func day(_ offset: Int) -> Date { CalendarMath.addingDays(offset, to: today, calendar: calendar) }
        func at(_ offset: Int, _ hour: Int, _ minute: Int = 0) -> Date {
            calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day(offset)) ?? day(offset)
        }
        func add(_ title: String, _ calendarIndex: Int, start: Date, end: Date, allDay: Bool = false,
                 location: String? = nil, notes: String? = nil, meet: Bool = false,
                 tentative: Bool = false, recurring: Bool = false) {
            counter += 1
            let info = calendars[calendarIndex]
            let externalID = "evt\(counter)"
            result.append(CalendarItem(
                id: "google:\(info.id):\(externalID)", source: .google, externalID: externalID,
                calendarID: info.id, accountEmail: info.accountEmail, title: title, start: start, end: end,
                isAllDay: allDay, location: location, notes: notes,
                meetURL: meet ? URL(string: "https://meet.google.com/abc-defg-hij") : nil,
                webURL: URL(string: "https://calendar.google.com/calendar/r/eventedit/\(externalID)?authuser=\(info.accountEmail)"),
                color: info.color, isTentative: tentative, isRecurring: recurring, etag: "\"1\""))
        }

        add("Holiday", 2, start: day(-9), end: day(-8), allDay: true)
        add("Long weekend", 2, start: day(12), end: day(13), allDay: true)
        add("Mom's birthday", 1, start: day(5), end: day(6), allDay: true)
        add("Trip to Chicago", 0, start: day(9), end: day(12), allDay: true, location: "Chicago")
        add("Priya out", 5, start: day(6), end: day(7), allDay: true)

        for offset in -35...40 {
            let weekday = calendar.component(.weekday, from: day(offset))
            guard weekday != 1 && weekday != 7 else { continue }
            add("Standup", 4, start: at(offset, 9, 30), end: at(offset, 9, 45), meet: true, recurring: true)
        }

        add("Long run", 0, start: at(0, 8), end: at(0, 9, 15), location: "Riverside loop")
        add("Lunch with Sam", 0, start: at(0, 12, 30), end: at(0, 13, 30), location: "Corner Café",
            notes: "Bring the book I borrowed.")
        add("Call with Dad", 0, start: at(0, 15), end: at(0, 15, 30), meet: true)
        add("Movie night", 0, start: at(0, 19, 30), end: at(0, 22))
        add("Design review", 4, start: at(-3, 14), end: at(-3, 15), meet: true)
        add("Dentist", 0, start: at(-2, 10), end: at(-2, 11), location: "Elm St Dental")
        add("Sprint demo", 4, start: at(-1, 16), end: at(-1, 17), meet: true)
        add("1:1 with Priya", 4, start: at(2, 13), end: at(2, 13, 30), meet: true, tentative: true)
        add("Roadmap planning", 4, start: at(4, 15), end: at(4, 16, 30), notes: "Bring Q1 priorities.", meet: true)
        add("Night shift", 5, start: at(3, 22), end: at(4, 2))
        add("Flight to Chicago", 0, start: at(9, 5, 40), end: at(9, 8, 55), location: "SFO · Terminal 2")
        add("Quarterly review", 4, start: at(20, 11), end: at(20, 12), meet: true)
        add("Old team lunch", 6, start: at(1, 12), end: at(1, 13))
        return result
    }

    /// A store backed by the in-memory mocks. With `failWrites`, every write fails after a short
    /// delay, which shows the optimistic update and the rollback banner.
    @MainActor
    public static func makeStore(failWrites: Bool = false) -> CalendarStore {
        let repository = Repository()
        let store = CalendarStore(repository: repository,
                                  source: Source(repository: repository, failWrites: failWrites),
                                  sync: Sync(repository: repository))
        store.start()
        return store
    }

    // MARK: Mocks

    /// In-memory `CalendarRepository`.
    public actor Repository: CalendarRepository {
        private var accountList: [Account]
        private var calendarList: [CalendarInfo]
        private var allItems: [CalendarItem]
        private var continuations: [UUID: AsyncStream<Void>.Continuation] = [:]

        public init(accounts: [Account] = PreviewData.accounts,
                    calendars: [CalendarInfo] = PreviewData.calendars,
                    items: [CalendarItem] = PreviewData.sampleItems()) {
            self.accountList = accounts
            self.calendarList = calendars
            self.allItems = items
        }

        public func accounts() async throws -> [Account] { accountList }
        public func calendars() async throws -> [CalendarInfo] { calendarList }

        public func items(in interval: DateInterval) async throws -> [CalendarItem] {
            let hidden = Set(accountList.filter(\.hidden).map(\.email))
            let visible = Set(calendarList.filter(\.visible).map(\.id))
            return allItems
                .filter { visible.contains($0.calendarID) && !hidden.contains($0.accountEmail) && $0.overlaps(interval) }
                .sorted(by: CalendarMath.dayOrder)
        }

        public func search(_ text: String, limit: Int) async throws -> [CalendarItem] {
            let needle = text.lowercased()
            return Array(allItems.filter {
                $0.title.lowercased().contains(needle)
                    || ($0.location?.lowercased().contains(needle) ?? false)
                    || ($0.notes?.lowercased().contains(needle) ?? false)
            }.sorted { $0.start < $1.start }.prefix(limit))
        }

        public nonisolated func changes() -> AsyncStream<Void> {
            let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
            let id = UUID()
            continuation.yield()
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeContinuation(id) }
            }
            Task { await self.addContinuation(id, continuation) }
            return stream
        }

        public func setCalendarVisible(_ calendarID: String, visible: Bool) async throws {
            guard let i = calendarList.firstIndex(where: { $0.id == calendarID }) else { throw AlmanacError.notFound }
            calendarList[i].visible = visible
            notify()
        }

        public func setAccountColor(_ email: String, color: String) async throws {
            guard let i = accountList.firstIndex(where: { $0.email == email }) else { throw AlmanacError.notFound }
            accountList[i].color = color
            notify()
        }

        public func setAccountHidden(_ email: String, hidden: Bool) async throws {
            guard let i = accountList.firstIndex(where: { $0.email == email }) else { throw AlmanacError.notFound }
            accountList[i].hidden = hidden
            notify()
        }

        func calendar(id: String) -> CalendarInfo? { calendarList.first { $0.id == id } }

        func upsert(_ item: CalendarItem, replacing oldID: String? = nil) {
            allItems.removeAll { $0.id == item.id || $0.id == oldID }
            allItems.append(item)
            notify()
        }

        func remove(id: String) throws {
            guard allItems.contains(where: { $0.id == id }) else { throw AlmanacError.notFound }
            allItems.removeAll { $0.id == id }
            notify()
        }

        /// Tells subscribers something changed.
        public func notify() {
            for continuation in continuations.values { continuation.yield() }
        }

        private func addContinuation(_ id: UUID, _ continuation: AsyncStream<Void>.Continuation) {
            continuations[id] = continuation
        }

        private func removeContinuation(_ id: UUID) {
            continuations[id] = nil
        }
    }

    /// In-memory `ItemSource` that writes into a `Repository`.
    public actor Source: ItemSource {
        public nonisolated let kind: ItemSourceKind = .google
        private let repository: Repository
        private let failWrites: Bool
        private var counter = 0

        public init(repository: Repository, failWrites: Bool = false) {
            self.repository = repository
            self.failWrites = failWrites
        }

        public func create(_ draft: EventDraft) async throws -> CalendarItem {
            try await simulateNetwork()
            guard let info = await repository.calendar(id: draft.calendarID) else { throw AlmanacError.notFound }
            guard info.canWrite else { throw AlmanacError.readOnlyCalendar }
            let item = makeItem(info: info, title: draft.title, start: draft.start, end: draft.end,
                                isAllDay: draft.isAllDay, location: draft.location, notes: draft.notes,
                                meet: draft.addMeet)
            await repository.upsert(item)
            return item
        }

        public func update(_ item: CalendarItem, with draft: EventDraft) async throws -> CalendarItem {
            try await simulateNetwork()
            guard !item.isRecurring else { throw AlmanacError.recurringNotSupported }
            guard let info = await repository.calendar(id: draft.calendarID) else { throw AlmanacError.notFound }
            guard info.canWrite else { throw AlmanacError.readOnlyCalendar }
            var updated = item
            updated.title = draft.title
            updated.start = draft.start
            updated.end = draft.end
            updated.isAllDay = draft.isAllDay
            updated.location = draft.location.isEmpty ? nil : draft.location
            updated.notes = draft.notes.isEmpty ? nil : draft.notes
            if info.id != item.calendarID {
                updated.calendarID = info.id
                updated.accountEmail = info.accountEmail
                updated.color = info.color
                updated.id = "google:\(info.id):\(item.externalID)"
            }
            await repository.upsert(updated, replacing: item.id)
            return updated
        }

        public func delete(_ item: CalendarItem) async throws {
            try await simulateNetwork()
            try await repository.remove(id: item.id)
        }

        /// Fake parser: the whole sentence becomes the title, at the next full hour today.
        public func quickAdd(_ text: String, calendarID: String) async throws -> CalendarItem {
            try await simulateNetwork()
            guard let info = await repository.calendar(id: calendarID) else { throw AlmanacError.notFound }
            let start = CalendarMath.defaultStart(on: Date())
            let item = makeItem(info: info, title: text, start: start, end: start.addingTimeInterval(3600),
                                isAllDay: false, location: "", notes: "", meet: false)
            await repository.upsert(item)
            return item
        }

        private func simulateNetwork() async throws {
            try await Task.sleep(for: .milliseconds(500))
            if failWrites { throw AlmanacError.api(status: 503, message: "Preview: writes are set to fail.") }
        }

        private func makeItem(info: CalendarInfo, title: String, start: Date, end: Date, isAllDay: Bool,
                              location: String, notes: String, meet: Bool) -> CalendarItem {
            counter += 1
            let externalID = "new\(counter)-\(Int(Date().timeIntervalSince1970))"
            return CalendarItem(
                id: "google:\(info.id):\(externalID)", source: .google, externalID: externalID,
                calendarID: info.id, accountEmail: info.accountEmail, title: title, start: start, end: end,
                isAllDay: isAllDay, location: location.isEmpty ? nil : location, notes: notes.isEmpty ? nil : notes,
                meetURL: meet ? URL(string: "https://meet.google.com/new-meet-link") : nil,
                webURL: URL(string: "https://calendar.google.com/calendar/r?authuser=\(info.accountEmail)"),
                color: info.color, etag: "\"1\"")
        }
    }

    /// `SyncControl` that waits a moment and pings the repository.
    public actor Sync: SyncControl {
        private let repository: Repository

        public init(repository: Repository) { self.repository = repository }

        public func syncNow() async {
            try? await Task.sleep(for: .milliseconds(700))
            await repository.notify()
        }
    }
}
