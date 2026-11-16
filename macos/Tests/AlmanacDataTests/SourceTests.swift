import AlmanacKit
import Foundation
import Testing
@testable import AlmanacData

@Suite struct SourceTests {
    let me = "me@example.com"
    let meCal = "me@example.com/me@example.com"
    let readOnlyCal = "me@example.com/en.usa#holiday@group.v.calendar.google.com"
    let teamCal = "me@example.com/team#1@group.calendar.google.com"

    func setup() async throws -> (AppDatabase, FakeGoogle, StubServer, GoogleCalendarSource) {
        let db = try await makeDatabase(calendars: [
            G.calendar(me, name: "Me", primary: true),
            G.calendar("en.usa#holiday@group.v.calendar.google.com", name: "Holidays", role: "reader"),
            G.calendar("team#1@group.calendar.google.com", name: "Team", role: "writer"),
        ])
        try await db.savePalette(["5": "#fbd75b"])
        let google = FakeGoogle()
        let server = StubServer { google.handle($0) }
        let source = GoogleCalendarSource(tokens: FakeTokens([me]), database: db, session: server.session)
        return (db, google, server, source)
    }

    var day: DateInterval { DateInterval(start: date("2026-11-16T00:00:00Z"), duration: 86_400) }

    @Test func createWithMeet() async throws {
        let (db, google, server, source) = try await setup()
        google.on("/calendars/me@example.com/events") { _ in
            .json(G.timed("new1", "Design review", start: "2026-11-16T15:00:00Z", end: "2026-11-16T16:00:00Z",
                          extra: #""hangoutLink":"https://meet.google.com/new-meet-ing""#))
        }
        let draft = EventDraft(calendarID: meCal, title: "Design review", start: date("2026-11-16T15:00:00Z"),
                               end: date("2026-11-16T16:00:00Z"), isAllDay: false, location: "Room 1", addMeet: true)
        let item = try await source.create(draft)

        let req = try #require(server.requests.first)
        #expect(req.method == "POST")
        #expect(req.query["conferenceDataVersion"] == "1")
        let body = try #require(req.json)
        #expect(body["summary"] as? String == "Design review")
        #expect(body["location"] as? String == "Room 1")
        let conference = try #require(body["conferenceData"] as? [String: Any])
        let create = try #require(conference["createRequest"] as? [String: Any])
        #expect((create["conferenceSolutionKey"] as? [String: Any])?["type"] as? String == "hangoutsMeet")
        #expect(!(create["requestId"] as? String ?? "").isEmpty)
        let start = try #require(body["start"] as? [String: Any])
        #expect((start["dateTime"] as? String).flatMap(GoogleDates.parseDateTime) == date("2026-11-16T15:00:00Z"))
        #expect(start["timeZone"] as? String == TimeZone.current.identifier)

        #expect(item.meetURL?.absoluteString == "https://meet.google.com/new-meet-ing")
        #expect(item.calendarID == meCal)
        #expect(try await db.items(in: day).map(\.externalID) == ["new1"])
    }

    @Test func createAllDayWithoutMeet() async throws {
        let (_, google, server, source) = try await setup()
        google.on("/calendars/me@example.com/events") { _ in .json(G.allDay("ad", "Trip", start: "2026-11-20", end: "2026-11-22")) }
        let draft = EventDraft(calendarID: meCal, title: "Trip", start: localDay("2026-11-20"), end: localDay("2026-11-22"), isAllDay: true)
        let item = try await source.create(draft)
        let req = try #require(server.requests.first)
        #expect(req.query["conferenceDataVersion"] == nil)
        let body = try #require(req.json)
        #expect(body["conferenceData"] == nil)
        #expect((body["start"] as? [String: Any])?["date"] as? String == "2026-11-20")
        #expect((body["end"] as? [String: Any])?["date"] as? String == "2026-11-22")
        #expect(item.isAllDay)
        #expect(item.end == localDay("2026-11-22"))
    }

    @Test func calendarIDIsEncodedInPath() async throws {
        let (_, google, _, source) = try await setup()
        google.on("/calendars/team#1@group.calendar.google.com/events/quickAdd") { req in
            .json(G.timed("qa", req.query["text"] ?? "", start: "2026-11-16T13:00:00Z", end: "2026-11-16T14:00:00Z"))
        }
        let item = try await source.quickAdd("Lunch with Sam + Alex 1pm", calendarID: teamCal)
        #expect(item.title == "Lunch with Sam + Alex 1pm")
        #expect(item.calendarID == teamCal)
    }

    @Test func updateSendsPatchWithEtag() async throws {
        let (db, google, server, source) = try await setup()
        try await insert(db, calendarID: meCal, [G.timed("e1", "Old", start: "2026-11-16T09:00:00Z", end: "2026-11-16T10:00:00Z")])
        let original = try #require(try await db.items(in: day).first)
        google.on("/calendars/me@example.com/events/e1") { _ in
            .json(G.timed("e1", "New title", start: "2026-11-16T09:00:00Z", end: "2026-11-16T11:00:00Z", extra: #""colorId":"5""#))
        }
        var draft = EventDraft(editing: original)
        draft.title = "New title"
        draft.end = date("2026-11-16T11:00:00Z")
        let updated = try await source.update(original, with: draft)

        let req = try #require(server.requests.first)
        #expect(req.method == "PATCH")
        #expect(req.headers["If-Match"] == "\"e-e1\"")
        #expect(req.json?["summary"] as? String == "New title")
        #expect((req.json?["start"] as? [String: Any])?["date"] is NSNull)
        #expect(updated.title == "New title")
        #expect(updated.color == "#fbd75b")
        #expect(try await db.items(in: day).map(\.end) == [date("2026-11-16T11:00:00Z")])
    }

    @Test func updateRejectsRecurringAndReadOnly() async throws {
        let (db, _, server, source) = try await setup()
        try await insert(db, calendarID: meCal, [G.timed("r_1", "Weekly", start: "2026-11-16T09:00:00Z", end: "2026-11-16T10:00:00Z",
                                                         extra: #""recurringEventId":"r""#)])
        try await insert(db, calendarID: readOnlyCal, [G.allDay("h1", "Holiday", start: "2026-11-16", end: "2026-11-17")])
        try await db.setCalendarVisible(readOnlyCal, visible: true)
        let items = try await db.items(in: day)
        let recurring = try #require(items.first { $0.externalID == "r_1" })
        let holiday = try #require(items.first { $0.externalID == "h1" })

        await #expect { try await source.update(recurring, with: EventDraft(editing: recurring)) } throws: { error in
            if case AlmanacError.recurringNotSupported = error { return true }
            return false
        }
        await #expect { try await source.update(holiday, with: EventDraft(editing: holiday)) } throws: { error in
            if case AlmanacError.readOnlyCalendar = error { return true }
            return false
        }
        await #expect { try await source.delete(holiday) } throws: { error in
            if case AlmanacError.readOnlyCalendar = error { return true }
            return false
        }
        await #expect {
            try await source.create(EventDraft(calendarID: readOnlyCal, title: "X", start: .now, end: .now, isAllDay: false))
        } throws: { error in
            if case AlmanacError.readOnlyCalendar = error { return true }
            return false
        }
        #expect(server.requests.isEmpty)
    }

    @Test func updateConflictReportsGoogleMessage() async throws {
        let (db, google, _, source) = try await setup()
        try await insert(db, calendarID: meCal, [G.timed("e1", "Old", start: "2026-11-16T09:00:00Z", end: "2026-11-16T10:00:00Z")])
        let original = try #require(try await db.items(in: day).first)
        google.on("/calendars/me@example.com/events/e1") { _ in .error(412, "Precondition Failed") }
        await #expect { try await source.update(original, with: EventDraft(editing: original)) } throws: { error in
            if case AlmanacError.api(412, "Precondition Failed") = error { return true }
            return false
        }
        #expect(try await db.items(in: day).first?.title == "Old")
    }

    @Test func updateOfDeletedEventRemovesItFromCache() async throws {
        let (db, google, _, source) = try await setup()
        try await insert(db, calendarID: meCal, [G.timed("e1", "Old", start: "2026-11-16T09:00:00Z", end: "2026-11-16T10:00:00Z")])
        let original = try #require(try await db.items(in: day).first)
        google.on("/calendars/me@example.com/events/e1") { _ in .error(404, "Not Found") }
        await #expect { try await source.update(original, with: EventDraft(editing: original)) } throws: { error in
            if case AlmanacError.notFound = error { return true }
            return false
        }
        #expect(try await db.items(in: day).isEmpty)
    }

    @Test func moveToAnotherCalendarPatchesFirst() async throws {
        let (db, google, server, source) = try await setup()
        try await insert(db, calendarID: meCal, [G.timed("e1", "Old", start: "2026-11-16T09:00:00Z", end: "2026-11-16T10:00:00Z")])
        try await db.setCalendarVisible(teamCal, visible: true)
        let original = try #require(try await db.items(in: day).first)
        google.on("/calendars/me@example.com/events/e1") { _ in
            .json(G.timed("e1", "Moved", start: "2026-11-16T09:00:00Z", end: "2026-11-16T10:00:00Z"))
        }
        google.on("/calendars/me@example.com/events/e1/move") { _ in
            .json(G.timed("e1", "Moved", start: "2026-11-16T09:00:00Z", end: "2026-11-16T10:00:00Z"))
        }
        var draft = EventDraft(editing: original)
        draft.calendarID = teamCal
        draft.title = "Moved"
        let moved = try await source.update(original, with: draft)
        #expect(server.requests.map(\.method) == ["PATCH", "POST"])
        #expect(server.requests.first?.path == "/calendars/me@example.com/events/e1")
        #expect(server.requests.first?.headers["If-Match"] == "\"e-e1\"")
        #expect(server.requests.last?.query["destination"] == "team#1@group.calendar.google.com")
        #expect(moved.calendarID == teamCal)
        #expect(moved.title == "Moved")
        #expect(try await db.items(in: day).map(\.calendarID) == [teamCal])
    }

    @Test func failedMoveKeepsPatchedEventInOriginalCalendar() async throws {
        let (db, google, _, source) = try await setup()
        try await insert(db, calendarID: meCal, [G.timed("e1", "Old", start: "2026-11-16T09:00:00Z", end: "2026-11-16T10:00:00Z")])
        try await db.setCalendarVisible(teamCal, visible: true)
        let original = try #require(try await db.items(in: day).first)
        google.on("/calendars/me@example.com/events/e1") { _ in
            .json(G.timed("e1", "Patched", start: "2026-11-16T09:00:00Z", end: "2026-11-16T10:00:00Z"))
        }
        google.on("/calendars/me@example.com/events/e1/move") { _ in .error(403, "Insufficient permissions") }
        var draft = EventDraft(editing: original)
        draft.calendarID = teamCal
        draft.title = "Patched"
        await #expect { try await source.update(original, with: draft) } throws: { error in
            guard case AlmanacError.api(403, let message) = error else { return false }
            return message.contains("saved") && message.contains("Team") && message.contains("Insufficient permissions")
        }
        let items = try await db.items(in: day)
        #expect(items.map(\.calendarID) == [meCal])
        #expect(items.map(\.title) == ["Patched"])
    }

    @Test func patchKeepsEventTimeZone() async throws {
        let (db, google, server, source) = try await setup()
        try await insert(db, calendarID: meCal, [
            #"{"id":"tz","status":"confirmed","etag":"\"e\"","summary":"NY","start":{"dateTime":"2026-11-16T04:00:00-05:00","timeZone":"America/New_York"},"end":{"dateTime":"2026-11-16T05:00:00-05:00","timeZone":"America/New_York"}}"#,
        ])
        let original = try #require(try await db.items(in: day).first)
        google.on("/calendars/me@example.com/events/tz") { _ in
            .json(#"{"id":"tz","status":"confirmed","summary":"NY 2","start":{"dateTime":"2026-11-16T04:00:00-05:00","timeZone":"America/New_York"},"end":{"dateTime":"2026-11-16T06:00:00-05:00","timeZone":"America/New_York"}}"#)
        }
        var draft = EventDraft(editing: original)
        draft.title = "NY 2"
        _ = try await source.update(original, with: draft)
        let start = try #require(server.requests.first?.json?["start"] as? [String: Any])
        #expect(start["timeZone"] as? String == "America/New_York")
        #expect((start["dateTime"] as? String)?.hasSuffix("-05:00") == true)
        #expect((start["dateTime"] as? String).flatMap(GoogleDates.parseDateTime) == date("2026-11-16T09:00:00Z"))

        // Without a stored zone, a new event gets the Mac's zone, and a patch leaves the event's zone alone.
        let fields = GoogleCalendarSource.fields(draft)
        #expect((fields["start"] as? [String: Any])?["timeZone"] as? String == TimeZone.current.identifier)
        let patch = try #require(GoogleCalendarSource.fields(draft, isPatch: true)["start"] as? [String: Any])
        #expect(patch["timeZone"] == nil)
        #expect(patch["dateTime"] is String)
    }

    @Test func unauthorizedIsRetriedOnceWithNewToken() async throws {
        let calls = Counter()
        let server = StubServer { _ in
            calls.increment() == 1 ? .error(401, "Invalid Credentials") : .json(#"{"event":{}}"#)
        }
        let tokens = FakeTokens([me])
        let api = GoogleAPI(tokens: tokens, session: server.session)
        _ = try await api.eventPalette(account: me)
        #expect(server.requests.count == 2)
        #expect(tokens.tokenCalls == 2)
        // The rejected token is dropped so the retry uses a fresh one, not the cached one again.
        #expect(tokens.invalidatedTokens == ["token-\(me)"])
        #expect(server.requests.map { $0.headers["Authorization"] } == ["Bearer token-\(me)", "Bearer token-\(me)-1"])
    }

    @Test func repeatedUnauthorizedMeansNeedsSignIn() async throws {
        let server = StubServer { _ in .error(401, "Invalid Credentials") }
        let api = GoogleAPI(tokens: FakeTokens([me]), session: server.session)
        await #expect { try await api.eventPalette(account: me) } throws: { error in
            if case AlmanacError.needsSignIn(let email) = error { return email == me }
            return false
        }
        #expect(server.requests.count == 2)
    }

    @Test func deleteRemovesFromCache() async throws {
        let (db, google, server, source) = try await setup()
        try await insert(db, calendarID: meCal, [
            G.timed("e1", "One", start: "2026-11-16T09:00:00Z", end: "2026-11-16T10:00:00Z"),
            G.timed("e2", "Two", start: "2026-11-16T11:00:00Z", end: "2026-11-16T12:00:00Z"),
        ])
        google.on("/calendars/me@example.com/events/e1") { _ in StubResponse(status: 204, body: Data()) }
        google.on("/calendars/me@example.com/events/e2") { _ in .error(410, "Resource has been deleted") }
        let items = try await db.items(in: day)
        try await source.delete(items[0])
        try await source.delete(items[1])
        #expect(server.requests.map(\.method) == ["DELETE", "DELETE"])
        #expect(try await db.items(in: day).isEmpty)
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }

    /// Adds one and returns the new value.
    func increment() -> Int { lock.withLock { count += 1; return count } }
}
