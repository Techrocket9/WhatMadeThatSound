import Foundation

/// What happened. Raw values are part of the on-disk format; never renumber them.
public enum AudioEventKind: UInt8, Sendable, CaseIterable {
    /// A process started producing audio output. Begins a session.
    case outputStarted = 1
    /// A process stopped producing audio output. Ends a session.
    case outputStopped = 2
    /// The output devices used by an ongoing session changed.
    case outputDevicesChanged = 3
    /// The agent started monitoring.
    case monitorStarted = 4
    /// The agent stopped monitoring (service disabled, logout, shutdown).
    case monitorStopped = 5
    /// The system default output device changed.
    case defaultOutputDeviceChanged = 6
}

/// Extra facts about a session boundary. Raw values are part of the on-disk format.
public struct AudioEventFlags: OptionSet, Sendable, Hashable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    /// The process was already playing when monitoring began, so the recorded start
    /// time is only an upper bound on when the sound really started.
    public static let alreadyPlayingAtMonitorStart = AudioEventFlags(rawValue: 1 << 0)
    /// The session ended because the process exited or disconnected from the audio server.
    public static let processExited = AudioEventFlags(rawValue: 1 << 1)
    /// The session was closed because monitoring stopped; the real end may be later.
    public static let monitorStopped = AudioEventFlags(rawValue: 1 << 2)
    /// The session was closed because the audio server (coreaudiod) restarted.
    public static let audioServerRestarted = AudioEventFlags(rawValue: 1 << 3)
}

/// An audio output device, identified the way Core Audio names it.
public struct OutputDevice: Hashable, Sendable {
    public var name: String
    public var uid: String

    public init(name: String, uid: String) {
        self.name = name
        self.uid = uid
    }
}

/// The process that produced audio, and the application it belongs to.
///
/// Audio is often rendered by helper processes (`Google Chrome Helper`,
/// `com.apple.WebKit.GPU`, …). `app*` fields describe the application that is
/// responsible for the helper, which is usually what a person wants to see.
public struct ProcessIdentity: Hashable, Sendable {
    public var pid: Int32
    /// Executable name of the process that is doing the audio I/O.
    public var processName: String
    public var processBundleID: String?
    public var executablePath: String?
    /// PID of the process macOS holds responsible for this one, when different.
    public var responsiblePID: Int32?
    /// Display name of the owning application bundle, when there is one.
    public var appName: String?
    public var appBundleID: String?
    /// Path of the owning application bundle (used for its icon).
    public var appPath: String?

    public init(
        pid: Int32,
        processName: String,
        processBundleID: String? = nil,
        executablePath: String? = nil,
        responsiblePID: Int32? = nil,
        appName: String? = nil,
        appBundleID: String? = nil,
        appPath: String? = nil
    ) {
        self.pid = pid
        self.processName = processName
        self.processBundleID = processBundleID
        self.executablePath = executablePath
        self.responsiblePID = responsiblePID
        self.appName = appName
        self.appBundleID = appBundleID
        self.appPath = appPath
    }

    /// The best human-readable name: the owning app if known, otherwise the process.
    public var displayName: String { appName ?? processName }
}

/// One entry in the event log.
public struct AudioEvent: Hashable, Sendable {
    public var kind: AudioEventKind
    public var timestamp: Date
    /// Identifies the playback session for `output*` events; 0 otherwise.
    public var sessionID: UInt64
    /// When the session started. Written on every session event so a session can be
    /// reconstructed even after its start record was evicted from the ring buffer.
    public var sessionStart: Date?
    public var flags: AudioEventFlags
    public var process: ProcessIdentity?
    public var devices: [OutputDevice]
    /// Free-form detail, e.g. the agent version on `monitorStarted`.
    public var note: String?

    public init(
        kind: AudioEventKind,
        timestamp: Date,
        sessionID: UInt64 = 0,
        sessionStart: Date? = nil,
        flags: AudioEventFlags = [],
        process: ProcessIdentity? = nil,
        devices: [OutputDevice] = [],
        note: String? = nil
    ) {
        self.kind = kind
        self.timestamp = timestamp
        self.sessionID = sessionID
        self.sessionStart = sessionStart
        self.flags = flags
        self.process = process
        self.devices = devices
        self.note = note
    }
}
