import AppKit
import SwiftUI

/// Shown in the main window when the app can't start, usually because the OAuth client file is missing.
/// Mirrors the plugin's `render_setup`.
struct SetupView: View {
    let model: AppModel
    let problem: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Almanac setup needed", systemImage: "calendar.badge.exclamationmark")
                .font(.system(size: 20, weight: .semibold))
            Text(problem)
                .textSelection(.enabled)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                Text("1. In Google Cloud, open the OAuth clients page and create (or reuse) a **Desktop app** client.")
                Text("2. Download its JSON. Almanac uses the SwiftBar plugin's file if it exists:")
                pathText(PluginConfig.directory().appendingPathComponent("credentials.json").path)
                Text("   Or save it as:")
                pathText(appSupportClientPath)
                Text("3. Make sure the consent screen has the calendar.events and calendar.readonly scopes, then click Try again.")
            }
            .font(.system(size: 13))
            HStack {
                Button("Open Google Cloud clients page") {
                    NSWorkspace.shared.open(URL(string: "https://console.cloud.google.com/auth/clients")!)
                }
                Button("Open Almanac folder") {
                    let dir = URL(fileURLWithPath: appSupportClientPath).deletingLastPathComponent()
                    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(dir)
                }
                Spacer()
                Button("Try again") { model.retrySetup() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(minWidth: 560, maxWidth: 680, minHeight: 320, alignment: .topLeading)
    }

    private var appSupportClientPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Almanac/client.json").path
    }

    private func pathText(_ path: String) -> some View {
        Text(path)
            .font(.system(.body, design: .monospaced))
            .textSelection(.enabled)
            .padding(.leading, 16)
    }
}
