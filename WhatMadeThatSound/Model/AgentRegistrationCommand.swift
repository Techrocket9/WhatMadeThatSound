import Foundation
import ServiceManagement
import WhatMadeThatSoundKit

/// Command-line control of the background agent's registration.
enum AgentRegistrationCommand {
    /// Handles a registration flag and returns an exit code, or returns `nil`
    /// if the arguments don't ask for one (normal app launch).
    static func run(arguments: [String]) -> Int32? {
        let service = SMAppService.agent(plistName: AppConstants.agentPlistName)
        switch arguments.dropFirst().first {
        case "--agent-status":
            print(describe(service.status))
            return 0

        case "--register-agent":
            // Always from scratch, so launchd picks up this copy's agent binary.
            let outcome = AgentLifecycle.reregister()
            UserDefaults.standard.set(true, forKey: ServiceController.didAutoRegisterKey)
            if case let .failed(message) = outcome {
                printError("could not register the agent: \(message)")
                return 1
            }
            print(describe(service.status))
            return 0

        case "--unregister-agent":
            do {
                try service.unregister()
            } catch where service.status != .enabled && service.status != .requiresApproval {
                // Wasn't registered in the first place.
            } catch {
                printError("could not unregister the agent: \(error.localizedDescription)")
                return 1
            }
            // An explicit "off" should stick: don't re-enable on the next launch.
            AgentFingerprint.forgetRegistration()
            UserDefaults.standard.set(true, forKey: ServiceController.didAutoRegisterKey)
            print(describe(service.status))
            return 0

        default:
            return nil
        }
    }

    private static func describe(_ status: SMAppService.Status) -> String {
        switch status {
        case .enabled: "enabled"
        case .requiresApproval: "requires approval (System Settings › General › Login Items)"
        case .notRegistered, .notFound: "not registered"
        @unknown default: "unknown (\(status.rawValue))"
        }
    }

    private static func printError(_ message: String) {
        FileHandle.standardError.write(Data("What Made That Sound: \(message)\n".utf8))
    }
}
