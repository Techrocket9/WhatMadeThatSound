import CoreAudio
import Foundation
import os

/// Receives events from the monitor. Called on the monitor's private queue.
public protocol AudioEventSink: AnyObject, Sendable {
    func record(_ event: AudioEvent)
}

/// Watches every Core Audio client process and reports when each one starts and
/// stops producing audio output.
///
/// Entirely event-driven: it registers HAL property listeners on the system
/// object (process list, default device, device list, server restarts) and on
/// each client process object (`IsRunningOutput`, `IsRunning`, output `Devices`),
/// and re-evaluates a process only when one of those properties changes.
///
/// Core Audio publishes a process's output device list a moment after its I/O
/// starts, so the start event is recorded after a short settle delay (but
/// stamped with the moment the I/O started). Sessions that end within that
/// delay are still recorded in full.
public final class AudioActivityMonitor: @unchecked Sendable {
    public struct Options: Sendable {
        /// How long to wait for the device list before recording a start.
        public var startSettleDelay: DispatchTimeInterval = .milliseconds(100)
        /// Stored in the `monitorStarted` event, e.g. the agent version.
        public var note: String?
        /// Processes to ignore in addition to the monitor's own process.
        public var ignoredPIDs: Set<pid_t> = []

        public init(note: String? = nil) {
            self.note = note
        }
    }

    private final class TrackedProcess {
        let objectID: AudioObjectID
        let identity: ProcessIdentity
        var listeners: [PropertyListener] = []
        var session: ActiveSession?

        init(objectID: AudioObjectID, identity: ProcessIdentity) {
            self.objectID = objectID
            self.identity = identity
        }

        func invalidateListeners() {
            listeners.forEach { $0.invalidate() }
            listeners.removeAll()
        }
    }

    private struct ActiveSession {
        let id: UInt64
        let start: Date
        var flags: AudioEventFlags
        var devices: [OutputDevice] = []
        var startRecorded = false

        /// Adds devices not seen before in this session; returns whether any were new.
        mutating func merge(_ newDevices: [OutputDevice]) -> Bool {
            var added = false
            for device in newDevices where !devices.contains(where: { $0.uid == device.uid }) {
                devices.append(device)
                added = true
            }
            return added
        }
    }

    private let sink: any AudioEventSink
    private let options: Options
    private let queue = DispatchQueue(label: "com.matthewy.WhatMadeThatSound.monitor", qos: .userInitiated)
    private let resolver = ProcessIdentityResolver()
    private let logger = Logger(subsystem: AppConstants.loggingSubsystem, category: "monitor")
    private let ignoredPIDs: Set<pid_t>

    // State below is confined to `queue`.
    private var isRunning = false
    private var systemListeners: [PropertyListener] = []
    private var processes: [AudioObjectID: TrackedProcess] = [:]
    private var ignoredObjects: Set<AudioObjectID> = []
    private var deviceCache: [AudioObjectID: OutputDevice] = [:]
    private var defaultOutput: OutputDevice?

    public init(sink: any AudioEventSink, options: Options = Options()) {
        self.sink = sink
        self.options = options
        self.ignoredPIDs = options.ignoredPIDs.union([getpid()])
    }

    /// Records `monitorStarted`, the processes already playing, and then every change.
    public func start() {
        queue.sync { startOnQueue() }
    }

    /// Ends all open sessions (flagged `monitorStopped`) and records `monitorStopped`.
    public func stop() {
        queue.sync { stopOnQueue() }
    }

    /// Number of processes currently producing output (for diagnostics and tests).
    public var activeSessionCount: Int {
        queue.sync { processes.values.count { $0.session != nil } }
    }

    // MARK: Lifecycle

    private func startOnQueue() {
        guard !isRunning else { return }
        isRunning = true
        updateDefaultOutput(recordChange: false)
        sink.record(AudioEvent(
            kind: .monitorStarted,
            timestamp: Date(),
            devices: defaultOutput.map { [$0] } ?? [],
            note: options.note
        ))
        installSystemListeners()
        synchronizeProcesses(initial: true)
        logger.info("Monitoring started; tracking \(self.processes.count) audio client processes")
    }

    private func stopOnQueue() {
        guard isRunning else { return }
        let now = Date()
        for process in processes.values {
            endSession(of: process, at: now, flags: .monitorStopped)
            process.invalidateListeners()
        }
        processes.removeAll()
        ignoredObjects.removeAll()
        systemListeners.forEach { $0.invalidate() }
        systemListeners.removeAll()
        sink.record(AudioEvent(kind: .monitorStopped, timestamp: now))
        isRunning = false
        logger.info("Monitoring stopped")
    }

    private func installSystemListeners() {
        let system = HAL.systemObject
        let selectors: [(AudioObjectPropertySelector, @Sendable (AudioActivityMonitor) -> Void)] = [
            (kAudioHardwarePropertyProcessObjectList, { $0.synchronizeProcesses(initial: false) }),
            (kAudioHardwarePropertyDefaultOutputDevice, { $0.updateDefaultOutput(recordChange: true) }),
            (kAudioHardwarePropertyDevices, { $0.deviceListChanged() }),
            (kAudioHardwarePropertyServiceRestarted, { $0.audioServerRestarted() }),
        ]
        systemListeners = selectors.compactMap { selector, action in
            let listener = PropertyListener(objectID: system, selector: selector, queue: queue) { [weak self] in
                guard let self, self.isRunning else { return }
                action(self)
            }
            if listener == nil {
                logger.error("Could not listen to system property \(fourCC(selector), privacy: .public)")
            }
            return listener
        }
    }

    // MARK: Processes

    private func synchronizeProcesses(initial: Bool) {
        guard let current = HAL.objectIDs(HAL.systemObject, kAudioHardwarePropertyProcessObjectList) else {
            logger.error("Could not read the audio process list")
            return
        }
        let now = Date()
        let currentSet = Set(current)

        for (objectID, process) in processes where !currentSet.contains(objectID) {
            endSession(of: process, at: now, flags: .processExited)
            process.invalidateListeners()
            processes[objectID] = nil
        }
        ignoredObjects.formIntersection(currentSet)

        for objectID in current where processes[objectID] == nil && !ignoredObjects.contains(objectID) {
            guard let pid: pid_t = HAL.scalar(objectID, kAudioProcessPropertyPID), pid > 0,
                  !ignoredPIDs.contains(pid)
            else {
                ignoredObjects.insert(objectID)
                continue
            }
            let identity = resolver.resolve(pid: pid, coreAudioBundleID: HAL.string(objectID, kAudioProcessPropertyBundleID))
            let process = TrackedProcess(objectID: objectID, identity: identity)
            let properties: [(AudioObjectPropertySelector, AudioObjectPropertyScope)] = [
                (kAudioProcessPropertyIsRunningOutput, kAudioObjectPropertyScopeGlobal),
                // `IsRunningOutput` doesn't always notify on its own; these reliably do.
                (kAudioProcessPropertyIsRunning, kAudioObjectPropertyScopeGlobal),
                (kAudioProcessPropertyDevices, kAudioObjectPropertyScopeOutput),
            ]
            process.listeners = properties.compactMap { selector, scope in
                PropertyListener(objectID: objectID, selector: selector, scope: scope, queue: queue) { [weak self] in
                    self?.evaluate(objectID)
                }
            }
            processes[objectID] = process
            evaluate(process, at: now, initial: initial)
        }
    }

    private func evaluate(_ objectID: AudioObjectID) {
        guard isRunning, let process = processes[objectID] else { return }
        evaluate(process, at: Date(), initial: false)
    }

    private func evaluate(_ process: TrackedProcess, at now: Date, initial: Bool) {
        let isRunningOutput: UInt32? = HAL.scalar(process.objectID, kAudioProcessPropertyIsRunningOutput)
        guard isRunningOutput ?? 0 != 0 else {
            if process.session != nil {
                endSession(of: process, at: now, flags: [])
            }
            return
        }

        let devices = currentOutputDevices(of: process.objectID)
        if var session = process.session {
            let added = session.merge(devices)
            process.session = session
            if added, session.startRecorded {
                record(.outputDevicesChanged, for: process, session: session, at: now)
            }
            return
        }

        var session = ActiveSession(
            id: UInt64.random(in: 1 ... UInt64.max),
            start: now,
            flags: initial ? .alreadyPlayingAtMonitorStart : []
        )
        _ = session.merge(devices)
        process.session = session
        if initial {
            recordStart(of: process)
        } else {
            let objectID = process.objectID
            let sessionID = session.id
            queue.asyncAfter(deadline: .now() + options.startSettleDelay) { [weak self] in
                self?.settle(objectID, sessionID: sessionID)
            }
        }
    }

    private func settle(_ objectID: AudioObjectID, sessionID: UInt64) {
        guard isRunning, let process = processes[objectID], let session = process.session,
              session.id == sessionID, !session.startRecorded
        else { return }
        _ = process.session?.merge(currentOutputDevices(of: objectID))
        recordStart(of: process)
    }

    private func recordStart(of process: TrackedProcess) {
        guard var session = process.session, !session.startRecorded else { return }
        session.startRecorded = true
        process.session = session
        record(.outputStarted, for: process, session: session, at: session.start)
    }

    private func endSession(of process: TrackedProcess, at now: Date, flags: AudioEventFlags) {
        guard process.session != nil else { return }
        recordStart(of: process) // No-op unless the session ended before settling.
        guard var session = process.session else { return }
        session.flags.formUnion(flags)
        record(.outputStopped, for: process, session: session, at: now)
        process.session = nil
    }

    private func record(_ kind: AudioEventKind, for process: TrackedProcess, session: ActiveSession, at timestamp: Date) {
        sink.record(AudioEvent(
            kind: kind,
            timestamp: timestamp,
            sessionID: session.id,
            sessionStart: session.start,
            flags: session.flags,
            process: process.identity,
            devices: session.devices
        ))
    }

    // MARK: Devices

    private func currentOutputDevices(of processObject: AudioObjectID) -> [OutputDevice] {
        let ids = HAL.objectIDs(processObject, kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeOutput) ?? []
        return ids.compactMap(device)
    }

    private func device(_ id: AudioObjectID) -> OutputDevice? {
        if let cached = deviceCache[id] { return cached }
        guard let uid = HAL.string(id, kAudioDevicePropertyDeviceUID) else { return nil }
        let device = OutputDevice(name: HAL.string(id, kAudioObjectPropertyName) ?? uid, uid: uid)
        deviceCache[id] = device
        return device
    }

    private func deviceListChanged() {
        let present = Set(HAL.objectIDs(HAL.systemObject, kAudioHardwarePropertyDevices) ?? [])
        deviceCache = deviceCache.filter { present.contains($0.key) }
    }

    private func updateDefaultOutput(recordChange: Bool) {
        guard let id = HAL.objectID(HAL.systemObject, kAudioHardwarePropertyDefaultOutputDevice),
              let device = device(id), device != defaultOutput
        else { return }
        let hadPrevious = defaultOutput != nil
        defaultOutput = device
        if recordChange, hadPrevious {
            sink.record(AudioEvent(kind: .defaultOutputDeviceChanged, timestamp: Date(), devices: [device]))
        }
    }

    private func audioServerRestarted() {
        logger.notice("Audio server restarted; resynchronizing")
        let now = Date()
        for process in processes.values {
            endSession(of: process, at: now, flags: .audioServerRestarted)
            process.invalidateListeners()
        }
        processes.removeAll()
        ignoredObjects.removeAll()
        deviceCache.removeAll()
        updateDefaultOutput(recordChange: true)
        synchronizeProcesses(initial: false)
    }
}

private func fourCC(_ value: UInt32) -> String {
    let bytes = [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: value >> $0) }
    return String(decoding: bytes, as: UTF8.self)
}
