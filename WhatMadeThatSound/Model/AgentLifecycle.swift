import Foundation
import os
import ServiceManagement
import WhatMadeThatSoundKit

/// Registering the agent so that it actually starts.
///
/// Without a Developer ID signature, Background Task Management (BTM) pins a
/// registered agent to the code-directory hash of the binary it saw when the
/// record was created. Unregistering only disables that record, so registering
/// an updated agent revives the old hash and launchd refuses to start it
/// ("launch constraint violation"). About ten seconds after such a refusal BTM
/// replaces the record with one for the binary now on disk, but launchd only
/// gets a runnable job for it once the registration is cycled again.
///
/// So: register, confirm the agent started, and if launchd refused it, wait for
/// BTM to refresh its record and cycle the registration once more. Each
/// registration can show the user a "background item added" notification, so
/// this deliberately stops after that one retry.
enum AgentLifecycle {
    enum Outcome: Equatable {
        case running
        case requiresApproval
        case failed(String)
    }

    private static let logger = Logger(subsystem: AppConstants.loggingSubsystem, category: "service")
    /// From a refused launch until BTM has replaced its stale record (observed: ~10 s).
    private static let staleRecordWindow: TimeInterval = 12
    private static let startTimeout: TimeInterval = 5

    /// Registers the agent and confirms it starts. Blocking; call off the main thread.
    static func enable(paths: AppPaths = .standard()) -> Outcome {
        let service = SMAppService.agent(plistName: AppConstants.agentPlistName)
        if let outcome = register(service) { return outcome }
        if waitForAgent(running: true, timeout: startTimeout, paths: paths) { return .running }
        return recoverFromRefusedLaunch(service, paths: paths)
    }

    /// Replaces an existing registration, e.g. after the app was updated.
    /// Blocking; call off the main thread.
    static func reregister(paths: AppPaths = .standard()) -> Outcome {
        let service = SMAppService.agent(plistName: AppConstants.agentPlistName)
        try? service.unregister()
        _ = waitForAgent(running: false, timeout: startTimeout, paths: paths)
        Thread.sleep(forTimeInterval: 1)
        if let outcome = register(service) { return outcome }
        if waitForAgent(running: true, timeout: startTimeout, paths: paths) { return .running }
        return recoverFromRefusedLaunch(service, paths: paths)
    }

    private static func recoverFromRefusedLaunch(_ service: SMAppService, paths: AppPaths) -> Outcome {
        logger.notice("launchd didn't start the agent; waiting for Background Task Management to refresh its record")
        Thread.sleep(forTimeInterval: staleRecordWindow - startTimeout)
        try? service.unregister()
        Thread.sleep(forTimeInterval: 2)
        if let outcome = register(service) { return outcome }
        if waitForAgent(running: true, timeout: startTimeout, paths: paths) { return .running }
        return .failed(String(localized: "The background recorder was registered but didn’t start. Try turning recording off and on again in a few seconds."))
    }

    /// Returns `nil` once registered, or the outcome if registering can't proceed.
    private static func register(_ service: SMAppService) -> Outcome? {
        do {
            try service.register()
        } catch let error as NSError where error.code == kSMErrorAlreadyRegistered {
            // Already registered: carry on and see whether it's running.
        } catch where service.status == .requiresApproval {
            AgentFingerprint.rememberRegistration()
            return .requiresApproval
        } catch {
            return .failed(error.localizedDescription)
        }
        AgentFingerprint.rememberRegistration()
        return service.status == .requiresApproval ? .requiresApproval : nil
    }

    /// Waits until an agent is (or isn't) holding the agent lock. Event-driven: the
    /// agent posts a Darwin notification whenever it starts or stops.
    static func waitForAgent(running: Bool, timeout: TimeInterval, paths: AppPaths) -> Bool {
        let isInState: @Sendable () -> Bool = { (AgentInstanceLock.currentOwner(at: paths.agentLockFile) != nil) == running }
        if isInState() { return true }
        let semaphore = DispatchSemaphore(value: 0)
        let observation = DarwinNotification.Observation(
            name: AppConstants.agentStateChangedNotification,
            queue: DispatchQueue(label: "com.matthewy.WhatMadeThatSound.agent-wait")
        ) {
            if isInState() { semaphore.signal() }
        }
        defer { observation?.cancel() }
        // Re-check after subscribing, in case the change happened in between.
        if isInState() { return true }
        return semaphore.wait(timeout: .now() + timeout) == .success || isInState()
    }
}
