import AppKit
import SwiftUI
import WhatMadeThatSoundKit

struct SettingsView: View {
    @Environment(LogStore.self) private var store
    @Environment(ServiceController.self) private var service
    @State private var isConfirmingClear = false
    @State private var clearError: String?

    var body: some View {
        Form {
            recordingSection
            historySection
        }
        .formStyle(.grouped)
        .frame(width: 540)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { service.refresh() }
        .confirmationDialog("Clear the entire history?", isPresented: $isConfirmingClear) {
            Button("Clear History", role: .destructive) {
                do {
                    try store.clearLog()
                    clearError = nil
                } catch {
                    clearError = String(describing: error)
                }
            }
        } message: {
            Text("Every recorded sound will be permanently deleted. Recording continues if it’s turned on.")
        }
    }

    private var recordingSection: some View {
        Section {
            Toggle("Record sounds in the background", isOn: Binding(
                get: { service.isEnabled },
                set: { service.setEnabled($0) }
            ))
            .disabled(service.registration == .unavailable || service.isChanging)

            LabeledContent("Status") {
                statusText
            }

            if service.registration == .requiresApproval {
                Button("Open Login Items Settings…") { service.openLoginItemsSettings() }
            }
            if let error = service.lastError {
                Text(error)
                    .foregroundStyle(.red)
            }
            if service.runningAgentIsFromAnotherCopy, let path = service.runningAgent?.executablePath {
                Text("Recording is being done by another copy of the app: \(path)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Background Recording")
        } footer: {
            Text("A small background agent starts when you log in and notes whenever an app starts or stops playing sound, even while this window is closed. It never records the audio itself.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var statusText: some View {
        if let agent = service.runningAgent {
            Label {
                Text("Recording since \(agent.startedAt.formatted(date: .abbreviated, time: .shortened))")
            } icon: {
                Image(systemName: "circle.fill").foregroundStyle(.green)
            }
        } else {
            switch service.registration {
            case .enabled: Text("Starting…").foregroundStyle(.secondary)
            case .requiresApproval: Text("Needs your approval in System Settings").foregroundStyle(.orange)
            case .disabled: Text("Off").foregroundStyle(.secondary)
            case .unavailable: Text("Unavailable in this copy of the app").foregroundStyle(.secondary)
            }
        }
    }

    private var historySection: some View {
        Section {
            LabeledContent("Space used") {
                if let stats = store.stats {
                    VStack(alignment: .trailing, spacing: 4) {
                        Text("\(Formatting.bytes(stats.usedBytes)) of \(Formatting.bytes(stats.capacity))")
                        ProgressView(value: Double(stats.usedBytes), total: Double(max(stats.capacity, 1)))
                            .frame(width: 160)
                    }
                } else {
                    Text("Nothing recorded yet").foregroundStyle(.secondary)
                }
            }
            LabeledContent("Sounds", value: store.assembler.sessions.count.formatted())
            if let oldest = store.assembler.sessions.first?.start {
                LabeledContent("Oldest", value: oldest.formatted(date: .long, time: .shortened))
            }
            LabeledContent("Location") {
                HStack {
                    Text(store.paths.logFile.path(percentEncoded: false))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                        .help(store.paths.logFile.path(percentEncoded: false))
                    Button("Show in Finder", action: revealLog)
                }
            }
            HStack {
                if let clearError {
                    Text(clearError).foregroundStyle(.red)
                }
                Spacer()
                Button("Clear History…", role: .destructive) { isConfirmingClear = true }
                    .disabled(store.stats == nil)
            }
        } header: {
            Text("History")
        } footer: {
            Text("The most recent \(Formatting.bytes(store.stats?.capacity ?? AppConstants.defaultLogCapacity)) of events are kept; older ones are discarded automatically.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func revealLog() {
        let file = store.paths.logFile
        if FileManager.default.fileExists(atPath: file.path) {
            NSWorkspace.shared.activateFileViewerSelecting([file])
        } else {
            NSWorkspace.shared.open(store.paths.directory)
        }
    }
}
