import AppKit
import SwiftUI

/// The window app, or the `schedulai` command line when given a command.
/// macOS may pass `-psn_…` or `-NS…` flags to an app it launches: those start the app.
@main
enum Entry {
    @MainActor
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        if let first = args.first, !first.hasPrefix("-") {
            JobStore.headless = true
            exit(CLI.run(args))
        }
        SchedulaiApp.main()
    }
}

struct SchedulaiApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var store = JobStore.shared

    var body: some Scene {
        WindowGroup("SchedulAI", id: "main") {
            ContentView(store: store)
                .frame(minWidth: 820, minHeight: 480)
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = StatusItemController(store: JobStore.shared)
        Updater.shared.start()
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        JobStore.shared.dockMenu()
    }

    /// The jobs run under launchd either way; the app stays in the Dock to
    /// show their state.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
