import AlmanacKit
import Foundation

// MARK: - Google Calendar API v3 JSON

struct GoogleErrorBody: Decodable {
    struct Inner: Decodable {
        var code: Int?
        var message: String?
    }
    var error: Inner?
}

struct GoogleColors: Decodable {
    struct Entry: Decodable {
        var background: String?
    }
    var event: [String: Entry]?
}

struct GoogleCalendarListPage: Decodable {
    var items: [GoogleCalendarListEntry]?
    var nextPageToken: String?
}

struct GoogleCalendarListEntry: Decodable, Sendable {
    var id: String
    var summary: String?
    var summaryOverride: String?
    var backgroundColor: String?
    var accessRole: String?
    var selected: Bool?
    var primary: Bool?

    var displayName: String {
        if let summaryOverride, !summaryOverride.isEmpty { return summaryOverride }
        return summary ?? ""
    }
}

struct GoogleEventsPage: Decodable {
    var items: [GoogleEvent]?
    var nextPageToken: String?
    var nextSyncToken: String?
}

struct GoogleEventTime: Codable, Sendable, Hashable {
    var date: String?
    var dateTime: String?
    var timeZone: String?
}

struct GoogleAttendee: Decodable, Sendable, Hashable {
    var isSelf: Bool?
    var responseStatus: String?

    enum CodingKeys: String, CodingKey {
        case isSelf = "self"
        case responseStatus
    }
}

struct GoogleEntryPoint: Decodable, Sendable, Hashable {
    var entryPointType: String?
    var uri: String?
}

struct GoogleConferenceData: Decodable, Sendable, Hashable {
    var entryPoints: [GoogleEntryPoint]?
}

struct GoogleEvent: Decodable, Sendable, Hashable {
    var id: String
    var status: String?
    var etag: String?
    var summary: String?
    var description: String?
    var location: String?
    var start: GoogleEventTime?
    var end: GoogleEventTime?
    var hangoutLink: String?
    var conferenceData: GoogleConferenceData?
    var attendees: [GoogleAttendee]?
    var eventType: String?
    var iCalUID: String?
    var colorId: String?
    var recurringEventId: String?
    var recurrence: [String]?
    var htmlLink: String?
    var updated: String?

    /// Same order as the plugin's `join_url`: hangoutLink, the conferenceData video entry,
    /// then a location that starts with https:// (its first word).
    var meetLink: String? {
        if let hangoutLink, !hangoutLink.isEmpty { return hangoutLink }
        for point in conferenceData?.entryPoints ?? [] where point.entryPointType == "video" {
            return point.uri
        }
        if let location, location.hasPrefix("https://") {
            return location.split(whereSeparator: \.isWhitespace).first.map(String.init)
        }
        return nil
    }

    /// Your own attendee entry's response, "accepted" when you are not listed (as in the plugin).
    var selfResponse: String {
        attendees?.first(where: { $0.isSelf == true })?.responseStatus ?? "accepted"
    }
}

// MARK: - HTTP client

/// Thin URLSession client for the endpoints Almanac uses. Every request asks the
/// TokenProvider for a fresh access token, so refreshes happen in one place.
struct GoogleAPI: Sendable {
    static let baseURL = "https://www.googleapis.com/calendar/v3"

    let tokens: any TokenProvider
    let session: URLSession

    enum Method: String {
        case get = "GET", post = "POST", patch = "PATCH", delete = "DELETE"
    }

    /// Characters left as-is in path segments and query values. Everything else is
    /// percent-encoded, so ids with `#` or `@` and tokens with `+` survive.
    private static let unreserved = CharacterSet(charactersIn:
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")

    static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }

    func request(
        _ method: Method, _ path: String, account: String, query: [(String, String)] = [],
        body: Data? = nil, headers: [String: String] = [:]
    ) async throws -> Data {
        let token = try await tokens.accessToken(for: account)
        do {
            return try await send(method, path, token: token, query: query, body: body, headers: headers)
        } catch AlmanacError.api(status: 401, _) {
            // The cached access token may have been revoked before it expired: drop it, get a
            // fresh one and retry once. A second 401 means the account has to sign in again.
            await tokens.invalidateAccessToken(for: account, token: token)
            let fresh = try await tokens.accessToken(for: account)
            do {
                return try await send(method, path, token: fresh, query: query, body: body, headers: headers)
            } catch AlmanacError.api(status: 401, _) {
                throw AlmanacError.needsSignIn(email: account)
            }
        }
    }

    private func send(
        _ method: Method, _ path: String, token: String, query: [(String, String)],
        body: Data?, headers: [String: String]
    ) async throws -> Data {
        var urlString = Self.baseURL + path
        if !query.isEmpty {
            urlString += "?" + query.map { "\(Self.encode($0.0))=\(Self.encode($0.1))" }.joined(separator: "&")
        }
        guard let url = URL(string: urlString) else {
            throw AlmanacError.api(status: 0, message: "Bad request URL")
        }
        var req = URLRequest(url: url)
        req.httpMethod = method.rawValue
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        for (name, value) in headers { req.setValue(value, forHTTPHeaderField: name) }

        let (data, response) = try await session.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let message = (try? JSONDecoder().decode(GoogleErrorBody.self, from: data))?.error?.message ?? ""
            throw AlmanacError.api(status: status, message: message)
        }
        return data
    }

    func get<T: Decodable>(_ type: T.Type, _ path: String, account: String, query: [(String, String)] = []) async throws -> T {
        let data = try await request(.get, path, account: account, query: query)
        return try JSONDecoder().decode(T.self, from: data)
    }

    // MARK: Endpoints

    func eventPalette(account: String) async throws -> [String: String] {
        let colors = try await get(GoogleColors.self, "/colors", account: account)
        return (colors.event ?? [:]).compactMapValues(\.background)
    }

    func calendarList(account: String) async throws -> [GoogleCalendarListEntry] {
        var all: [GoogleCalendarListEntry] = []
        var pageToken: String?
        repeat {
            var query = [("maxResults", "250")]
            if let pageToken { query.append(("pageToken", pageToken)) }
            let page = try await get(GoogleCalendarListPage.self, "/users/me/calendarList", account: account, query: query)
            all += page.items ?? []
            pageToken = page.nextPageToken
        } while pageToken != nil
        return all
    }

    /// Pages through events.list. Returns all items and the final page's nextSyncToken.
    func listEvents(account: String, calendarID: String, query base: [(String, String)]) async throws -> (events: [GoogleEvent], syncToken: String?) {
        var all: [GoogleEvent] = []
        var pageToken: String?
        var syncToken: String?
        repeat {
            var query = base + [("maxResults", "250")]
            if let pageToken { query.append(("pageToken", pageToken)) }
            let page = try await get(GoogleEventsPage.self, "/calendars/\(Self.encode(calendarID))/events",
                                     account: account, query: query)
            all += page.items ?? []
            pageToken = page.nextPageToken
            syncToken = page.nextSyncToken ?? syncToken
        } while pageToken != nil
        return (all, syncToken)
    }
}
