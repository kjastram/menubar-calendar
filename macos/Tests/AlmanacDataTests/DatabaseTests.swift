import AlmanacKit
import Foundation
import GRDB
import Testing
@testable import AlmanacData

@Suite struct DatabaseTests {
    @Test func paletteAssignment() async throws {
        let db = try AppDatabase.inMemory()
        try await db.ensureAccount("a@x.com")
        try await db.ensureAccount("b@x.com", color: accountPalette[2])
        try await db.ensureAccount("c@x.com")
        try await db.ensureAccount("d@x.com")
        // Seeing an account again changes nothing.
        try await db.ensureAccount("a@x.com")
        let colors = Dictionary(uniqueKeysWithValues: try await db.accounts().map { ($0.email, $0.color) })
        #expect(colors == ["a@x.com": accountPalette[0], "b@x.com": accountPalette[2],
                           "c@x.com": accountPalette[1], "d@x.com": accountPalette[3]])

        // Once every color is used, cycle by count as the plugin does.
        for i in 0..<4 { try await db.ensureAccount("z\(i)@x.com") }
        try await db.ensureAccount("last@x.com")
        let last = try await db.accounts().first { $0.email == "last@x.com" }
        #expect(last?.color == accountPalette[8 % accountPalette.count])
    }

    @Test func ensureAccountWithColorUpdatesExisting() async throws {
        let db = try AppDatabase.inMemory()
        try await db.ensureAccount("a@x.com")
        try await db.ensureAccount("a@x.com", color: "#111111", hidden: true)
        let a = try #require(try await db.accounts().first)
        #expect(a.color == "#111111")
        #expect(a.hidden)
        #expect(a.status == .ok)
    }

    @Test func accountStatusRoundTrip() async throws {
        let db = try AppDatabase.inMemory()
        try await db.ensureAccount("a@x.com")
        try await db.setAccountStatus("a@x.com", .error("Rate limit"))
        #expect(try await db.accounts().first?.status == .error("Rate limit"))
        try await db.setAccountStatus("a@x.com", .needsSignIn)
        #expect(try await db.accounts().first?.status == .needsSignIn)
        try await db.setAccountStatus("a@x.com", .ok)
        #expect(try await db.accounts().first?.status == .ok)
    }

    @Test func initialVisibilityFollowsSelectedAndExclude() async throws {
        let db = try AppDatabase.inMemory()
        let me = "me@example.com"
        try await db.ensureAccount(me)
        try await db.setExcludedCalendars(["Holidays in Germany", "team@group.calendar.google.com"])
        let list = try JSONDecoder().decode(GoogleCalendarListPage.self, from: Data(#"""
            {"items":[
              {"id":"me@example.com","summary":"me@example.com","summaryOverride":"Me","backgroundColor":"#111","accessRole":"owner","selected":true,"primary":true},
              {"id":"de#holiday@group.v.calendar.google.com","summary":"Holidays in Germany","backgroundColor":"#222","accessRole":"reader","selected":true},
              {"id":"team@group.calendar.google.com","summary":"Team","backgroundColor":"#333","accessRole":"writer","selected":true},
              {"id":"other@group.calendar.google.com","summary":"Other","backgroundColor":"#444","accessRole":"reader","selected":false},
              {"id":"birthdays","summary":"Birthdays","backgroundColor":"#555","accessRole":"reader"}
            ]}
            """#.utf8))
        try await db.applyCalendarList(account: me, entries: list.items ?? [])
        let visible = Dictionary(uniqueKeysWithValues: try await db.calendars().map { ($0.name, $0.visible) })
        #expect(visible == ["Me": true, "Holidays in Germany": false, "Team": false, "Other": false, "Birthdays": false])

        let primary = try #require(try await db.calendars().first { $0.isPrimary })
        #expect(primary.id == "me@example.com/me@example.com")
        #expect(primary.canWrite)

        // The user's choice survives the next calendarList.
        try await db.setCalendarVisible("me@example.com/other@group.calendar.google.com", visible: true)
        try await db.applyCalendarList(account: me, entries: list.items ?? [])
        #expect(try await db.calendars().first { $0.name == "Other" }?.visible == true)

        // Excluding later hides an existing calendar by id or name.
        try await db.setExcludedCalendars(["other@group.calendar.google.com", "Me"])
        #expect(try await db.calendars().allSatisfy { !$0.visible })
    }

    @Test func calendarsRemovedFromListAreDeleted() async throws {
        let db = try await makeDatabase(calendars: [
            G.calendar("me@example.com", name: "Me", primary: true),
            G.calendar("gone@group.calendar.google.com", name: "Gone"),
        ])
        let gone = "me@example.com/gone@group.calendar.google.com"
        try await insert(db, calendarID: gone, [G.timed("g1", "Old", start: "2026-11-16T09:00:00Z", end: "2026-11-16T10:00:00Z")])
        let list = try JSONDecoder().decode(GoogleCalendarListPage.self,
                                            from: Data(#"{"items":[\#(G.calendar("me@example.com", name: "Me Renamed", color: "#ff0000", primary: true))]}"#.utf8))
        try await db.applyCalendarList(account: "me@example.com", entries: list.items ?? [])
        let calendars = try await db.calendars()
        #expect(calendars.map(\.name) == ["Me Renamed"])
        #expect(calendars.first?.color == "#ff0000")
        #expect(try await db.eventRecords(calendarID: gone).isEmpty)
    }

    @Test func itemsRangeVisibilityAndFilters() async throws {
        let db = try await makeDatabase(calendars: [
            G.calendar("me@example.com", name: "Me", primary: true),
            G.calendar("hidden@group.calendar.google.com", name: "Hidden", selected: false),
        ])
        let me = "me@example.com/me@example.com"
        try await insert(db, calendarID: me, [
            G.timed("in", "Inside", start: "2026-11-16T09:00:00Z", end: "2026-11-16T10:00:00Z"),
            G.timed("cross", "Crosses start", start: "2026-11-15T23:00:00Z", end: "2026-11-16T01:00:00Z"),
            G.timed("before", "Before", start: "2026-11-15T20:00:00Z", end: "2026-11-15T21:00:00Z"),
            G.timed("after", "After", start: "2026-11-18T09:00:00Z", end: "2026-11-18T10:00:00Z"),
            G.timed("touch", "Ends at start", start: "2026-11-15T22:00:00Z", end: "2026-11-16T00:00:00Z"),
            G.timed("declined", "Declined", start: "2026-11-16T11:00:00Z", end: "2026-11-16T12:00:00Z",
                    extra: #""attendees":[{"self":true,"responseStatus":"declined"}]"#),
            G.timed("wl", "Office", start: "2026-11-16T08:00:00Z", end: "2026-11-16T17:00:00Z", extra: #""eventType":"workingLocation""#),
        ])
        // A cancelled row (sync deletes these, but reading must skip one if it is there).
        var cancelled = try #require(EventRecord(
            event: try decodeEvent(G.timed("cancelled", "Cancelled", start: "2026-11-16T13:00:00Z", end: "2026-11-16T14:00:00Z")),
            calendarID: me, accountEmail: "me@example.com", palette: [:]))
        cancelled.status = "cancelled"
        try await db.writer.write { [cancelled] db in try cancelled.insert(db) }
        try await insert(db, calendarID: "me@example.com/hidden@group.calendar.google.com", [
            G.timed("h", "Hidden calendar", start: "2026-11-16T09:00:00Z", end: "2026-11-16T10:00:00Z"),
        ])

        let range = DateInterval(start: date("2026-11-16T00:00:00Z"), end: date("2026-11-17T00:00:00Z"))
        #expect(try await db.items(in: range).map(\.externalID) == ["cross", "in"])

        // Declined/workingLocation rows are still in the cache; only reading skips them.
        #expect(try await db.eventRecords(calendarID: me).contains { $0.externalID == "declined" })
        #expect(try await db.eventRecords(calendarID: me).contains { $0.externalID == "wl" })

        try await db.setCalendarVisible("me@example.com/hidden@group.calendar.google.com", visible: true)
        #expect(try await db.items(in: range).map(\.externalID) == ["cross", "h", "in"])

        try await db.setAccountHidden("me@example.com", hidden: true)
        #expect(try await db.items(in: range).isEmpty)
    }

    @Test func itemsSortAllDayFirstAndDedupeAcrossAccounts() async throws {
        let db = try await makeDatabase()
        try await db.ensureAccount("work@example.com")
        let list = try JSONDecoder().decode(GoogleCalendarListPage.self,
                                            from: Data(#"{"items":[\#(G.calendar("work@example.com", name: "Work", primary: true))]}"#.utf8))
        try await db.applyCalendarList(account: "work@example.com", entries: list.items ?? [])

        let day = localDay("2026-11-16")
        let nine = GoogleDates.formatDateTime(day.addingTimeInterval(9 * 3600))
        let ten = GoogleDates.formatDateTime(day.addingTimeInterval(10 * 3600))
        let midnight = GoogleDates.formatDateTime(day)
        let one = GoogleDates.formatDateTime(day.addingTimeInterval(3600))
        try await insert(db, calendarID: "me@example.com/me@example.com", [
            G.timed("m1", "Planning", start: nine, end: ten, extra: #""iCalUID":"shared@google.com""#),
            G.timed("m2", "Midnight", start: midnight, end: one),
            G.allDay("m3", "Holiday", start: "2026-11-16", end: "2026-11-17"),
        ])
        try await insert(db, calendarID: "work@example.com/work@example.com", account: "work@example.com", [
            G.timed("w1", "Planning", start: nine, end: ten,
                    extra: #""iCalUID":"shared@google.com","hangoutLink":"https://meet.google.com/abc""#),
        ])
        let items = try await db.items(in: DateInterval(start: day, duration: 86_400))
        #expect(items.map(\.title) == ["Holiday", "Midnight", "Planning"])
        let planning = try #require(items.last)
        #expect(planning.accountEmail == "work@example.com")
        #expect(planning.meetURL?.absoluteString == "https://meet.google.com/abc")
    }

    @Test func search() async throws {
        let db = try await makeDatabase()
        try await insert(db, calendarID: "me@example.com/me@example.com", [
            G.timed("1", "Dentist", start: "2026-11-16T09:00:00Z", end: "2026-11-16T10:00:00Z"),
            G.timed("2", "Lunch", start: "2026-11-17T09:00:00Z", end: "2026-11-17T10:00:00Z", extra: #""location":"Café DENTAL""#),
            G.timed("3", "Call", start: "2026-11-18T09:00:00Z", end: "2026-11-18T10:00:00Z", extra: #""description":"about 100% done""#),
            G.timed("4", "Café", start: "2026-11-19T09:00:00Z", end: "2026-11-19T10:00:00Z"),
        ])
        #expect(try await db.search("dent", limit: 10).map(\.externalID) == ["1", "2"])
        #expect(try await db.search("dent", limit: 1).map(\.externalID) == ["1"])
        #expect(try await db.search("100%", limit: 10).map(\.externalID) == ["3"])
        #expect(try await db.search("CAFÉ", limit: 10).map(\.externalID) == ["2", "4"])
        #expect(try await db.search("cafe", limit: 10).map(\.externalID) == ["2", "4"])
        #expect(try await db.search("  ", limit: 10).isEmpty)
    }

    @Test func removeAccountDeletesEverything() async throws {
        let db = try await makeDatabase()
        let cal = "me@example.com/me@example.com"
        try await db.replaceEvents(calendarID: cal, accountEmail: "me@example.com",
                                   events: [try decodeEvent(G.timed("1", "A", start: "2026-11-16T09:00:00Z", end: "2026-11-16T10:00:00Z"))],
                                   syncToken: "tok")
        try await db.removeAccount("me@example.com")
        #expect(try await db.accounts().isEmpty)
        #expect(try await db.calendars().isEmpty)
        #expect(try await db.eventRecords(calendarID: cal).isEmpty)
        #expect(try await db.syncState(calendarID: cal) == nil)
    }

    @Test(.timeLimit(.minutes(1))) func changesFiresOnWrites() async throws {
        let db = try await makeDatabase()
        var updates = db.changes().makeAsyncIterator()
        #expect(await updates.next() != nil)  // right away
        try await insert(db, calendarID: "me@example.com/me@example.com",
                         [G.timed("1", "A", start: "2026-11-16T09:00:00Z", end: "2026-11-16T10:00:00Z")])
        #expect(await updates.next() != nil)
        try await db.setAccountColor("me@example.com", color: "#000000")
        #expect(await updates.next() != nil)
        try await db.setCalendarVisible("me@example.com/me@example.com", visible: false)
        #expect(await updates.next() != nil)
    }

    @Test func openOnDisk() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("almanac-\(UUID().uuidString).sqlite")
        defer {
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
        }
        do {
            let db = try AppDatabase.open(at: url)
            try await db.ensureAccount("a@x.com")
        }
        let reopened = try AppDatabase.open(at: url)
        #expect(try await reopened.accounts().map(\.email) == ["a@x.com"])
    }

    @Test func reservedColorsAreSkippedForNewAccounts() async throws {
        let db = try AppDatabase.inMemory()
        try await db.ensureAccount("a@x.com")
        // The plugin gave palette[1] and palette[2] to accounts not signed in here yet (and palette[0] to a@x.com).
        try await db.reserveColors([accountPalette[0], accountPalette[1], accountPalette[2]])
        try await db.ensureAccount("b@x.com")
        #expect(try await db.accounts().first { $0.email == "b@x.com" }?.color == accountPalette[3])
        // An explicit color still wins.
        try await db.ensureAccount("c@x.com", color: accountPalette[1])
        #expect(try await db.accounts().first { $0.email == "c@x.com" }?.color == accountPalette[1])
        // Replacing the list frees the colors again.
        try await db.reserveColors([])
        try await db.ensureAccount("d@x.com")
        #expect(try await db.accounts().first { $0.email == "d@x.com" }?.color == accountPalette[2])
    }

    @Test func incrementalSkipsEventsOlderThanCache() async throws {
        let db = try await makeDatabase()
        let cal = "me@example.com/me@example.com"
        try await insert(db, calendarID: cal, [
            G.timed("1", "Newer", start: "2026-11-16T09:00:00Z", end: "2026-11-16T10:00:00Z", extra: #""updated":"2026-11-15T10:00:00.000Z""#),
        ])
        try await insert(db, calendarID: cal, [
            G.timed("1", "Older", start: "2026-11-16T09:00:00Z", end: "2026-11-16T10:00:00Z", extra: #""updated":"2026-11-15T09:00:00.000Z""#),
        ])
        #expect(try await db.eventRecords(calendarID: cal).map(\.title) == ["Newer"])
        try await insert(db, calendarID: cal, [
            G.timed("1", "Latest", start: "2026-11-16T09:00:00Z", end: "2026-11-16T10:00:00Z", extra: #""updated":"2026-11-15T11:00:00Z""#),
        ])
        #expect(try await db.eventRecords(calendarID: cal).map(\.title) == ["Latest"])
    }

    @Test func syncFetchedBeforeLocalWriteCannotUndoIt() async throws {
        let db = try await makeDatabase()
        let cal = "me@example.com/me@example.com"
        try await insert(db, calendarID: cal, [
            G.timed("del", "Deleted here", start: "2026-11-16T09:00:00Z", end: "2026-11-16T10:00:00Z"),
            G.timed("edit", "Old", start: "2026-11-16T11:00:00Z", end: "2026-11-16T12:00:00Z"),
        ])
        let fetchStarted = Date().addingTimeInterval(-5)
        try await db.deleteEvent(calendarID: cal, externalID: "del")
        try await db.saveEvent(try decodeEvent(G.timed("edit", "Edited here", start: "2026-11-16T11:00:00Z", end: "2026-11-16T12:00:00Z")),
                               calendarID: cal, accountEmail: "me@example.com")
        let stalePage = try [
            G.timed("del", "Deleted here", start: "2026-11-16T09:00:00Z", end: "2026-11-16T10:00:00Z"),
            G.timed("edit", "Old", start: "2026-11-16T11:00:00Z", end: "2026-11-16T12:00:00Z"),
            G.timed("other", "Other", start: "2026-11-16T13:00:00Z", end: "2026-11-16T14:00:00Z"),
        ].map(decodeEvent)

        try await db.applyChanges(calendarID: cal, accountEmail: "me@example.com", events: stalePage, syncToken: "s",
                                  fetchStartedAt: fetchStarted)
        var rows = try await db.eventRecords(calendarID: cal)
        #expect(rows.map(\.externalID) == ["edit", "other"])
        #expect(rows.first?.title == "Edited here")

        try await db.replaceEvents(calendarID: cal, accountEmail: "me@example.com", events: stalePage, syncToken: "s2",
                                   fetchStartedAt: fetchStarted)
        rows = try await db.eventRecords(calendarID: cal)
        #expect(rows.map(\.externalID) == ["edit", "other"])
        #expect(rows.first?.title == "Edited here")

        // A page fetched after the write is applied as usual.
        try await db.replaceEvents(calendarID: cal, accountEmail: "me@example.com", events: stalePage, syncToken: "s3",
                                   fetchStartedAt: Date().addingTimeInterval(1))
        rows = try await db.eventRecords(calendarID: cal)
        #expect(rows.map(\.externalID) == ["del", "edit", "other"])
        #expect(rows.first { $0.externalID == "edit" }?.title == "Old")
    }

    @Test func localWritesExpireAfterTheWindow() async throws {
        let db = try await makeDatabase()
        let cal = "me@example.com/me@example.com"
        try await db.deleteEvent(calendarID: cal, externalID: "gone")
        try await db.writer.write { db in
            try db.execute(sql: "UPDATE local_writes SET written_at = written_at - ?", arguments: [AppDatabase.localWriteWindow + 1])
        }
        let page = [try decodeEvent(G.timed("gone", "Back", start: "2026-11-16T09:00:00Z", end: "2026-11-16T10:00:00Z"))]
        try await db.applyChanges(calendarID: cal, accountEmail: "me@example.com", events: page, syncToken: nil,
                                  fetchStartedAt: Date().addingTimeInterval(-AppDatabase.localWriteWindow - 10))
        #expect(try await db.eventRecords(calendarID: cal).map(\.externalID) == ["gone"])
    }

    @Test func migratesVersionOneDatabase() async throws {
        let queue = try DatabaseQueue()
        try AppDatabase.migrator.migrate(queue, upTo: "v1")
        try await queue.write { db in
            try db.execute(sql: "INSERT INTO accounts (source, external_id, color) VALUES ('google', 'a@x.com', '#111111')")
        }
        let db = try AppDatabase(writer: queue)
        #expect(try await db.accounts().map(\.email) == ["a@x.com"])
        #expect(try await db.calendarErrors().isEmpty)
    }

    @Test func storesEventTimeZone() async throws {
        let db = try await makeDatabase()
        let cal = "me@example.com/me@example.com"
        try await insert(db, calendarID: cal, [
            #"{"id":"tz","status":"confirmed","summary":"NY","start":{"dateTime":"2026-11-16T09:00:00-05:00","timeZone":"America/New_York"},"end":{"dateTime":"2026-11-16T10:00:00-05:00","timeZone":"America/New_York"}}"#,
        ])
        #expect(try await db.timeZone(calendarID: cal, externalID: "tz") == "America/New_York")
    }
}
