import AlmanacKit
import AppKit
import SwiftUI

/// The `.window` style popover. Replaces the plugin's dropdown.
struct MenuBarPopover: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @Environment(\.dismiss) private var dismiss
    @State private var quickAddText = ""
    @State private var addingQuickly = false

    private var menu: MenuBarModel { model.menu }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let problem = model.setupProblem {
                setupNotice(problem)
            } else if menu.loaded && menu.accounts.isEmpty && model.canManageAccounts {
                signInNotice
            } else {
                problemRows
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        sections
                    }
                }
                .frame(maxHeight: 440)
                .fixedSize(horizontal: false, vertical: true)
                if model.services != nil { quickAdd }
            }
            if let error = model.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            footer
        }
        .padding(14)
        .frame(width: 360)
        .task { await menu.reload() }
    }

    // MARK: - Header and notices

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(menu.now.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
                .font(.system(size: 17, weight: .semibold))
            Spacer()
            if model.setupProblem == nil {
                let count = todayCount
                Text(count == 1 ? "1 event" : "\(count) events")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 4)
    }

    private var todayCount: Int {
        menu.allDay(on: menu.now).count + menu.timed(on: menu.now).count
    }

    private func setupNotice(_ problem: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Almanac setup needed").font(.system(size: 13, weight: .semibold))
            Text(problem).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(4)
            Button("Show setup") { showMainWindow() }
        }
        .padding(.horizontal, 4)
    }

    private var signInNotice: some View {
        HStack {
            Button {
                Task { await model.addAccount() }
            } label: {
                Label(model.isSigningIn ? "Waiting for the browser…" : "Sign in to Google Calendar",
                      systemImage: "person.crop.circle.badge.plus")
            }
            .disabled(model.isSigningIn)
            if model.isSigningIn {
                Button("Cancel") { model.cancelSignIn() }
            }
        }
        .padding(.horizontal, 4)
    }

    @ViewBuilder private var problemRows: some View {
        let problems = menu.problems
        let failedCalendars = menu.failedCalendars
        if !problems.isEmpty || !failedCalendars.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(problems, id: \.email) { problem in
                    if problem.needsSignIn {
                        Button {
                            Task { await model.addAccount() }
                        } label: {
                            Label("Sign in again: \(problem.email)", systemImage: "person.crop.circle.badge.exclamationmark")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(PopoverRowStyle())
                        .disabled(!model.canManageAccounts || model.isSigningIn)
                    } else {
                        VStack(alignment: .leading, spacing: 2) {
                            Label("Couldn't load \(problem.email)", systemImage: "exclamationmark.triangle")
                                .font(.system(size: 13))
                            if let message = problem.message {
                                Text(message).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                                    .help(message)
                            }
                        }
                        .padding(.horizontal, 10)
                    }
                }
                ForEach(failedCalendars, id: \.id) { calendar in
                    Label("Couldn't load \(calendar.name)", systemImage: "exclamationmark.triangle")
                        .font(.system(size: 13))
                        .help(calendar.message)
                        .padding(.horizontal, 10)
                }
                if model.isSigningIn && problems.contains(where: \.needsSignIn) {
                    Button {
                        model.cancelSignIn()
                    } label: {
                        Label("Waiting for the browser… Cancel", systemImage: "xmark.circle")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(PopoverRowStyle())
                }
            }
        }
    }

    // MARK: - Sections

    @ViewBuilder private var sections: some View {
        let now = menu.now
        let ongoing = menu.ongoing
        let next = menu.next
        let nextIDs = Set(next.map(\.id))
        let ongoingIDs = Set(ongoing.map(\.id))

        if !ongoing.isEmpty {
            section("Now") {
                ForEach(ongoing) { item in
                    EventRow(item: item, label: "until \(MenuText.time(item.end))", model: model, dimmed: false,
                             onOpen: { open(item) })
                }
            }
        }

        if !next.isEmpty {
            NextUpCard(items: next, now: now, model: model, onOpen: open)
        }

        let todayAllDay = menu.allDay(on: now)
        let todayTimed = menu.timed(on: now).filter { !nextIDs.contains($0.id) && !ongoingIDs.contains($0.id) }
        section("Today") {
            ForEach(todayAllDay) { item in
                EventRow(item: item, label: "All day", model: model, dimmed: false, onOpen: { open(item) })
            }
            ForEach(todayTimed) { item in
                EventRow(item: item, label: MenuText.time(item.start), model: model, dimmed: item.end <= now,
                         onOpen: { open(item) })
            }
            if !menu.accounts.isEmpty && menu.activeAccounts.isEmpty {
                emptyText("All accounts are hidden")
            } else if todayAllDay.isEmpty
                        && !todayTimed.contains(where: { $0.start > now })
                        && !next.contains(where: { Calendar.current.isDate($0.start, inSameDayAs: now) }) {
                emptyText("No more events today")
            }
        }

        let tomorrow = menu.tomorrow
        let tomorrowAllDay = menu.allDay(on: tomorrow)
        let tomorrowTimed = menu.timed(on: tomorrow).filter { !nextIDs.contains($0.id) }
        if !tomorrowAllDay.isEmpty || !tomorrowTimed.isEmpty {
            section("Tomorrow") {
                ForEach(tomorrowAllDay) { item in
                    EventRow(item: item, label: "All day", model: model, dimmed: false, onOpen: { open(item) })
                }
                ForEach(tomorrowTimed) { item in
                    EventRow(item: item, label: MenuText.time(item.start), model: model, dimmed: false,
                             onOpen: { open(item) })
                }
            }
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .kerning(0.4)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
            content()
        }
    }

    private func emptyText(_ text: String) -> some View {
        Text(text).font(.system(size: 13)).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.vertical, 4)
    }

    // MARK: - Quick add and footer

    private var quickAdd: some View {
        HStack(spacing: 8) {
            Image(systemName: addingQuickly ? "hourglass" : "plus").foregroundStyle(.secondary)
            TextField("Quick add: “Gym tomorrow 7am”", text: $quickAddText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .disabled(addingQuickly || model.defaultCalendar == nil)
                .onSubmit {
                    let text = quickAddText
                    addingQuickly = true
                    Task {
                        if await model.quickAdd(text) { quickAddText = "" }
                        addingQuickly = false
                    }
                }
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.primary.opacity(0.12)))
        .help(model.defaultCalendar.map { "Adds to \($0.name) (\($0.accountEmail))" } ?? "No calendar you can add events to")
    }

    private var footer: some View {
        VStack(spacing: 4) {
            Divider()
            HStack(spacing: 2) {
                Button { showMainWindow() } label: { Label("Open calendar", systemImage: "calendar") }
                Spacer()
                Button {
                    Task { await model.syncNow() }
                } label: {
                    Label("Sync now", systemImage: "arrow.clockwise")
                }
                .disabled(model.services == nil || model.isSyncing)
                Button("Settings…") {
                    dismiss()
                    NSApp.activate(ignoringOtherApps: true)
                    openSettings()
                }
            }
            .buttonStyle(FooterButtonStyle())
            HStack {
                Text(syncedText).font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("Quit Almanac") { NSApp.terminate(nil) }
                    .buttonStyle(FooterButtonStyle())
                    .font(.system(size: 11))
            }
            .padding(.leading, 10)
        }
    }

    private var syncedText: String {
        if model.isSyncing { return "Syncing…" }
        guard let synced = model.lastSynced else { return model.previewData ? "Preview data" : "Not synced yet" }
        return "Synced \(MenuText.time(synced))"
    }

    // MARK: - Navigation

    private func showMainWindow() {
        dismiss()
        openWindow(id: AlmanacApp.mainWindowID)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Opens the main window on the item's day, with the item selected.
    private func open(_ item: CalendarItem) {
        model.services?.store.reveal(item)
        showMainWindow()
    }
}

// MARK: - Rows

private struct NextUpCard: View {
    let items: [CalendarItem]
    let now: Date
    let model: AppModel
    let onOpen: (CalendarItem) -> Void

    var body: some View {
        let first = items[0]
        let accent = hexColor(model.menu.color(for: first))
        VStack(alignment: .leading, spacing: 8) {
            Text("Next up · in \(minutesText(first.start.timeIntervalSince(now)))".uppercased())
                .font(.system(size: 11, weight: .semibold))
                .kerning(0.5)
                .foregroundStyle(accent)
            ForEach(items) { item in
                HStack(alignment: .center, spacing: 10) {
                    Button { onOpen(item) } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(MenuText.clean(item.title))
                                .font(.system(size: 15, weight: .semibold))
                                .lineLimit(2)
                            Text(detail(item))
                                .font(.system(size: 12.5))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu { EventContextMenu(item: item) }
                    if let meet = item.meetURL {
                        Button("Join") { NSWorkspace.shared.open(meet) }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
    }

    private func minutesText(_ seconds: TimeInterval) -> String {
        let mins = max(1, Int((seconds / 60).rounded()))
        return mins < 60 ? "\(mins) min" : MenuText.delta(seconds)
    }

    private func detail(_ item: CalendarItem) -> String {
        var parts = ["\(MenuText.time(item.start)) – \(MenuText.time(item.end))"]
        if let location = item.location, !location.isEmpty, !location.hasPrefix("https://") {
            parts.append(MenuText.clean(location))
        } else if model.menu.activeAccounts.count > 1 {
            parts.append(model.menu.calendarName(for: item))
        }
        return parts.joined(separator: " · ")
    }
}

private struct EventRow: View {
    let item: CalendarItem
    let label: String
    let model: AppModel
    let dimmed: Bool
    let onOpen: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onOpen) {
                HStack(spacing: 10) {
                    Image(nsImage: barImage(color: model.menu.color(for: item), filled: item.meetURL != nil))
                    Text(label)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(width: 64, alignment: .leading)
                        .lineLimit(1)
                    Text(MenuText.clean(item.title))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if let meet = item.meetURL {
                Button("Join") { NSWorkspace.shared.open(meet) }
                    .controlSize(.small)
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .opacity(dimmed ? 0.55 : 1)
        .modifier(HoverBackground())
        .help(tooltip)
        .contextMenu { EventContextMenu(item: item) }
    }

    private var tooltip: String {
        var lines = [MenuText.clean(item.title)]
        if !item.isAllDay {
            lines.append("\(MenuText.time(item.start)) – \(MenuText.time(item.end))")
        }
        let calendar = model.menu.calendarName(for: item)
        lines.append(calendar == item.accountEmail ? calendar : "\(calendar) (\(item.accountEmail))")
        if let location = item.location, !location.isEmpty, !location.hasPrefix("https://") {
            lines.append(MenuText.clean(location))
        }
        if item.isTentative { lines.append("Not confirmed") }
        return lines.joined(separator: "\n")
    }
}

private struct EventContextMenu: View {
    let item: CalendarItem

    var body: some View {
        if let meet = item.meetURL {
            Button("Join meeting") { NSWorkspace.shared.open(meet) }
        }
        if let web = item.webURL {
            Button("Open in Google Calendar") { NSWorkspace.shared.open(web) }
        }
    }
}

private struct HoverBackground: ViewModifier {
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(hovering ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 7))
            .onHover { hovering = $0 }
    }
}

private struct PopoverRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.6 : 1)
            .modifier(HoverBackground())
    }
}

private struct FooterButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .medium))
            .padding(.horizontal, 10)
            .frame(height: 28)
            .contentShape(Rectangle())
            .opacity(isEnabled ? (configuration.isPressed ? 0.6 : 1) : 0.4)
            .modifier(HoverBackground())
    }
}
