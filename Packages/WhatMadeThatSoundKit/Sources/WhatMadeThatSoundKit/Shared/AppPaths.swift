import Foundation

/// Locations of the files shared between the agent and the viewer app.
public struct AppPaths: Sendable, Hashable {
    /// Environment variable that relocates all data (used for testing and development).
    public static let dataDirectoryEnvironmentKey = "WMTS_DATA_DIR"

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// The ring buffer holding the event log.
    public var logFile: URL { directory.appending(path: "events.ringlog", directoryHint: .notDirectory) }

    /// Lock file held by the running agent; also records which agent holds it.
    public var agentLockFile: URL { directory.appending(path: "agent.lock", directoryHint: .notDirectory) }

    /// `~/Library/Application Support/WhatMadeThatSound`, unless overridden by `WMTS_DATA_DIR`.
    public static func standard(environment: [String: String] = ProcessInfo.processInfo.environment) -> AppPaths {
        if let override = environment[dataDirectoryEnvironmentKey], !override.isEmpty {
            return AppPaths(directory: URL(filePath: override, directoryHint: .isDirectory))
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return AppPaths(directory: base.appending(path: "WhatMadeThatSound", directoryHint: .isDirectory))
    }

    public func createDirectoryIfNeeded() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
}
