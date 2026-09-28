import Foundation

/// Identifiers shared by the viewer app, the background agent and the on-disk log.
public enum AppConstants {
    /// Bundle identifier of the viewer app.
    public static let appBundleIdentifier = "com.matthewy.WhatMadeThatSound"

    /// launchd label of the background agent. Must match the `Label` key in the
    /// LaunchAgent plist embedded in the app bundle.
    public static let agentLabel = "com.matthewy.WhatMadeThatSound.Agent"

    /// File name of the LaunchAgent plist inside `Contents/Library/LaunchAgents`.
    public static let agentPlistName = agentLabel + ".plist"

    /// Name of the agent executable inside `Contents/MacOS`.
    public static let agentExecutableName = "WhatMadeThatSoundAgent"

    /// Darwin notification the agent posts after committing new records to the log.
    public static let logChangedNotification = "com.matthewy.WhatMadeThatSound.logChanged"

    /// Darwin notification the agent posts when it starts or stops monitoring.
    public static let agentStateChangedNotification = "com.matthewy.WhatMadeThatSound.agentStateChanged"

    /// Size of the ring buffer's data region: 200 MiB of the most recent events.
    public static let defaultLogCapacity: UInt64 = 200 * 1024 * 1024

    /// Unified logging subsystem used by every component.
    public static let loggingSubsystem = appBundleIdentifier
}
