import AlmanacKit
import Foundation
import Testing
@testable import AlmanacData

@Suite struct MappingTests {
    let account = "me@example.com"
    let cal = "me@example.com/me@example.com"

    func record(_ json: String, palette: [String: String] = [:]) throws -> EventRecord {
        try #require(EventRecord(event: decodeEvent(json), calendarID: cal, accountEmail: account, palette: palette))
    }

    @Test func timedEvent() throws {
        let r = try record(G.timed("e1", "Standup", start: "2026-11-16T09:00:00-08:00", end: "2026-11-16T09:30:00-08:00",
                                   extra: #""location":"Room 4","description":"Daily","iCalUID":"uid1@google.com""#))
        let item = r.item(accountEmail: account, calendarColor: "#123456")
        #expect(item.id == "google:\(cal):e1")
        #expect(item.title == "Standup")
        #expect(item.start == date("2026-11-16T17:00:00Z"))
        #expect(item.end == date("2026-11-16T17:30:00Z"))
        #expect(!item.isAllDay)
        #expect(item.location == "Room 4")
        #expect(item.notes == "Daily")
        #expect(item.color == "#123456")
        #expect(item.etag == "\"e-e1\"")
        #expect(item.meetURL == nil)
        #expect(!item.isTentative)
        #expect(!item.isRecurring)
        #expect(r.iCalUID == "uid1@google.com")
    }

    @Test func fractionalSecondsAndUTC() throws {
        let r = try record(G.timed("e1", "X", start: "2026-11-16T09:00:00.000Z", end: "2026-11-16T10:00:00Z"))
        #expect(r.startAt == date("2026-11-16T09:00:00Z").timeIntervalSince1970)
    }

    @Test func allDayUsesLocalMidnightAndExclusiveEnd() throws {
        let r = try record(G.allDay("a1", "Trip", start: "2026-11-20", end: "2026-11-22"))
        let item = r.item(accountEmail: account, calendarColor: "#000000")
        #expect(item.isAllDay)
        #expect(item.start == localDay("2026-11-20"))
        #expect(item.end == localDay("2026-11-22"))
        let cal = Calendar.current
        #expect(cal.component(.hour, from: item.start) == 0)
        // Two days, end exclusive: covers the 21st but not the 22nd.
        #expect(item.overlaps(DateInterval(start: localDay("2026-11-21"), end: localDay("2026-11-22"))))
        #expect(!item.overlaps(DateInterval(start: localDay("2026-11-22"), end: localDay("2026-11-23"))))
    }

    @Test func allDayIsRecomputedInAnotherTimeZone() throws {
        var tokyo = Calendar(identifier: .gregorian)
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let event = try decodeEvent(G.allDay("a1", "Holiday", start: "2026-11-23", end: "2026-11-24"))
        let r = try #require(EventRecord(event: event, calendarID: cal, accountEmail: account, palette: [:], calendar: tokyo))
        var berlin = Calendar(identifier: .gregorian)
        berlin.timeZone = TimeZone(identifier: "Europe/Berlin")!
        let item = r.item(accountEmail: account, calendarColor: "#000", calendar: berlin)
        #expect(item.start == GoogleDates.localMidnight("2026-11-23", calendar: berlin))
        #expect(item.end == GoogleDates.localMidnight("2026-11-24", calendar: berlin))
    }

    @Test func meetLinkOrder() throws {
        let conference = #""conferenceData":{"entryPoints":[{"entryPointType":"phone","uri":"tel:+1"},{"entryPointType":"video","uri":"https://zoom.us/j/1"}]}"#
        let hangout = #""hangoutLink":"https://meet.google.com/abc-defg-hij""#
        let httpsLocation = #""location":"https://teams.example.com/meet/9 (Teams)""#

        let all = try record(G.timed("1", "A", start: "2026-11-16T09:00:00Z", end: "2026-11-16T10:00:00Z",
                                     extra: [hangout, conference, httpsLocation].joined(separator: ",")))
        #expect(all.meetURL == "https://meet.google.com/abc-defg-hij")

        let noHangout = try record(G.timed("2", "A", start: "2026-11-16T09:00:00Z", end: "2026-11-16T10:00:00Z",
                                           extra: [conference, httpsLocation].joined(separator: ",")))
        #expect(noHangout.meetURL == "https://zoom.us/j/1")

        let onlyLocation = try record(G.timed("3", "A", start: "2026-11-16T09:00:00Z", end: "2026-11-16T10:00:00Z",
                                              extra: httpsLocation))
        #expect(onlyLocation.meetURL == "https://teams.example.com/meet/9")

        let plainLocation = try record(G.timed("4", "A", start: "2026-11-16T09:00:00Z", end: "2026-11-16T10:00:00Z",
                                               extra: #""location":"http://example.com""#))
        #expect(plainLocation.meetURL == nil)
    }

    @Test func responseStatus() throws {
        func attendees(_ me: String) -> String {
            #""attendees":[{"email":"a@x.com","responseStatus":"declined"},{"email":"me@example.com","self":true,"responseStatus":"\#(me)"}]"#
        }
        let declined = try record(G.timed("1", "A", start: "2026-11-16T09:00:00Z", end: "2026-11-16T10:00:00Z", extra: attendees("declined")))
        #expect(declined.isSkipped)

        for status in ["tentative", "needsAction"] {
            let r = try record(G.timed("2", "A", start: "2026-11-16T09:00:00Z", end: "2026-11-16T10:00:00Z", extra: attendees(status)))
            #expect(!r.isSkipped)
            #expect(r.item(accountEmail: account, calendarColor: "#000").isTentative)
        }

        let accepted = try record(G.timed("3", "A", start: "2026-11-16T09:00:00Z", end: "2026-11-16T10:00:00Z", extra: attendees("accepted")))
        #expect(!accepted.item(accountEmail: account, calendarColor: "#000").isTentative)

        // Another attendee declining doesn't matter when you're not listed.
        let notListed = try record(G.timed("4", "A", start: "2026-11-16T09:00:00Z", end: "2026-11-16T10:00:00Z",
                                           extra: #""attendees":[{"email":"a@x.com","responseStatus":"declined"}]"#))
        #expect(!notListed.isSkipped)
        #expect(notListed.selfResponse == "accepted")
    }

    @Test func skippedTypes() throws {
        let working = try record(G.allDay("w", "Home", start: "2026-11-16", end: "2026-11-17", extra: #""eventType":"workingLocation""#))
        #expect(working.isSkipped)
        let focus = try record(G.timed("f", "Focus", start: "2026-11-16T09:00:00Z", end: "2026-11-16T10:00:00Z", extra: #""eventType":"focusTime""#))
        #expect(!focus.isSkipped)
    }

    @Test func authuserLink() throws {
        let r = try record(G.timed("e1", "A", start: "2026-11-16T09:00:00Z", end: "2026-11-16T10:00:00Z"))
        let item = r.item(accountEmail: account, calendarColor: "#000")
        #expect(item.webURL?.absoluteString == "https://www.google.com/calendar/event?eid=e1&authuser=me@example.com")
    }

    @Test func colorIdAndRecurring() throws {
        let r = try record(G.timed("e1_20261116", "A", start: "2026-11-16T09:00:00Z", end: "2026-11-16T10:00:00Z",
                                   extra: #""colorId":"5","recurringEventId":"e1""#),
                           palette: ["5": "#fbd75b"])
        let item = r.item(accountEmail: account, calendarColor: "#000")
        #expect(item.color == "#fbd75b")
        #expect(item.isRecurring)
        #expect(r.recurringEventID == "e1")

        let unknown = try record(G.timed("e2", "A", start: "2026-11-16T09:00:00Z", end: "2026-11-16T10:00:00Z", extra: #""colorId":"9""#),
                                 palette: ["5": "#fbd75b"])
        #expect(unknown.item(accountEmail: account, calendarColor: "#abcdef").color == "#abcdef")
    }

    @Test func missingTitleAndTimes() throws {
        let untitled = try record(#"{"id":"u","start":{"dateTime":"2026-11-16T09:00:00Z"},"end":{"dateTime":"2026-11-16T10:00:00Z"}}"#)
        #expect(untitled.item(accountEmail: account, calendarColor: "#000").title == "(No title)")
        let noTimes = try decodeEvent(G.cancelled("c"))
        #expect(EventRecord(event: noTimes, calendarID: cal, accountEmail: account, palette: [:]) == nil)
    }
}

@Suite struct DedupeTests {
    func item(_ id: String, _ title: String, start: String, end: String, cal: String = "c1", meet: Bool = false) -> CalendarItem {
        CalendarItem(id: "google:\(cal):\(id)", source: .google, externalID: id, calendarID: cal, accountEmail: "a",
                     title: title, start: date(start), end: date(end), isAllDay: false,
                     meetURL: meet ? URL(string: "https://meet.google.com/x") : nil, color: "#000")
    }

    @Test func sameUIDAndStartKeepsMeetingCopy() {
        let a = item("1", "Sync", start: "2026-11-16T09:00:00Z", end: "2026-11-16T10:00:00Z", cal: "c1")
        let b = item("1", "Sync (copy)", start: "2026-11-16T09:00:00Z", end: "2026-11-16T09:45:00Z", cal: "c2", meet: true)
        let result = DisplayRules.dedupe([(a, "uid1"), (b, "uid1")])
        #expect(result.count == 1)
        #expect(result.first?.calendarID == "c2")
    }

    @Test func sameCleanTitleAndTimes() {
        let a = item("1", "Team  sync", start: "2026-11-16T09:00:00Z", end: "2026-11-16T10:00:00Z", cal: "c1", meet: true)
        let b = item("2", " team sync ", start: "2026-11-16T09:00:00Z", end: "2026-11-16T10:00:00Z", cal: "c2")
        let result = DisplayRules.dedupe([(b, "uid2"), (a, "uid1")])
        #expect(result.map(\.id) == [a.id])
    }

    @Test func differentTimesStaySeparate() {
        let a = item("1", "Sync", start: "2026-11-16T09:00:00Z", end: "2026-11-16T10:00:00Z")
        let b = item("2", "Sync", start: "2026-11-16T09:00:00Z", end: "2026-11-16T11:00:00Z")
        let c = item("3", "Sync", start: "2026-11-17T09:00:00Z", end: "2026-11-17T10:00:00Z")
        let result = DisplayRules.dedupe([(c, "u3"), (b, "u2"), (a, "u1")])
        #expect(result.count == 3)
        #expect(result.last?.id == c.id)
    }

    @Test func sameUIDDifferentStartIsRecurringInstance() {
        let a = item("1_a", "Weekly", start: "2026-11-16T09:00:00Z", end: "2026-11-16T10:00:00Z")
        let b = item("1_b", "Weekly", start: "2026-11-23T09:00:00Z", end: "2026-11-23T10:00:00Z")
        #expect(DisplayRules.dedupe([(a, "uid"), (b, "uid")]).count == 2)
    }
}
