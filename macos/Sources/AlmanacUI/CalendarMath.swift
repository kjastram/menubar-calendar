import Foundation
import AlmanacKit

/// Plain date math for the month grid. Every function takes the `Calendar` to use,
/// so it can be tested with a fixed time zone and week start.
public enum CalendarMath {
    /// The month grid always shows six weeks.
    public static let gridDayCount = 42

    public static func startOfMonth(_ date: Date, calendar: Calendar = .current) -> Date {
        calendar.dateInterval(of: .month, for: date)?.start ?? calendar.startOfDay(for: date)
    }

    public static func addingDays(_ days: Int, to date: Date, calendar: Calendar = .current) -> Date {
        let moved = calendar.date(byAdding: .day, value: days, to: date) ?? date
        return calendar.startOfDay(for: moved)
    }

    public static func addingMonths(_ months: Int, to date: Date, calendar: Calendar = .current) -> Date {
        let moved = calendar.date(byAdding: .month, value: months, to: startOfMonth(date, calendar: calendar)) ?? date
        return startOfMonth(moved, calendar: calendar)
    }

    /// First day shown in the grid: the start of the week (per `calendar.firstWeekday`)
    /// that contains the first of the month.
    public static func gridStart(forMonth month: Date, calendar: Calendar = .current) -> Date {
        let first = startOfMonth(month, calendar: calendar)
        let weekday = calendar.component(.weekday, from: first)
        let offset = (weekday - calendar.firstWeekday + 7) % 7
        return addingDays(-offset, to: first, calendar: calendar)
    }

    /// The 42 days (local midnights) shown for `month`.
    public static func monthGridDays(forMonth month: Date, calendar: Calendar = .current) -> [Date] {
        let start = gridStart(forMonth: month, calendar: calendar)
        return (0..<gridDayCount).map { addingDays($0, to: start, calendar: calendar) }
    }

    /// From the first grid day's midnight to the midnight after the last grid day.
    public static func gridInterval(forMonth month: Date, calendar: Calendar = .current) -> DateInterval {
        let start = gridStart(forMonth: month, calendar: calendar)
        let end = addingDays(gridDayCount, to: start, calendar: calendar)
        return DateInterval(start: start, end: end)
    }

    public static func dayInterval(_ day: Date, calendar: Calendar = .current) -> DateInterval {
        let start = calendar.startOfDay(for: day)
        return DateInterval(start: start, end: addingDays(1, to: start, calendar: calendar))
    }

    /// Weekday symbols rotated so the first one is `calendar.firstWeekday`.
    public static func orderedWeekdaySymbols(_ symbols: [String], firstWeekday: Int) -> [String] {
        guard symbols.count == 7, (1...7).contains(firstWeekday) else { return symbols }
        let shift = firstWeekday - 1
        return Array(symbols[shift...] + symbols[..<shift])
    }

    /// True if the item is drawn on `day`. End times are exclusive, so an all-day item
    /// ending at midnight (or a timed item ending exactly at midnight) does not show on the next day.
    /// A zero-length item shows on the day it starts.
    public static func occurs(_ item: CalendarItem, on day: Date, calendar: Calendar = .current) -> Bool {
        let interval = dayInterval(day, calendar: calendar)
        if item.end <= item.start {
            return item.start >= interval.start && item.start < interval.end
        }
        return item.start < interval.end && item.end > interval.start
    }

    /// True if the item starts on `day` (used to decide whether to print its start time).
    public static func starts(_ item: CalendarItem, on day: Date, calendar: Calendar = .current) -> Bool {
        calendar.isDate(item.start, inSameDayAs: day)
    }

    /// Order within one day: all-day first, then by start, then longer first, then title.
    public static func dayOrder(_ a: CalendarItem, _ b: CalendarItem) -> Bool {
        if a.isAllDay != b.isAllDay { return a.isAllDay }
        if a.start != b.start { return a.start < b.start }
        if a.end != b.end { return a.end > b.end }
        return a.title.localizedStandardCompare(b.title) == .orderedAscending
    }

    public static func items(on day: Date, from items: [CalendarItem], calendar: Calendar = .current) -> [CalendarItem] {
        items.filter { occurs($0, on: day, calendar: calendar) }.sorted(by: dayOrder)
    }

    /// Items per day for the given days, keyed by each day's midnight.
    public static func itemsByDay(_ items: [CalendarItem], days: [Date], calendar: Calendar = .current) -> [Date: [CalendarItem]] {
        var result: [Date: [CalendarItem]] = [:]
        for day in days {
            let key = calendar.startOfDay(for: day)
            let list = self.items(on: key, from: items, calendar: calendar)
            if !list.isEmpty { result[key] = list }
        }
        return result
    }

    /// The last day the item is drawn on. For all-day items this is the day before the exclusive end.
    public static func lastDay(of item: CalendarItem, calendar: Calendar = .current) -> Date {
        if item.end <= item.start { return calendar.startOfDay(for: item.start) }
        let last = item.end.addingTimeInterval(-1)
        return max(calendar.startOfDay(for: last), calendar.startOfDay(for: item.start))
    }

    /// Exclusive end for an all-day range whose last day (inclusive) is `lastDay`.
    public static func exclusiveEnd(forLastDay lastDay: Date, calendar: Calendar = .current) -> Date {
        addingDays(1, to: calendar.startOfDay(for: lastDay), calendar: calendar)
    }

    public static func spansMultipleDays(_ item: CalendarItem, calendar: Calendar = .current) -> Bool {
        lastDay(of: item, calendar: calendar) > calendar.startOfDay(for: item.start)
    }

    /// How many chip lines fit in a grid cell of the given height.
    public static func chipCapacity(cellHeight: Double, header: Double = 34, line: Double = 20) -> Int {
        max(1, Int(((cellHeight - header) / line).rounded(.down)))
    }

    /// With `count` items and room for `capacity` lines: how many chips to draw and the "+N more" number.
    /// When things overflow, one line is given up for the "+N more" label.
    public static func chipLayout(count: Int, capacity: Int) -> (shown: Int, more: Int) {
        guard count > capacity else { return (count, 0) }
        let shown = max(capacity - 1, 0)
        return (shown, count - shown)
    }

    /// Default start for a new event on `day`: the next full hour if `day` is today, otherwise 9:00.
    public static func defaultStart(on day: Date, now: Date = Date(), calendar: Calendar = .current) -> Date {
        let dayStart = calendar.startOfDay(for: day)
        if calendar.isDate(day, inSameDayAs: now),
           let hour = calendar.dateInterval(of: .hour, for: now)?.end,
           calendar.isDate(hour, inSameDayAs: now) {
            return hour
        }
        return nineAM(on: dayStart, calendar: calendar)
    }

    public static func nineAM(on day: Date, calendar: Calendar = .current) -> Date {
        calendar.date(bySettingHour: 9, minute: 0, second: 0, of: calendar.startOfDay(for: day)) ?? day
    }
}
