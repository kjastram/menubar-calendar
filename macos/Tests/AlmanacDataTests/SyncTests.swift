import AlmanacKit
import Foundation
import Testing
@testable import AlmanacData

/// Mutable fake Google state shared with the stub handler.
final class FakeGoogle: @unchecked Sendable {
    private let lock = NSLock()
    private var routes: [String: @Sendable (RecordedRequest) -> StubResponse] = [:]

    func on(_ path: String, _ response: @escaping @Sendable (RecordedRequest) -> StubResponse) {
        lock.withLock { routes[path] = response }
    }

    func handle(_ request: RecordedRequest) -> StubResponse {
        let route = lock.withLock { routes[request.path] }
        return route?(request) ?? .error(404, "Not Found: \(request.path)")
    }
}

@Suite struct SyncTests {
    let me = "me@example.com"
    let meCal = "me@example.com/me@example.com"
    let teamCal = "me@example.com/team@group.calendar.google.com"

    func setup(accounts: [String] = ["me@example.com"]) throws -> (AppDatabase, FakeGoogle, StubServer, FakeTokens, SyncEngine) {
        let db = try AppDatabase.inMemory()
        let google = FakeGoogle()
        let server = StubServer { google.handle($0) }
        let tokens = FakeTokens(accounts)
        let engine = SyncEngine(tokens: tokens, database: db, session: server.session)
        google.on("/colors") { _ in G.colors }
        google.on("/users/me/calendarList") { _ in
            G.calendarList([G.calendar("me@example.com", name: "me@example.com", primary: true),
                            G.calendar("team@group.calendar.google.com", name: "Team", role: "reader")])
        }
        google.on("/calendars/team@group.calendar.google.com/events") { req in
            G.events([], nextSyncToken: req.query["syncToken"] == nil ? "t1" : "t2")
        }
        return (db, google, server, tokens, engine)
    }

    @Test func fullThenIncrementalSync() async throws {
        let (db, google, server, _, engine) = try setup()
        google.on("/calendars/me@example.com/events") { req in
            switch (req.query["syncToken"], req.query["pageToken"]) {
            case (nil, nil):
                return G.events([
                    G.timed("e1", "Standup", start: "2026-11-16T09:00:00Z", end: "2026-11-16T09:30:00Z", extra: #""colorId":"5""#),
                    G.timed("e2", "Review", start: "2026-11-16T11:00:00Z", end: "2026-11-16T12:00:00Z"),
                ], nextPageToken: "p2")
            case (nil, "p2"):
                return G.events([
                    G.timed("r1_20261117", "Weekly", start: "2026-11-17T09:00:00Z", end: "2026-11-17T10:00:00Z",
                            extra: #""recurringEventId":"r1""#),
                    G.allDay("a1", "Offsite", start: "2026-11-18", end: "2026-11-19"),
                ], nextSyncToken: "s1")
            case ("s1", nil):
                return G.events([
                    G.cancelled("e2"),
                    G.cancelled("r1"),
                    G.timed("e1", "Standup (moved)", start: "2026-11-16T10:00:00Z", end: "2026-11-16T10:30:00Z"),
                    G.timed("e4", "New", start: "2026-11-16T14:00:00Z", end: "2026-11-16T15:00:00Z"),
                ], nextSyncToken: "s2")
            default:
                return .error(400, "unexpected \(req.query)")
            }
        }

        await engine.syncNow()

        let accounts = try await db.accounts()
        #expect(accounts.map(\.email) == [me])
        #expect(accounts.first?.color == accountPalette[0])
        #expect(accounts.first?.status == .ok)
        #expect(try await db.calendars().map(\.id).sorted() == [meCal, teamCal])

        let full = server.requests.filter { $0.path == "/calendars/me@example.com/events" }
        #expect(full.count == 2)
        for req in full {
            #expect(req.query["singleEvents"] == "true")
            #expect(req.query["syncToken"] == nil)
            #expect(req.query["orderBy"] == nil)
            #expect(req.headers["Authorization"] == "Bearer token-me@example.com")
        }
        let timeMin = try #require(full.first?.query["timeMin"].flatMap(GoogleDates.parseDateTime))
        let timeMax = try #require(full.first?.query["timeMax"].flatMap(GoogleDates.parseDateTime))
        let days = timeMax.timeIntervalSince(timeMin) / 86_400
        #expect(days > 450 && days < 462)  // 3 months back + 12 months ahead
        #expect(abs(timeMin.timeIntervalSinceNow + 92 * 86_400) < 3 * 86_400)
        #expect(full.last?.query["pageToken"] == "p2")
        #expect(try await db.syncState(calendarID: meCal)?.syncToken == "s1")
        #expect(try await db.syncState(calendarID: teamCal)?.syncToken == "t1")

        let week = DateInterval(start: date("2026-11-16T00:00:00Z"), end: date("2026-11-20T00:00:00Z"))
        var items = try await db.items(in: week)
        #expect(Set(items.map(\.externalID)) == ["e1", "e2", "r1_20261117", "a1"])
        #expect(items.first { $0.externalID == "e1" }?.color == "#fbd75b")

        server.clearLog()
        await engine.syncNow()

        let incremental = server.requests.filter { $0.path.hasSuffix("/events") }
        #expect(incremental.count == 2)
        for req in incremental {
            #expect(req.query["syncToken"] != nil)
            #expect(req.query["singleEvents"] == "true")
            #expect(req.query["timeMin"] == nil)
            #expect(req.query["timeMax"] == nil)
        }
        items = try await db.items(in: week)
        #expect(Set(items.map(\.externalID)) == ["e1", "e4", "a1"])
        #expect(items.first { $0.externalID == "e1" }?.title == "Standup (moved)")
        #expect(try await db.syncState(calendarID: meCal)?.syncToken == "s2")
        #expect(try await db.syncState(calendarID: teamCal)?.syncToken == "t2")
    }

    @Test func goneTokenTriggersFullResync() async throws {
        let (db, google, server, _, engine) = try setup()
        google.on("/calendars/me@example.com/events") { req in
            switch req.query["syncToken"] {
            case nil:
                return G.events([G.timed("fresh", "Fresh", start: "2026-11-16T09:00:00Z", end: "2026-11-16T10:00:00Z")],
                                nextSyncToken: "s9")
            default:
                return .error(410, "Sync token is no longer valid, a full sync is required.")
            }
        }
        // Cached state from an earlier run.
        let stale = try decodeEvent(G.timed("stale", "Stale", start: "2026-11-16T12:00:00Z", end: "2026-11-16T13:00:00Z"))
        try await db.ensureAccount(me)
        let list = try JSONDecoder().decode(GoogleCalendarListPage.self, from: Data(#"{"items":[\#(G.calendar(me, name: me, primary: true))]}"#.utf8))
        try await db.applyCalendarList(account: me, entries: list.items ?? [])
        try await db.replaceEvents(calendarID: meCal, accountEmail: me, events: [stale], syncToken: "old")

        await engine.syncNow()

        let calls = server.requests.filter { $0.path == "/calendars/me@example.com/events" }
        #expect(calls.map { $0.query["syncToken"] } == ["old", nil])
        #expect(calls.last?.query["timeMin"] != nil)
        #expect(try await db.eventRecords(calendarID: meCal).map(\.externalID) == ["fresh"])
        #expect(try await db.syncState(calendarID: meCal)?.syncToken == "s9")
        #expect(try await db.accounts().first?.status == .ok)
    }

    @Test func needsSignInKeepsCachedEvents() async throws {
        let (db, google, _, tokens, engine) = try setup()
        google.on("/calendars/me@example.com/events") { req in
            G.events([G.timed("e1", "Kept", start: "2026-11-16T09:00:00Z", end: "2026-11-16T10:00:00Z")], nextSyncToken: "s1")
        }
        await engine.syncNow()
        tokens.setNeedsSignIn(me)
        await engine.syncNow()

        #expect(try await db.accounts().first?.status == .needsSignIn)
        let items = try await db.items(in: DateInterval(start: date("2026-11-16T00:00:00Z"), duration: 86_400))
        #expect(items.map(\.title) == ["Kept"])
    }

    @Test func accountLevelErrorUsesGoogleMessageAndOnlyAffectsThatAccount() async throws {
        let (db, google, _, _, engine) = try setup(accounts: ["me@example.com", "work@example.com"])
        let failing = Flag()
        google.on("/calendars/me@example.com/events") { _ in
            G.events([G.timed("e1", "Cached", start: "2026-11-16T09:00:00Z", end: "2026-11-16T10:00:00Z")], nextSyncToken: "s1")
        }
        google.on("/calendars/work@example.com/events") { _ in G.events([], nextSyncToken: "w1") }
        // Both accounts see the same calendarList route; give work its own primary calendar.
        google.on("/users/me/calendarList") { req in
            if req.headers["Authorization"] == "Bearer token-work@example.com" {
                return G.calendarList([G.calendar("work@example.com", name: "Work", primary: true)])
            }
            return failing.isSet ? .error(403, "Rate Limit Exceeded")
                : G.calendarList([G.calendar("me@example.com", name: "Me", primary: true)])
        }
        await engine.syncNow()
        failing.set()
        await engine.syncNow()

        let status = Dictionary(uniqueKeysWithValues: try await db.accounts().map { ($0.email, $0.status) })
        #expect(status == ["me@example.com": .error("Rate Limit Exceeded"), "work@example.com": .ok])
        #expect(try await db.accounts().map(\.color) == [accountPalette[0], accountPalette[1]])
        let items = try await db.items(in: DateInterval(start: date("2026-11-16T00:00:00Z"), duration: 86_400))
        #expect(items.map(\.title) == ["Cached"])
        // Account-level failures make the engine back off.
        let broken = StubServer { _ in .error(500, "Backend Error") }
        let api = GoogleAPI(tokens: FakeTokens([me]), session: broken.session)
        #expect(await SyncEngine.syncAccount(me, api: api, database: db) == false)
    }

    @Test(arguments: [(429, "Too Many Requests"), (503, "Backend Error"), (403, "Rate Limit Exceeded")])
    func rateLimitOrServerErrorInCalendarFailsAccount(status: Int, message: String) async throws {
        let (db, google, server, _, _) = try setup()
        google.on("/calendars/me@example.com/events") { _ in .error(status, message) }
        let api = GoogleAPI(tokens: FakeTokens([me]), session: server.session)
        try await db.ensureAccount(me)
        #expect(await SyncEngine.syncAccount(me, api: api, database: db) == false)  // backs off
        #expect(try await db.accounts().first?.status == .error(message))
    }

    @Test func calendarErrorIsRecordedPerCalendarWithoutBackoff() async throws {
        let (db, google, server, _, engine) = try setup()
        let failing = Flag()
        google.on("/users/me/calendarList") { _ in
            G.calendarList([G.calendar("me@example.com", name: "Me", primary: true),
                            G.calendar("team@group.calendar.google.com", name: "Team", role: "reader"),
                            G.calendar("off@group.calendar.google.com", name: "Off", selected: false)])
        }
        google.on("/calendars/me@example.com/events") { _ in
            G.events([G.timed("e1", "Kept", start: "2026-11-16T09:00:00Z", end: "2026-11-16T10:00:00Z")], nextSyncToken: "s1")
        }
        google.on("/calendars/team@group.calendar.google.com/events") { _ in
            failing.isSet ? .error(404, "Calendar not found") : G.events([], nextSyncToken: "t1")
        }
        google.on("/calendars/off@group.calendar.google.com/events") { _ in .error(403, "Forbidden") }
        await engine.syncNow()
        #expect(try await db.calendarErrors().isEmpty)  // the failing calendar is hidden
        #expect(try await db.calendar(id: "me@example.com/off@group.calendar.google.com")?.syncError == "Forbidden")

        failing.set()
        let api = GoogleAPI(tokens: FakeTokens([me]), session: server.session)
        #expect(await SyncEngine.syncAccount(me, api: api, database: db) == true)  // no backoff

        #expect(try await db.accounts().first?.status == .ok)
        #expect(try await db.calendarErrors() == [teamCal: "Calendar not found"])
        let items = try await db.items(in: DateInterval(start: date("2026-11-16T00:00:00Z"), duration: 86_400))
        #expect(items.map(\.title) == ["Kept"])

        // Hiding the account hides its calendar errors too.
        try await db.setAccountHidden(me, hidden: true)
        #expect(try await db.calendarErrors().isEmpty)
        try await db.setAccountHidden(me, hidden: false)

        // A later success clears the error.
        google.on("/calendars/team@group.calendar.google.com/events") { _ in G.events([], nextSyncToken: "t2") }
        await engine.syncNow()
        #expect(try await db.calendarErrors().isEmpty)
    }

    @Test func networkErrorInCalendarMarksAccountAndBacksOff() async throws {
        let (db, google, server, _, _) = try setup()
        google.on("/calendars/me@example.com/events") { _ in .offline }
        let api = GoogleAPI(tokens: FakeTokens([me]), session: server.session)
        try await db.ensureAccount(me)
        #expect(await SyncEngine.syncAccount(me, api: api, database: db) == false)
        guard case .error = try await db.accounts().first?.status else {
            Issue.record("expected an account error")
            return
        }
    }

    @Test func staleFullSyncRunsAgainWithMovedWindow() async throws {
        let (db, google, server, _, engine) = try setup()
        google.on("/calendars/me@example.com/events") { req in
            req.query["syncToken"] == nil
                ? G.events([G.timed("late", "Far ahead", start: "2027-11-10T09:00:00Z", end: "2027-11-10T10:00:00Z")],
                           nextSyncToken: "s2")
                : G.events([], nextSyncToken: "s1b")
        }
        try await db.ensureAccount(me)
        _ = try await db.applyCalendarList(account: me, entries: JSONDecoder().decode(GoogleCalendarListPage.self,
            from: Data(#"{"items":[\#(G.calendar(me, name: me, primary: true))]}"#.utf8)).items ?? [])
        let old = try decodeEvent(G.timed("old", "Old", start: "2026-11-16T09:00:00Z", end: "2026-11-16T10:00:00Z"))
        try await db.replaceEvents(calendarID: meCal, accountEmail: me, events: [old], syncToken: "s1")

        // Synced fully 3 days ago: only the token is used.
        try await db.writer.write { db in
            try db.execute(sql: "UPDATE sync_state SET last_full_sync = ?", arguments: [Date().timeIntervalSince1970 - 3 * 86_400])
        }
        await engine.syncNow()
        var calls = server.requests.filter { $0.path == "/calendars/me@example.com/events" }
        #expect(calls.map { $0.query["syncToken"] } == ["s1"])

        // 8 days ago: full sync again, which replaces the rows and resets the clock.
        try await db.writer.write { db in
            try db.execute(sql: "UPDATE sync_state SET last_full_sync = ?", arguments: [Date().timeIntervalSince1970 - 8 * 86_400])
        }
        server.clearLog()
        await engine.syncNow()
        calls = server.requests.filter { $0.path == "/calendars/me@example.com/events" }
        #expect(calls.count == 1)
        #expect(calls.first?.query["syncToken"] == nil)
        let timeMax = try #require(calls.first?.query["timeMax"].flatMap(GoogleDates.parseDateTime))
        let expectedMax = try #require(Calendar.current.date(byAdding: .month, value: 12, to: Date()))
        #expect(abs(timeMax.timeIntervalSince(expectedMax)) < 3600)  // measured from now, not from the first sync
        #expect(try await db.eventRecords(calendarID: meCal).map(\.externalID) == ["late"])
        let state = try #require(try await db.syncState(calendarID: meCal))
        #expect(state.syncToken == "s2")
        #expect(abs((state.lastFullSync ?? 0) - Date().timeIntervalSince1970) < 60)
    }

    @Test func goneTokenKeepsCacheUntilFullSyncSucceeds() async throws {
        let (db, google, _, _, engine) = try setup()
        google.on("/calendars/me@example.com/events") { req in
            req.query["syncToken"] == nil ? .error(500, "Backend Error") : .error(410, "Gone")
        }
        try await db.ensureAccount(me)
        _ = try await db.applyCalendarList(account: me, entries: JSONDecoder().decode(GoogleCalendarListPage.self,
            from: Data(#"{"items":[\#(G.calendar(me, name: me, primary: true))]}"#.utf8)).items ?? [])
        let cached = try decodeEvent(G.timed("cached", "Cached", start: "2026-11-16T12:00:00Z", end: "2026-11-16T13:00:00Z"))
        try await db.replaceEvents(calendarID: meCal, accountEmail: me, events: [cached], syncToken: "old")

        await engine.syncNow()

        #expect(try await db.eventRecords(calendarID: meCal).map(\.externalID) == ["cached"])
        let state = try #require(try await db.syncState(calendarID: meCal))
        #expect(state.syncToken == nil)
        // A 5xx is a Google-side problem, so it fails the account (and the engine backs off).
        #expect(try await db.accounts().first?.status == .error("Backend Error"))
    }

    @Test(.timeLimit(.minutes(1))) func syncNowDuringRunningPassRunsOneMorePass() async throws {
        let (db, google, server, tokens, engine) = try setup()
        let gate = Gate()
        let first = Flag()
        google.on("/colors") { _ in
            if !first.isSet { first.set(); gate.wait() }
            return G.colors
        }
        google.on("/calendars/me@example.com/events") { _ in G.events([], nextSyncToken: "s1") }
        google.on("/calendars/new@example.com/events") { _ in G.events([], nextSyncToken: "n1") }

        let running = Task { await engine.syncNow() }
        try await waitUntil { gate.isReached }
        // An account signs in while the first pass (which read the account list already) is blocked.
        tokens.add("new@example.com")
        let second = Task { await engine.syncNow() }
        try await waitUntil { await engine.hasQueuedPass }
        let third = Task { await engine.syncNow() }
        try await Task.sleep(for: .milliseconds(100))
        gate.open()
        await second.value
        #expect(try await db.accounts().map(\.email).contains("new@example.com"))
        await third.value
        await running.value
        // First pass: one account. The single extra pass shared by both callers: two accounts.
        #expect(server.requests.filter { $0.path == "/colors" }.count == 3)
        #expect(await engine.hasQueuedPass == false)
    }

    @Test(.timeLimit(.minutes(1))) func accountRemovedDuringSyncLeavesNoRows() async throws {
        let (db, google, _, tokens, engine) = try setup()
        let gate = Gate()
        google.on("/users/me/calendarList") { _ in
            gate.wait()
            return G.calendarList([G.calendar("me@example.com", name: "Me", primary: true)])
        }
        google.on("/calendars/me@example.com/events") { _ in G.events([], nextSyncToken: "s1") }
        let sync = Task { await engine.syncNow() }
        try await waitUntil { gate.isReached }
        // What AppModel.removeAccount does: sign out, then delete the rows.
        tokens.remove(me)
        try await db.removeAccount(me)
        gate.open()
        await sync.value
        #expect(try await db.accounts().isEmpty)
        #expect(try await db.calendars().isEmpty)
    }

    @Test(.timeLimit(.minutes(1))) func startPollsUntilStopped() async throws {
        let db = try AppDatabase.inMemory()
        let google = FakeGoogle()
        let server = StubServer { google.handle($0) }
        google.on("/colors") { _ in G.colors }
        google.on("/users/me/calendarList") { _ in G.calendarList([]) }
        let engine = SyncEngine(tokens: FakeTokens([me]), database: db, session: server.session,
                                interval: .milliseconds(20))
        await engine.start()
        while server.requests.filter({ $0.path == "/colors" }).count < 3 {
            try await Task.sleep(for: .milliseconds(10))
        }
        await engine.stop()
        try await Task.sleep(for: .milliseconds(100))
        let count = server.requests.count
        try await Task.sleep(for: .milliseconds(100))
        #expect(server.requests.count == count)
    }
}

extension SyncTests {
    @Test(.timeLimit(.minutes(1))) func passFinishedRunsForSyncNowAndTimedPasses() async throws {
        let db = try AppDatabase.inMemory()
        let google = FakeGoogle()
        let server = StubServer { google.handle($0) }
        google.on("/colors") { _ in G.colors }
        google.on("/users/me/calendarList") { _ in G.calendarList([]) }
        let engine = SyncEngine(tokens: FakeTokens([me]), database: db, session: server.session,
                                interval: .milliseconds(20))
        let passes = Counter()
        await engine.setOnPassFinished { _ = passes.increment() }
        await engine.syncNow()
        #expect(passes.value == 1)
        await engine.start()
        while passes.value < 3 {
            try await Task.sleep(for: .milliseconds(10))
        }
        await engine.stop()
    }
}

final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}
