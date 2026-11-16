import Foundation

/// A signed-in Google account. The email is the id, as in the SwiftBar plugin
/// (the primary calendar's id is the account's email).
public struct Account: Identifiable, Hashable, Sendable {
    public var email: String
    /// Hex color like "#4f8ff7".
    public var color: String
    /// Hidden accounts stay signed in but their events are not shown.
    public var hidden: Bool
    public var status: AccountStatus

    public var id: String { email }

    public init(email: String, color: String, hidden: Bool = false, status: AccountStatus = .ok) {
        self.email = email
        self.color = color
        self.hidden = hidden
        self.status = status
    }
}

public enum AccountStatus: Hashable, Sendable {
    case ok
    /// The refresh token was rejected; the user has to sign in again.
    case needsSignIn
    /// Last sync failed for another reason (network, API error). Cached events are still shown.
    case error(String)
}

/// One calendar from an account's calendarList.
public struct CalendarInfo: Identifiable, Hashable, Sendable {
    /// Local id: "<accountEmail>/<googleID>".
    public var id: String
    public var accountEmail: String
    public var googleID: String
    /// `summaryOverride` if set, otherwise `summary`.
    public var name: String
    public var color: String
    /// Google's accessRole: "owner", "writer", "reader" or "freeBusyReader".
    public var accessRole: String
    public var visible: Bool
    public var isPrimary: Bool

    public var canWrite: Bool { accessRole == "owner" || accessRole == "writer" }

    public init(id: String, accountEmail: String, googleID: String, name: String, color: String,
                accessRole: String, visible: Bool, isPrimary: Bool) {
        self.id = id
        self.accountEmail = accountEmail
        self.googleID = googleID
        self.name = name
        self.color = color
        self.accessRole = accessRole
        self.visible = visible
        self.isPrimary = isPrimary
    }

    public static func localID(accountEmail: String, googleID: String) -> String {
        "\(accountEmail)/\(googleID)"
    }
}

public enum ItemSourceKind: String, Hashable, Sendable, Codable {
    case google
    /// Phase 7.
    case todo
}

/// Something drawn on the calendar. Views use this, never a Google type,
/// so tasks can be added later as another source.
public struct CalendarItem: Identifiable, Hashable, Sendable {
    /// Local id: "<source>:<calendarID>:<externalID>".
    public var id: String
    public var source: ItemSourceKind
    /// Google event id (for a recurring instance, the instance id).
    public var externalID: String
    public var calendarID: String
    public var accountEmail: String
    public var title: String
    /// For all-day items: midnight local time of the first day.
    public var start: Date
    /// For all-day items: midnight local time of the day AFTER the last day (exclusive, like Google).
    public var end: Date
    public var isAllDay: Bool
    public var location: String?
    public var notes: String?
    /// Video meeting link (hangoutLink, conferenceData video entry, or an https location).
    public var meetURL: URL?
    /// Google Calendar web link with `authuser=<email>` added.
    public var webURL: URL?
    /// Event color if set, else the calendar color.
    public var color: String
    /// Your response is "tentative" or "needsAction".
    public var isTentative: Bool
    /// Part of a recurring series. Not editable in v1.
    public var isRecurring: Bool
    public var etag: String?

    public init(id: String, source: ItemSourceKind, externalID: String, calendarID: String,
                accountEmail: String, title: String, start: Date, end: Date, isAllDay: Bool,
                location: String? = nil, notes: String? = nil, meetURL: URL? = nil, webURL: URL? = nil,
                color: String, isTentative: Bool = false, isRecurring: Bool = false, etag: String? = nil) {
        self.id = id
        self.source = source
        self.externalID = externalID
        self.calendarID = calendarID
        self.accountEmail = accountEmail
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.location = location
        self.notes = notes
        self.meetURL = meetURL
        self.webURL = webURL
        self.color = color
        self.isTentative = isTentative
        self.isRecurring = isRecurring
        self.etag = etag
    }

    /// True if the item covers any part of the given interval.
    public func overlaps(_ interval: DateInterval) -> Bool {
        start < interval.end && end > interval.start
    }
}

/// Input for creating or editing an event.
public struct EventDraft: Hashable, Sendable {
    public var calendarID: String
    public var title: String
    public var start: Date
    /// Exclusive for all-day events, as in CalendarItem.
    public var end: Date
    public var isAllDay: Bool
    public var location: String
    public var notes: String
    /// Create a Google Meet link (create only; ignored on edit if one exists).
    public var addMeet: Bool

    public init(calendarID: String, title: String, start: Date, end: Date, isAllDay: Bool,
                location: String = "", notes: String = "", addMeet: Bool = false) {
        self.calendarID = calendarID
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.location = location
        self.notes = notes
        self.addMeet = addMeet
    }

    public init(editing item: CalendarItem) {
        self.init(calendarID: item.calendarID, title: item.title, start: item.start, end: item.end,
                  isAllDay: item.isAllDay, location: item.location ?? "", notes: item.notes ?? "")
    }
}

/// Colors handed out to new accounts in order. Same list and order as the SwiftBar plugin.
public let accountPalette = ["#4f8ff7", "#f0883e", "#3fb950", "#d670d6", "#e5534b", "#2cc6c6", "#e3b341", "#a371f7"]
