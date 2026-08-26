//
//  main.swift
//  FarsiTalkWrite — Farsi push-to-talk dictation for macOS
//
//  Copyright (C) 2026  Zeneax Lab by Shahram Mazar
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program.  If not, see <https://www.gnu.org/licenses/>.
//

import Foundation
import AppKit

// CLI subcommands short-circuit before any UI is created.
if CLI.run(CommandLine.arguments) {
    exit(0)
}

// Menu bar agent: no Dock icon, no main window.
//
// Top-level code is nonisolated, but AppDelegate is @MainActor — and this really
// does run on the main thread, so the isolation is asserted rather than hopped.
// A Task here would return before `app.run()` and leave the app without a delegate.
let app = NSApplication.shared
MainActor.assumeIsolated {
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
}
app.run()
