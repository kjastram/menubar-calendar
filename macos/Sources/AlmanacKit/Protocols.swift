import Foundation

public enum AlmanacError: Error, Sendable, LocalizedError {
    /// The account's refresh token was rejected or is missing.
    case needsSignIn(email: String)
    /// Google returned an error. `message` is Google's own text when there is one.
    case api(status: Int, message: String)
    /// Recurring events can't be edited in v1.
    case recurringNotSupported
    case readOnlyCalendar
    case notFound

    public var errorDescription: String? {
        switch self {
        case .needsSignIn(let email): "Sign in again: \(email)"
        case .api(let status, let message): message.isEmpty ? "Google returned error \(status)" : message
        case .recurringNotSupported: "Recurring events can be edited in Google Calendar."
        case .readOnlyCalendar: "This calendar is read-only."
        case .notFound: "The event no longer exists."
        }
    }
}

/// Gives a valid access token for an account. Implemented by AlmanacAuth.AuthService.
public protocol TokenProvider: Sendable {
    /// Refreshes the token if needed. Throws `AlmanacError.needsSignIn` if the refresh token is rejected.
    func accessToken(for email: String) async throws -> String
    /// Emails of all signed-in accounts, sorted.
    func signedInEmails() async -> [String]
    /// Google answered 401 with `token`: the next `accessToken(for:)` must refresh instead of
    /// returning it again. Does nothing if `token` was already replaced.
    func invalidateAccessToken(for email: String, token: String?) async
}

extension TokenProvider {
    public func invalidateAccessToken(for email: String, token: String?) async {}
}

/// Read side of the local cache. Implemented by AlmanacData.AppDatabase.
/// All methods are safe to call from any thread.
public protocol CalendarRepository: Sendable {
    func accounts() async throws -> [Account]
    func calendars() async throws -> [CalendarInfo]
    /// Items overlapping `interval` from visible calendars of non-hidden accounts, ready to draw:
    /// cancelled, declined and workingLocation events are already removed, and duplicates across
    /// calendars/accounts are merged (same iCalUID + start, or same title + start + end; the copy
    /// with a meeting link wins). Sorted by start, all-day first on the same day.
    func items(in interval: DateInterval) async throws -> [CalendarItem]
    /// Case-insensitive search in title, location and notes across all cached items.
    func search(_ text: String, limit: Int) async throws -> [CalendarItem]
    /// Yields once right away and again every time accounts, calendars or events change.
    func changes() -> AsyncStream<Void>

    func setCalendarVisible(_ calendarID: String, visible: Bool) async throws
    func setAccountColor(_ email: String, color: String) async throws
    func setAccountHidden(_ email: String, hidden: Bool) async throws
}

/// A place items come from and are written to. Google now, todos later.
/// Implemented by AlmanacData.GoogleCalendarSource. Writes update the cache before returning.
public protocol ItemSource: Sendable {
    var kind: ItemSourceKind { get }
    func create(_ draft: EventDraft) async throws -> CalendarItem
    /// Throws `AlmanacError.recurringNotSupported` for recurring items.
    func update(_ item: CalendarItem, with draft: EventDraft) async throws -> CalendarItem
    func delete(_ item: CalendarItem) async throws
    /// Google's quickAdd: creates an event from a sentence like "Lunch with Sam Friday 1pm".
    func quickAdd(_ text: String, calendarID: String) async throws -> CalendarItem
}

/// Triggers a sync. Implemented by AlmanacData.SyncEngine.
public protocol SyncControl: Sendable {
    func syncNow() async
}
