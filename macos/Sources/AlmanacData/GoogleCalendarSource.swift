import AlmanacKit
import Foundation

/// Writes events to Google Calendar. Each write updates the cache before returning, and marks the
/// event as written locally so a sync fetched before the write can't undo it.
public actor GoogleCalendarSource: ItemSource {
    public nonisolated let kind: ItemSourceKind = .google

    private let api: GoogleAPI
    private let database: AppDatabase

    public init(tokens: any TokenProvider, database: AppDatabase, session: URLSession = .shared) {
        self.api = GoogleAPI(tokens: tokens, session: session)
        self.database = database
    }

    public func create(_ draft: EventDraft) async throws -> CalendarItem {
        let calendar = try await writableCalendar(draft.calendarID)
        var body = Self.fields(draft)
        var query: [(String, String)] = []
        if draft.addMeet {
            body["conferenceData"] = Self.meetRequest()
            query.append(("conferenceDataVersion", "1"))
        }
        let data = try await api.request(.post, eventsPath(calendar), account: calendar.accountEmail, query: query,
                                         body: try JSONSerialization.data(withJSONObject: body))
        return try await store(data, in: calendar)
    }

    /// Patches the event in its current calendar, then moves it if the calendar changed. If the move
    /// fails, the cache keeps the patched event in its original calendar and the error says so.
    public func update(_ item: CalendarItem, with draft: EventDraft) async throws -> CalendarItem {
        if item.isRecurring { throw AlmanacError.recurringNotSupported }
        let calendar = try await writableCalendar(item.calendarID)
        var target: CalendarRecord?
        if draft.calendarID != item.calendarID {
            let destination = try await writableCalendar(draft.calendarID)
            guard destination.accountEmail == calendar.accountEmail else {
                throw AlmanacError.api(status: 400, message: "Events can only move between calendars of the same account.")
            }
            target = destination
        }
        let zone = try await database.timeZone(calendarID: calendar.id, externalID: item.externalID)
            .flatMap(TimeZone.init(identifier:))
        var body = Self.fields(draft, timeZone: zone, isPatch: true)
        var query: [(String, String)] = []
        if draft.addMeet && item.meetURL == nil {
            body["conferenceData"] = Self.meetRequest()
            query.append(("conferenceDataVersion", "1"))
        }
        var headers: [String: String] = [:]
        if let etag = item.etag { headers["If-Match"] = etag }
        let payload = try JSONSerialization.data(withJSONObject: body)
        let data = try await mapNotFound(item, in: calendar) {
            try await api.request(.patch, eventPath(calendar, item.externalID), account: calendar.accountEmail,
                                  query: query, body: payload, headers: headers)
        }
        let patched = try await store(data, in: calendar)
        guard let target else { return patched }

        let movedData: Data
        do {
            movedData = try await api.request(.post, eventPath(calendar, item.externalID) + "/move",
                                              account: calendar.accountEmail, query: [("destination", target.externalID)])
        } catch {
            let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            throw AlmanacError.api(status: (error as? AlmanacError).flatMap(Self.status) ?? 0, message:
                "Your changes were saved in \(calendar.name), but the event couldn't be moved to \(target.name): \(reason)")
        }
        try await database.deleteEvent(calendarID: calendar.id, externalID: item.externalID)
        return try await store(movedData, in: target)
    }

    private static func status(_ error: AlmanacError) -> Int? {
        if case .api(let status, _) = error { return status }
        return nil
    }

    public func delete(_ item: CalendarItem) async throws {
        let calendar = try await writableCalendar(item.calendarID)
        do {
            _ = try await api.request(.delete, eventPath(calendar, item.externalID), account: calendar.accountEmail)
        } catch AlmanacError.api(let status, _) where status == 404 || status == 410 {
            // Already gone on Google's side: that's the result we wanted.
        }
        try await database.deleteEvent(calendarID: calendar.id, externalID: item.externalID)
    }

    public func quickAdd(_ text: String, calendarID: String) async throws -> CalendarItem {
        let calendar = try await writableCalendar(calendarID)
        let data = try await api.request(.post, eventsPath(calendar) + "/quickAdd", account: calendar.accountEmail,
                                         query: [("text", text)])
        return try await store(data, in: calendar)
    }

    // MARK: Helpers

    private func writableCalendar(_ id: String) async throws -> CalendarRecord {
        guard let calendar = try await database.calendar(id: id) else { throw AlmanacError.notFound }
        guard calendar.info.canWrite else { throw AlmanacError.readOnlyCalendar }
        return calendar
    }

    private func eventsPath(_ calendar: CalendarRecord) -> String {
        "/calendars/\(GoogleAPI.encode(calendar.externalID))/events"
    }

    private func eventPath(_ calendar: CalendarRecord, _ eventID: String) -> String {
        eventsPath(calendar) + "/" + GoogleAPI.encode(eventID)
    }

    /// 404/410 on an edit means the event was deleted elsewhere: drop it from the cache and say so.
    private func mapNotFound(_ item: CalendarItem, in calendar: CalendarRecord,
                             _ call: () async throws -> Data) async throws -> Data {
        do {
            return try await call()
        } catch AlmanacError.api(let status, _) where status == 404 || status == 410 {
            try await database.deleteEvent(calendarID: item.calendarID, externalID: item.externalID)
            throw AlmanacError.notFound
        }
    }

    private func store(_ data: Data, in calendar: CalendarRecord) async throws -> CalendarItem {
        let event = try JSONDecoder().decode(GoogleEvent.self, from: data)
        try await database.saveEvent(event, calendarID: calendar.id, accountEmail: calendar.accountEmail)
        guard let item = try await database.item(calendarID: calendar.id, externalID: event.id) else {
            throw AlmanacError.notFound
        }
        return item
    }

    static func meetRequest() -> [String: Any] {
        ["createRequest": ["requestId": UUID().uuidString, "conferenceSolutionKey": ["type": "hangoutsMeet"]]]
    }

    /// Event fields for insert/patch. The unused one of date/dateTime is sent as null so
    /// switching between all-day and timed works with patch.
    /// `timeZone` is the event's own zone when editing; nil uses the Mac's zone. On a patch with no
    /// known zone, `timeZone` is left out so Google keeps the event's (the dateTime has an offset anyway).
    static func fields(_ draft: EventDraft, timeZone: TimeZone? = nil, isPatch: Bool = false,
                       calendar: Calendar = .current) -> [String: Any] {
        let zone = timeZone ?? calendar.timeZone
        func time(_ date: Date) -> [String: Any] {
            if draft.isAllDay {
                return ["date": GoogleDates.dayString(date, calendar: calendar), "dateTime": NSNull(), "timeZone": NSNull()]
            }
            var fields: [String: Any] = ["dateTime": GoogleDates.formatDateTime(date, timeZone: zone), "date": NSNull()]
            if timeZone != nil || !isPatch { fields["timeZone"] = zone.identifier }
            return fields
        }
        return [
            "summary": draft.title,
            "location": draft.location,
            "description": draft.notes,
            "start": time(draft.start),
            "end": time(draft.end),
        ]
    }
}
