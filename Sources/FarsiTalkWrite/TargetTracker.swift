//
//  TargetTracker.swift
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

import AppKit

/// Remembers which app owned the keyboard when a dictation started, and puts it
/// back in front before text is inserted.
///
/// This exists for the menu bar trigger: clicking a status item can pull activation
/// away from the app you were typing in, and without restoration the Farsi text
/// would paste into whatever gained focus instead. The fn trigger rarely needs it,
/// but both paths run the same code so there is only one behaviour to reason about.
final class TargetTracker {

    private(set) var target: NSRunningApplication?

    /// Called at the moment the trigger fires, before any UI is shown.
    func capture() {
        let frontmost = NSWorkspace.shared.frontmostApplication
        // Never target ourselves; that would paste into the Setup Guide's own field
        // when the user did not mean it.
        if frontmost?.bundleIdentifier == Bundle.main.bundleIdentifier {
            target = nil
            FTWLog.info("Trigger fired while FarsiTalkWrite was frontmost; will paste into the focused field here.")
        } else {
            target = frontmost
            FTWLog.info("Dictation target: \(frontmost?.localizedName ?? "unknown")")
        }
    }

    /// Re-activates the captured app and waits briefly for the window server to
    /// settle before the caller synthesises a keystroke.
    func restore() async {
        guard let target, !target.isTerminated else { return }
        guard !target.isActive else { return }

        target.activate(options: [])
        try? await Task.sleep(nanoseconds: 120_000_000) // 120 ms
    }

    func clear() {
        target = nil
    }
}
