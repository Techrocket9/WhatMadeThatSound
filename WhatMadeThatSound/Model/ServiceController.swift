import AppKit
import Foundation
import Observation
import os
import ServiceManagement
import WhatMadeThatSoundKit

/// Turns the background recording agent on and off, and reports whether it's running.
///
/// The agent is registered with `SMAppService` as a LaunchAgent embedded in the
/// app bundle, so launchd starts it at every login and keeps it alive until the
/// user turns it off — whether or not this app is open.
@MainActor
@Observable
final class ServiceController {
    enum Registration: Equatable {
        /// Registered and allowed to run.
        case enabled
        /// Registered, but the user must allow it in System Settings → Login Items.
        case requiresApproval
        /// Not registered: nothing is being recorded.
        case disabled
        /// This copy of the app can't host the agent (e.g. it wasn't built as a full app bundle).
        case unavailable
    }

    private(set) var registration: Registration = .disabled
    /// The agent process currently recording, if any.
    private(set) var runningAgent: AgentInstanceLock.Owner?
    private(set) var lastError: String?
    private(set) var isChanging = false

    /// Whether the user has asked for background recording (the switch position).
    var isEnabled: Bool { registration == .enabled || registration == .requiresApproval }
    var isRecording: Bool { runningAgent != nil }

    /// True if the recording agent is from a different copy of the app than this one.
    var runningAgentIsFromAnotherCopy: Bool {
        guard let path = runningAgent?.executablePath, !path.isEmpty else { return false }
        let mine = Bundle.main.bundleURL.appending(path: "Contents/MacOS/\(AppConstants.agentExecutableName)")
        return URL(filePath: path).resolvingSymlinksInPath().path != mine.resolvingSymlinksInPath().path
    }

    private let service = SMAppService.agent(plistName: AppConstants.agentPlistName)
    private let paths: AppPaths
    private var agentObservation: DarwinNotification.Observation?
    private var activationObserver: NSObjectProtocol?
    private let logger = Logger(subsystem: AppConstants.loggingSubsystem, category: "service")
    private static let didAutoRegisterKey = "didRegisterAgentOnFirstLaunch"

    init(paths: AppPaths = .standard()) {
        self.paths = paths
    }

    func start() {
        guard agentObservation == nil else { return }
        // The agent announces when it starts and stops; the user may also change
        // Login Items in System Settings, which we notice when the app is reactivated.
        agentObservation = DarwinNotification.Observation(name: AppConstants.agentStateChangedNotification, queue: .main) { [weak self] in
            MainActor.assumeIsolated { self?.refresh() }
        }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
        registerOnFirstLaunchIfNeeded()
    }

    func refresh() {
        switch service.status {
        case .enabled: registration = .enabled
        case .requiresApproval: registration = .requiresApproval
        case .notRegistered: registration = .disabled
        case .notFound: registration = .unavailable
        @unknown default: registration = .disabled
        }
        runningAgent = AgentInstanceLock.currentOwner(at: paths.agentLockFile)
    }

    func setEnabled(_ enabled: Bool) {
        guard !isChanging else { return }
        isChanging = true
        lastError = nil
        Task {
            do {
                if enabled {
                    try service.register()
                } else {
                    try await service.unregister()
                }
                logger.notice("Background agent \(enabled ? "registered" : "unregistered", privacy: .public)")
            } catch {
                logger.error("Could not \(enabled ? "register" : "unregister", privacy: .public) agent: \(error, privacy: .public)")
                // Registering can "fail" only because approval is pending; the status says so.
                if !(enabled && service.status == .requiresApproval) {
                    lastError = error.localizedDescription
                }
            }
            isChanging = false
            refresh()
        }
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// Recording is the point of the app, so turn it on the first time the app runs.
    /// After that, the switch in Settings is the only thing that changes it.
    private func registerOnFirstLaunchIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.didAutoRegisterKey) else { return }
        guard registration != .unavailable else { return }
        defaults.set(true, forKey: Self.didAutoRegisterKey)
        if registration == .disabled {
            setEnabled(true)
        }
    }
}
