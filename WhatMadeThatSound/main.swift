import Foundation

// Scripts (e.g. `make install` / `make uninstall`) can manage the background agent
// without opening a window:
//   "What Made That Sound" --agent-status | --register-agent | --unregister-agent
if let exitCode = AgentRegistrationCommand.run(arguments: CommandLine.arguments) {
    exit(exitCode)
}
WhatMadeThatSoundApp.main()
