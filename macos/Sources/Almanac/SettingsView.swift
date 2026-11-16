import AlmanacKit
import AppKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    let model: AppModel

    var body: some View {
        TabView {
            AccountsTab(model: model).tabItem { Label("Accounts", systemImage: "person.2") }
            CalendarsTab(model: model).tabItem { Label("Calendars", systemImage: "calendar") }
            GeneralTab().tabItem { Label("General", systemImage: "gearshape") }
        }
        .frame(width: 560, height: 440)
        .task { await model.menu.reload() }
    }
}

// MARK: - Accounts

private struct AccountsTab: View {
    let model: AppModel
    @State private var removing: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let problem = model.setupProblem {
                Text(problem).foregroundStyle(.secondary)
            }
            List {
                ForEach(model.menu.accounts) { account in
                    AccountRow(model: model, account: account, onRemove: { removing = account.email })
                }
                if model.menu.accounts.isEmpty {
                    Text("No accounts yet.").foregroundStyle(.secondary)
                }
            }
            .listStyle(.inset)
            HStack {
                Button {
                    Task { await model.addAccount() }
                } label: {
                    Label(model.isSigningIn ? "Waiting for the browser…" : "Add Google account…", systemImage: "plus")
                }
                .disabled(!model.canManageAccounts || model.isSigningIn)
                if model.isSigningIn {
                    Button("Cancel") { model.cancelSignIn() }
                }
                Spacer()
                if model.previewData {
                    Text("Preview data: accounts can't be changed.").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Sign-in opens your browser.").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let error = model.lastError {
                Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .confirmationDialog("Remove \(removing ?? "")?", isPresented: Binding(
            get: { removing != nil }, set: { if !$0 { removing = nil } }
        )) {
            Button("Remove account", role: .destructive) {
                if let email = removing { Task { await model.removeAccount(email) } }
                removing = nil
            }
        } message: {
            Text("Signs out and deletes this account's cached events. Google access is revoked.")
        }
    }
}

private struct AccountRow: View {
    let model: AppModel
    let account: Account
    let onRemove: () -> Void

    private var needsSignIn: Bool {
        account.status == .needsSignIn || model.menu.needsSignIn.contains(account.email)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: needsSignIn ? "exclamationmark.triangle.fill" : "circle.fill")
                    .foregroundStyle(needsSignIn ? Color.orange : hexColor(account.color))
                    .font(.system(size: needsSignIn ? 12 : 9))
                Text(account.email).font(.system(size: 13, weight: .medium))
                Text(statusText).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                if needsSignIn {
                    Button("Sign in again") { Task { await model.addAccount() } }
                        .disabled(!model.canManageAccounts || model.isSigningIn)
                }
                Button("Remove", action: onRemove).disabled(!model.canManageAccounts)
            }
            HStack(spacing: 6) {
                ForEach(accountPalette, id: \.self) { hex in
                    Button {
                        Task { await model.setAccountColor(account.email, hex) }
                    } label: {
                        Circle()
                            .fill(hexColor(hex))
                            .frame(width: 14, height: 14)
                            .overlay(Circle().stroke(Color.primary, lineWidth: account.color.lowercased() == hex ? 2 : 0)
                                .padding(-3))
                    }
                    .buttonStyle(.plain)
                    .help(hex)
                }
                Spacer()
                Toggle("Show events", isOn: Binding(
                    get: { !account.hidden },
                    set: { shown in Task { await model.setAccountHidden(account.email, !shown) } }
                ))
                .toggleStyle(.checkbox)
            }
            .padding(.leading, 20)
        }
        .padding(.vertical, 4)
    }

    private var statusText: String {
        if needsSignIn { return "needs sign-in" }
        if case .error(let message) = account.status { return "sync failed: \(message)" }
        return account.hidden ? "signed in · hidden" : "signed in"
    }
}

// MARK: - Calendars

private struct CalendarsTab: View {
    let model: AppModel
    @AppStorage(AppSettings.defaultCalendarID) private var savedDefault = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            List {
                ForEach(model.menu.accounts) { account in
                    Section(account.email) {
                        let calendars = model.menu.calendars
                            .filter { $0.accountEmail == account.email }
                            .sorted { ($0.isPrimary ? 0 : 1, $0.name) < ($1.isPrimary ? 0 : 1, $1.name) }
                        ForEach(calendars) { calendar in
                            Toggle(isOn: Binding(
                                get: { calendar.visible },
                                set: { visible in Task { await model.setCalendarVisible(calendar.id, visible) } }
                            )) {
                                HStack(spacing: 8) {
                                    Circle().fill(hexColor(calendar.color)).frame(width: 9, height: 9)
                                    Text(calendar.name)
                                    if !calendar.canWrite {
                                        Text("read-only").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .toggleStyle(.checkbox)
                        }
                        if calendars.isEmpty {
                            Text("No calendars synced yet.").foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .listStyle(.inset)
            let writable = model.services?.store.writableCalendars ?? []
            Picker("Default calendar for new events", selection: Binding(
                get: { writable.contains { $0.id == savedDefault } ? savedDefault : (model.defaultCalendar?.id ?? "") },
                set: { model.setDefaultCalendar($0) }
            )) {
                if writable.isEmpty {
                    Text("None").tag("")
                }
                ForEach(writable) { calendar in
                    Text("\(calendar.name) (\(calendar.accountEmail))").tag(calendar.id)
                }
            }
            .disabled(writable.isEmpty)
        }
        .padding(20)
    }
}

// MARK: - General

private struct GeneralTab: View {
    @AppStorage(AppSettings.lookaheadMinutes) private var lookahead = AppSettings.defaultLookahead
    @AppStorage(AppSettings.titleLength) private var titleLength = AppSettings.defaultTitleLength
    @AppStorage(AppSettings.showNextEvent) private var showNextEvent = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    private var inAppBundle: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: Binding(get: { launchAtLogin }, set: { setLaunchAtLogin($0) }))
                    .disabled(!inAppBundle)
                if !inAppBundle {
                    Text("Only works when running from Almanac.app (scripts/build-app.sh).")
                        .font(.caption).foregroundStyle(.secondary)
                } else if SMAppService.mainApp.status == .requiresApproval {
                    Text("Allow Almanac in System Settings → General → Login Items.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Menu bar") {
                Toggle("Show next event in menu bar", isOn: $showNextEvent)
                Picker("Title length", selection: $titleLength) {
                    ForEach(options([12, 16, 20, 24, 32, 40], including: titleLength), id: \.self) { n in
                        Text("\(n) characters").tag(n)
                    }
                }
                .disabled(!showNextEvent)
                Picker("Look-ahead for “Next up”", selection: $lookahead) {
                    ForEach(options([15, 30, 45, 60, 90, 120, 180, 240], including: lookahead), id: \.self) { n in
                        Text("\(n) min").tag(n)
                    }
                }
                .disabled(!showNextEvent)
            }
        }
        .formStyle(.grouped)
        .padding(8)
    }

    private func options(_ base: [Int], including value: Int) -> [Int] {
        base.contains(value) ? base : (base + [value]).sorted()
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = error.localizedDescription
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}
