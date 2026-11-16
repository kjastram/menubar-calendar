import SwiftUI
import AlmanacKit

/// Right panel: the selected day's items and the selected item's details.
struct DayInspector: View {
    let store: CalendarStore

    var body: some View {
        let day = store.selectedDay
        let items = store.selectedDayItems
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 2) {
                    SectionLabel(text: day.formatted(.dateTime.weekday(.wide)), size: 12)
                    Text(day.formatted(.dateTime.month(.wide).day()))
                        .font(Fonts.heading(26))
                        .foregroundStyle(Theme.ink)
                }
                .padding(.horizontal, 4)

                if items.isEmpty {
                    Text("Nothing scheduled. Press ⌘N or use New event to add one.")
                        .font(Fonts.text(13))
                        .foregroundStyle(Theme.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 18)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.sidebar))
                } else {
                    VStack(spacing: 2) {
                        ForEach(items) { item in
                            ItemRow(item: item, when: Formats.when(item, calendar: store.calendar),
                                    isSelected: store.selectedItemID == item.id) {
                                store.select(item: item)
                            }
                        }
                    }
                }

                if let item = store.selectedItem {
                    ItemDetail(store: store, item: item)
                }

                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel(text: "Tasks", size: 12)
                    Hairline()
                }
                .padding(.horizontal, 4)
                .padding(.top, 8)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 18)
        }
        .frame(width: 300)
        .frame(maxHeight: .infinity)
        .background(Theme.ground)
    }
}

/// A row with a color bar (filled = has a meeting link, outlined = none), title and time.
struct ItemRow: View {
    let item: CalendarItem
    let when: String
    let isSelected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        let color = HexColor.color(item.color)
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Group {
                    if item.meetURL != nil {
                        RoundedRectangle(cornerRadius: 2).fill(color)
                    } else {
                        RoundedRectangle(cornerRadius: 2).strokeBorder(color, lineWidth: 1.5)
                    }
                }
                .frame(width: 4)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title.isEmpty ? "(No title)" : item.title)
                        .font(Fonts.text(13.5, .semibold))
                        .foregroundStyle(Theme.ink)
                        .multilineTextAlignment(.leading)
                    HStack(spacing: 6) {
                        Text(when).monospacedDigit()
                        if item.isTentative { Text("· Not confirmed") }
                    }
                    .font(Fonts.text(12))
                    .foregroundStyle(Theme.secondary)
                }
                Spacer(minLength: 0)
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 8).fill(isSelected || hovering ? Theme.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(item.isTentative ? 0.6 : 1)
        .onHover { hovering = $0 }
    }
}

/// Details for one item: when, calendar, location, notes, Join, Edit/Delete or Google links.
struct ItemDetail: View {
    let store: CalendarStore
    let item: CalendarItem
    @Environment(\.openURL) private var openURL

    var body: some View {
        let info = store.calendarInfo(id: item.calendarID)
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title.isEmpty ? "(No title)" : item.title)
                    .font(Fonts.text(16, .semibold))
                    .foregroundStyle(Theme.ink)
                    .textSelection(.enabled)
                Text(Formats.whenLong(item, calendar: store.calendar))
                    .font(Fonts.text(12.5))
                    .monospacedDigit()
                    .foregroundStyle(Theme.secondary)
                if item.isTentative {
                    Text("Not confirmed")
                        .font(Fonts.text(12, .medium))
                        .foregroundStyle(Theme.secondary)
                }
            }
            HStack(spacing: 8) {
                ItemDot(color: HexColor.color(item.color))
                Text(info?.name ?? "Calendar")
                    .foregroundStyle(Theme.ink)
                Text(item.accountEmail)
                    .foregroundStyle(Theme.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(Fonts.text(12.5))

            if let location = item.location, !location.isEmpty {
                Button {
                    if let url = Self.mapsURL(for: location) { openURL(url) }
                } label: {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "mappin.and.ellipse")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.secondary)
                        Text(location)
                            .font(Fonts.text(12.5))
                            .foregroundStyle(Theme.ink)
                            .multilineTextAlignment(.leading)
                            .underline(false)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Open in Maps")
            }

            if let notes = item.notes, !notes.isEmpty {
                Text(notes)
                    .font(Fonts.text(12.5))
                    .foregroundStyle(Theme.secondary)
                    .lineSpacing(2)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let meet = item.meetURL {
                Button {
                    openURL(meet)
                } label: {
                    Label("Join video call", systemImage: "video")
                }
                .buttonStyle(PlainButtonStyle(prominent: true, height: 36, fullWidth: true))
            }

            actions(info: info)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.divider, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Event details")
    }

    @ViewBuilder private func actions(info: CalendarInfo?) -> some View {
        if store.canEdit(item) {
            HStack(spacing: 8) {
                Button("Edit") { store.edit(item) }
                    .buttonStyle(PlainButtonStyle(fullWidth: true))
                    .help("Edit (E)")
                Button("Delete") { store.requestDelete(item) }
                    .buttonStyle(PlainButtonStyle(destructive: true, fullWidth: true))
                    .help("Delete (⌫)")
            }
        } else if item.isRecurring, !(store.isReadOnly(item)), let web = item.webURL {
            Button("Edit in Google Calendar") { openURL(web) }
                .buttonStyle(PlainButtonStyle(fullWidth: true))
        } else if store.isReadOnly(item) {
            Text("Read-only calendar")
                .font(Fonts.text(12))
                .foregroundStyle(Theme.tertiary)
        }
        if let web = item.webURL {
            Button {
                openURL(web)
            } label: {
                Label("Open in Google Calendar", systemImage: "arrow.up.right.square")
                    .font(Fonts.text(12.5, .medium))
                    .foregroundStyle(Theme.secondary)
            }
            .buttonStyle(.plain)
        }
    }

    static func mapsURL(for location: String) -> URL? {
        if location.hasPrefix("https://") || location.hasPrefix("http://") { return URL(string: location) }
        var components = URLComponents(string: "https://maps.apple.com/")
        components?.queryItems = [URLQueryItem(name: "q", value: location)]
        return components?.url
    }
}

/// Replaces the day inspector while the search field has text.
struct SearchResultsView: View {
    let store: CalendarStore

    var body: some View {
        let cal = store.calendar
        let groups = Dictionary(grouping: store.searchResults) { cal.startOfDay(for: $0.start) }
        let days = groups.keys.sorted()
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    SectionLabel(text: "Search", size: 12)
                    Spacer()
                    if store.isSearchLoading { ProgressView().controlSize(.mini) }
                }
                .padding(.horizontal, 4)
                if store.searchResults.isEmpty && !store.isSearchLoading {
                    Text("No events match “\(store.searchText)”.")
                        .font(Fonts.text(13))
                        .foregroundStyle(Theme.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 18)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.sidebar))
                }
                ForEach(days, id: \.self) { day in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(day.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().year()))
                            .font(Fonts.text(12, .semibold))
                            .foregroundStyle(Theme.secondary)
                            .padding(.horizontal, 4)
                            .padding(.bottom, 2)
                        ForEach(groups[day] ?? []) { item in
                            ItemRow(item: item, when: Formats.when(item, calendar: cal),
                                    isSelected: store.selectedItemID == item.id) {
                                store.reveal(item)
                            }
                        }
                    }
                }
                if let item = store.selectedItem, store.searchResults.contains(where: { $0.id == item.id }) {
                    ItemDetail(store: store, item: item)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 18)
        }
        .frame(width: 300)
        .frame(maxHeight: .infinity)
        .background(Theme.ground)
    }
}
