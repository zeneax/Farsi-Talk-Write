//
//  Permissions.swift
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
import AVFoundation
import ApplicationServices
import IOKit.hid
import AppKit

enum PermissionState {
    case granted
    case denied
    case notDetermined

    var isGranted: Bool { self == .granted }

    var symbol: String {
        switch self {
        case .granted: return "✓"
        case .denied: return "✗"
        case .notDetermined: return "?"
        }
    }

    var label: String {
        switch self {
        case .granted: return "granted"
        case .denied: return "denied"
        case .notDetermined: return "not yet requested"
        }
    }
}

enum Permissions {

    // MARK: - Microphone

    static var microphone: PermissionState {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return .granted
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }

    static func requestMicrophone() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    // MARK: - Accessibility (needed to post ⌘V into other apps)

    static var accessibility: PermissionState {
        AXIsProcessTrusted() ? .granted : .denied
    }

    /// Shows the system prompt with the "Open System Settings" button.
    static func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    // MARK: - Input Monitoring (needed to observe the 🌐 key via CGEventTap)

    static var inputMonitoring: PermissionState {
        switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
        case kIOHIDAccessTypeGranted: return .granted
        case kIOHIDAccessTypeDenied: return .denied
        default: return .notDetermined
        }
    }

    @discardableResult
    static func requestInputMonitoring() -> Bool {
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    // MARK: - The 🌐 / fn key usage setting

    /// System Settings → Keyboard → "Press 🌐 to:"
    /// 0 = Do Nothing, 1 = Show Emoji & Symbols, 2 = Change Input Source, 3 = Start Dictation.
    /// Only 0 leaves the key free for us, since our event tap is listen-only and
    /// does not swallow the keypress.
    enum FnUsage: Int {
        case doNothing = 0
        case showEmoji = 1
        case changeInputSource = 2
        case startDictation = 3

        var label: String {
            switch self {
            case .doNothing: return "Do Nothing"
            case .showEmoji: return "Show Emoji & Symbols"
            case .changeInputSource: return "Change Input Source"
            case .startDictation: return "Start Dictation"
            }
        }
    }

    static var fnKeyUsage: FnUsage? {
        guard let value = CFPreferencesCopyAppValue(
            "AppleFnUsageType" as CFString,
            "com.apple.HIToolbox" as CFString
        ) as? Int else {
            // Absent normally means the system default, which is not "Do Nothing".
            return nil
        }
        return FnUsage(rawValue: value)
    }

    static var fnKeyIsFree: Bool {
        fnKeyUsage == .doNothing
    }

    // MARK: - System Settings deep links
    //
    // These URL schemes are undocumented and have shifted between macOS releases.
    // Every caller must also show the written click-path so a dead link is a
    // minor annoyance rather than a blocked setup.

    enum SettingsPane {
        case microphone
        case accessibility
        case inputMonitoring
        case keyboard

        var url: URL? {
            let base = "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension"
            switch self {
            case .microphone:      return URL(string: "\(base)?Privacy_Microphone")
            case .accessibility:   return URL(string: "\(base)?Privacy_Accessibility")
            case .inputMonitoring: return URL(string: "\(base)?Privacy_ListenEvent")
            case .keyboard:        return URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")
            }
        }

        /// Fallback instructions, shown next to the button in the Setup Guide.
        var clickPath: String {
            switch self {
            case .microphone:
                return "System Settings → Privacy & Security → Microphone"
            case .accessibility:
                return "System Settings → Privacy & Security → Accessibility"
            case .inputMonitoring:
                return "System Settings → Privacy & Security → Input Monitoring"
            case .keyboard:
                return "System Settings → Keyboard → “Press 🌐 to:”"
            }
        }
    }

    @discardableResult
    static func open(_ pane: SettingsPane) -> Bool {
        guard let url = pane.url else { return false }
        return NSWorkspace.shared.open(url)
    }

    // MARK: - Aggregate status

    struct Status {
        var microphone: PermissionState
        var accessibility: PermissionState
        var inputMonitoring: PermissionState
        var fnUsage: FnUsage?
        var triggerMode: TriggerMode
        var triggerKeyCode: Int = 63

        /// Input Monitoring is irrelevant in menu-bar-only mode.
        var needsInputMonitoring: Bool { triggerMode != .menuBarOnly }

        /// Whether the 🌐 key must be set to "Do Nothing".
        ///
        /// Only for gestures built out of *bare* presses of that key. A short press
        /// then reaches both macOS and this app, so the system action fires on every
        /// trigger and steals focus. `shiftCombo` and `holdDuration` are deliberately
        /// designed around that: a plain press is left entirely to macOS, so the key
        /// can keep switching input source — which is the whole point of them.
        var needsGlobeKeyFree: Bool {
            guard triggerKeyCode == 63 else { return false }   // not the 🌐 key at all
            switch triggerMode {
            case .triplePress, .holdToTalk: return true
            case .holdDuration, .shiftCombo, .menuBarOnly: return false
            }
        }

        var isReady: Bool {
            guard microphone.isGranted, accessibility.isGranted else { return false }
            if needsInputMonitoring {
                guard inputMonitoring.isGranted else { return false }
                if needsGlobeKeyFree, fnUsage != .doNothing { return false }
            }
            return true
        }
    }

    static func status(triggerMode: TriggerMode, triggerKeyCode: Int = 63) -> Status {
        Status(
            microphone: microphone,
            accessibility: accessibility,
            inputMonitoring: inputMonitoring,
            fnUsage: fnKeyUsage,
            triggerMode: triggerMode,
            triggerKeyCode: triggerKeyCode
        )
    }
}
