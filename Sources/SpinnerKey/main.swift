import Foundation
import SpinnerKeyCore

// One binary for both modes, so the Keychain item SpinnerKey creates is readable by the
// scheduled runs without extra prompts:
//   SpinnerKey            → configuration window
//   SpinnerKey rotate     → headless run (launchd)
if let command = CommandLine.arguments.dropFirst().first, Headless.commands.contains(command) {
    exit(Headless.run(command))
}

SpinnerKeyApp.main()
