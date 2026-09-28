import AppKit
import SwiftUI
import WhatMadeThatSoundKit

/// Started from main.swift.
struct WhatMadeThatSoundApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private let model = AppModel.shared

    var body: some Scene {
        Window("What Made That Sound", id: "main") {
            ContentView()
                .environment(model.store)
                .environment(model.service)
                .frame(minWidth: 760, minHeight: 420)
        }
        .defaultSize(width: 1100, height: 660)
        .commands {
            SidebarCommands()
            InspectorCommands()
        }

        Settings {
            SettingsView()
                .environment(model.store)
                .environment(model.service)
        }
    }
}

/// App-wide state. Started when the app finishes launching rather than when a
/// window appears, so first-launch agent registration doesn't depend on the UI.
@MainActor
final class AppModel {
    static let shared = AppModel()

    let store = LogStore()
    let service = ServiceController()

    func start() {
        store.start()
        service.start()
        #if DEBUG
        DebugSnapshot.runIfRequested(store: store)
        #endif
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppModel.shared.start()
    }

    /// The viewer is an ordinary app: closing its window quits it. Recording
    /// continues in the background agent.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}
