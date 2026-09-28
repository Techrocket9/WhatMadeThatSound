import AppKit
import SwiftUI
import WhatMadeThatSoundKit

@main
struct WhatMadeThatSoundApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = LogStore()
    @State private var service = ServiceController()

    var body: some Scene {
        Window("What Made That Sound", id: "main") {
            ContentView()
                .environment(store)
                .environment(service)
                .frame(minWidth: 760, minHeight: 420)
                .task {
                    store.start()
                    service.start()
                    #if DEBUG
                    DebugSnapshot.runIfRequested(store: store)
                    #endif
                }
        }
        .defaultSize(width: 1100, height: 660)
        .commands {
            SidebarCommands()
            InspectorCommands()
        }

        Settings {
            SettingsView()
                .environment(store)
                .environment(service)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// The viewer is an ordinary app: closing its window quits it. Recording
    /// continues in the background agent.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
