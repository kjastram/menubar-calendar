import SwiftUI
import AlmanacKit

/// Small month for the sidebar. Shows the displayed month; clicking a day selects it.
struct MiniMonth: View {
    let store: CalendarStore

    var body: some View {
        let cal = store.calendar
        let days = store.gridDays
        let symbols = CalendarMath.orderedWeekdaySymbols(cal.veryShortStandaloneWeekdaySymbols, firstWeekday: cal.firstWeekday)
        let columns = Array(repeating: GridItem(.flexible(minimum: 0), spacing: 0), count: 7)
        VStack(alignment: .leading, spacing: 6) {
            Text(store.displayedMonth.formatted(.dateTime.month(.wide).year()))
                .font(Fonts.text(12.5, .semibold))
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, 4)
            LazyVGrid(columns: columns, spacing: 0) {
                ForEach(Array(symbols.enumerated()), id: \.offset) { _, symbol in
                    Text(symbol)
                        .font(Fonts.text(10.5, .medium))
                        .foregroundStyle(Theme.tertiary)
                        .frame(height: 20)
                }
                ForEach(days, id: \.self) { day in
                    MiniDay(store: store, day: day)
                }
            }
        }
    }
}

private struct MiniDay: View {
    let store: CalendarStore
    let day: Date
    @State private var hovering = false

    var body: some View {
        let cal = store.calendar
        let isToday = cal.isDateInToday(day)
        let isSelected = cal.isDate(day, inSameDayAs: store.selectedDay)
        let inMonth = cal.isDate(day, equalTo: store.displayedMonth, toGranularity: .month)
        Button {
            store.select(day: day)
        } label: {
            Text(String(cal.component(.day, from: day)))
                .font(Fonts.text(11.5, isToday || isSelected ? .semibold : .regular))
                .monospacedDigit()
                .foregroundStyle(isToday ? Theme.onAccent : (inMonth ? Theme.ink : Theme.tertiary))
                .frame(width: 26, height: 26)
                .background(Circle().fill(isToday ? Theme.accent : (isSelected ? Theme.miniSelected : (hovering ? Theme.hover : .clear))))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(day.formatted(date: .complete, time: .omitted))
    }
}

/// Sidebar: mini month, calendars grouped by account, sync status and settings.
struct SidebarView: View {
    let store: CalendarStore

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            MiniMonth(store: store)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(store.calendarGroups, id: \.account.email) { group in
                        AccountSection(store: store, account: group.account, calendars: group.calendars)
                    }
                }
            }
            .scrollIndicators(.never)
            Spacer(minLength: 0)
            SyncFooter(store: store)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 16)
        .frame(width: 232)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.sidebar)
    }
}

private struct AccountSection: View {
    let store: CalendarStore
    let account: Account
    let calendars: [CalendarInfo]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(account.email.uppercased())
                    .font(Fonts.text(11, .semibold))
                    .kerning(0.4)
                    .foregroundStyle(Theme.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
                Button {
                    store.setAccountHidden(account.email, hidden: !account.hidden)
                } label: {
                    Image(systemName: account.hidden ? "eye.slash" : "eye")
                        .font(.system(size: 11))
                }
                .buttonStyle(IconButtonStyle(size: 20))
                .help(account.hidden ? "Show this account's events" : "Hide this account's events")
                .accessibilityLabel(account.hidden ? "Show account" : "Hide account")
            }
            .padding(.horizontal, 4)
            statusLine
            VStack(alignment: .leading, spacing: 0) {
                ForEach(calendars) { info in
                    CalendarRow(info: info) { store.setCalendarVisible(info.id, visible: $0) }
                }
            }
            .opacity(account.hidden ? 0.45 : 1)
        }
    }

    @ViewBuilder private var statusLine: some View {
        switch account.status {
        case .ok:
            if account.hidden {
                Text("Hidden")
                    .font(Fonts.text(11.5))
                    .foregroundStyle(Theme.tertiary)
                    .padding(.horizontal, 4)
            }
        case .needsSignIn:
            Label("Needs sign-in. Use Settings to sign in again.", systemImage: "exclamationmark.triangle")
                .font(Fonts.text(11.5))
                .foregroundStyle(Theme.warning)
                .padding(.horizontal, 4)
        case .error(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(Fonts.text(11.5))
                .foregroundStyle(Theme.warning)
                .lineLimit(2)
                .padding(.horizontal, 4)
        }
    }
}

private struct CalendarRow: View {
    let info: CalendarInfo
    let setVisible: (Bool) -> Void

    var body: some View {
        let color = HexColor.color(info.color)
        Button {
            setVisible(!info.visible)
        } label: {
            HStack(spacing: 9) {
                RoundedRectangle(cornerRadius: 3.5)
                    .fill(info.visible ? color : Color.clear)
                    .overlay(RoundedRectangle(cornerRadius: 3.5).strokeBorder(info.visible ? color : Theme.border, lineWidth: 1.5))
                    .overlay {
                        if info.visible {
                            Image(systemName: "checkmark")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    }
                    .frame(width: 14, height: 14)
                Text(info.name)
                    .font(Fonts.text(13))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Circle().fill(color).frame(width: 8, height: 8)
            }
            .padding(.vertical, 3)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(info.name)
        .accessibilityValue(info.visible ? "Shown" : "Hidden")
        .help(info.canWrite ? info.name : "\(info.name) (read-only)")
    }
}

private struct SyncFooter: View {
    let store: CalendarStore

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(hasProblem ? Theme.warning : Theme.ok).frame(width: 6, height: 6)
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text(statusText(now: context.date))
                    .font(Fonts.text(12))
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Button {
                store.syncNow()
            } label: {
                if store.isSyncing {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "arrow.clockwise").font(.system(size: 13))
                }
            }
            .buttonStyle(IconButtonStyle())
            .keyboardShortcut("r", modifiers: .command)
            .disabled(store.isSyncing)
            .help("Sync now (⌘R)")
            .accessibilityLabel("Sync now")
            SettingsLink {
                Image(systemName: "gearshape").font(.system(size: 14))
            }
            .buttonStyle(IconButtonStyle())
            .help("Settings")
            .accessibilityLabel("Settings")
        }
        .padding(.horizontal, 4)
    }

    private var hasProblem: Bool {
        store.accounts.contains { $0.status != .ok }
    }

    private func statusText(now: Date) -> String {
        if store.isSyncing { return "Syncing…" }
        if store.accounts.contains(where: { $0.status == .needsSignIn }) { return "Sign-in needed" }
        guard let updated = store.lastUpdated else { return "Not synced yet" }
        if now.timeIntervalSince(updated) < 60 { return "Updated just now" }
        return "Updated " + updated.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
    }
}
