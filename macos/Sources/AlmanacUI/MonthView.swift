import SwiftUI
import AlmanacKit

/// Six-week month grid.
struct MonthView: View {
    let store: CalendarStore
    /// Called when a day or item is clicked, so the window can put keyboard focus on the grid.
    var onInteract: () -> Void = {}
    var onOpenItem: (CalendarItem) -> Void = { _ in }

    var body: some View {
        let cal = store.calendar
        let days = store.gridDays
        let symbols = CalendarMath.orderedWeekdaySymbols(cal.shortStandaloneWeekdaySymbols, firstWeekday: cal.firstWeekday)
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(Array(symbols.enumerated()), id: \.offset) { _, symbol in
                    SectionLabel(text: symbol)
                        .padding(.horizontal, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(height: 32)
            Hairline()
            GeometryReader { geo in
                let rowHeight = geo.size.height / 6
                let capacity = CalendarMath.chipCapacity(cellHeight: rowHeight)
                VStack(spacing: 0) {
                    ForEach(0..<6, id: \.self) { row in
                        HStack(spacing: 0) {
                            ForEach(0..<7, id: \.self) { column in
                                let day = days[row * 7 + column]
                                DayCell(store: store, day: day, capacity: capacity,
                                        onInteract: onInteract, onOpenItem: onOpenItem)
                            }
                        }
                        .frame(height: rowHeight)
                    }
                }
            }
        }
        .background(Theme.ground)
    }
}

private struct DayCell: View {
    let store: CalendarStore
    let day: Date
    let capacity: Int
    let onInteract: () -> Void
    let onOpenItem: (CalendarItem) -> Void

    var body: some View {
        let cal = store.calendar
        let items = store.items(on: day)
        let layout = CalendarMath.chipLayout(count: items.count, capacity: capacity)
        let isToday = cal.isDateInToday(day)
        let isSelected = cal.isDate(day, inSameDayAs: store.selectedDay)
        let inMonth = cal.isDate(day, equalTo: store.displayedMonth, toGranularity: .month)

        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label(inMonth: inMonth))
                    .font(Fonts.text(12.5, isToday ? .semibold : .medium))
                    .monospacedDigit()
                    .foregroundStyle(isToday ? Theme.onAccent : (inMonth ? Theme.ink : Theme.tertiary))
                    .padding(.horizontal, 6)
                    .frame(minWidth: 24, minHeight: 24)
                    .background(Capsule().fill(isToday ? Theme.accent : Color.clear))
                Spacer(minLength: 0)
            }
            .padding(.bottom, 2)
            ForEach(items.prefix(layout.shown)) { item in
                MonthChip(item: item, day: day, calendar: cal, isSelected: store.selectedItemID == item.id)
                    .gesture(
                        TapGesture(count: 2).onEnded { onOpenItem(item) }
                            .simultaneously(with: TapGesture().onEnded {
                                store.select(day: day)
                                store.select(item: item)
                                onInteract()
                            })
                    )
            }
            if layout.more > 0 {
                Text("+\(layout.more) more")
                    .font(Fonts.text(11, .medium))
                    .foregroundStyle(Theme.secondary)
                    .padding(.horizontal, 4)
            }
            Spacer(minLength: 0)
        }
        .padding(EdgeInsets(top: 6, leading: 6, bottom: 4, trailing: 6))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(background(isToday: isToday, isSelected: isSelected))
        .overlay {
            if isSelected {
                Rectangle().strokeBorder(Theme.accent, lineWidth: 2)
            }
        }
        .overlay(alignment: .trailing) { Hairline(vertical: true) }
        .overlay(alignment: .bottom) { Hairline() }
        .clipped()
        .contentShape(Rectangle())
        .gesture(
            TapGesture(count: 2).onEnded { store.newEvent(on: day) }
                .simultaneously(with: TapGesture().onEnded {
                    store.select(day: day)
                    onInteract()
                })
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(day.formatted(date: .complete, time: .omitted) + ", \(items.count) events")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private func label(inMonth: Bool) -> String {
        let cal = store.calendar
        if !inMonth && cal.component(.day, from: day) == 1 {
            return day.formatted(.dateTime.month(.abbreviated).day())
        }
        return String(cal.component(.day, from: day))
    }

    private func background(isToday: Bool, isSelected: Bool) -> Color {
        if isSelected && !isToday { return Theme.selectedCell }
        if store.calendar.isDateInWeekend(day) { return Theme.weekend }
        return Theme.ground
    }
}

/// One line in a day cell. All-day: tinted chip. Timed: dot, time, title.
/// The dot is filled when the item has a meeting link and outlined when it doesn't.
struct MonthChip: View {
    let item: CalendarItem
    let day: Date
    let calendar: Calendar
    var isSelected = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let color = HexColor.color(item.color)
        HStack(spacing: 5) {
            ItemDot(color: color, filled: item.isAllDay || item.meetURL != nil, size: 6)
            if !item.isAllDay && CalendarMath.starts(item, on: day, calendar: calendar) {
                Text(Formats.chipTime(item.start))
                    .monospacedDigit()
                    .foregroundStyle(Theme.secondary)
            }
            Text(item.title.isEmpty ? "(No title)" : item.title)
                .foregroundStyle(Theme.ink)
                .truncationMode(.tail)
        }
        .font(Fonts.text(11.5, item.isAllDay ? .semibold : .regular))
        .lineLimit(1)
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, minHeight: 18, maxHeight: 18, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 4).fill(chipBackground(color))
        )
        .overlay {
            if item.isTentative && item.isAllDay {
                RoundedRectangle(cornerRadius: 4).strokeBorder(color.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
            }
        }
        .opacity(item.isTentative ? 0.55 : 1)
        .contentShape(Rectangle())
        .help(item.title)
    }

    private func chipBackground(_ color: Color) -> Color {
        if item.isAllDay { return color.opacity(colorScheme == .dark ? 0.28 : 0.16) }
        return isSelected ? Theme.hover : .clear
    }
}

/// Filled or outlined color dot.
struct ItemDot: View {
    let color: Color
    var filled = true
    var size: CGFloat = 8

    var body: some View {
        Group {
            if filled {
                Circle().fill(color)
            } else {
                Circle().strokeBorder(color, lineWidth: 1.5)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
