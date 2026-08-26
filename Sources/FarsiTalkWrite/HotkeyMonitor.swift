//
//  HotkeyMonitor.swift
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
import CoreGraphics
import Carbon.HIToolbox

/// Watches a single modifier key via a listen-only CGEventTap.
///
/// Listen-only matters: we never swallow the keypress, so the 🌐 key keeps doing
/// whatever macOS is configured to do with it. That is why "Press 🌐 to:" must be
/// set to "Do Nothing" — otherwise the emoji picker opens on every trigger and
/// steals focus from the field being dictated into.
final class HotkeyMonitor {

    /// Fired when the configured gesture completes: the Nth press in triple-press
    /// mode, or the key going down in hold-to-talk mode.
    var onTriggerStart: (() -> Void)?
    /// Hold-to-talk only: the key came back up after the minimum hold.
    var onTriggerEnd: (() -> Void)?
    /// Raw press/release, used by `--test-hotkey` for diagnostics.
    var onRawKeyEvent: ((Bool) -> Void)?

    private(set) var isRunning = false

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private var config = TriggerConfig()
    private var pressTimestamps: [TimeInterval] = []
    private var holdStartedAt: TimeInterval?
    private var keyIsDown = false
    /// Fires if the key is still held when it expires; cancelled on early release.
    private var holdTimer: Timer?

    // MARK: - Lifecycle

    enum MonitorError: LocalizedError {
        case inputMonitoringDenied
        case tapCreationFailed

        var errorDescription: String? {
            switch self {
            case .inputMonitoringDenied:
                return "Input Monitoring permission is required to watch the 🌐 key."
            case .tapCreationFailed:
                return "Could not create the keyboard event tap."
            }
        }
    }

    func start(config: TriggerConfig) throws {
        stop()
        guard config.mode != .menuBarOnly else {
            FTWLog.info("Trigger mode is menu-bar-only; no event tap installed.")
            return
        }
        guard Permissions.inputMonitoring.isGranted else {
            throw MonitorError.inputMonitoringDenied
        }

        self.config = config
        pressTimestamps.removeAll()
        holdStartedAt = nil
        keyIsDown = false

        let mask = (1 << CGEventType.flagsChanged.rawValue)
        let context = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<HotkeyMonitor>.fromOpaque(userInfo).takeUnretainedValue()
                monitor.handle(type: type, event: event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: context
        ) else {
            throw MonitorError.tapCreationFailed
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.tap = tap
        self.runLoopSource = source
        isRunning = true

        FTWLog.info("Hotkey monitor started (mode \(config.mode.rawValue), keycode \(config.triggerKeyCode))")
    }

    func stop() {
        holdTimer?.invalidate()
        holdTimer = nil
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        }
        tap = nil
        runLoopSource = nil
        isRunning = false
    }

    deinit { stop() }

    // MARK: - Event handling

    private func handle(type: CGEventType, event: CGEvent) {
        // The system disables taps that run slow or when the user changes security
        // settings; re-enable rather than silently going deaf.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap {
                FTWLog.warn("Event tap was disabled by the system; re-enabling.")
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return
        }

        guard type == .flagsChanged else { return }

        let keyCode = Int(event.getIntegerValueField(.keyboardEventKeycode))
        guard keyCode == config.triggerKeyCode else { return }

        // For a modifier key, "is the key down" is "is its flag now set".
        let isDown = event.flags.contains(Self.modifierFlag(for: keyCode))
        guard isDown != keyIsDown else { return } // ignore duplicate reports
        keyIsDown = isDown

        // Captured here, on the event itself, rather than polling global modifier
        // state later — by the time the async block runs, Shift may be released.
        let shiftHeld = event.flags.contains(.maskShift)

        let now = event.timestamp > 0
            ? Double(event.timestamp) / 1_000_000_000.0
            : ProcessInfo.processInfo.systemUptime

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.onRawKeyEvent?(isDown)

            switch self.config.mode {
            case .triplePress:  self.handleTriplePress(isDown: isDown, at: now)
            case .holdToTalk:   self.handleHold(isDown: isDown, at: now)
            case .holdDuration: self.handleHoldDuration(isDown: isDown)
            case .shiftCombo:   self.handleShiftCombo(isDown: isDown, shiftHeld: shiftHeld)
            case .menuBarOnly:  break
            }
        }
    }

    private func handleTriplePress(isDown: Bool, at now: TimeInterval) {
        guard isDown else { return }

        let window = config.tapWindowSeconds
        pressTimestamps.append(now)
        pressTimestamps = pressTimestamps.filter { now - $0 <= window }

        if pressTimestamps.count >= config.tapCount {
            pressTimestamps.removeAll()
            onTriggerStart?()
        }
    }

    /// Fires on key-down only while Shift is held. A plain press is ignored
    /// entirely, so the key's system function is untouched.
    private func handleShiftCombo(isDown: Bool, shiftHeld: Bool) {
        guard isDown, shiftHeld else { return }
        onTriggerStart?()
    }

    /// Starts only when the key has been held long enough to be deliberate.
    /// A short press is never consumed, so the key keeps its system behaviour.
    private func handleHoldDuration(isDown: Bool) {
        holdTimer?.invalidate()
        holdTimer = nil

        guard isDown else { return }

        let timer = Timer.scheduledTimer(
            withTimeInterval: config.holdTriggerSeconds, repeats: false
        ) { [weak self] _ in
            guard let self, self.keyIsDown else { return }
            self.onTriggerStart?()
        }
        RunLoop.main.add(timer, forMode: .common)
        holdTimer = timer
    }

    private func handleHold(isDown: Bool, at now: TimeInterval) {
        if isDown {
            holdStartedAt = now
            onTriggerStart?()
        } else {
            defer { holdStartedAt = nil }
            guard let started = holdStartedAt else { return }
            // A quick tap should do nothing rather than fire an empty recording.
            if now - started >= config.holdMinSeconds {
                onTriggerEnd?()
            } else {
                onTriggerEnd?()
                FTWLog.info("Hold shorter than the minimum; treated as a cancel.")
            }
        }
    }

    /// Maps a modifier key code to the flag it sets, so `triggerKeyCode` can be
    /// retargeted to Right ⌘ or Right ⌥ without touching this logic.
    static func modifierFlag(for keyCode: Int) -> CGEventFlags {
        switch keyCode {
        case kVK_Function: return .maskSecondaryFn
        case kVK_Command, kVK_RightCommand: return .maskCommand
        case kVK_Option, kVK_RightOption: return .maskAlternate
        case kVK_Shift, kVK_RightShift: return .maskShift
        case kVK_Control, kVK_RightControl: return .maskControl
        case kVK_CapsLock: return .maskAlphaShift
        default: return .maskSecondaryFn
        }
    }

    static func keyName(for keyCode: Int) -> String {
        switch keyCode {
        case kVK_Function: return "🌐 (fn)"
        case kVK_Command: return "Left ⌘"
        case kVK_RightCommand: return "Right ⌘"
        case kVK_Option: return "Left ⌥"
        case kVK_RightOption: return "Right ⌥"
        case kVK_Shift: return "Left ⇧"
        case kVK_RightShift: return "Right ⇧"
        case kVK_Control: return "Left ⌃"
        case kVK_RightControl: return "Right ⌃"
        case kVK_CapsLock: return "Caps Lock"
        default: return "key code \(keyCode)"
        }
    }
}
