import AlmanacKit
import Foundation
import GRDB

// MARK: - Rows

struct AccountRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "accounts"

    var source: String = ItemSourceKind.google.rawValue
    /// The account email.
    var externalID: String
    var color: String
    var hidden: Bool
    /// "ok", "needsSignIn" or "error".
    var status: String
    var statusMessage: String?

    enum CodingKeys: String, CodingKey {
        case source, externalID = "external_id", color, hidden, status, statusMessage = "status_message"
    }

    var accountStatus: AccountStatus {
        switch status {
        case "needsSignIn": .needsSignIn
        case "error": .error(statusMessage ?? "")
        default: .ok
        }
    }

    static func encode(_ status: AccountStatus) -> (String, String?) {
        switch status {
        case .ok: ("ok", nil)
        case .needsSignIn: ("needsSignIn", nil)
        case .error(let message): ("error", message)
        }
    }

    var account: Account {
        Account(email: externalID, color: color, hidden: hidden, status: accountStatus)
    }
}

struct CalendarRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {
    static let databaseTableName = "calendars"

    /// Local id "<email>/<googleID>".
    var id: String
    var source: String = ItemSourceKind.google.rawValue
    var accountEmail: String
    /// Google calendar id.
    var externalID: String
    var name: String
    var color: String
    var accessRole: String
    var visible: Bool
    var isPrimary: Bool
    /// Message from this calendar's last failed sync, nil after a successful one.
    var syncError: String?

    enum CodingKeys: String, CodingKey {
        case id, source, accountEmail = "account_email", externalID = "external_id", name, color,
             accessRole = "access_role", visible, isPrimary = "is_primary", syncError = "sync_error"
    }

    var info: CalendarInfo {
        CalendarInfo(id: id, accountEmail: accountEmail, googleID: externalID, name: name, color: color,
                     accessRole: accessRole, visible: visible, isPrimary: isPrimary)
    }
}

/// One cached Google event. Rows keep the fields the display rules need; skipping
/// cancelled/declined/workingLocation events happens when reading, not here.
struct EventRecord: Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {
    static let databaseTableName = "events"

    var source: String = ItemSourceKind.google.rawValue
    var calendarID: String
    /// Google event id (instance id for recurring instances).
    var externalID: String
    var etag: String?
    var title: String?
    /// Unix seconds. For all-day events, local midnight when the row was written;
    /// `startDate`/`endDate` are the source of truth and are re-read at display time.
    var startAt: Double
    var endAt: Double
    var allDay: Bool
    /// "yyyy-MM-dd" for all-day events (end is exclusive), nil otherwise.
    var startDate: String?
    var endDate: String?
    var location: String?
    var notes: String?
    var meetURL: String?
    /// htmlLink with authuser=<email> added.
    var webURL: String?
    var recurringEventID: String?
    var isRecurring: Bool
    var status: String?
    var eventType: String?
    var iCalUID: String?
    var colorID: String?
    /// Resolved from colors.get; nil means use the calendar color.
    var color: String?
    var selfResponse: String
    var updatedAt: String?
    /// The event's own start.timeZone, sent back on patch so edits keep it.
    var timeZone: String?

    enum CodingKeys: String, CodingKey {
        case source, calendarID = "calendar_id", externalID = "external_id", etag, title,
             startAt = "start_at", endAt = "end_at", allDay = "all_day", startDate = "start_date",
             endDate = "end_date", location, notes, meetURL = "meet_url", webURL = "web_url",
             recurringEventID = "recurring_event_id", isRecurring = "is_recurring", status,
             eventType = "event_type", iCalUID = "ical_uid", colorID = "color_id", color,
             selfResponse = "self_response", updatedAt = "updated_at", timeZone = "time_zone"
    }

    /// Hidden from the calendar per the plugin's rules.
    var isSkipped: Bool {
        status == "cancelled" || eventType == "workingLocation" || selfResponse == "declined"
    }
}

struct SyncStateRecord: Codable, FetchableRecord, PersistableRecord, Sendable {
    static let databaseTableName = "sync_state"

    var calendarID: String
    var syncToken: String?
    var lastFullSync: Double?

    enum CodingKeys: String, CodingKey {
        case calendarID = "calendar_id", syncToken = "sync_token", lastFullSync = "last_full_sync"
    }
}

// MARK: - Dates

enum GoogleDates {
    /// RFC 3339, with or without fractional seconds.
    static func parseDateTime(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)
    }

    static func formatDateTime(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = timeZone
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    /// "yyyy-MM-dd" → midnight local time of that day.
    static func localMidnight(_ text: String, calendar: Calendar = .current) -> Date? {
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    /// Local calendar day of `date` as "yyyy-MM-dd".
    static func dayString(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}

// MARK: - Google event → row

extension EventRecord {
    /// Builds a row from a Google event. Returns nil when the event has no usable start/end
    /// (cancelled entries in incremental results often carry only an id).
    init?(event: GoogleEvent, calendarID: String, accountEmail: String, palette: [String: String],
          calendar: Calendar = .current) {
        guard let start = event.start, let end = event.end else { return nil }
        let startAt: Date
        let endAt: Date
        if let startDay = start.date {
            guard let s = GoogleDates.localMidnight(startDay, calendar: calendar) else { return nil }
            let e = end.date.flatMap { GoogleDates.localMidnight($0, calendar: calendar) }
                ?? calendar.date(byAdding: .day, value: 1, to: s) ?? s
            startAt = s
            endAt = e
        } else {
            guard let s = start.dateTime.flatMap(GoogleDates.parseDateTime),
                  let e = end.dateTime.flatMap(GoogleDates.parseDateTime) else { return nil }
            startAt = s
            endAt = e
        }
        let allDay = start.date != nil
        var webURL: String?
        if let link = event.htmlLink, !link.isEmpty {
            // authuser opens the event in the right account when the browser has several.
            webURL = link + (link.contains("?") ? "&" : "?") + "authuser=" + accountEmail
        }
        self.init(
            calendarID: calendarID,
            externalID: event.id,
            etag: event.etag,
            title: event.summary,
            startAt: startAt.timeIntervalSince1970,
            endAt: endAt.timeIntervalSince1970,
            allDay: allDay,
            startDate: allDay ? start.date : nil,
            endDate: allDay ? (end.date ?? GoogleDates.dayString(endAt, calendar: calendar)) : nil,
            location: event.location,
            notes: event.description,
            meetURL: event.meetLink,
            webURL: webURL,
            recurringEventID: event.recurringEventId,
            isRecurring: event.recurringEventId != nil || !(event.recurrence ?? []).isEmpty,
            status: event.status,
            eventType: event.eventType,
            iCalUID: event.iCalUID,
            colorID: event.colorId,
            color: event.colorId.flatMap { palette[$0] },
            selfResponse: event.selfResponse,
            updatedAt: event.updated,
            timeZone: start.timeZone
        )
    }

    /// The drawable item. `calendarColor` is used when the event has no color of its own.
    func item(accountEmail: String, calendarColor: String, calendar: Calendar = .current) -> CalendarItem {
        var start = Date(timeIntervalSince1970: startAt)
        var end = Date(timeIntervalSince1970: endAt)
        if allDay {
            // Recompute from the stored day so a time zone change doesn't shift all-day events.
            if let s = startDate.flatMap({ GoogleDates.localMidnight($0, calendar: calendar) }) { start = s }
            if let e = endDate.flatMap({ GoogleDates.localMidnight($0, calendar: calendar) }) { end = e }
        }
        return CalendarItem(
            id: "\(source):\(calendarID):\(externalID)",
            source: ItemSourceKind(rawValue: source) ?? .google,
            externalID: externalID,
            calendarID: calendarID,
            accountEmail: accountEmail,
            title: (title?.isEmpty ?? true) ? "(No title)" : title ?? "",
            start: start,
            end: end,
            isAllDay: allDay,
            location: (location?.isEmpty ?? true) ? nil : location,
            notes: (notes?.isEmpty ?? true) ? nil : notes,
            meetURL: meetURL.flatMap { URL(string: $0) },
            webURL: webURL.flatMap { URL(string: $0) },
            color: color ?? calendarColor,
            isTentative: selfResponse == "tentative" || selfResponse == "needsAction",
            isRecurring: isRecurring,
            etag: etag
        )
    }
}

// MARK: - Display rules

enum DisplayRules {
    /// Whitespace collapsed and lowercased, for the title part of the duplicate key.
    static func cleanTitle(_ text: String) -> String {
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return (collapsed.isEmpty ? "(No title)" : collapsed).lowercased()
    }

    /// Display order: by start, all-day first at the same start, then title.
    static func ordered(_ a: CalendarItem, _ b: CalendarItem) -> Bool {
        if a.start != b.start { return a.start < b.start }
        if a.isAllDay != b.isAllDay { return a.isAllDay }
        if a.title != b.title { return a.title < b.title }
        return a.id < b.id
    }

    /// The plugin's duplicate rule: same iCalUID + start, or same cleaned title + start + end.
    /// Copies with a meeting link are considered first, so they win. Result is sorted for display.
    static func dedupe(_ entries: [(item: CalendarItem, uid: String)]) -> [CalendarItem] {
        struct UIDKey: Hashable { var uid: String; var start: Date }
        struct TitleKey: Hashable { var title: String; var start: Date; var end: Date }
        let sorted = entries.sorted { a, b in
            if (a.item.meetURL != nil) != (b.item.meetURL != nil) { return a.item.meetURL != nil }
            return ordered(a.item, b.item)
        }
        var seenUID = Set<UIDKey>()
        var seenTitle = Set<TitleKey>()
        var result: [CalendarItem] = []
        for entry in sorted {
            let u = UIDKey(uid: entry.uid, start: entry.item.start)
            let t = TitleKey(title: cleanTitle(entry.item.title), start: entry.item.start, end: entry.item.end)
            if seenUID.contains(u) || seenTitle.contains(t) { continue }
            seenUID.insert(u)
            seenTitle.insert(t)
            result.append(entry.item)
        }
        return result.sorted(by: ordered)
    }
}
