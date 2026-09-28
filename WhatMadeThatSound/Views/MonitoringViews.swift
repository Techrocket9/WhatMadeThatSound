import SwiftUI
import WhatMadeThatSoundKit

/// Explains, above the list, why new sounds aren't being recorded — and offers the fix.
struct MonitoringBanner: View {
    @Environment(ServiceController.self) private var service

    var body: some View {
        if let content {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: content.symbol)
                        .foregroundStyle(content.tint)
                        .imageScale(.large)
                    // No fixedSize here: probed at zero width it would report a
                    // one-character-per-line height and stretch the whole window.
                    Text(content.message)
                        .lineLimit(3)
                        .layoutPriority(1)
                    Spacer(minLength: 8)
                    content.action
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(content.tint.opacity(0.12))
                Divider()
            }
        }
    }

    private struct Content {
        var symbol: String
        var tint: Color
        var message: String
        var action: AnyView
    }

    private var content: Content? {
        if let error = service.lastError {
            return Content(symbol: "exclamationmark.triangle.fill", tint: .red,
                           message: String(localized: "Couldn’t change background recording: \(error)"),
                           action: AnyView(SettingsLink { Text("Settings…") }))
        }
        if service.isRecording {
            return nil
        }
        switch service.registration {
        case .disabled:
            return Content(symbol: "pause.circle.fill", tint: .orange,
                           message: String(localized: "Background recording is off, so new sounds aren’t being logged."),
                           action: AnyView(Button("Turn On") { service.setEnabled(true) }.disabled(service.isChanging)))
        case .requiresApproval:
            return Content(symbol: "hand.raised.fill", tint: .orange,
                           message: String(localized: "Allow “What Made That Sound” in System Settings › General › Login Items to start recording."),
                           action: AnyView(Button("Open System Settings") { service.openLoginItemsSettings() }))
        case .enabled:
            return Content(symbol: "hourglass", tint: .secondary,
                           message: String(localized: "Waiting for the background recorder to start…"),
                           action: AnyView(Button("Login Items…") { service.openLoginItemsSettings() }))
        case .unavailable:
            return Content(symbol: "exclamationmark.triangle.fill", tint: .orange,
                           message: String(localized: "This copy of the app can’t run the background recorder. Run the built app bundle instead."),
                           action: AnyView(EmptyView()))
        }
    }
}

/// Toolbar indicator of whether sounds are being recorded right now; opens Settings.
struct MonitoringStatusButton: View {
    @Environment(ServiceController.self) private var service

    var body: some View {
        SettingsLink {
            Label {
                Text(service.isRecording ? "Recording" : "Not Recording")
            } icon: {
                Image(systemName: service.isRecording ? "record.circle" : "pause.circle")
                    .foregroundStyle(service.isRecording ? Color.red : Color.secondary)
            }
            .labelStyle(.titleAndIcon)
        }
        .help(helpText)
    }

    private var helpText: String {
        if let agent = service.runningAgent {
            let since = agent.startedAt.formatted(date: .abbreviated, time: .shortened)
            return String(localized: "Recording in the background since \(since). Click to change in Settings.")
        }
        return String(localized: "Sounds aren’t being recorded. Click to turn recording on in Settings.")
    }
}
