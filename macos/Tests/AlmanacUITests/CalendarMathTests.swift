import Foundation
import Testing
import AlmanacKit
@testable import AlmanacUI

/// Fixed calendar so results don't depend on the machine's time zone or locale.
private func makeCalendar(firstWeekday: Int = 1) -> Calendar {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "America/New_York")!
    cal.locale = Locale(identifier: "en_US_POSIX")
    cal.firstWeekday = firstWeekday
    return cal
}

private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0, calendar: Calendar) -> Date {
    calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
}

private func item(_ title: String = "Item", start: Date, end: Date, allDay: Bool = false) -> CalendarItem {
    CalendarItem(id: "google:cal:\(title)", source: .google, externalID: title, calendarID: "cal",
                 accountEmail: "a@example.com", title: title, start: start, end: end,
                 isAllDay: allDay, color: "#2F6FEB")
}

@Suite("CalendarMath grid")
struct CalendarMathGridTests {
    @Test func gridStartIsSundayWhenWeekStartsOnSunday() {
        let cal = makeCalendar(firstWeekday: 1)
        let start = CalendarMath.gridStart(forMonth: date(2026, 11, 15, 13, calendar: cal), calendar: cal)
        #expect(start == date(2026, 11, 1, calendar: cal))
    }

    @Test func gridStartIsMondayWhenWeekStartsOnMonday() {
        let cal = makeCalendar(firstWeekday: 2)
        let start = CalendarMath.gridStart(forMonth: date(2026, 11, 15, 13, calendar: cal), calendar: cal)
        #expect(start == date(2026, 10, 26, calendar: cal))
    }

    @Test func monthGridHas42Days() {
        let cal = makeCalendar()
        let days = CalendarMath.monthGridDays(forMonth: date(2026, 11, 1, calendar: cal), calendar: cal)
        #expect(days.count == 42)
    }

    @Test func monthGridDaysAreAllLocalMidnightsAcrossDSTChange() {
        let cal = makeCalendar(firstWeekday: 2)
        // Grid runs Oct 26 to Dec 6 and contains the Nov 1 fall-back change.
        let days = CalendarMath.monthGridDays(forMonth: date(2026, 11, 1, calendar: cal), calendar: cal)
        let allMidnight = days.allSatisfy { cal.startOfDay(for: $0) == $0 }
        #expect(allMidnight)
    }

    @Test func monthGridDaysAreConsecutiveCalendarDaysAcrossDSTChange() {
        let cal = makeCalendar(firstWeekday: 1)
        let days = CalendarMath.monthGridDays(forMonth: date(2026, 11, 1, calendar: cal), calendar: cal)
        let expected = (0..<42).map { date(2026, 11, 1 + $0, calendar: cal) }
        #expect(days == expected)
    }

    @Test func gridIntervalEndsAtMidnightAfterLastGridDay() {
        let cal = makeCalendar(firstWeekday: 1)
        let interval = CalendarMath.gridInterval(forMonth: date(2026, 11, 1, calendar: cal), calendar: cal)
        #expect(interval.start == date(2026, 11, 1, calendar: cal))
        #expect(interval.end == date(2026, 12, 13, calendar: cal))
    }

    @Test func addingOneMonthFromJan31GivesFirstOfFebruary() {
        let cal = makeCalendar()
        let result = CalendarMath.addingMonths(1, to: date(2026, 1, 31, 10, calendar: cal), calendar: cal)
        #expect(result == date(2026, 2, 1, calendar: cal))
    }

    @Test func addingMinusOneMonthFromMarch31GivesFirstOfFebruary() {
        let cal = makeCalendar()
        let result = CalendarMath.addingMonths(-1, to: date(2026, 3, 31, calendar: cal), calendar: cal)
        #expect(result == date(2026, 2, 1, calendar: cal))
    }

    @Test func orderedWeekdaySymbolsStartAtFirstWeekday() {
        let symbols = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        let ordered = CalendarMath.orderedWeekdaySymbols(symbols, firstWeekday: 2)
        #expect(ordered == ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"])
    }

    @Test func orderedWeekdaySymbolsUnchangedForSundayStart() {
        let symbols = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        #expect(CalendarMath.orderedWeekdaySymbols(symbols, firstWeekday: 1) == symbols)
    }
}

@Suite("CalendarMath items")
struct CalendarMathItemTests {
    let cal = makeCalendar()

    @Test func allDayEventWithExclusiveEndIsNotDrawnOnItsEndDay() {
        let event = item(start: date(2026, 11, 10, calendar: cal), end: date(2026, 11, 12, calendar: cal), allDay: true)
        #expect(CalendarMath.occurs(event, on: date(2026, 11, 11, calendar: cal), calendar: cal))
        #expect(!CalendarMath.occurs(event, on: date(2026, 11, 12, calendar: cal), calendar: cal))
    }

    @Test func timedEventEndingExactlyAtMidnightStaysOnItsOwnDay() {
        let event = item(start: date(2026, 11, 10, 22, calendar: cal), end: date(2026, 11, 11, calendar: cal))
        #expect(CalendarMath.occurs(event, on: date(2026, 11, 10, calendar: cal), calendar: cal))
        #expect(!CalendarMath.occurs(event, on: date(2026, 11, 11, calendar: cal), calendar: cal))
    }

    @Test func eventCrossingMidnightShowsOnBothDays() {
        let event = item(start: date(2026, 11, 10, 22, calendar: cal), end: date(2026, 11, 11, 2, calendar: cal))
        #expect(CalendarMath.occurs(event, on: date(2026, 11, 10, calendar: cal), calendar: cal))
        #expect(CalendarMath.occurs(event, on: date(2026, 11, 11, calendar: cal), calendar: cal))
    }

    @Test func zeroLengthEventShowsOnItsStartDay() {
        let moment = date(2026, 11, 10, 9, 30, calendar: cal)
        let event = item(start: moment, end: moment)
        #expect(CalendarMath.occurs(event, on: date(2026, 11, 10, calendar: cal), calendar: cal))
    }

    @Test func zeroLengthEventDoesNotShowOnOtherDays() {
        let moment = date(2026, 11, 10, 9, 30, calendar: cal)
        let event = item(start: moment, end: moment)
        #expect(!CalendarMath.occurs(event, on: date(2026, 11, 9, calendar: cal), calendar: cal))
        #expect(!CalendarMath.occurs(event, on: date(2026, 11, 11, calendar: cal), calendar: cal))
    }

    @Test func lastDayOfAllDayEventIsDayBeforeExclusiveEnd() {
        let event = item(start: date(2026, 11, 10, calendar: cal), end: date(2026, 11, 13, calendar: cal), allDay: true)
        #expect(CalendarMath.lastDay(of: event, calendar: cal) == date(2026, 11, 12, calendar: cal))
    }

    @Test func lastDayOfTimedEventEndingAtMidnightIsItsStartDay() {
        let event = item(start: date(2026, 11, 10, 22, calendar: cal), end: date(2026, 11, 11, calendar: cal))
        #expect(CalendarMath.lastDay(of: event, calendar: cal) == date(2026, 11, 10, calendar: cal))
    }

    @Test func lastDayOfZeroLengthEventIsItsStartDay() {
        let moment = date(2026, 11, 10, 9, calendar: cal)
        #expect(CalendarMath.lastDay(of: item(start: moment, end: moment), calendar: cal) == date(2026, 11, 10, calendar: cal))
    }

    @Test func exclusiveEndIsMidnightAfterLastDay() {
        let result = CalendarMath.exclusiveEnd(forLastDay: date(2026, 11, 12, 15, calendar: cal), calendar: cal)
        #expect(result == date(2026, 11, 13, calendar: cal))
    }

    @Test func exclusiveEndAcrossDSTChangeIsLocalMidnight() {
        let result = CalendarMath.exclusiveEnd(forLastDay: date(2026, 11, 1, calendar: cal), calendar: cal)
        #expect(result == date(2026, 11, 2, calendar: cal))
    }

    @Test func exclusiveEndAndLastDayRoundTrip() {
        let lastDay = date(2026, 11, 12, calendar: cal)
        let event = item(start: date(2026, 11, 10, calendar: cal),
                         end: CalendarMath.exclusiveEnd(forLastDay: lastDay, calendar: cal), allDay: true)
        #expect(CalendarMath.lastDay(of: event, calendar: cal) == lastDay)
    }

    @Test func itemsOnDayPutAllDayFirstThenOrderByStart() {
        let day = date(2026, 11, 10, calendar: cal)
        let late = item("Late", start: date(2026, 11, 10, 15, calendar: cal), end: date(2026, 11, 10, 16, calendar: cal))
        let early = item("Early", start: date(2026, 11, 10, 8, calendar: cal), end: date(2026, 11, 10, 9, calendar: cal))
        let allDay = item("All day", start: day, end: date(2026, 11, 11, calendar: cal), allDay: true)
        let result = CalendarMath.items(on: day, from: [late, early, allDay], calendar: cal)
        #expect(result.map(\.title) == ["All day", "Early", "Late"])
    }

    @Test func itemsByDayOmitsDaysWithNoItems() {
        let day = date(2026, 11, 10, calendar: cal)
        let event = item(start: date(2026, 11, 10, 9, calendar: cal), end: date(2026, 11, 10, 10, calendar: cal))
        let days = [day, date(2026, 11, 11, calendar: cal)]
        let result = CalendarMath.itemsByDay([event], days: days, calendar: cal)
        #expect(Array(result.keys) == [day])
    }
}

@Suite("CalendarMath chips")
struct CalendarMathChipTests {
    @Test func fiveItemsWithRoomForThreeShowTwoAndPlusThreeMore() {
        let layout = CalendarMath.chipLayout(count: 5, capacity: 3)
        #expect(layout.shown == 2)
        #expect(layout.more == 3)
    }

    @Test func itemsThatFitAreAllShownWithNoMoreLabel() {
        let layout = CalendarMath.chipLayout(count: 3, capacity: 3)
        #expect(layout.shown == 3)
        #expect(layout.more == 0)
    }

    @Test func chipCapacityIsAtLeastOne() {
        #expect(CalendarMath.chipCapacity(cellHeight: 10) == 1)
    }
}

@Suite("HexColor")
struct HexColorTests {
    @Test func parsesSixDigitHexWithHash() throws {
        let c = try #require(HexColor.components("#FF8000"))
        #expect(c.red == 1)
        #expect(abs(c.green - 128.0 / 255) < 1e-9)
        #expect(c.blue == 0)
    }

    @Test func parsesSixDigitHexWithoutHash() throws {
        let c = try #require(HexColor.components("00ff00"))
        #expect(c.red == 0 && c.green == 1 && c.blue == 0)
    }

    @Test func expandsThreeDigitShorthand() throws {
        let c = try #require(HexColor.components("#fff"))
        #expect(c.red == 1 && c.green == 1 && c.blue == 1)
    }

    @Test func ignoresSurroundingWhitespace() {
        #expect(HexColor.components("  #000000\n") != nil)
    }

    @Test func rejectsNonHexCharacters() {
        #expect(HexColor.components("#GGGGGG") == nil)
    }

    @Test func rejectsWrongLength() {
        #expect(HexColor.components("#12345") == nil)
        #expect(HexColor.components("#1234567") == nil)
    }

    @Test func rejectsEmptyString() {
        #expect(HexColor.components("") == nil)
    }
}
