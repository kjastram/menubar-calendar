import Foundation
import AlmanacKit

/// Text for times and dates shown in the views.
enum Formats {
    /// "9:30" (no AM/PM in 12-hour locales), for month chips.
    static func chipTime(_ date: Date, calendar: Calendar = .current) -> String {
        var text = time(date)
        for symbol in [calendar.amSymbol, calendar.pmSymbol] where !symbol.isEmpty {
            text = text.replacingOccurrences(of: symbol, with: "")
        }
        return text.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "\u{202F}")))
    }

    static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    /// Short "when" text for a row in the day list.
    static func when(_ item: CalendarItem, calendar: Calendar = .current) -> String {
        if item.isAllDay {
            guard CalendarMath.spansMultipleDays(item, calendar: calendar) else { return "All day" }
            return "All day · " + dayRange(item, calendar: calendar)
        }
        if item.end <= item.start { return time(item.start) }
        if CalendarMath.spansMultipleDays(item, calendar: calendar) {
            return (item.start..<item.end).formatted(.interval.month(.abbreviated).day().hour().minute())
        }
        return (item.start..<item.end).formatted(.interval.hour().minute())
    }

    /// Long "when" text for the detail card: "Saturday, November 14 · 12:30 – 1:30 PM".
    static func whenLong(_ item: CalendarItem, calendar: Calendar = .current) -> String {
        let day = item.start.formatted(.dateTime.weekday(.wide).month(.wide).day())
        if item.isAllDay {
            guard CalendarMath.spansMultipleDays(item, calendar: calendar) else { return day + " · All day" }
            return dayRange(item, calendar: calendar) + " · All day"
        }
        if item.end <= item.start { return day + " · " + time(item.start) }
        if CalendarMath.spansMultipleDays(item, calendar: calendar) {
            return (item.start..<item.end).formatted(.interval.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
        }
        return day + " · " + (item.start..<item.end).formatted(.interval.hour().minute())
    }

    /// "Nov 14 – Nov 16" using the inclusive last day.
    static func dayRange(_ item: CalendarItem, calendar: Calendar = .current) -> String {
        let last = CalendarMath.lastDay(of: item, calendar: calendar)
        let style = Date.FormatStyle.dateTime.month(.abbreviated).day()
        return item.start.formatted(style) + " – " + last.formatted(style)
    }

    static func monthName(_ date: Date) -> String {
        date.formatted(.dateTime.month(.wide))
    }

    static func year(_ date: Date) -> String {
        date.formatted(.dateTime.year())
    }
}
