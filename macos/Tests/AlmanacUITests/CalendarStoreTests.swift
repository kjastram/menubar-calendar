import Foundation
import Testing
import AlmanacKit
@testable import AlmanacUI

@MainActor
private func loadedStore(failWrites: Bool = false) async -> CalendarStore {
    await waitForItems(PreviewData.makeStore(failWrites: failWrites))
}

@MainActor
private func waitForItems(_ store: CalendarStore) async -> CalendarStore {
    // makeStore starts a background reload too; a newer reload makes an older one return early,
    // so wait for the data to show up instead of trusting one reload() call.
    for _ in 0..<200 where store.items.isEmpty {
        await store.reload()
        try? await Task.sleep(for: .milliseconds(10))
    }
    return store
}

/// The personal calendar is writable and visible; "Long run" is a plain event on it today.
@MainActor
private func editableItem(in store: CalendarStore) throws -> CalendarItem {
    let item = try #require(store.items.first { $0.title == "Long run" })
    try #require(store.canEdit(item))
    return item
}

@MainActor
private func draft(in store: CalendarStore, title: String,
                   calendarID: String = PreviewData.calendars[0].id) -> EventDraft {
    let start = store.calendar.date(bySettingHour: 11, minute: 0, second: 0, of: store.selectedDay)!
    return EventDraft(calendarID: calendarID, title: title,
                      start: start, end: start.addingTimeInterval(3600), isAllDay: false)
}

/// Lets the main actor run other tasks until `condition` holds (or gives up).
@MainActor
private func waitUntil(_ condition: () -> Bool) async {
    for _ in 0..<500 where !condition() { try? await Task.sleep(for: .milliseconds(1)) }
}

@MainActor
@Suite("CalendarStore writes")
struct CalendarStoreWriteTests {
    @Test func createShowsPendingItemRightAway() async throws {
        let store = await loadedStore()
        let task = Task { await store.create(draft(in: store, title: "Optimistic")) }
        await waitUntil { store.items.contains { $0.title == "Optimistic" } }
        let shown = try #require(store.items.first { $0.title == "Optimistic" })
        #expect(shown.id.hasPrefix("pending:"))
        _ = await task.value
    }

    @Test func createReplacesPendingItemWithRealOne() async throws {
        let store = await loadedStore()
        let created = try #require(await store.create(draft(in: store, title: "Real")))
        let matches = store.items.filter { $0.title == "Real" }
        #expect(matches.count == 1)
        #expect(matches.first?.id == created.id)
        #expect(!created.id.hasPrefix("pending:"))
    }

    @Test func createSelectsTheRealItemAfterwards() async throws {
        let store = await loadedStore()
        let created = try #require(await store.create(draft(in: store, title: "Selected")))
        #expect(store.selectedItemID == created.id)
    }

    @Test func failedCreateRemovesPendingItemAndSetsError() async {
        let store = await loadedStore(failWrites: true)
        let result = await store.create(draft(in: store, title: "Doomed"))
        #expect(result == nil)
        #expect(!store.items.contains { $0.title == "Doomed" })
        #expect(store.lastError != nil)
    }

    @Test func failedCreateClearsSelectionOfPendingItem() async {
        let store = await loadedStore(failWrites: true)
        _ = await store.create(draft(in: store, title: "Doomed"))
        #expect(store.selectedItemID == nil)
    }

    @Test func failedUpdateRestoresOriginalItemAndSetsError() async throws {
        let store = await loadedStore(failWrites: true)
        let original = try editableItem(in: store)
        var changed = EventDraft(editing: original)
        changed.title = "Renamed"
        let result = await store.update(original, with: changed)
        #expect(result == nil)
        #expect(store.items.contains(original))
        #expect(!store.items.contains { $0.title == "Renamed" })
        #expect(store.lastError != nil)
    }

    @Test func failedDeleteBringsItemBackAndSetsError() async throws {
        let store = await loadedStore(failWrites: true)
        let original = try editableItem(in: store)
        let ok = await store.delete(original)
        #expect(ok == false)
        #expect(store.items.contains(original))
        #expect(store.lastError != nil)
    }

    @Test func deleteRemovesItemRightAway() async throws {
        let store = await loadedStore(failWrites: true)
        let original = try editableItem(in: store)
        let task = Task { await store.delete(original) }
        await waitUntil { !store.items.contains(original) }
        #expect(!store.items.contains(original))
        _ = await task.value
    }
}

@MainActor
@Suite("CalendarStore visibility")
struct CalendarStoreVisibilityTests {
    @Test func hidingACalendarDropsItsItemsRightAway() async throws {
        let store = await loadedStore()
        let calendarID = PreviewData.calendars[0].id
        try #require(store.items.contains { $0.calendarID == calendarID })
        store.setCalendarVisible(calendarID, visible: false)
        #expect(!store.items.contains { $0.calendarID == calendarID })
    }

    @Test func hidingACalendarKeepsOtherCalendarsItems() async throws {
        let store = await loadedStore()
        let hidden = PreviewData.calendars[0].id
        let otherCount = store.items.filter { $0.calendarID != hidden }.count
        try #require(otherCount > 0)
        store.setCalendarVisible(hidden, visible: false)
        #expect(store.items.filter { $0.calendarID != hidden }.count == otherCount)
    }
}

/// Writes the new item into the repository right away (like the real source, which saves to the
/// cache before returning), then holds `create` until the test lets it finish.
private actor HeldSource: ItemSource {
    nonisolated let kind: ItemSourceKind = .google
    private let repository: PreviewData.Repository
    private var waiting: CheckedContinuation<Void, Never>?
    private var released = false

    init(repository: PreviewData.Repository) { self.repository = repository }

    func create(_ draft: EventDraft) async throws -> CalendarItem {
        guard let info = PreviewData.calendars.first(where: { $0.id == draft.calendarID }) else { throw AlmanacError.notFound }
        let item = CalendarItem(
            id: "google:\(info.id):held", source: .google, externalID: "held", calendarID: info.id,
            accountEmail: info.accountEmail, title: draft.title, start: draft.start, end: draft.end,
            isAllDay: draft.isAllDay, color: info.color)
        await repository.upsert(item)
        if !released { await withCheckedContinuation { waiting = $0 } }
        return item
    }

    func finishCreate() {
        released = true
        waiting?.resume()
        waiting = nil
    }

    func update(_ item: CalendarItem, with draft: EventDraft) async throws -> CalendarItem { throw AlmanacError.notFound }
    func delete(_ item: CalendarItem) async throws { throw AlmanacError.notFound }
    func quickAdd(_ text: String, calendarID: String) async throws -> CalendarItem { throw AlmanacError.notFound }
}

@MainActor
@Suite("CalendarStore pending create")
struct CalendarStorePendingCreateTests {
    @Test func reloadWithTheRealItemHidesThePendingOne() async throws {
        let repository = PreviewData.Repository()
        let source = HeldSource(repository: repository)
        let store = CalendarStore(repository: repository, source: source, sync: PreviewData.Sync(repository: repository))
        store.start()
        _ = await waitForItems(store)

        let task = Task { await store.create(draft(in: store, title: "Twin")) }
        // The repository change triggers a reload while create is still waiting.
        await waitUntil { store.items.contains { $0.title == "Twin" && !$0.id.hasPrefix("pending:") } }
        let whilePending = store.items.filter { $0.title == "Twin" }
        #expect(whilePending.count == 1)
        #expect(whilePending.first?.id.hasPrefix("pending:") == false)

        await source.finishCreate()
        let created = try #require(await task.value)
        let afterwards = store.items.filter { $0.title == "Twin" }
        #expect(afterwards.map(\.id) == [created.id])
    }

    @Test func olderLookAlikeDoesNotHideThePendingItem() async throws {
        let store = await loadedStore()
        let existing = try editableItem(in: store)
        let copy = EventDraft(editing: existing)
        let task = Task { await store.create(copy) }
        await waitUntil { store.items.contains { $0.id.hasPrefix("pending:") } }
        #expect(store.items.filter { $0.title == existing.title && $0.start == existing.start }.count == 2)
        _ = await task.value
    }
}

@MainActor
@Suite("CalendarStore calendar choice")
struct CalendarStoreCalendarChoiceTests {
    private let personal = PreviewData.calendars[0].id
    private let work = PreviewData.calendars[4].id

    @Test func settingTheDefaultForgetsTheLastUsedCalendar() async throws {
        let store = await loadedStore()
        _ = try #require(await store.create(draft(in: store, title: "On work", calendarID: work)))
        #expect(store.preferredCalendarID == work)
        store.defaultCalendarID = personal
        #expect(store.preferredCalendarID == personal)
        #expect(store.quickAddCalendarID == personal)
    }

    @Test func quickAddUsesTheDefaultBeforeTheLastUsedCalendar() async throws {
        let store = await loadedStore()
        store.defaultCalendarID = personal
        _ = try #require(await store.create(draft(in: store, title: "On work", calendarID: work)))
        #expect(store.quickAddCalendarID == personal)
        #expect(store.preferredCalendarID == work)
    }

    @Test func withoutADefaultQuickAddUsesTheLastUsedCalendar() async throws {
        let store = await loadedStore()
        _ = try #require(await store.create(draft(in: store, title: "On work", calendarID: work)))
        #expect(store.quickAddCalendarID == work)
    }
}
