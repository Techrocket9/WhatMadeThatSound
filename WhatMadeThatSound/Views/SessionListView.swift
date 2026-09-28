import AppKit
import SwiftUI
import WhatMadeThatSoundKit

/// The sounds for the selected day (or all days), one row per playback session.
struct SessionListView: View {
    @Environment(LogStore.self) private var store
    @Environment(ServiceController.self) private var service
    @Binding var selection: Set<AudioSession.ID>
    var showDetails: () -> Void

    var body: some View {
        @Bindable var store = store
        Group {
            if !store.hasLoaded {
                ProgressView("Loading history…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if store.displayedSessions.isEmpty {
                emptyState
            } else {
                table(sortOrder: $store.sortOrder)
            }
        }
    }

    private var showsDates: Bool {
        if case .day = store.selection { return false }
        return true
    }

    private func table(sortOrder: Binding<[KeyPathComparator<AudioSession>]>) -> some View {
        // Cells get plain values rather than reading the environment themselves:
        // table cells are hosted separately and must not depend on it.
        let showsDates = showsDates
        let isRecording = service.isRecording
        return Table(store.displayedSessions, selection: $selection, sortOrder: sortOrder) {
            TableColumn("Started", value: \.start) { session in
                StartCell(session: session, showsDate: showsDates)
            }
            .width(min: 80, ideal: showsDates ? 150 : 90)

            TableColumn("Ended", value: \.sortableEnd) { session in
                EndCell(session: session, isRecording: isRecording)
            }
            .width(min: 80, ideal: 90)

            TableColumn("Duration", value: \.sortableDuration) { session in
                DurationCell(session: session, isRecording: isRecording)
            }
            .width(min: 60, ideal: 75)

            TableColumn("Application", value: \.source.displayName) { session in
                ApplicationCell(identity: session.source.identity)
            }
            .width(min: 120, ideal: 170)

            TableColumn("Process", value: \.source.identity.processName) { session in
                Text(session.processDescription)
                    .help(session.source.identity.executablePath ?? session.source.identity.processName)
            }
            .width(min: 100, ideal: 180)

            TableColumn("Output Device", value: \.devices.displayName) { session in
                Text(session.devices.displayName)
            }
            .width(min: 100, ideal: 150)
        }
        .contextMenu(forSelectionType: AudioSession.ID.self) { ids in
            contextMenu(for: ids)
        } primaryAction: { _ in
            showDetails()
        }
        .onCopyCommand {
            [NSItemProvider(object: copyText(for: selection) as NSString)]
        }
        .safeAreaInset(edge: .bottom) {
            if store.isDisplayTruncated {
                Text("Showing the \(LogStore.allSessionsDisplayLimit) most recent of \(store.matchingSessionCount) sounds. Choose a day to see the rest.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(8)
                    .background(.bar)
            }
        }
    }

    @ViewBuilder
    private func contextMenu(for ids: Set<AudioSession.ID>) -> some View {
        let sessions = store.displayedSessions.filter { ids.contains($0.id) }
        if !sessions.isEmpty {
            Button("Copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(copyText(for: ids), forType: .string)
            }
        }
        if sessions.count == 1, let identity = sessions.first?.source.identity {
            Button("Show Details") { showDetails() }
            Divider()
            if let path = identity.appPath ?? identity.executablePath, FileManager.default.fileExists(atPath: path) {
                Button("Show “\(identity.displayName)” in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: path)])
                }
            }
            Button("Show Only “\(identity.displayName)”") {
                store.searchText = identity.appBundleID ?? identity.processBundleID ?? identity.processName
            }
        }
    }

    private func copyText(for ids: Set<AudioSession.ID>) -> String {
        store.displayedSessions
            .filter { ids.contains($0.id) }
            .map(\.copyText)
            .joined(separator: "\n")
    }

    @ViewBuilder
    private var emptyState: some View {
        if !store.searchText.isEmpty {
            ContentUnavailableView.search(text: store.searchText)
        } else if let error = store.loadError {
            ContentUnavailableView("Can’t Read the History", systemImage: "exclamationmark.triangle", description: Text(error))
        } else if store.assembler.sessions.isEmpty {
            ContentUnavailableView {
                Label("No Sounds Recorded Yet", systemImage: "waveform")
            } description: {
                if service.isRecording {
                    Text("Whenever an app starts or stops playing sound, it will show up here.")
                } else {
                    Text("Turn on background recording to log which apps play sounds.")
                }
            } actions: {
                if !service.isEnabled, service.registration != .unavailable {
                    Button("Turn On Recording") { service.setEnabled(true) }
                }
            }
        } else {
            ContentUnavailableView("No Sounds on This Day", systemImage: "calendar")
        }
    }
}

// MARK: - Cells

private struct StartCell: View {
    let session: AudioSession
    let showsDate: Bool

    var body: some View {
        let approximate = session.flags.contains(.alreadyPlayingAtMonitorStart)
        let time = showsDate ? Formatting.dayAndTime(session.start) : Formatting.time(session.start)
        Text((approximate ? "≤ " : "") + time)
            .monospacedDigit()
            .help(approximate ? "Already playing when recording started, so it may have started earlier." : "")
    }
}

private struct EndCell: View {
    let session: AudioSession
    let isRecording: Bool

    var body: some View {
        switch session.status {
        case .ended:
            let end = session.end ?? session.start
            let cutShort = session.flags.contains(.monitorStopped)
            // Only repeat the date when the sound ran past midnight.
            let time = Calendar.current.isDate(end, inSameDayAs: session.start)
                ? Formatting.time(end) : Formatting.dayAndTime(end)
            Text((cutShort ? "≥ " : "") + time)
                .monospacedDigit()
                .help(cutShort ? "Recording stopped at this time; the sound may have continued." : "")
        case .open where isRecording:
            Label("Playing", systemImage: "speaker.wave.2.fill")
                .symbolEffect(.variableColor.iterative, options: .repeating)
                .foregroundStyle(.tint)
        case .open, .interrupted:
            Text("Unknown")
                .foregroundStyle(.secondary)
                .help("Recording stopped before this sound ended.")
        }
    }
}

private struct DurationCell: View {
    let session: AudioSession
    let isRecording: Bool

    var body: some View {
        if let duration = session.duration {
            Text(Formatting.duration(duration))
                .monospacedDigit()
        } else if session.status == .open, isRecording {
            Text(timerInterval: session.start ... Date.distantFuture, countsDown: false)
                .monospacedDigit()
                .foregroundStyle(.tint)
        } else {
            Text("—")
                .foregroundStyle(.secondary)
        }
    }
}

private struct ApplicationCell: View {
    let identity: ProcessIdentity

    var body: some View {
        HStack(spacing: 6) {
            SourceIcon(identity: identity)
            Text(identity.displayName)
        }
        .help(identity.appBundleID ?? identity.processBundleID ?? identity.executablePath ?? identity.processName)
    }
}
