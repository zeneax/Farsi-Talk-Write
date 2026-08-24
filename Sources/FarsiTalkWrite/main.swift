import Foundation
import AppKit

// CLI subcommands short-circuit before any UI is created.
if CLI.run(CommandLine.arguments) {
    exit(0)
}

// Menu bar agent: no Dock icon, no main window.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
