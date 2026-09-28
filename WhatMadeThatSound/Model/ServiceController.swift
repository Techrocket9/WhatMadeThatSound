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
    nonisolated static let didAutoRegisterKey = "didRegisterAgentOnFirstLaunch"

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
        #if DEBUG
        // A development build (e.g. run from Xcode) is a second copy of the app;
        // registering from it would take the agent over from the installed copy.
        // Its Settings switch still registers explicitly.
        #else
        if !registerOnFirstLaunchIfNeeded() {
            repairRegistrationIfNeeded()
        }
        #endif
    }

    func refresh() {
        switch service.status {
        case .enabled: registration = .enabled
        case .requiresApproval: registration = .requiresApproval
        // `.notFound` is also what an agent that was never registered reports, so
        // only call it unavailable if the bundle really lacks the agent.
        case .notRegistered, .notFound: registration = Self.bundleContainsAgent ? .disabled : .unavailable
        @unknown default: registration = .disabled
        }
        runningAgent = AgentInstanceLock.currentOwner(at: paths.agentLockFile)
    }

    func setEnabled(_ enabled: Bool) {
        guard !isChanging else { return }
        isChanging = true
        lastError = nil
        let paths = self.paths
        Task {
            if enabled {
                let outcome = await Task.detached { AgentLifecycle.enable(paths: paths) }.value
                report(outcome)
            } else {
                do {
                    try await service.unregister()
                    AgentFingerprint.forgetRegistration()
                    logger.notice("Background agent unregistered")
                } catch {
                    logger.error("Could not unregister agent: \(error, privacy: .public)")
                    lastError = error.localizedDescription
                }
            }
            isChanging = false
            refresh()
        }
    }

    private func report(_ outcome: AgentLifecycle.Outcome) {
        switch outcome {
        case .running:
            logger.notice("Background agent registered and running")
        case .requiresApproval:
            logger.notice("Background agent registered; waiting for approval")
        case let .failed(message):
            logger.error("Could not start background agent: \(message, privacy: .public)")
            lastError = message
        }
    }

    /// Whether this copy of the app carries the agent and its LaunchAgent plist
    /// (it doesn't when run as a bare executable, e.g. from `swift run`).
    private static var bundleContainsAgent: Bool {
        let contents = Bundle.main.bundleURL.appending(path: "Contents")
        let files = [
            contents.appending(path: "Library/LaunchAgents/\(AppConstants.agentPlistName)"),
            contents.appending(path: "MacOS/\(AppConstants.agentExecutableName)"),
        ]
        return files.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// Recording is the point of the app, so turn it on the first time the app runs.
    /// After that, the switch in Settings is the only thing that changes it.
    /// Returns whether it registered.
    private func registerOnFirstLaunchIfNeeded() -> Bool {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.didAutoRegisterKey) else { return false }
        guard registration != .unavailable else { return false }
        // With WMTS_DATA_DIR set (development), the launchd agent would record
        // somewhere else entirely, so don't register it behind the developer's back.
        guard paths == .standard(environment: [:]) else { return false }
        defaults.set(true, forKey: Self.didAutoRegisterKey)
        guard registration == .disabled else { return false }
        setEnabled(true)
        return true
    }

    /// Keeps an enabled agent launchable after the app is updated or another copy
    /// of it took over the registration (see `AgentFingerprint`).
    private func repairRegistrationIfNeeded() {
        guard registration == .enabled || registration == .requiresApproval,
              paths == .standard(environment: [:])
        else { return }
        if AgentFingerprint.current != AgentFingerprint.registered {
            logger.notice("This copy's agent differs from the registered one; registering again")
            reregister()
            return
        }
        // Registered and unchanged but not running: give launchd a moment (it may be
        // starting it right now), then register again once.
        guard registration == .enabled, runningAgent == nil else { return }
        Task {
            try? await Task.sleep(for: .seconds(3))
            refresh()
            guard registration == .enabled, runningAgent == nil else { return }
            logger.notice("Agent is registered but not running; registering again")
            reregister()
        }
    }

    private func reregister() {
        guard !isChanging else { return }
        isChanging = true
        let paths = self.paths
        Task {
            let outcome = await Task.detached { AgentLifecycle.reregister(paths: paths) }.value
            report(outcome)
            isChanging = false
            refresh()
        }
    }
}
