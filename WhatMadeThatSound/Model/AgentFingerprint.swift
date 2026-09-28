import Foundation
import Security
import WhatMadeThatSoundKit

/// Identifies the exact agent binary embedded in this copy of the app.
///
/// When the app isn't signed with a Developer ID, launchd pins a registered
/// agent to the code-directory hash of the binary it saw at registration. A new
/// build (or another copy of the app taking over the registration) then fails
/// to launch with a launch-constraint violation until the agent is registered
/// again — so the app remembers what it registered and re-registers on change.
enum AgentFingerprint {
    private static let defaultsKey = "registeredAgentFingerprint"

    /// "<bundle path>|<cdhash>" of this copy's agent, or `nil` if it can't be read.
    static var current: String? {
        let agent = Bundle.main.bundleURL.appending(path: "Contents/MacOS/\(AppConstants.agentExecutableName)")
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(agent as CFURL, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, [], &information) == errSecSuccess,
              let information = information as? [String: Any],
              let cdhash = information[kSecCodeInfoUnique as String] as? Data
        else { return nil }
        let hash = cdhash.map { String(format: "%02x", $0) }.joined()
        return "\(Bundle.main.bundleURL.resolvingSymlinksInPath().path)|\(hash)"
    }

    static var registered: String? {
        UserDefaults.standard.string(forKey: defaultsKey)
    }

    static func rememberRegistration() {
        UserDefaults.standard.set(current, forKey: defaultsKey)
    }

    static func forgetRegistration() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }
}
