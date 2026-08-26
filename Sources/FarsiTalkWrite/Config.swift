//
//  Config.swift
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

// MARK: - Provider profiles

enum ProviderKind: String, Codable, CaseIterable {
    /// POST {baseURL}/interactions, key in x-goog-api-key, text at steps[].content[].text
    case geminiInteractions
    /// POST {baseURL}/chat/completions, Bearer auth, text at choices[0].message.content
    case openAICompatible

    var displayName: String {
        switch self {
        case .geminiInteractions: return "Gemini Interactions"
        case .openAICompatible:   return "OpenAI-compatible"
        }
    }
}

struct ProviderProfile: Codable {
    var displayName: String
    var kind: ProviderKind
    var baseURL: String
    var model: String
    var extraHeaders: [String: String] = [:]
    var timeoutSeconds: Double = 45
    var note: String?
    var modelPresets: [String] = []

    /// How much the model is allowed to "think" before answering, for providers
    /// that expose it: "low", "medium", "high", or "" to omit the field.
    /// Transcription needs none, and low is measurably faster.
    var reasoningEffort: String = "low"
}

// MARK: - Trigger

enum TriggerMode: String, Codable {
    case triplePress
    case holdToTalk
    case menuBarOnly
}

struct TriggerConfig: Codable {
    var mode: TriggerMode = .triplePress
    /// 63 = kVK_Function (the 🌐/fn key). 54 = Right ⌘, 58 = Right ⌥.
    var triggerKeyCode: Int = 63
    var tapCount: Int = 3
    var tapWindowSeconds: Double = 0.6
    var holdMinSeconds: Double = 0.25
}

// MARK: - Recording

enum InputDeviceMode: String, Codable {
    case systemDefault
    case preferWhenAvailable
    case pinned
}

struct InputDeviceConfig: Codable {
    var mode: InputDeviceMode = .systemDefault
    /// CoreAudio device UID, used by .preferWhenAvailable and .pinned.
    var preferredUID: String?
}

/// Bluetooth (HFP) links need a moment to negotiate; the first few hundred ms
/// of a recording is silence or noise. Discarded per transport type.
struct LeadInConfig: Codable {
    var defaultMs: Int = 150
    var bluetoothMs: Int = 350

    enum CodingKeys: String, CodingKey {
        case defaultMs = "default"
        case bluetoothMs = "bluetooth"
    }
}

struct RecordingConfig: Codable {
    var maxSeconds: Double = 60
    var silenceStopSeconds: Double = 2.5
    var minSpeechSeconds: Double = 1.0
    var inputDevice = InputDeviceConfig()
    var leadInDiscardMs = LeadInConfig()
    /// Keyed by CoreAudio device UID, plus a "default" entry. AirPods run hotter
    /// and noisier than the built-in mic, so one global threshold does not work.
    var silenceThresholdDb: [String: Double] = ["default": -45]

    func silenceThreshold(forDeviceUID uid: String?) -> Double {
        if let uid, let v = silenceThresholdDb[uid] { return v }
        return silenceThresholdDb["default"] ?? -45
    }

    func leadInDiscard(isBluetooth: Bool) -> Int {
        isBluetooth ? leadInDiscardMs.bluetoothMs : leadInDiscardMs.defaultMs
    }
}

// MARK: - Insertion & HUD

enum InsertionMode: String, Codable {
    case paste
    case type
}

struct InsertionConfig: Codable {
    var mode: InsertionMode = .paste

    /// Wrap embedded Latin words in Unicode isolates so they stay where they were
    /// spoken instead of being flung to the start or end of the line by the
    /// bidirectional algorithm. Adds invisible characters, so it can be turned off
    /// for targets that mishandle them (some terminals and code editors).
    var bidiIsolation: Bool = true
}

struct HUDConfig: Codable {
    var enabled: Bool = true
    var position: String = "bottomCenter"
}

enum DictationLanguage: String, Codable, CaseIterable {
    /// Transcribe whatever is spoken, in the language it was spoken in.
    case auto
    case farsi
    case english

    var displayName: String {
        switch self {
        case .auto: return "Auto-detect"
        case .farsi: return "فارسی (Farsi)"
        case .english: return "English"
        }
    }
}

struct UIConfig: Codable {
    /// Set once the user closes the Setup Guide themselves. After that the guide
    /// is opened on request only — an app that reopens a wizard on every launch
    /// is worse than one that quietly reports its problem in the menu bar.
    var setupDismissed: Bool = false

    /// Keep a Dock icon permanently.
    ///
    /// On a notched MacBook a full menu bar silently swallows new status items —
    /// they are created, report themselves visible, and are given no position.
    /// When that happens the menu bar icon is not a reliable way to reach the app,
    /// so the Dock icon becomes the guaranteed one.
    var alwaysShowDockIcon: Bool = true
}

// MARK: - Root

struct Config: Codable {
    var schemaVersion: Int = 1
    /// OpenRouter by default: Google's inference endpoint is unreachable from some
    /// networks (it accepts the request, then never returns a response), whereas
    /// OpenRouter resells the same models — and 3.7 Flash for less.
    var activeProvider: String = "openrouter"
    var providers: [String: ProviderProfile] = [:]
    var fallbackProvider: String?

    /// How many times to attempt a transcription before giving up. The audio is
    /// already on disk by this point, so the only cost of trying again is a
    /// fraction of a cent — cheap next to making someone repeat themselves.
    var retryAttempts: Int = 3
    var trigger = TriggerConfig()
    var recording = RecordingConfig()
    var insertion = InsertionConfig()
    var hud = HUDConfig()
    var ui = UIConfig()

    /// Which language the transcript should come out in.
    var language: DictationLanguage = .auto

    /// The Farsi prompt. Kept under its original key so existing configs and any
    /// customisation the user has made survive the addition of other languages.
    var prompt: String = Config.defaultPrompt
    var promptEnglish: String = Config.defaultEnglishPrompt
    var promptAuto: String = Config.defaultAutoPrompt

    /// The prompt actually sent, for the currently selected language. Settable so
    /// the Prompt tab edits whichever language is currently selected rather than
    /// always writing to the Farsi one.
    var activePrompt: String {
        get {
            switch language {
            case .farsi: return prompt
            case .english: return promptEnglish
            case .auto: return promptAuto
            }
        }
        set {
            switch language {
            case .farsi: prompt = newValue
            case .english: promptEnglish = newValue
            case .auto: promptAuto = newValue
            }
        }
    }

    /// The default for whichever language is selected, for "Restore default".
    var activeDefaultPrompt: String {
        switch language {
        case .farsi: return Config.defaultPrompt
        case .english: return Config.defaultEnglishPrompt
        case .auto: return Config.defaultAutoPrompt
        }
    }

    var activeProfile: ProviderProfile? { providers[activeProvider] }

    /// Provider ids sorted for stable menu ordering: built-ins first, then the rest.
    var orderedProviderIDs: [String] {
        let builtIn = ["google-free", "google-pro", "openrouter"]
        let known = builtIn.filter { providers[$0] != nil }
        let extra = providers.keys.filter { !builtIn.contains($0) }.sorted()
        return known + extra
    }
}

// MARK: - Defaults

extension Config {
    static let defaultPrompt = """
    تو یک سیستم رونویسی گفتار فارسی هستی.
    - فقط متنِ گفته‌شده را بنویس. هیچ توضیح، مقدمه یا پاسخی اضافه نکن.
    - علائم نگارشی (، . ؟ !) و پاراگراف‌بندی درست را اضافه کن.
    - کلمات پرکننده («اِاِ»، «یعنی»، «چیز»، تکرارها و لکنت‌ها) را حذف کن.
    - از «ی» و «ک» فارسی استفاده کن، نه عربیِ ي/ك.
    - نیم‌فاصله را درست به کار ببر: می‌خواهم، کتاب‌ها، نمی‌شود.
    - کلمات انگلیسی (مثل PDF، Slack، Claude Code) را به همان خط لاتین بنویس و \
    دقیقاً در همان جایی بگذار که گفته شده‌اند. آن‌ها را به اول یا آخر جمله منتقل نکن \
    و به فارسی ترجمه یا آوانویسی نکن.
    - اگر صدا خالی یا نامفهوم بود، رشتهٔ خالی برگردان.
    """

    static let defaultEnglishPrompt = """
    You are a speech transcription system.
    - Write only what was said. Add no explanation, preamble, or reply.
    - Add correct punctuation, capitalisation, and paragraph breaks.
    - Remove filler words ("um", "uh", "you know", "like"), false starts, \
    stutters, and repeated words.
    - Keep technical terms, product names, and acronyms in their normal written \
    form (PDF, GitHub, OAuth, macOS).
    - If the audio is empty or unintelligible, return an empty string.
    """

    /// Deliberately instructs the model to follow the speaker rather than pick a
    /// single output language: someone dictating in Persian who says an English
    /// sentence should get that sentence in English, not transliterated.
    static let defaultAutoPrompt = """
    You are a speech transcription system. Transcribe the audio in the language \
    it was actually spoken in — do not translate.

    - Write only what was said. Add no explanation, preamble, or reply.
    - Add correct punctuation and paragraph breaks for that language.
    - Remove filler words, false starts, stutters, and repetitions.
    - If the speech is in English, use normal English capitalisation and keep \
    technical terms in their standard written form (PDF, GitHub, macOS).
    - اگر گفتار فارسی است: از «ی» و «ک» فارسی استفاده کن (نه ي/ك عربی)، \
    نیم‌فاصله را درست به کار ببر (می‌خواهم، کتاب‌ها، نمی‌شود)، و علائم نگارشی \
    فارسی (، ؛ ؟) را رعایت کن.
    - کلمات انگلیسی داخل جملهٔ فارسی را به همان خط لاتین و دقیقاً در همان جای \
    گفته‌شده بنویس؛ آن‌ها را ترجمه یا آوانویسی نکن و جابه‌جا نکن.
    - If the audio is empty or unintelligible, return an empty string.
    """

    static let geminiAPIRevision = "2026-05-20"

    static func makeDefault() -> Config {
        var c = Config()
        c.providers = [
            "google-free": ProviderProfile(
                displayName: "Google — Free (3.7 Flash)",
                kind: .geminiInteractions,
                baseURL: "https://generativelanguage.googleapis.com/v1beta",
                model: "gemini-3.7-flash",
                extraHeaders: ["Api-Revision": geminiAPIRevision],
                timeoutSeconds: 45,
                note: "Key must come from a Google Cloud project WITHOUT billing enabled.",
                modelPresets: [
                    "gemini-3.7-flash",
                    "gemini-3.5-flash",
                    "gemini-3.5-flash-lite",
                    "gemini-3.1-flash-lite",
                ]
            ),
            "google-pro": ProviderProfile(
                displayName: "Google — Paid (3.1 Pro)",
                kind: .geminiInteractions,
                baseURL: "https://generativelanguage.googleapis.com/v1beta",
                model: "gemini-3.1-pro-preview",
                extraHeaders: ["Api-Revision": geminiAPIRevision],
                timeoutSeconds: 45,
                note: "Key must come from a Google Cloud project WITH billing enabled.",
                modelPresets: [
                    "gemini-3.1-pro-preview",
                    "gemini-3.7-flash",
                    "gemini-3.5-flash-lite",
                ]
            ),
            "openrouter": ProviderProfile(
                displayName: "OpenRouter",
                kind: .openAICompatible,
                baseURL: "https://openrouter.ai/api/v1",
                // 3.7 Flash is audio-capable and, on OpenRouter, actually cheaper
                // than buying the same model from Google directly.
                model: "google/gemini-3.7-flash",
                extraHeaders: [
                    "HTTP-Referer": "https://localhost/farsitalkwrite",
                    "X-Title": "FarsiTalkWrite",
                ],
                timeoutSeconds: 45,
                note: "Needs prepaid credit. Every model below accepts audio input.",
                modelPresets: [
                    "google/gemini-3.7-flash",
                    "google/gemini-3.6-flash",
                    "google/gemini-3.1-flash-lite",
                    "google/gemini-3.5-flash",
                    "google/gemini-3.1-pro-preview",
                ]
            ),
        ]
        return c
    }
}

// MARK: - Persistence

enum ConfigStore {
    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/farsitalkwrite", isDirectory: true)
    }

    static var fileURL: URL {
        directory.appendingPathComponent("config.json")
    }

    /// Raw JSON as last read from disk, so that keys this build does not know
    /// about survive a save instead of being silently dropped.
    private static var rawOnDisk: [String: Any] = [:]

    static var existsOnDisk: Bool {
        FileManager.default.fileExists(atPath: fileURL.path)
    }

    static func load() -> Config {
        guard let data = try? Data(contentsOf: fileURL) else {
            let fresh = Config.makeDefault()
            _ = try? save(fresh)
            return fresh
        }
        rawOnDisk = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]

        let decoder = JSONDecoder()
        guard var config = try? decoder.decode(Config.self, from: data) else {
            // Unreadable config: back it up rather than destroying it, and start clean.
            let backup = fileURL.appendingPathExtension("broken-\(Int(Date().timeIntervalSince1970))")
            try? FileManager.default.moveItem(at: fileURL, to: backup)
            FTWLog.warn("config.json could not be decoded; moved aside to \(backup.lastPathComponent)")
            let fresh = Config.makeDefault()
            _ = try? save(fresh)
            return fresh
        }
        config = migrate(config)
        return config
    }

    @discardableResult
    static func save(_ config: Config) throws -> URL {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let encoded = try encoder.encode(config)

        // Merge over whatever was on disk so unknown/future keys are preserved.
        let encodedDict = (try? JSONSerialization.jsonObject(with: encoded)) as? [String: Any] ?? [:]
        let merged = deepMerge(base: rawOnDisk, overlay: encodedDict)
        let out = try JSONSerialization.data(
            withJSONObject: merged,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )

        try out.write(to: fileURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        rawOnDisk = merged
        return fileURL
    }

    /// Overlay wins on conflicts; nested dictionaries merge rather than replace.
    private static func deepMerge(base: [String: Any], overlay: [String: Any]) -> [String: Any] {
        var result = base
        for (key, value) in overlay {
            if let subOverlay = value as? [String: Any],
               let subBase = result[key] as? [String: Any] {
                result[key] = deepMerge(base: subBase, overlay: subOverlay)
            } else {
                result[key] = value
            }
        }
        return result
    }

    private static func migrate(_ config: Config) -> Config {
        var c = config
        // Re-seed any built-in profile the user has removed or that postdates their config,
        // without touching profiles they have customised.
        let defaults = Config.makeDefault()
        for (id, profile) in defaults.providers where c.providers[id] == nil {
            c.providers[id] = profile
        }
        if c.providers[c.activeProvider] == nil {
            c.activeProvider = c.orderedProviderIDs.first ?? "google-free"
        }
        if c.recording.silenceThresholdDb["default"] == nil {
            c.recording.silenceThresholdDb["default"] = -45
        }
        // Configs written before multi-language support have no English/auto
        // prompt; seed them rather than sending an empty instruction.
        if c.promptEnglish.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            c.promptEnglish = Config.defaultEnglishPrompt
        }
        if c.promptAuto.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            c.promptAuto = Config.defaultAutoPrompt
        }
        c.schemaVersion = max(c.schemaVersion, 1)
        return c
    }
}
