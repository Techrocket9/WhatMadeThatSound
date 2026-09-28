import Foundation

/// A process that made sound. All sessions from the same process share one
/// instance, which keeps large histories compact and makes search cheap.
public final class SoundSource: Hashable, Sendable {
    public let identity: ProcessIdentity
    /// Lowercased text that search matches against.
    public let searchText: String

    init(identity: ProcessIdentity) {
        self.identity = identity
        searchText = [
            identity.appName, identity.appBundleID, identity.processName, identity.processBundleID,
            identity.executablePath, String(identity.pid),
        ]
        .compactMap { $0 }
        .joined(separator: "\n")
        .lowercased()
    }

    public var displayName: String { identity.displayName }

    public static func == (lhs: SoundSource, rhs: SoundSource) -> Bool { lhs === rhs }
    public func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}

/// The output devices a session played to, shared between sessions like `SoundSource`.
public final class OutputDeviceList: Hashable, Sendable {
    public let devices: [OutputDevice]
    public let displayName: String
    public let searchText: String

    init(devices: [OutputDevice]) {
        self.devices = devices
        displayName = devices.map(\.name).joined(separator: ", ")
        searchText = devices.map { "\($0.name)\n\($0.uid)" }.joined(separator: "\n").lowercased()
    }

    public static func == (lhs: OutputDeviceList, rhs: OutputDeviceList) -> Bool { lhs === rhs }
    public func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}

/// A span of time during which one process produced audio output.
public struct AudioSession: Identifiable, Hashable, Sendable {
    public enum Status: Hashable, Sendable {
        /// No end has been recorded yet: still playing, as far as the log knows.
        case open
        /// Ended at `end`.
        case ended
        /// Monitoring restarted before an end was recorded (e.g. the agent was
        /// killed), so when it ended is unknown.
        case interrupted
    }

    public let id: UInt64
    public let source: SoundSource
    public var start: Date
    public var end: Date?
    public var status: Status
    public var flags: AudioEventFlags
    public var devices: OutputDeviceList

    public var duration: TimeInterval? { end.map { $0.timeIntervalSince(start) } }
}

/// Turns the flat event log into playback sessions (start + stop pairs).
///
/// Sessions are kept sorted by start time. Feed it events in log order, either
/// all at once or incrementally as the log grows.
public struct SessionAssembler: Sendable {
    public private(set) var sessions: [AudioSession] = []
    public private(set) var eventCount = 0
    /// Whether the most recent monitor lifecycle event was a start.
    public private(set) var monitorRunning = false
    public private(set) var lastMonitorStart: Date?
    public private(set) var lastMonitorStop: Date?
    public private(set) var currentDefaultOutput: OutputDevice?

    private var indexByID: [UInt64: Int] = [:]
    private var openSessionIDs: Set<UInt64> = []
    private var sources: [ProcessIdentity: SoundSource] = [:]
    private var deviceLists: [[OutputDevice]: OutputDeviceList] = [:]

    public init() {}

    /// Every distinct process in the log.
    public var allSources: some Collection<SoundSource> { sources.values }

    public func session(withID id: UInt64) -> AudioSession? {
        indexByID[id].map { sessions[$0] }
    }

    public mutating func apply(contentsOf events: some Sequence<AudioEvent>) {
        for event in events {
            apply(event)
        }
    }

    public mutating func apply(_ event: AudioEvent) {
        eventCount += 1
        switch event.kind {
        case .outputStarted:
            guard event.sessionID != 0 else { return }
            if let index = indexByID[event.sessionID] {
                sessions[index].flags.formUnion(event.flags)
                sessions[index].devices = deviceList(merging: sessions[index].devices.devices, event.devices)
            } else if let process = event.process {
                insert(newSession(for: event, process: process, status: .open))
                openSessionIDs.insert(event.sessionID)
            }

        case .outputDevicesChanged:
            guard event.sessionID != 0 else { return }
            if let index = indexByID[event.sessionID] {
                sessions[index].devices = deviceList(merging: sessions[index].devices.devices, event.devices)
            } else if let process = event.process {
                // The start was evicted from the log; the event still says when it began.
                insert(newSession(for: event, process: process, status: .open))
                openSessionIDs.insert(event.sessionID)
            }

        case .outputStopped:
            guard event.sessionID != 0 else { return }
            if let index = indexByID[event.sessionID] {
                sessions[index].end = event.timestamp
                sessions[index].status = .ended
                sessions[index].flags.formUnion(event.flags)
                sessions[index].devices = deviceList(merging: sessions[index].devices.devices, event.devices)
                openSessionIDs.remove(event.sessionID)
            } else if let process = event.process {
                var session = newSession(for: event, process: process, status: .ended)
                session.end = event.timestamp
                insert(session)
            }

        case .monitorStarted:
            // Anything still open was never closed: the previous agent died.
            interruptOpenSessions()
            monitorRunning = true
            lastMonitorStart = event.timestamp
            if let device = event.devices.first {
                currentDefaultOutput = device
            }

        case .monitorStopped:
            interruptOpenSessions()
            monitorRunning = false
            lastMonitorStop = event.timestamp

        case .defaultOutputDeviceChanged:
            if let device = event.devices.first {
                currentDefaultOutput = device
            }
        }
    }

    private mutating func newSession(for event: AudioEvent, process: ProcessIdentity, status: AudioSession.Status) -> AudioSession {
        AudioSession(
            id: event.sessionID,
            source: source(for: process),
            start: event.sessionStart ?? event.timestamp,
            end: nil,
            status: status,
            flags: event.flags,
            devices: deviceList(merging: [], event.devices)
        )
    }

    private mutating func interruptOpenSessions() {
        for id in openSessionIDs {
            if let index = indexByID[id] {
                sessions[index].status = .interrupted
            }
        }
        openSessionIDs.removeAll()
    }

    private mutating func source(for identity: ProcessIdentity) -> SoundSource {
        if let existing = sources[identity] { return existing }
        let source = SoundSource(identity: identity)
        sources[identity] = source
        return source
    }

    private mutating func deviceList(merging existing: [OutputDevice], _ new: [OutputDevice]) -> OutputDeviceList {
        var merged = existing
        for device in new where !merged.contains(where: { $0.uid == device.uid }) {
            merged.append(device)
        }
        if let list = deviceLists[merged] { return list }
        let list = OutputDeviceList(devices: merged)
        deviceLists[merged] = list
        return list
    }

    /// Inserts keeping `sessions` sorted by (start, id). New sessions almost always
    /// go at the end; out-of-order ones come from starts recorded slightly late.
    private mutating func insert(_ session: AudioSession) {
        let key = (session.start, session.id)
        var low = sessions.startIndex
        var high = sessions.endIndex
        if let last = sessions.last, (last.start, last.id) < key {
            low = high
        }
        while low < high {
            let middle = (low + high) / 2
            if (sessions[middle].start, sessions[middle].id) < key {
                low = middle + 1
            } else {
                high = middle
            }
        }
        sessions.insert(session, at: low)
        for index in low ..< sessions.endIndex {
            indexByID[sessions[index].id] = index
        }
    }
}
