import Foundation
import Observation
import AlmanacKit

/// What the event sheet is showing.
public enum EventFormMode: Identifiable, Hashable, Sendable {
    /// New event. `start` is the prefilled start time.
    case create(start: Date)
    case edit(CalendarItem)

    public var id: String {
        switch self {
        case .create(let start): "create:\(start.timeIntervalSinceReferenceDate)"
        case .edit(let item): "edit:\(item.id)"
        }
    }
}

/// State for the main window: displayed month, selected day and item, visible items,
/// search, and writes with optimistic updates.
@MainActor @Observable
public final class CalendarStore {
    @ObservationIgnored private let repository: any CalendarRepository
    @ObservationIgnored private let source: any ItemSource
    @ObservationIgnored private let sync: any SyncControl

    /// The calendar used for all date math (week start, day boundaries).
    public var calendar: Calendar { .current }

    /// Local midnight of the selected day. Setting a day outside the grid moves the grid.
    public var selectedDay: Date {
        didSet {
            let normalized = calendar.startOfDay(for: selectedDay)
            if normalized != selectedDay { selectedDay = normalized; return }
            if !gridInterval.contains(selectedDay) {
                displayedMonth = CalendarMath.startOfMonth(selectedDay, calendar: calendar)
            }
            if let item = selectedItem, !CalendarMath.occurs(item, on: selectedDay, calendar: calendar) {
                selectedItemID = nil
            }
        }
    }

    /// First of the month shown in the grid. Changing it reloads items.
    public var displayedMonth: Date {
        didSet {
            let normalized = CalendarMath.startOfMonth(displayedMonth, calendar: calendar)
            if normalized != displayedMonth { displayedMonth = normalized; return }
            if normalized != oldValue { requestReload() }
        }
    }

    public private(set) var accounts: [Account] = []
    public private(set) var calendars: [CalendarInfo] = []
    /// Items for the displayed month's 6-week grid.
    public private(set) var items: [CalendarItem] = []
    /// `items` split by day (keyed by local midnight), sorted for display.
    public private(set) var itemsByDay: [Date: [CalendarItem]] = [:]
    /// Message for the non-modal error banner.
    public var lastError: String?

    public var selectedItemID: String?

    public var searchText: String = "" {
        didSet { if searchText != oldValue { scheduleSearch() } }
    }
    public private(set) var searchResults: [CalendarItem] = []
    public private(set) var isSearchLoading = false

    /// Set to show the event sheet.
    public var form: EventFormMode?
    /// Set to ask "Delete ‘Title’?".
    public var pendingDeletion: CalendarItem?

    public private(set) var isSyncing = false
    /// When the cache last delivered fresh data.
    public private(set) var lastUpdated: Date?
    /// Bumped by `requestSearchFocus()`; the window focuses the search field when it changes.
    public private(set) var searchFocusRequest = 0

    /// The calendar picked in Settings. Setting it forgets the last used calendar, so the new
    /// default wins until another calendar is used.
    public var defaultCalendarID: String? {
        didSet { lastUsedCalendarID = nil }
    }
    @ObservationIgnored private var lastUsedCalendarID: String?

    private enum PendingChange {
        /// A create that hasn't returned yet. `knownIDs` are the cached items' ids when it started,
        /// so a reload that already has the real item can be told apart from an older look-alike.
        case insert(CalendarItem, knownIDs: Set<String>)
        case replace(oldID: String, with: CalendarItem)
        case remove(String)
    }
    @ObservationIgnored private var pending: [(UUID, PendingChange)] = []
    @ObservationIgnored private var fetchedItems: [CalendarItem] = []
    @ObservationIgnored private var changesTask: Task<Void, Never>?
    @ObservationIgnored private var reloadTask: Task<Void, Never>?
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var reloadGeneration = 0

    public init(repository: any CalendarRepository, source: any ItemSource, sync: any SyncControl) {
        self.repository = repository
        self.source = source
        self.sync = sync
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        self.selectedDay = today
        self.displayedMonth = CalendarMath.startOfMonth(today, calendar: cal)
    }

    // MARK: Loading

    /// Subscribes to `repository.changes()` and reloads the visible range on every change.
    /// Safe to call more than once.
    public func start() {
        guard changesTask == nil else { return }
        let stream = repository.changes()
        changesTask = Task { [weak self] in
            for await _ in stream {
                guard let self else { return }
                await self.reload()
            }
        }
    }

    public var gridDays: [Date] {
        CalendarMath.monthGridDays(forMonth: displayedMonth, calendar: calendar)
    }

    public var gridInterval: DateInterval {
        CalendarMath.gridInterval(forMonth: displayedMonth, calendar: calendar)
    }

    private func requestReload() {
        reloadTask?.cancel()
        reloadTask = Task { [weak self] in await self?.reload() }
    }

    /// Reads accounts, calendars and the grid's items from the cache.
    public func reload() async {
        reloadGeneration += 1
        let generation = reloadGeneration
        let interval = gridInterval
        do {
            let accounts = try await repository.accounts()
            let calendars = try await repository.calendars()
            let fetched = try await repository.items(in: interval)
            guard generation == reloadGeneration else { return }
            self.accounts = accounts
            self.calendars = calendars
            self.fetchedItems = fetched
            self.lastUpdated = Date()
            rebuildItems()
        } catch {
            guard generation == reloadGeneration else { return }
            lastError = "Couldn't read the calendar cache: \(Self.message(error))"
        }
    }

    /// Applies pending optimistic changes on top of what the cache returned.
    private func rebuildItems() {
        var result = fetchedItems
        for (_, change) in pending {
            switch change {
            case .insert(let item, let knownIDs):
                // The real item can reach the cache (and a reload) before source.create returns.
                if result.contains(where: {
                    !knownIDs.contains($0.id) && !isPendingID($0.id) && Self.isSameEvent($0, item)
                }) { continue }
                result.removeAll { $0.id == item.id }
                result.append(item)
            case .replace(let oldID, let item):
                result.removeAll { $0.id == oldID || $0.id == item.id }
                result.append(item)
            case .remove(let id):
                result.removeAll { $0.id == id }
            }
        }
        let hiddenAccounts = Set(accounts.filter(\.hidden).map(\.email))
        let hiddenCalendars = Set(calendars.filter { !$0.visible }.map(\.id))
        let interval = gridInterval
        result = result.filter {
            !hiddenAccounts.contains($0.accountEmail) && !hiddenCalendars.contains($0.calendarID)
                && ($0.overlaps(interval) || ($0.start == $0.end && interval.contains($0.start)))
        }
        result.sort { a, b in
            let da = calendar.startOfDay(for: a.start), db = calendar.startOfDay(for: b.start)
            return da != db ? da < db : CalendarMath.dayOrder(a, b)
        }
        items = result
        itemsByDay = CalendarMath.itemsByDay(result, days: gridDays, calendar: calendar)
    }

    // MARK: Lookup

    public func items(on day: Date) -> [CalendarItem] {
        itemsByDay[calendar.startOfDay(for: day)] ?? []
    }

    public var selectedDayItems: [CalendarItem] { items(on: selectedDay) }

    public var selectedItem: CalendarItem? {
        guard let id = selectedItemID else { return nil }
        return items.first { $0.id == id } ?? searchResults.first { $0.id == id }
    }

    public func calendarInfo(id: String) -> CalendarInfo? {
        calendars.first { $0.id == id }
    }

    public func account(email: String) -> Account? {
        accounts.first { $0.email == email }
    }

    /// Calendars that new events can go into: writable, from accounts that aren't hidden.
    public var writableCalendars: [CalendarInfo] {
        let hidden = Set(accounts.filter(\.hidden).map(\.email))
        return calendars.filter { $0.canWrite && !hidden.contains($0.accountEmail) }
    }

    /// For the event sheet: last used calendar, then the settings default, then the first primary
    /// writable calendar.
    public var preferredCalendarID: String? {
        firstWritable([lastUsedCalendarID, defaultCalendarID])
    }

    /// For the menu bar's quick add: the settings default, then the last used calendar, then the
    /// first primary writable calendar.
    public var quickAddCalendarID: String? {
        firstWritable([defaultCalendarID, lastUsedCalendarID])
    }

    private func firstWritable(_ candidates: [String?]) -> String? {
        let writable = writableCalendars
        for candidate in candidates {
            if let candidate, writable.contains(where: { $0.id == candidate }) { return candidate }
        }
        return (writable.first(where: \.isPrimary) ?? writable.first)?.id
    }

    /// Calendars grouped by account, in account order.
    public var calendarGroups: [(account: Account, calendars: [CalendarInfo])] {
        var groups = accounts.map { account in
            (account: account, calendars: calendars.filter { $0.accountEmail == account.email })
        }
        let known = Set(accounts.map(\.email))
        let orphans = Dictionary(grouping: calendars.filter { !known.contains($0.accountEmail) }, by: \.accountEmail)
        for email in orphans.keys.sorted() {
            groups.append((account: Account(email: email, color: "#888888"), calendars: orphans[email] ?? []))
        }
        return groups
    }

    /// Editable in v1: not recurring, from a writable calendar, from this store's source.
    public func canEdit(_ item: CalendarItem) -> Bool {
        guard !item.isRecurring, !isPendingID(item.id), item.source == source.kind else { return false }
        return calendarInfo(id: item.calendarID)?.canWrite ?? false
    }

    /// Recurring items can't be deleted from the app in v1 either (they open in Google Calendar).
    public func canDelete(_ item: CalendarItem) -> Bool { canEdit(item) }

    public func isReadOnly(_ item: CalendarItem) -> Bool {
        !(calendarInfo(id: item.calendarID)?.canWrite ?? false)
    }

    private func isPendingID(_ id: String) -> Bool { id.hasPrefix("pending:") }

    // MARK: Navigation

    public func nextMonth() { displayedMonth = CalendarMath.addingMonths(1, to: displayedMonth, calendar: calendar) }
    public func previousMonth() { displayedMonth = CalendarMath.addingMonths(-1, to: displayedMonth, calendar: calendar) }

    public func goToToday() {
        let today = calendar.startOfDay(for: Date())
        displayedMonth = CalendarMath.startOfMonth(today, calendar: calendar)
        selectedDay = today
    }

    /// Selects a day shown in the grid (clicking a day from the next month does not move the grid).
    public func select(day: Date) {
        selectedDay = calendar.startOfDay(for: day)
    }

    /// Arrow-key movement. Moves the grid when the selection leaves the displayed month.
    public func moveSelection(byDays days: Int) {
        let target = CalendarMath.addingDays(days, to: selectedDay, calendar: calendar)
        let month = CalendarMath.startOfMonth(target, calendar: calendar)
        if month != displayedMonth { displayedMonth = month }
        selectedDay = target
    }

    public func select(item: CalendarItem) {
        selectedItemID = item.id
    }

    /// Jumps to an item's day and selects it (search results, menu bar).
    public func reveal(_ item: CalendarItem) {
        let day = calendar.startOfDay(for: item.start)
        displayedMonth = CalendarMath.startOfMonth(day, calendar: calendar)
        selectedDay = day
        selectedItemID = item.id
    }

    /// Selects the first item of the selected day when nothing is selected.
    public func selectFirstItemOfDay() {
        selectedItemID = selectedDayItems.first?.id
    }

    public func requestSearchFocus() { searchFocusRequest += 1 }

    // MARK: Sheets

    /// Opens the new event sheet. With a day: 9:00 AM that day. Without: the selected day
    /// (next full hour if it's today, else 9:00 AM).
    public func newEvent(on day: Date? = nil) {
        let start = day.map { CalendarMath.nineAM(on: $0, calendar: calendar) }
            ?? CalendarMath.defaultStart(on: selectedDay, calendar: calendar)
        form = .create(start: start)
    }

    public func edit(_ item: CalendarItem) {
        guard canEdit(item) else { return }
        form = .edit(item)
    }

    public func requestDelete(_ item: CalendarItem) {
        guard canDelete(item) else { return }
        pendingDeletion = item
    }

    // MARK: Sync

    public func syncNow() {
        guard !isSyncing else { return }
        isSyncing = true
        Task { [weak self] in
            guard let self else { return }
            await self.sync.syncNow()
            self.isSyncing = false
            await self.reload()
        }
    }

    // MARK: Visibility

    public func setCalendarVisible(_ calendarID: String, visible: Bool) {
        guard let index = calendars.firstIndex(where: { $0.id == calendarID }) else { return }
        let old = calendars[index].visible
        guard old != visible else { return }
        calendars[index].visible = visible
        rebuildItems()
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.repository.setCalendarVisible(calendarID, visible: visible)
                await self.reload()
            } catch {
                if let i = self.calendars.firstIndex(where: { $0.id == calendarID }) { self.calendars[i].visible = old }
                self.rebuildItems()
                self.lastError = "Couldn't change the calendar: \(Self.message(error))"
            }
        }
    }

    public func setAccountHidden(_ email: String, hidden: Bool) {
        guard let index = accounts.firstIndex(where: { $0.email == email }) else { return }
        let old = accounts[index].hidden
        guard old != hidden else { return }
        accounts[index].hidden = hidden
        rebuildItems()
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.repository.setAccountHidden(email, hidden: hidden)
                await self.reload()
            } catch {
                if let i = self.accounts.firstIndex(where: { $0.email == email }) { self.accounts[i].hidden = old }
                self.rebuildItems()
                self.lastError = "Couldn't change the account: \(Self.message(error))"
            }
        }
    }

    // MARK: Writes (optimistic, rolled back on error)

    @discardableResult
    public func create(_ draft: EventDraft) async -> CalendarItem? {
        guard let info = calendarInfo(id: draft.calendarID) else {
            lastError = "Pick a calendar for the event."
            return nil
        }
        lastUsedCalendarID = draft.calendarID
        let token = UUID()
        let temp = CalendarItem(
            id: "pending:\(token.uuidString)", source: source.kind, externalID: "", calendarID: info.id,
            accountEmail: info.accountEmail, title: draft.title, start: draft.start, end: draft.end,
            isAllDay: draft.isAllDay, location: Self.nonEmpty(draft.location), notes: Self.nonEmpty(draft.notes),
            color: info.color)
        pending.append((token, .insert(temp, knownIDs: Set(fetchedItems.map(\.id)))))
        reveal(temp)
        rebuildItems()
        do {
            let created = try await source.create(draft)
            fetchedItems.removeAll { $0.id == created.id }
            fetchedItems.append(created)
            finish(token)
            if selectedItemID == temp.id { selectedItemID = created.id }
            refreshSearch()
            return created
        } catch {
            finish(token)
            if selectedItemID == temp.id { selectedItemID = nil }
            lastError = "Couldn't create “\(draft.title)”: \(Self.message(error))"
            return nil
        }
    }

    @discardableResult
    public func update(_ item: CalendarItem, with draft: EventDraft) async -> CalendarItem? {
        guard canEdit(item) else {
            lastError = item.isRecurring ? AlmanacError.recurringNotSupported.localizedDescription
                : AlmanacError.readOnlyCalendar.localizedDescription
            return nil
        }
        lastUsedCalendarID = draft.calendarID
        var optimistic = item
        optimistic.title = draft.title
        optimistic.start = draft.start
        optimistic.end = draft.end
        optimistic.isAllDay = draft.isAllDay
        optimistic.location = Self.nonEmpty(draft.location)
        optimistic.notes = Self.nonEmpty(draft.notes)
        if let info = calendarInfo(id: draft.calendarID), info.id != item.calendarID {
            optimistic.calendarID = info.id
            optimistic.accountEmail = info.accountEmail
            optimistic.color = info.color
        }
        let token = UUID()
        pending.append((token, .replace(oldID: item.id, with: optimistic)))
        rebuildItems()
        do {
            let updated = try await source.update(item, with: draft)
            fetchedItems.removeAll { $0.id == item.id || $0.id == updated.id }
            fetchedItems.append(updated)
            finish(token)
            if selectedItemID == item.id { selectedItemID = updated.id }
            refreshSearch()
            return updated
        } catch {
            finish(token)
            lastError = "Couldn't save “\(item.title)”: \(Self.message(error))"
            return nil
        }
    }

    @discardableResult
    public func delete(_ item: CalendarItem) async -> Bool {
        if pendingDeletion?.id == item.id { pendingDeletion = nil }
        guard canDelete(item) else {
            lastError = item.isRecurring ? AlmanacError.recurringNotSupported.localizedDescription
                : AlmanacError.readOnlyCalendar.localizedDescription
            return false
        }
        let token = UUID()
        pending.append((token, .remove(item.id)))
        if selectedItemID == item.id { selectedItemID = nil }
        rebuildItems()
        do {
            try await source.delete(item)
            fetchedItems.removeAll { $0.id == item.id }
            finish(token)
            refreshSearch()
            return true
        } catch {
            finish(token)
            lastError = "Couldn't delete “\(item.title)”: \(Self.message(error))"
            return false
        }
    }

    /// Google's quick add. Not optimistic (Google parses the date); selects the new event on success.
    /// Returns the error message on failure so the sheet can show it inline.
    public func quickAdd(_ text: String, calendarID: String) async -> Result<CalendarItem, QuickAddError> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(QuickAddError(message: "Type something to add.")) }
        lastUsedCalendarID = calendarID
        do {
            let created = try await source.quickAdd(trimmed, calendarID: calendarID)
            fetchedItems.removeAll { $0.id == created.id }
            fetchedItems.append(created)
            reveal(created)
            rebuildItems()
            refreshSearch()
            return .success(created)
        } catch {
            return .failure(QuickAddError(message: Self.message(error)))
        }
    }

    private func finish(_ token: UUID) {
        pending.removeAll { $0.0 == token }
        rebuildItems()
    }

    // MARK: Search

    public var isSearchActive: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public func clearSearch() { searchText = "" }

    private func scheduleSearch() {
        searchTask?.cancel()
        let text = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            searchResults = []
            isSearchLoading = false
            return
        }
        isSearchLoading = true
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled, let self else { return }
            do {
                let results = try await self.repository.search(text, limit: 200)
                guard !Task.isCancelled else { return }
                self.searchResults = results
            } catch {
                guard !Task.isCancelled else { return }
                self.searchResults = []
                self.lastError = "Search failed: \(Self.message(error))"
            }
            self.isSearchLoading = false
        }
    }

    private func refreshSearch() {
        if isSearchActive { scheduleSearch() }
    }

    // MARK: Helpers

    /// Same calendar, title and times: how a pending create recognizes its real item.
    private static func isSameEvent(_ a: CalendarItem, _ b: CalendarItem) -> Bool {
        a.calendarID == b.calendarID && a.title == b.title && a.start == b.start && a.end == b.end
            && a.isAllDay == b.isAllDay
    }

    private static func nonEmpty(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func message(_ error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}

public struct QuickAddError: Error, Sendable, Hashable {
    public var message: String
}
