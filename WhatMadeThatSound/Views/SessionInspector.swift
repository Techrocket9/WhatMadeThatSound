import SwiftUI
import WhatMadeThatSoundKit

/// Everything known about one sound: when, which process, which app, which device.
struct SessionInspector: View {
    @Environment(ServiceController.self) private var service
    let session: AudioSession?

    var body: some View {
        if let session {
            details(session)
        } else {
            ContentUnavailableView(
                "No Selection",
                systemImage: "waveform",
                description: Text("Select a sound to see which process made it.")
            )
        }
    }

    private func details(_ session: AudioSession) -> some View {
        let identity = session.source.identity
        return Form {
            Section {
                HStack(spacing: 12) {
                    SourceIcon(identity: identity, size: 48)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(identity.displayName)
                            .font(.title3.weight(.semibold))
                        if let bundleID = identity.appBundleID ?? identity.processBundleID {
                            Text(bundleID)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            Section("Sound") {
                LabeledContent("Started", value: precise(session.start))
                if session.flags.contains(.alreadyPlayingAtMonitorStart) {
                    Text("Already playing when recording started; it may have started earlier.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Ended", value: endDescription(session))
                LabeledContent("Duration", value: session.duration.map(Formatting.duration) ?? "—")
                LabeledContent("Output", value: session.devices.displayName.isEmpty ? "—" : session.devices.displayName)
                if session.flags.contains(.processExited) {
                    Text("Ended when the process quit.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Process") {
                LabeledContent("Name", value: identity.processName)
                LabeledContent("PID", value: String(identity.pid))
                if let bundleID = identity.processBundleID {
                    LabeledContent("Bundle ID") { Text(bundleID).textSelection(.enabled) }
                }
                if let path = identity.executablePath {
                    pathRow("Executable", path)
                }
            }

            if identity.appPath != nil || identity.responsiblePID != nil {
                Section("Application") {
                    if let name = identity.appName {
                        LabeledContent("Name", value: name)
                    }
                    if let path = identity.appPath {
                        pathRow("Location", path)
                    }
                    if let responsible = identity.responsiblePID {
                        LabeledContent("Responsible PID", value: String(responsible))
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func pathRow(_ title: LocalizedStringKey, _ path: String) -> some View {
        LabeledContent(title) {
            Text(path)
                .font(.callout)
                .textSelection(.enabled)
                .lineLimit(nil)
                .multilineTextAlignment(.trailing)
        }
    }

    private func precise(_ date: Date) -> String {
        date.formatted(.dateTime.year().month().day().hour().minute().second().secondFraction(.fractional(3)))
    }

    private func endDescription(_ session: AudioSession) -> String {
        switch session.status {
        case .ended:
            let end = precise(session.end ?? session.start)
            return session.flags.contains(.monitorStopped) ? String(localized: "\(end) (recording stopped)") : end
        case .open where service.isRecording:
            return String(localized: "Still playing")
        case .open, .interrupted:
            return String(localized: "Unknown")
        }
    }
}
