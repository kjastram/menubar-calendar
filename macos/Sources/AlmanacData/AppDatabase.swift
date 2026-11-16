import AlmanacKit
import Foundation
import GRDB

/// The local SQLite cache. Safe to use from any thread.
public final class AppDatabase: CalendarRepository, Sendable {
    let writer: any DatabaseWriter

    init(writer: any DatabaseWriter) throws {
        self.writer = writer
        try Self.migrator.migrate(writer)
    }

    /// ~/Library/Application Support/Almanac/cache.sqlite. Creates the folder.
    public static func defaultURL() throws -> URL {
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: true)
        let folder = support.appendingPathComponent("Almanac", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("cache.sqlite")
    }

    public static func open(at url: URL) throws -> AppDatabase {
        try AppDatabase(writer: DatabasePool(path: url.path))
    }

    /// For tests and previews.
    public static func inMemory() throws -> AppDatabase {
        try AppDatabase(writer: DatabaseQueue())
    }

    // MARK: Schema

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE accounts (
                    source TEXT NOT NULL,
                    external_id TEXT NOT NULL,
                    color TEXT NOT NULL,
                    hidden BOOLEAN NOT NULL DEFAULT 0,
                    status TEXT NOT NULL DEFAULT 'ok',
                    status_message TEXT,
                    PRIMARY KEY (source, external_id)
                );
                CREATE TABLE calendars (
                    id TEXT PRIMARY KEY NOT NULL,
                    source TEXT NOT NULL,
                    account_email TEXT NOT NULL,
                    external_id TEXT NOT NULL,
                    name TEXT NOT NULL,
                    color TEXT NOT NULL,
                    access_role TEXT NOT NULL,
                    visible BOOLEAN NOT NULL,
                    is_primary BOOLEAN NOT NULL DEFAULT 0,
                    UNIQUE (source, account_email, external_id),
                    FOREIGN KEY (source, account_email) REFERENCES accounts (source, external_id) ON DELETE CASCADE
                );
                CREATE TABLE events (
                    source TEXT NOT NULL,
                    calendar_id TEXT NOT NULL REFERENCES calendars (id) ON DELETE CASCADE,
                    external_id TEXT NOT NULL,
                    etag TEXT,
                    title TEXT,
                    start_at DOUBLE NOT NULL,
                    end_at DOUBLE NOT NULL,
                    all_day BOOLEAN NOT NULL,
                    start_date TEXT,
                    end_date TEXT,
                    location TEXT,
                    notes TEXT,
                    meet_url TEXT,
                    web_url TEXT,
                    recurring_event_id TEXT,
                    is_recurring BOOLEAN NOT NULL DEFAULT 0,
                    status TEXT,
                    event_type TEXT,
                    ical_uid TEXT,
                    color_id TEXT,
                    color TEXT,
                    self_response TEXT NOT NULL DEFAULT 'accepted',
                    updated_at TEXT,
                    PRIMARY KEY (source, calendar_id, external_id)
                );
                CREATE INDEX events_range ON events (start_at, end_at);
                CREATE INDEX events_recurring ON events (calendar_id, recurring_event_id);
                CREATE TABLE sync_state (
                    calendar_id TEXT PRIMARY KEY NOT NULL REFERENCES calendars (id) ON DELETE CASCADE,
                    sync_token TEXT,
                    last_full_sync DOUBLE
                );
                -- Google's event color palette (colors.get), so writes can resolve colorId too.
                CREATE TABLE event_colors (
                    color_id TEXT PRIMARY KEY NOT NULL,
                    background TEXT NOT NULL
                );
                -- Calendar names or Google ids that start hidden (the plugin's "exclude").
                CREATE TABLE excluded_calendars (
                    value TEXT PRIMARY KEY NOT NULL
                );
                """)
        }
        migrator.registerMigration("v2") { db in
            try db.execute(sql: """
                ALTER TABLE calendars ADD COLUMN sync_error TEXT;
                ALTER TABLE events ADD COLUMN time_zone TEXT;
                -- Events created, changed or deleted through GoogleCalendarSource in the last couple of
                -- minutes, so a sync page fetched before the write can't undo it.
                CREATE TABLE local_writes (
                    calendar_id TEXT NOT NULL,
                    external_id TEXT NOT NULL,
                    written_at DOUBLE NOT NULL,
                    PRIMARY KEY (calendar_id, external_id)
                );
                -- Colors taken by accounts that have no row yet (the plugin's account_colors).
                CREATE TABLE reserved_colors (
                    color TEXT PRIMARY KEY NOT NULL
                );
                """)
        }
        return migrator
    }

    // MARK: CalendarRepository

    public func accounts() async throws -> [Account] {
        try await writer.read { db in
            try AccountRecord.fetchAll(db, sql: "SELECT * FROM accounts ORDER BY external_id").map(\.account)
        }
    }

    public func calendars() async throws -> [CalendarInfo] {
        try await writer.read { db in
            try CalendarRecord.fetchAll(db, sql: """
                SELECT * FROM calendars ORDER BY account_email, is_primary DESC, name COLLATE NOCASE
                """).map(\.info)
        }
    }

    public func items(in interval: DateInterval) async throws -> [CalendarItem] {
        // All-day rows store midnight from when they were written; widen the query by a day
        // and filter exactly after recomputing their local dates.
        let day: Double = 86_400
        let rows = try await visibleRows(
            extra: "AND e.start_at < ? AND e.end_at > ?",
            arguments: [interval.end.timeIntervalSince1970 + day, interval.start.timeIntervalSince1970 - day])
        return DisplayRules.dedupe(rows.filter { $0.item.overlaps(interval) })
    }

    public func search(_ text: String, limit: Int) async throws -> [CalendarItem] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, limit > 0 else { return [] }
        // SQLite's LIKE only folds ASCII case, so match in Swift; the cache is small.
        let rows = try await visibleRows(extra: "", arguments: [])
        let matching = rows.filter { entry in
            [entry.item.title, entry.item.location ?? "", entry.item.notes ?? ""].contains {
                $0.range(of: trimmed, options: [.caseInsensitive, .diacriticInsensitive]) != nil
            }
        }
        return Array(DisplayRules.dedupe(matching).prefix(limit))
    }

    public func changes() -> AsyncStream<Void> {
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        continuation.yield()
        let observation = DatabaseRegionObservation(tracking: Table("accounts"), Table("calendars"), Table("events"))
        let cancellable = observation.start(in: writer, onError: { _ in continuation.finish() },
                                            onChange: { _ in continuation.yield() })
        continuation.onTermination = { _ in cancellable.cancel() }
        return stream
    }

    public func setCalendarVisible(_ calendarID: String, visible: Bool) async throws {
        try await writer.write { db in
            try db.execute(sql: "UPDATE calendars SET visible = ? WHERE id = ? AND visible != ?",
                           arguments: [visible, calendarID, visible])
        }
    }

    public func setAccountColor(_ email: String, color: String) async throws {
        try await writer.write { db in
            try db.execute(sql: "UPDATE accounts SET color = ? WHERE source = 'google' AND external_id = ?",
                           arguments: [color, email])
        }
    }

    public func setAccountHidden(_ email: String, hidden: Bool) async throws {
        try await writer.write { db in
            try db.execute(sql: "UPDATE accounts SET hidden = ? WHERE source = 'google' AND external_id = ?",
                           arguments: [hidden, email])
        }
    }

    // MARK: Accounts

    /// Called by sync when it first sees an account: inserts it with the next accountPalette color not used
    /// by an account or reserved with `reserveColors` (same rule as the plugin's account_colors) unless a color is given.
    /// For an existing account this changes nothing, unless `color` is given: then color and hidden are set
    /// (used when importing the plugin's settings).
    public func ensureAccount(_ email: String, color: String? = nil, hidden: Bool = false) async throws {
        try await writer.write { db in
            if var existing = try AccountRecord.fetchOne(db, key: ["source": "google", "external_id": email]) {
                guard let color, existing.color != color || existing.hidden != hidden else { return }
                existing.color = color
                existing.hidden = hidden
                try existing.update(db)
                return
            }
            var used = try String.fetchAll(db, sql: "SELECT color FROM accounts")
            let taken = Set(used)
            used += try String.fetchAll(db, sql: "SELECT color FROM reserved_colors").filter { !taken.contains($0) }
            let assigned = color ?? Self.nextPaletteColor(used: used)
            try AccountRecord(externalID: email, color: assigned, hidden: hidden, status: "ok").insert(db)
        }
    }

    /// First palette color not in use; when all are used, cycles by account count (as the plugin does).
    static func nextPaletteColor(used: [String]) -> String {
        let usedSet = Set(used)
        return accountPalette.first { !usedSet.contains($0) } ?? accountPalette[used.count % accountPalette.count]
    }

    /// Colors the palette rule must skip for accounts without a color, such as the plugin's
    /// account_colors values for accounts not signed in yet. Replaces the previous list.
    public func reserveColors(_ colors: [String]) async throws {
        try await writer.write { db in
            try db.execute(sql: "DELETE FROM reserved_colors")
            for color in Set(colors) {
                try db.execute(sql: "INSERT INTO reserved_colors (color) VALUES (?)", arguments: [color])
            }
        }
    }

    /// Deletes the account with its calendars, events and sync state.
    public func removeAccount(_ email: String) async throws {
        try await writer.write { db in
            try db.execute(sql: "DELETE FROM accounts WHERE source = 'google' AND external_id = ?", arguments: [email])
        }
    }

    public func setAccountStatus(_ email: String, _ status: AccountStatus) async throws {
        let (code, message) = AccountRecord.encode(status)
        try await writer.write { db in
            try db.execute(sql: """
                UPDATE accounts SET status = ?, status_message = ?
                WHERE source = 'google' AND external_id = ? AND (status != ? OR status_message IS NOT ?)
                """, arguments: [code, message, email, code, message])
        }
    }

    /// Last sync error per calendar id, for visible calendars of shown accounts. Empty when all synced.
    public func calendarErrors() async throws -> [String: String] {
        try await writer.read { db in
            var errors: [String: String] = [:]
            for row in try Row.fetchAll(db, sql: """
                SELECT c.id, c.sync_error FROM calendars c
                JOIN accounts a ON a.source = c.source AND a.external_id = c.account_email
                WHERE c.visible = 1 AND a.hidden = 0 AND c.sync_error IS NOT NULL
                """) {
                errors[row["id"]] = row["sync_error"]
            }
            return errors
        }
    }

    /// Marks calendars hidden by name or google id (the plugin's "exclude" list). Applies now and to calendars seen later.
    public func setExcludedCalendars(_ namesOrIDs: [String]) async throws {
        try await writer.write { db in
            try db.execute(sql: "DELETE FROM excluded_calendars")
            for value in Set(namesOrIDs) {
                try db.execute(sql: "INSERT INTO excluded_calendars (value) VALUES (?)", arguments: [value])
            }
            try db.execute(sql: """
                UPDATE calendars SET visible = 0
                WHERE visible = 1 AND (name IN (SELECT value FROM excluded_calendars)
                                       OR external_id IN (SELECT value FROM excluded_calendars))
                """)
        }
    }

    // MARK: Internal reads

    /// Event rows from visible calendars of non-hidden accounts, with the plugin's skip rules applied.
    private func visibleRows(extra: String, arguments: StatementArguments) async throws -> [(item: CalendarItem, uid: String)] {
        try await writer.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT e.*, c.color AS calendar_color, c.account_email AS calendar_account
                FROM events e
                JOIN calendars c ON c.id = e.calendar_id
                JOIN accounts a ON a.source = c.source AND a.external_id = c.account_email
                WHERE c.visible = 1 AND a.hidden = 0 \(extra)
                """, arguments: arguments)
            return try rows.compactMap { row in
                let record = try EventRecord(row: row)
                guard !record.isSkipped else { return nil }
                let item = record.item(accountEmail: row["calendar_account"], calendarColor: row["calendar_color"])
                return (item, record.iCalUID ?? record.externalID)
            }
        }
    }

    func calendar(id: String) async throws -> CalendarRecord? {
        try await writer.read { db in try CalendarRecord.fetchOne(db, key: id) }
    }

    func calendarRecords(account email: String) async throws -> [CalendarRecord] {
        try await writer.read { db in
            try CalendarRecord.fetchAll(db, sql: "SELECT * FROM calendars WHERE account_email = ?", arguments: [email])
        }
    }

    func eventRecords(calendarID: String) async throws -> [EventRecord] {
        try await writer.read { db in
            try EventRecord.fetchAll(db, sql: "SELECT * FROM events WHERE calendar_id = ? ORDER BY start_at",
                                     arguments: [calendarID])
        }
    }

    func syncState(calendarID: String) async throws -> SyncStateRecord? {
        try await writer.read { db in try SyncStateRecord.fetchOne(db, key: calendarID) }
    }

    /// One cached event as an item, without the display filters.
    func item(calendarID: String, externalID: String) async throws -> CalendarItem? {
        try await writer.read { db in
            let row = try Row.fetchOne(db, sql: """
                SELECT e.*, c.color AS calendar_color, c.account_email AS calendar_account
                FROM events e JOIN calendars c ON c.id = e.calendar_id
                WHERE e.calendar_id = ? AND e.external_id = ?
                """, arguments: [calendarID, externalID])
            guard let row else { return nil }
            return try EventRecord(row: row).item(accountEmail: row["calendar_account"], calendarColor: row["calendar_color"])
        }
    }

    // MARK: Sync writes

    func savePalette(_ palette: [String: String]) async throws {
        try await writer.write { db in
            let current = try Row.fetchAll(db, sql: "SELECT color_id, background FROM event_colors")
            var existing: [String: String] = [:]
            for row in current { existing[row["color_id"]] = row["background"] }
            guard existing != palette else { return }
            try db.execute(sql: "DELETE FROM event_colors")
            for (id, background) in palette {
                try db.execute(sql: "INSERT INTO event_colors (color_id, background) VALUES (?, ?)",
                               arguments: [id, background])
            }
        }
    }

    /// Applies an account's calendarList: inserts new calendars (visible = `selected`, minus excluded),
    /// updates names/colors/roles of known ones (keeping the user's visibility) and deletes calendars
    /// no longer listed, with their events. Returns the account's calendars after the change.
    @discardableResult
    func applyCalendarList(account email: String, entries: [GoogleCalendarListEntry]) async throws -> [CalendarRecord] {
        try await writer.write { db in
            let excluded = Set(try String.fetchAll(db, sql: "SELECT value FROM excluded_calendars"))
            let existing = try CalendarRecord.fetchAll(db, sql: "SELECT * FROM calendars WHERE account_email = ?",
                                                       arguments: [email])
            var byID = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            var listed = Set<String>()
            for entry in entries {
                let id = CalendarInfo.localID(accountEmail: email, googleID: entry.id)
                listed.insert(id)
                let name = entry.displayName
                let color = entry.backgroundColor ?? "#4285f4"
                let role = entry.accessRole ?? "reader"
                let primary = entry.primary ?? false
                if var record = byID[id] {
                    let before = record
                    record.name = name
                    record.color = color
                    record.accessRole = role
                    record.isPrimary = primary
                    if record != before { try record.update(db) }
                    byID[id] = record
                } else {
                    let visible = (entry.selected ?? false) && !excluded.contains(name) && !excluded.contains(entry.id)
                    let record = CalendarRecord(id: id, accountEmail: email, externalID: entry.id, name: name,
                                                color: color, accessRole: role, visible: visible, isPrimary: primary)
                    try record.insert(db)
                    byID[id] = record
                }
            }
            for id in byID.keys where !listed.contains(id) {
                try db.execute(sql: "DELETE FROM calendars WHERE id = ?", arguments: [id])
                byID[id] = nil
            }
            return entries.compactMap { byID[CalendarInfo.localID(accountEmail: email, googleID: $0.id)] }
        }
    }

    /// Replaces all of a calendar's events with a full sync result and stores the sync token.
    /// Events written locally after `fetchStartedAt` keep their cached row (or stay deleted).
    func replaceEvents(calendarID: String, accountEmail: String, events: [GoogleEvent], syncToken: String?,
                       fetchStartedAt: Date? = nil) async throws {
        try await writer.write { db in
            let palette = try Self.palette(db)
            let protected = try Self.localWrites(db, calendarID: calendarID, since: fetchStartedAt)
            let kept = try EventRecord.fetchAll(db, sql: "SELECT * FROM events WHERE calendar_id = ?", arguments: [calendarID])
                .filter { protected.contains($0.externalID) }
            try db.execute(sql: "DELETE FROM events WHERE calendar_id = ?", arguments: [calendarID])
            for event in events where event.status != "cancelled" && !protected.contains(event.id) {
                if let record = EventRecord(event: event, calendarID: calendarID, accountEmail: accountEmail, palette: palette) {
                    try record.insert(db, onConflict: .replace)
                }
            }
            for record in kept { try record.insert(db, onConflict: .replace) }
            try SyncStateRecord(calendarID: calendarID, syncToken: syncToken,
                                lastFullSync: Date().timeIntervalSince1970).save(db)
        }
    }

    /// Applies incremental changes: cancelled events are deleted (with their instances), others upserted.
    /// Skips events older than the cached row, and events written locally after `fetchStartedAt`.
    func applyChanges(calendarID: String, accountEmail: String, events: [GoogleEvent], syncToken: String?,
                      fetchStartedAt: Date? = nil) async throws {
        try await writer.write { db in
            let protected = try Self.localWrites(db, calendarID: calendarID, since: fetchStartedAt)
            try Self.apply(db, calendarID: calendarID, accountEmail: accountEmail,
                           events: events.filter { !protected.contains($0.id) }, skipOlder: true)
            if let syncToken {
                try db.execute(sql: "UPDATE sync_state SET sync_token = ? WHERE calendar_id = ?",
                               arguments: [syncToken, calendarID])
            }
        }
    }

    /// Forgets a calendar's sync token (after 410 Gone). Cached events stay until the full sync replaces them.
    func clearSyncToken(_ calendarID: String) async throws {
        try await writer.write { db in
            try db.execute(sql: "UPDATE sync_state SET sync_token = NULL WHERE calendar_id = ?", arguments: [calendarID])
        }
    }

    /// Records a calendar's sync result: an error message, or nil after a successful sync.
    func setCalendarError(_ calendarID: String, _ message: String?) async throws {
        try await writer.write { db in
            try db.execute(sql: "UPDATE calendars SET sync_error = ? WHERE id = ? AND sync_error IS NOT ?",
                           arguments: [message, calendarID, message])
        }
    }

    /// The event's start.timeZone as last stored.
    func timeZone(calendarID: String, externalID: String) async throws -> String? {
        try await writer.read { db in
            try String.fetchOne(db, sql: "SELECT time_zone FROM events WHERE calendar_id = ? AND external_id = ?",
                                arguments: [calendarID, externalID])
        }
    }

    /// Upserts one event after a write call, and marks it written locally.
    func saveEvent(_ event: GoogleEvent, calendarID: String, accountEmail: String) async throws {
        try await writer.write { db in
            try Self.apply(db, calendarID: calendarID, accountEmail: accountEmail, events: [event], skipOlder: false)
            try Self.markLocalWrite(db, calendarID: calendarID, externalID: event.id)
        }
    }

    /// Deletes one event after a write call, and marks it written locally.
    func deleteEvent(calendarID: String, externalID: String) async throws {
        try await writer.write { db in
            try db.execute(sql: "DELETE FROM events WHERE calendar_id = ? AND external_id = ?",
                           arguments: [calendarID, externalID])
            try Self.markLocalWrite(db, calendarID: calendarID, externalID: externalID)
        }
    }

    /// How long a local write is protected from sync results fetched before it.
    static let localWriteWindow: TimeInterval = 120

    private static func markLocalWrite(_ db: Database, calendarID: String, externalID: String) throws {
        let now = Date().timeIntervalSince1970
        try db.execute(sql: "DELETE FROM local_writes WHERE written_at < ?", arguments: [now - localWriteWindow])
        try db.execute(sql: "INSERT OR REPLACE INTO local_writes (calendar_id, external_id, written_at) VALUES (?, ?, ?)",
                       arguments: [calendarID, externalID, now])
    }

    /// Ids written locally at or after `since` (within the protection window). Empty when `since` is nil.
    private static func localWrites(_ db: Database, calendarID: String, since: Date?) throws -> Set<String> {
        guard let since else { return [] }
        let cutoff = max(since.timeIntervalSince1970, Date().timeIntervalSince1970 - localWriteWindow)
        return Set(try String.fetchAll(db, sql: """
            SELECT external_id FROM local_writes WHERE calendar_id = ? AND written_at >= ?
            """, arguments: [calendarID, cutoff]))
    }

    private static func palette(_ db: Database) throws -> [String: String] {
        var palette: [String: String] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT color_id, background FROM event_colors") {
            palette[row["color_id"]] = row["background"]
        }
        return palette
    }

    private static func apply(_ db: Database, calendarID: String, accountEmail: String, events: [GoogleEvent],
                              skipOlder: Bool) throws {
        let palette = try palette(db)
        for event in events {
            if skipOlder, try isOlderThanCached(db, event, calendarID: calendarID) { continue }
            if event.status == "cancelled" {
                try db.execute(sql: """
                    DELETE FROM events WHERE calendar_id = ? AND (external_id = ? OR recurring_event_id = ?)
                    """, arguments: [calendarID, event.id, event.id])
            } else if let record = EventRecord(event: event, calendarID: calendarID, accountEmail: accountEmail, palette: palette) {
                try record.insert(db, onConflict: .replace)
            }
        }
    }

    /// True when the cached row has a later `updated` than the incoming event.
    private static func isOlderThanCached(_ db: Database, _ event: GoogleEvent, calendarID: String) throws -> Bool {
        guard let incoming = event.updated.flatMap(GoogleDates.parseDateTime),
              let cachedText = try String.fetchOne(db, sql: """
                  SELECT updated_at FROM events WHERE calendar_id = ? AND external_id = ?
                  """, arguments: [calendarID, event.id]),
              let cached = GoogleDates.parseDateTime(cachedText) else { return false }
        return incoming < cached
    }
}
