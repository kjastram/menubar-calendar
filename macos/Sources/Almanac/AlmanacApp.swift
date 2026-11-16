import AlmanacUI
import AppKit
import SwiftUI

@main
struct AlmanacApp: App {
    static let mainWindowID = "main"

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel.shared

    init() {
        if CommandLine.arguments.contains("--print-plugin-config") {
            Self.printPluginConfig()
        }
        AppModel.shared.start()
    }

    var body: some Scene {
        Window("Almanac", id: Self.mainWindowID) {
            MainWindowContent(model: model)
        }
        .defaultSize(width: 1100, height: 720)

        MenuBarExtra {
            MenuBarPopover(model: model)
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(model: model)
        }
    }

    /// `Almanac --print-plugin-config`: shows how the plugin's config.json parses, then exits.
    private static func printPluginConfig() -> Never {
        let url = PluginConfig.fileURL()
        do {
            if let config = try PluginConfig.load(from: url) {
                print("\(url.path)\n\(config.summary)")
                exit(0)
            }
            print("No plugin config at \(url.path)")
            exit(0)
        } catch {
            FileHandle.standardError.write(Data("Couldn't read \(url.path): \(error)\n".utf8))
            exit(1)
        }
    }
}

/// The main window: the calendar, or the setup steps when the app can't start.
/// Shows the Dock icon while it is open.
private struct MainWindowContent: View {
    let model: AppModel

    var body: some View {
        Group {
            if let services = model.services {
                MainWindowView(store: services.store)
            } else {
                SetupView(model: model, problem: model.setupProblem ?? "Starting…")
            }
        }
        .onAppear {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
        .onDisappear {
            NSApp.setActivationPolicy(.accessory)
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
            if let window = note.object as? NSWindow,
               window.identifier?.rawValue.hasPrefix(AlmanacApp.mainWindowID) == true {
                model.syncSoon()
            }
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // The .app sets LSUIElement; this covers running the bare binary. The main window switches to .regular.
        NSApp.setActivationPolicy(.accessory)
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        AppModel.shared.syncSoon()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
