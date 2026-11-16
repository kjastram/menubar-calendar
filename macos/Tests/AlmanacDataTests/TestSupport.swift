import AlmanacKit
import Foundation
import Testing
@testable import AlmanacData

/// What a stubbed request looked like.
struct RecordedRequest: Sendable {
    var method: String
    var path: String
    var query: [String: String]
    var headers: [String: String]
    var body: Data?

    var json: [String: Any]? {
        body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
    }
}

struct StubResponse: Sendable {
    var status: Int
    var body: Data

    static func json(_ text: String, status: Int = 200) -> StubResponse {
        StubResponse(status: status, body: Data(text.utf8))
    }

    /// The request fails with a URLError, as when the network is down.
    static let offline = StubResponse(status: -1, body: Data())

    static func error(_ status: Int, _ message: String) -> StubResponse {
        .json(#"{"error":{"code":\#(status),"message":"\#(message)"}}"#, status: status)
    }
}

/// A fake Google server for one test. Each test gets its own URLSession; requests are routed
/// to the right server by a header, so tests can run in parallel.
final class StubServer: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: @Sendable (RecordedRequest) -> StubResponse
    private var log: [RecordedRequest] = []
    let id = UUID().uuidString

    init(_ handler: @escaping @Sendable (RecordedRequest) -> StubResponse) {
        self.handler = handler
        StubProtocol.register(self)
    }

    var session: URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        config.httpAdditionalHeaders = [StubProtocol.header: id]
        return URLSession(configuration: config)
    }

    func setHandler(_ handler: @escaping @Sendable (RecordedRequest) -> StubResponse) {
        lock.withLock { self.handler = handler }
    }

    var requests: [RecordedRequest] { lock.withLock { log } }

    func clearLog() { lock.withLock { log.removeAll() } }

    func respond(_ request: RecordedRequest) -> StubResponse {
        let handler = lock.withLock { () -> @Sendable (RecordedRequest) -> StubResponse in
            log.append(request)
            return self.handler
        }
        return handler(request)
    }
}

final class StubProtocol: URLProtocol, @unchecked Sendable {
    static let header = "X-Stub-Server"
    private static let lock = NSLock()
    nonisolated(unsafe) private static var servers: [String: StubServer] = [:]

    static func register(_ server: StubServer) {
        lock.withLock { servers[server.id] = server }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let id = request.value(forHTTPHeaderField: Self.header) ?? ""
        guard let server = Self.lock.withLock({ Self.servers[id] }), let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        var query: [String: String] = [:]
        for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] {
            query[item.name] = item.value ?? ""
        }
        let recorded = RecordedRequest(
            method: request.httpMethod ?? "GET",
            path: url.path.replacingOccurrences(of: "/calendar/v3", with: ""),
            query: query,
            headers: request.allHTTPHeaderFields ?? [:],
            body: request.httpBody ?? Self.read(request.httpBodyStream))
        let response = server.respond(recorded)
        if response.status < 0 {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let http = HTTPURLResponse(url: url, statusCode: response.status, httpVersion: "HTTP/1.1",
                                   headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func read(_ stream: InputStream?) -> Data? {
        guard let stream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

final class FakeTokens: TokenProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var emails: [String]
    private var signedOut: Set<String> = []
    private var calls = 0
    /// Bumped by invalidateAccessToken, so the next token differs, as after a real refresh.
    private var generation = 0
    private var invalidated: [String?] = []

    init(_ emails: [String]) { self.emails = emails }

    /// Tokens passed to invalidateAccessToken(for:token:), in order.
    var invalidatedTokens: [String?] { lock.withLock { invalidated } }

    func setNeedsSignIn(_ email: String) { lock.withLock { _ = signedOut.insert(email) } }

    func add(_ email: String) { lock.withLock { emails.append(email) } }

    func remove(_ email: String) { lock.withLock { emails.removeAll { $0 == email } } }

    /// How many times accessToken(for:) was called.
    var tokenCalls: Int { lock.withLock { calls } }

    func accessToken(for email: String) async throws -> String {
        let (out, generation) = lock.withLock { () -> (Bool, Int) in
            calls += 1
            return (signedOut.contains(email), self.generation)
        }
        if out { throw AlmanacError.needsSignIn(email: email) }
        return generation == 0 ? "token-\(email)" : "token-\(email)-\(generation)"
    }

    func invalidateAccessToken(for email: String, token: String?) async {
        lock.withLock {
            invalidated.append(token)
            generation += 1
        }
    }

    func signedInEmails() async -> [String] { lock.withLock { emails.sorted() } }
}

/// Builds Google JSON for tests.
enum G {
    static func calendarList(_ entries: [String]) -> StubResponse {
        .json(#"{"items":[\#(entries.joined(separator: ","))]}"#)
    }

    static func calendar(_ id: String, name: String, selected: Bool = true, role: String = "owner",
                         color: String = "#9fc6e7", primary: Bool = false) -> String {
        #"{"id":"\#(id)","summary":"\#(name)","backgroundColor":"\#(color)","accessRole":"\#(role)","selected":\#(selected),"primary":\#(primary)}"#
    }

    static func events(_ items: [String], nextSyncToken: String? = nil, nextPageToken: String? = nil) -> StubResponse {
        var fields = [#""items":[\#(items.joined(separator: ","))]"#]
        if let nextSyncToken { fields.append(#""nextSyncToken":"\#(nextSyncToken)""#) }
        if let nextPageToken { fields.append(#""nextPageToken":"\#(nextPageToken)""#) }
        return .json("{\(fields.joined(separator: ","))}")
    }

    static func timed(_ id: String, _ title: String, start: String, end: String, extra: String = "") -> String {
        #"{"id":"\#(id)","status":"confirmed","etag":"\"e-\#(id)\"","summary":"\#(title)","start":{"dateTime":"\#(start)"},"end":{"dateTime":"\#(end)"},"htmlLink":"https://www.google.com/calendar/event?eid=\#(id)"\#(extra.isEmpty ? "" : "," + extra)}"#
    }

    static func allDay(_ id: String, _ title: String, start: String, end: String, extra: String = "") -> String {
        #"{"id":"\#(id)","status":"confirmed","summary":"\#(title)","start":{"date":"\#(start)"},"end":{"date":"\#(end)"}\#(extra.isEmpty ? "" : "," + extra)}"#
    }

    static func cancelled(_ id: String) -> String {
        #"{"id":"\#(id)","status":"cancelled"}"#
    }

    static let colors = StubResponse.json(##"{"event":{"5":{"background":"#fbd75b","foreground":"#1d1d1d"}}}"##)
}

func date(_ text: String) -> Date { GoogleDates.parseDateTime(text)! }

func localDay(_ text: String) -> Date { GoogleDates.localMidnight(text)! }

func decodeEvent(_ json: String) throws -> GoogleEvent {
    try JSONDecoder().decode(GoogleEvent.self, from: Data(json.utf8))
}

/// A database with one account and the given calendars (local ids "<email>/<googleID>").
func makeDatabase(account: String = "me@example.com",
                  calendars: [String] = [G.calendar("me@example.com", name: "Me", primary: true)]) async throws -> AppDatabase {
    let db = try AppDatabase.inMemory()
    try await db.ensureAccount(account)
    let list = try JSONDecoder().decode(GoogleCalendarListPage.self,
                                        from: Data(#"{"items":[\#(calendars.joined(separator: ","))]}"#.utf8))
    try await db.applyCalendarList(account: account, entries: list.items ?? [])
    return db
}

/// Writes Google events straight into a calendar's cache.
func insert(_ db: AppDatabase, calendarID: String, account: String = "me@example.com", _ events: [String]) async throws {
    let decoded = try events.map(decodeEvent)
    try await db.applyChanges(calendarID: calendarID, accountEmail: account, events: decoded, syncToken: nil)
}

/// Holds a stubbed request until `open()` is called, and tells the test when it was reached.
final class Gate: @unchecked Sendable {
    private let released = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var reached = false

    /// Called from a stub handler: blocks until the test opens the gate (at most 10 seconds).
    func wait() {
        lock.withLock { reached = true }
        _ = released.wait(timeout: .now() + 10)
    }

    var isReached: Bool { lock.withLock { reached } }

    func open() { released.signal() }
}

/// Polls `condition` every 10 ms for up to 5 seconds.
func waitUntil(_ condition: @Sendable () async -> Bool) async throws {
    for _ in 0..<500 {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("condition not met in time")
}
