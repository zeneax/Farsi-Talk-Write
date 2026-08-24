import Foundation
import AppKit

/// Terminal subcommands. Each exercises a single layer of the pipeline, so a
/// failure is localised instead of showing up as "dictation doesn't work".
enum CLI {

    static let usage = """
    FarsiTalkWrite — Farsi push-to-talk dictation

    USAGE
      FarsiTalkWrite                          launch the menu bar app
      FarsiTalkWrite --check                  report permissions, config, and keys
      FarsiTalkWrite --list-devices           list audio input devices
      FarsiTalkWrite --test-audio [--device UID] [--seconds N]
                                              record and write a WAV to /tmp
      FarsiTalkWrite --test-transcribe FILE [--provider ID]
                                              transcribe a WAV, print text + tokens
      FarsiTalkWrite --test-insert TEXT       paste text into the frontmost app
      FarsiTalkWrite --test-hotkey            log key events and trigger fires
      FarsiTalkWrite --set-key [--provider ID] [--from-file PATH]
                                              store an API key in the Keychain
      FarsiTalkWrite --config-path            print the config file location
      FarsiTalkWrite --help                   this message
    """

    /// Returns true if the arguments were handled as a CLI command, so the GUI
    /// should not start.
    static func run(_ arguments: [String]) -> Bool {
        var args = arguments
        args.removeFirst() // executable path

        guard let command = args.first, command.hasPrefix("--") else { return false }
        FTWLog.echoToStderr = true

        let options = parseOptions(args)

        switch command {
        case "--help", "-h":
            Term.out(usage)
        case "--check":
            check()
        case "--config-path":
            Term.out(ConfigStore.fileURL.path)
        case "--set-key":
            setKey(providerID: options["provider"], fromFile: options["from-file"])
        case "--list-devices":
            listDevices()
        case "--test-audio":
            testAudio(deviceUID: options["device"], seconds: Double(options["seconds"] ?? "") ?? 5)
        case "--test-transcribe":
            testTranscribe(path: positional(args), providerID: options["provider"])
        case "--test-insert":
            testInsert(text: positional(args))
        case "--test-hotkey":
            testHotkey()
        default:
            Term.out("Unknown command: \(command)\n")
            Term.out(usage)
            exit(2)
        }

        return true
    }

    /// Very small option parser: `--name value` pairs plus bare flags.
    static func parseOptions(_ args: [String]) -> [String: String] {
        var options: [String: String] = [:]
        var index = 0
        while index < args.count {
            let arg = args[index]
            if arg.hasPrefix("--") {
                let name = String(arg.dropFirst(2))
                if index + 1 < args.count, !args[index + 1].hasPrefix("--") {
                    options[name] = args[index + 1]
                    index += 2
                    continue
                }
                options[name] = ""
            }
            index += 1
        }
        return options
    }

    /// Positional argument following the leading subcommand, if any.
    static func positional(_ args: [String]) -> String? {
        guard args.count >= 2, !args[1].hasPrefix("--") else { return nil }
        return args[1]
    }

    // MARK: - --check

    static func check() {
        let config = ConfigStore.load()

        Term.heading("Configuration")
        Term.row("config file", ConfigStore.fileURL.path, ok: ConfigStore.existsOnDisk)
        Term.row("active provider", config.activeProvider, ok: config.activeProfile != nil)
        if let profile = config.activeProfile {
            Term.row("model", profile.model)
            Term.row("endpoint", profile.baseURL)
            Term.row("kind", profile.kind.displayName)
        }
        Term.row("trigger mode", config.trigger.mode.rawValue)

        Term.heading("API keys (Keychain)")
        for id in config.orderedProviderIDs {
            let profile = config.providers[id]!
            Term.row(id, "\(Keychain.masked(forProvider: id))  — \(profile.displayName)",
                     ok: Keychain.hasKey(forProvider: id))
        }

        Term.heading("Audio input")
        if let device = AudioDeviceManager.resolveInputDevice(config.recording.inputDevice) {
            Term.row("will record from", "\(device.name) (\(device.transport.label), \(Int(device.sampleRate)) Hz)", ok: true)
        } else {
            Term.row("will record from", "no input device found", ok: false)
        }

        Term.heading("Permissions")
        let status = Permissions.status(triggerMode: config.trigger.mode)
        Term.row("Microphone", status.microphone.label, ok: status.microphone.isGranted)
        Term.row("Accessibility", status.accessibility.label, ok: status.accessibility.isGranted)

        if status.needsInputMonitoring {
            Term.row("Input Monitoring", status.inputMonitoring.label, ok: status.inputMonitoring.isGranted)
            let fnLabel = status.fnUsage.map { "\($0.label) (\($0.rawValue))" } ?? "system default"
            Term.row("🌐 key set to", fnLabel, ok: status.fnUsage == .doNothing)
            if status.fnUsage != .doNothing {
                Term.out("      → must be “Do Nothing”: \(Permissions.SettingsPane.keyboard.clickPath)")
            }
        } else {
            Term.row("Input Monitoring", "not needed in menu-bar-only mode", ok: true)
        }

        Term.heading("Result")
        if status.isReady {
            Term.out("  ✓ All system permissions are in place.")
        } else {
            Term.out("  ✗ Setup incomplete — open the app and use Setup Guide, or fix the ✗ rows above.")
        }
        Term.out()
    }

    // MARK: - --list-devices

    static func listDevices() {
        let config = ConfigStore.load()
        let devices = AudioDeviceManager.allInputDevices()
        let active = AudioDeviceManager.resolveInputDevice(config.recording.inputDevice)

        Term.heading("Audio input devices")
        guard !devices.isEmpty else {
            Term.out("  none found")
            return
        }

        for device in devices {
            let marker = device.uid == active?.uid ? "→" : " "
            Term.out("  \(marker) \(device.name)")
            Term.out("      transport   \(device.transport.label)\(device.isBluetooth ? "  (needs lead-in discard)" : "")")
            Term.out("      rate        \(Int(device.sampleRate)) Hz")
            Term.out("      uid         \(device.uid)")
            let threshold = config.recording.silenceThreshold(forDeviceUID: device.uid)
            Term.out("      threshold   \(Int(threshold)) dBFS")
            Term.out()
        }
    }

    // MARK: - --test-audio

    static func testAudio(deviceUID: String?, seconds: Double) {
        var config = ConfigStore.load()
        if let deviceUID, !deviceUID.isEmpty {
            config.recording.inputDevice.mode = .pinned
            config.recording.inputDevice.preferredUID = deviceUID
        }
        // Fixed-length capture: disable the silence stop for this test.
        config.recording.maxSeconds = seconds
        config.recording.silenceStopSeconds = .greatestFiniteMagnitude

        guard Permissions.microphone.isGranted else {
            Term.out("Microphone permission is not granted. Run the app once and use the Setup Guide.")
            exit(1)
        }

        let recorder = AudioRecorder()
        let output = URL(fileURLWithPath: "/tmp/ftw-test.wav")
        var done = false

        recorder.onFinished = { recording in
            do {
                try recording.wav.write(to: output)
                Term.out()
                Term.heading("Recorded")
                Term.row("device", recording.device.map { "\($0.name) (\($0.transport.label))" } ?? "unknown")
                Term.row("duration", String(format: "%.2f s", recording.duration))
                Term.row("stopped by", recording.reason.label)
                Term.row("file", output.path)
                Term.row("audio tokens", "~\(recording.estimatedAudioTokens)")
                Term.out()
                Term.out("  Check it:  afplay \(output.path)")
                Term.out("             afinfo \(output.path)   (expect 16000 Hz, 1 channel)")
                Term.out()
            } catch {
                Term.out("Could not write \(output.path): \(error.localizedDescription)")
            }
            done = true
        }

        recorder.onLevel = { level in
            let bars = Int(max(0, min(20, (Double(level) + 60) / 3)))
            let meter = String(repeating: "█", count: bars).padding(toLength: 20, withPad: "░", startingAt: 0)
            FileHandle.standardError.write(Data("\r  \(meter) \(Int(level)) dBFS ".utf8))
        }

        do {
            try recorder.start(config: config)
            Term.out("Recording for \(Int(seconds))s — speak now.")
        } catch {
            Term.out("✗ \(error.localizedDescription)")
            exit(1)
        }

        while !done && RunLoop.current.run(mode: .default, before: .distantFuture) {}
    }

    // MARK: - --test-transcribe

    static func testTranscribe(path: String?, providerID: String?) {
        guard let path else {
            Term.out("Usage: FarsiTalkWrite --test-transcribe FILE.wav [--provider ID]")
            exit(2)
        }
        guard let wav = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            Term.out("Could not read \(path)")
            exit(1)
        }

        var config = ConfigStore.load()
        if let providerID, !providerID.isEmpty {
            guard config.providers[providerID] != nil else {
                Term.out("No such provider: \(providerID)")
                Term.out("Known: \(config.orderedProviderIDs.joined(separator: ", "))")
                exit(2)
            }
            config.activeProvider = providerID
        }

        let profile = config.activeProfile
        Term.heading("Transcribing")
        Term.row("file", "\(path) (\(wav.count / 1024) KB)")
        Term.row("provider", config.activeProvider)
        Term.row("model", profile?.model ?? "—")

        let done = DispatchSemaphore(value: 0)
        var exitCode: Int32 = 0

        Task {
            let started = Date()
            do {
                let provider = try ProviderRegistry.make(profileID: config.activeProvider, config: config)
                let result = try await provider.transcribe(wav: wav, prompt: config.activePrompt)
                let elapsed = Date().timeIntervalSince(started)

                Term.heading("Result")
                Term.out("  \(result.text)")
                Term.out()
                Term.row("latency", String(format: "%.1f s", elapsed))
                Term.row("tokens", result.tokenSummary)
                if let cost = ProviderRegistry.estimatedCost(for: result) {
                    Term.row("est. cost", cost)
                }
                Term.row("characters", String(result.text.count))
                Term.out()
            } catch {
                Term.out()
                Term.out("  ✗ \(error.localizedDescription)")
                Term.out()
                exitCode = 1
            }
            done.signal()
        }

        done.wait()
        exit(exitCode)
    }

    // MARK: - --test-insert

    static func testInsert(text: String?) {
        let payload = text ?? "سلام دنیا"
        let config = ConfigStore.load()

        guard Permissions.accessibility.isGranted else {
            Term.out("✗ Accessibility permission is required to type into other apps.")
            Term.out("  \(Permissions.SettingsPane.accessibility.clickPath)")
            exit(1)
        }

        Term.out("Switch to the target app — inserting in 3 seconds…")
        Thread.sleep(forTimeInterval: 3)

        let before = NSPasteboard.general.string(forType: .string)
        do {
            try TextInserter.insert(payload, mode: config.insertion.mode)
            Term.out("✓ Inserted: \(payload)")

            // Give the deferred clipboard restore time to run before we exit.
            Thread.sleep(forTimeInterval: 0.8)
            let after = NSPasteboard.general.string(forType: .string)
            if before == after {
                Term.out("✓ Clipboard restored unchanged.")
            } else {
                Term.out("! Clipboard now holds: \(after ?? "nothing")")
            }
        } catch {
            Term.out("✗ \(error.localizedDescription)")
            exit(1)
        }
    }

    // MARK: - --test-hotkey

    static func testHotkey() {
        let config = ConfigStore.load()
        let monitor = HotkeyMonitor()

        guard Permissions.inputMonitoring.isGranted else {
            Term.out("✗ Input Monitoring permission is required to watch the key.")
            Term.out("  \(Permissions.SettingsPane.inputMonitoring.clickPath)")
            exit(1)
        }

        let keyName = HotkeyMonitor.keyName(for: config.trigger.triggerKeyCode)
        Term.heading("Hotkey test")
        Term.row("mode", config.trigger.mode.rawValue)
        Term.row("key", keyName)
        Term.row("press count", String(config.trigger.tapCount))
        Term.row("window", "\(config.trigger.tapWindowSeconds) s")
        Term.out()
        Term.out("  Press \(keyName). Type normally too — nothing should fire from ordinary typing.")
        Term.out("  Ctrl-C to stop.")
        Term.out()

        var presses = 0
        var fires = 0

        monitor.onRawKeyEvent = { isDown in
            if isDown {
                presses += 1
                Term.out("  ↓ \(keyName) press #\(presses)")
            } else {
                Term.out("  ↑ \(keyName) release")
            }
        }
        monitor.onTriggerStart = {
            fires += 1
            Term.out("  ★ TRIGGER FIRED (\(fires) total)")
        }
        monitor.onTriggerEnd = {
            Term.out("  ■ trigger ended")
        }

        var triggerConfig = config.trigger
        if triggerConfig.mode == .menuBarOnly {
            Term.out("  (mode is menu-bar-only; testing as triple-press for diagnostics)")
            triggerConfig.mode = .triplePress
        }

        do {
            try monitor.start(config: triggerConfig)
        } catch {
            Term.out("✗ \(error.localizedDescription)")
            exit(1)
        }

        RunLoop.current.run()
    }

    // MARK: - --set-key

    static func setKey(providerID: String?, fromFile: String?) {
        let config = ConfigStore.load()
        let id = providerID?.isEmpty == false ? providerID! : config.activeProvider

        guard let profile = config.providers[id] else {
            Term.out("No such provider: \(id)")
            Term.out("Known providers: \(config.orderedProviderIDs.joined(separator: ", "))")
            exit(2)
        }

        Term.out("Setting API key for “\(profile.displayName)” (\(id))")
        if let note = profile.note { Term.out("  Note: \(note)") }

        let entered: String?
        if let fromFile, !fromFile.isEmpty {
            // Paste-free route: the key never passes through the terminal, so
            // bracketed-paste markers and shell history are both sidestepped.
            let path = (fromFile as NSString).expandingTildeInPath
            guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
                Term.out("✗ Could not read \(path)")
                exit(1)
            }
            entered = sanitize(contents)
            Term.out("  Read from \(path)")
        } else {
            Term.out("Paste the key and press return (input is hidden):")
            entered = readSecretLine()
        }

        guard let key = entered, !key.isEmpty else {
            Term.out("No key entered; nothing changed.")
            exit(1)
        }

        // Input is hidden, so a mis-paste is invisible until a request fails much
        // later. Real keys are a single opaque token: no whitespace, no quotes.
        if let complaint = validate(key: key, kind: profile.kind) {
            Term.out("✗ That does not look like an API key: \(complaint)")
            Term.out("  Read \(key.count) characters. Nothing was saved.")
            Term.out()
            Term.out("  If pasting into the hidden prompt keeps failing, use either:")
            Term.out("    • the app’s Setup Guide (a normal password field), or")
            Term.out("    • --set-key --from-file ~/key.txt")
            exit(1)
        }

        do {
            try Keychain.set(key, forProvider: id)
            Term.out("✓ Saved to Keychain as \(Keychain.masked(forProvider: id))")
            Term.out("  Verify with: FarsiTalkWrite --test-transcribe /tmp/ftw-test.wav --provider \(id)")
        } catch {
            Term.out("✗ \(error.localizedDescription)")
            exit(1)
        }
    }

    /// Returns a human-readable complaint if the string cannot be an API key,
    /// or nil if it looks plausible.
    static func validate(key: String, kind: ProviderKind) -> String? {
        if key.rangeOfCharacter(from: .whitespacesAndNewlines) != nil {
            return "it contains spaces — looks like a shell command got pasted instead"
        }
        if key.contains("\"") || key.contains("'") {
            return "it contains quote marks"
        }
        if key.count < 20 {
            return "it is only \(key.count) characters; keys are much longer"
        }
        // Deliberately no prefix check. Google AI Studio has issued at least two
        // formats ("AIza…" and "AQ.Ab8RN…") and gating on a known prefix rejects
        // valid keys the moment the provider changes it. Whitespace, quotes, and
        // length are the signals that actually indicate a mis-paste.
        return nil
    }

    /// Reads a line without echoing it, so keys do not end up in scrollback.
    private static func readSecretLine() -> String? {
        var term = termios()
        let isTTY = tcgetattr(STDIN_FILENO, &term) == 0
        var original = term

        if isTTY {
            term.c_lflag &= ~UInt(ECHO)
            tcsetattr(STDIN_FILENO, TCSAFLUSH, &term)
        }
        defer {
            if isTTY {
                tcsetattr(STDIN_FILENO, TCSAFLUSH, &original)
                Term.out()
            }
        }

        guard let raw = readLine(strippingNewline: true) else { return nil }
        return sanitize(raw)
    }

    /// Terminals with bracketed paste enabled wrap pasted text in ESC[200~ … ESC[201~.
    /// With echo disabled those markers are invisible, so they silently become part
    /// of the "key" and every request fails with a baffling auth error.
    static func sanitize(_ raw: String) -> String {
        var text = raw
            .replacingOccurrences(of: "\u{1B}[200~", with: "")
            .replacingOccurrences(of: "\u{1B}[201~", with: "")

        text = String(text.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0)
        })

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
