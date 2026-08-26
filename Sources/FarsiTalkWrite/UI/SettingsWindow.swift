//
//  SettingsWindow.swift
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

/// Where "configurable" becomes real rather than a JSON file you have to remember
/// the shape of. Four tabs; the Providers tab is the important one.
final class SettingsWindow: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {

    var config: Config { didSet { if window != nil { reloadAll() } } }

    var onConfigChanged: ((Config) -> Void)?
    var onOpenSetupGuide: (() -> Void)?
    var onShowQuickHelp: ((NSView) -> Void)?
    var onClosed: (() -> Void)?

    private var window: NSWindow?
    private let tabView = NSTabView()

    // Providers tab
    private let providerTable = NSTableView()
    private let displayNameField = NSTextField()
    private let kindPopup = NSPopUpButton()
    private let baseURLField = NSTextField()
    private let modelCombo = NSComboBox()
    private let keyField = NSSecureTextField()
    private let headersField = NSTextField()
    private let activeCheckbox = NSButton()
    private let testResultLabel = NSTextField(wrappingLabelWithString: "")
    private var selectedProviderID: String = ""

    // Trigger tab
    private let triggerPopup = NSPopUpButton()
    private let keyCodePopup = NSPopUpButton()
    private let tapCountField = NSTextField()
    private let tapWindowField = NSTextField()
    private let holdMinField = NSTextField()

    // Recording tab
    private let recDevicePopup = NSPopUpButton()
    private let maxSecondsField = NSTextField()
    private let silenceStopField = NSTextField()
    private let minSpeechField = NSTextField()
    private let thresholdSlider = NSSlider()
    private let thresholdLabel = NSTextField(labelWithString: "")
    private let meterView = LevelMeterView()
    private var meterRecorder: AudioRecorder?

    // Prompt tab
    private let promptTextView = NSTextView()
    private let languagePopup = NSPopUpButton()

    init(config: Config) {
        self.config = config
        super.init()
    }

    // MARK: - Presentation

    func present() {
        if window == nil { build() }
        reloadAll()
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        stopMeter()
        commitPrompt()
        onClosed?()
    }

    private func build() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 500),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "FarsiTalkWrite Settings"
        window.delegate = self
        window.isReleasedWhenClosed = false

        tabView.translatesAutoresizingMaskIntoConstraints = false
        tabView.addTabViewItem(tab("Providers", providersView()))
        tabView.addTabViewItem(tab("Trigger", triggerView()))
        tabView.addTabViewItem(tab("Recording", recordingView()))
        tabView.addTabViewItem(tab("Prompt", promptView()))

        let root = NSView()
        root.addSubview(tabView)
        NSLayoutConstraint.activate([
            tabView.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            tabView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            tabView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            tabView.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
        ])

        window.contentView = root
        self.window = window
    }

    private func tab(_ label: String, _ view: NSView) -> NSTabViewItem {
        let item = NSTabViewItem(identifier: label)
        item.label = label
        item.view = view
        return item
    }

    // MARK: - Providers tab

    private func providersView() -> NSView {
        let root = NSView()

        providerTable.headerView = nil
        providerTable.dataSource = self
        providerTable.delegate = self
        providerTable.rowHeight = 24
        let column = NSTableColumn(identifier: .init("provider"))
        column.width = 180
        providerTable.addTableColumn(column)

        let scroll = NSScrollView()
        scroll.documentView = providerTable
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let add = NSButton(title: "+", target: self, action: #selector(addProvider))
        let remove = NSButton(title: "−", target: self, action: #selector(removeProvider))
        add.bezelStyle = .rounded
        remove.bezelStyle = .rounded
        let listButtons = NSStackView(views: [add, remove, NSView()])
        listButtons.orientation = .horizontal
        listButtons.spacing = 6
        listButtons.translatesAutoresizingMaskIntoConstraints = false

        // Detail form
        kindPopup.removeAllItems()
        for kind in ProviderKind.allCases { kindPopup.addItem(withTitle: kind.displayName) }

        modelCombo.isEditable = true
        modelCombo.completes = true

        let refresh = NSButton(title: "Refresh", target: self, action: #selector(refreshModels))
        refresh.bezelStyle = .rounded

        let saveKey = NSButton(title: "Save", target: self, action: #selector(saveKey))
        saveKey.bezelStyle = .rounded

        activeCheckbox.setButtonType(.radio)
        activeCheckbox.title = "Use as active provider"
        activeCheckbox.target = self
        activeCheckbox.action = #selector(makeActive)

        let test = NSButton(title: "Test connection", target: self, action: #selector(testConnection))
        test.bezelStyle = .rounded

        let help = NSButton(title: "?", target: self, action: #selector(showHelp))
        help.bezelStyle = .helpButton

        testResultLabel.font = .systemFont(ofSize: 11)
        testResultLabel.preferredMaxLayoutWidth = 420

        let form = NSStackView()
        form.orientation = .vertical
        form.alignment = .leading
        form.spacing = 8
        form.translatesAutoresizingMaskIntoConstraints = false

        form.addArrangedSubview(labelled("Display name", displayNameField))
        form.addArrangedSubview(labelled("Kind", kindPopup))
        form.addArrangedSubview(labelled("Base URL", baseURLField))
        form.addArrangedSubview(labelled("Model", modelCombo, trailing: refresh))
        form.addArrangedSubview(labelled("API key", keyField, trailing: saveKey))
        form.addArrangedSubview(labelled("Headers", headersField))
        form.addArrangedSubview(activeCheckbox)
        form.addArrangedSubview(NSStackView(views: [test, help]))
        form.addArrangedSubview(testResultLabel)

        for field in [displayNameField, baseURLField, headersField] {
            field.target = self
            field.action = #selector(commitProviderEdits)
        }
        kindPopup.target = self
        kindPopup.action = #selector(commitProviderEdits)
        modelCombo.target = self
        modelCombo.action = #selector(commitProviderEdits)
        headersField.placeholderString = "Api-Revision: 2026-05-20, X-Title: FarsiTalkWrite"

        root.addSubview(scroll)
        root.addSubview(listButtons)
        root.addSubview(form)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            scroll.widthAnchor.constraint(equalToConstant: 190),
            scroll.bottomAnchor.constraint(equalTo: listButtons.topAnchor, constant: -6),

            listButtons.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            listButtons.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16),

            form.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            form.leadingAnchor.constraint(equalTo: scroll.trailingAnchor, constant: 20),
            form.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
        ])

        return root
    }

    // MARK: - Trigger tab

    private func triggerView() -> NSView {
        let stack = verticalForm()

        triggerPopup.removeAllItems()
        triggerPopup.addItems(withTitles: ["Triple-press key", "Hold key", "Menu bar only"])
        triggerPopup.target = self
        triggerPopup.action = #selector(commitTrigger)

        keyCodePopup.removeAllItems()
        for (code, _) in Self.triggerKeys {
            keyCodePopup.addItem(withTitle: HotkeyMonitor.keyName(for: code))
            keyCodePopup.lastItem?.tag = code
        }
        keyCodePopup.target = self
        keyCodePopup.action = #selector(commitTrigger)

        for field in [tapCountField, tapWindowField, holdMinField] {
            field.target = self
            field.action = #selector(commitTrigger)
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalToConstant: 70).isActive = true
        }

        stack.addArrangedSubview(labelled("Mode", triggerPopup))
        stack.addArrangedSubview(labelled("Key", keyCodePopup))
        stack.addArrangedSubview(labelled("Press count", tapCountField))
        stack.addArrangedSubview(labelled("Press window (s)", tapWindowField))
        stack.addArrangedSubview(labelled("Minimum hold (s)", holdMinField))
        stack.addArrangedSubview(hint("""
        Menu bar only removes the keyboard trigger entirely, and with it the need \
        for Input Monitoring permission. The 🌐 key must be set to “Do Nothing” in \
        System Settings for the other two modes to be usable.
        """))

        return wrap(stack)
    }

    private static let triggerKeys: [(Int, String)] = [
        (63, "fn"), (54, "rcmd"), (55, "lcmd"), (58, "lopt"), (61, "ropt"), (59, "lctrl"), (62, "rctrl"),
    ]

    // MARK: - Recording tab

    private func recordingView() -> NSView {
        let stack = verticalForm()

        recDevicePopup.target = self
        recDevicePopup.action = #selector(commitRecording)

        for field in [maxSecondsField, silenceStopField, minSpeechField] {
            field.target = self
            field.action = #selector(commitRecording)
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalToConstant: 70).isActive = true
        }

        thresholdSlider.minValue = -70
        thresholdSlider.maxValue = -10
        thresholdSlider.target = self
        thresholdSlider.action = #selector(thresholdChanged)
        thresholdSlider.translatesAutoresizingMaskIntoConstraints = false
        thresholdSlider.widthAnchor.constraint(equalToConstant: 220).isActive = true

        meterView.translatesAutoresizingMaskIntoConstraints = false
        meterView.heightAnchor.constraint(equalToConstant: 22).isActive = true
        meterView.widthAnchor.constraint(equalToConstant: 320).isActive = true

        let listen = NSButton(title: "Start meter", target: self, action: #selector(toggleMeter))
        listen.bezelStyle = .rounded

        stack.addArrangedSubview(labelled("Input device", recDevicePopup))
        stack.addArrangedSubview(labelled("Max seconds", maxSecondsField))
        stack.addArrangedSubview(labelled("Stop after silence (s)", silenceStopField))
        stack.addArrangedSubview(labelled("Min speech before silence stop (s)", minSpeechField))
        stack.addArrangedSubview(labelled("Silence threshold", thresholdSlider, trailing: thresholdLabel))
        stack.addArrangedSubview(meterView)
        stack.addArrangedSubview(listen)
        stack.addArrangedSubview(hint("""
        The threshold is saved per device. AirPods run hotter and noisier than the \
        built-in mic, so calibrate each one: start the meter, stay quiet, and set \
        the threshold just above the resting level.
        """))

        return wrap(stack)
    }

    // MARK: - Prompt tab

    private func promptView() -> NSView {
        promptTextView.isEditable = true
        promptTextView.font = .systemFont(ofSize: 13)
        promptTextView.baseWritingDirection = .rightToLeft
        promptTextView.isAutomaticQuoteSubstitutionEnabled = false

        let scroll = NSScrollView()
        scroll.documentView = promptTextView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        languagePopup.removeAllItems()
        for language in DictationLanguage.allCases {
            languagePopup.addItem(withTitle: language.displayName)
            languagePopup.lastItem?.representedObject = language.rawValue
        }
        languagePopup.target = self
        languagePopup.action = #selector(languageChanged)

        let languageRow = NSStackView(views: [
            NSTextField(labelWithString: "Dictation language:"), languagePopup,
        ])
        languageRow.orientation = .horizontal
        languageRow.spacing = 8
        languageRow.translatesAutoresizingMaskIntoConstraints = false

        let restore = NSButton(title: "Restore default", target: self, action: #selector(restorePrompt))
        restore.bezelStyle = .rounded
        let apply = NSButton(title: "Apply", target: self, action: #selector(commitPromptAction))
        apply.bezelStyle = .rounded

        let buttons = NSStackView(views: [restore, NSView(), apply])
        buttons.orientation = .horizontal
        buttons.translatesAutoresizingMaskIntoConstraints = false

        let note = hint("""
        Transcription quality lives here more than anywhere else in the app. \
        Changes apply to the next dictation — no restart.
        """)

        let root = NSView()
        root.addSubview(languageRow)
        root.addSubview(scroll)
        root.addSubview(buttons)
        root.addSubview(note)

        NSLayoutConstraint.activate([
            languageRow.topAnchor.constraint(equalTo: root.topAnchor, constant: 16),
            languageRow.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),

            scroll.topAnchor.constraint(equalTo: languageRow.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            scroll.heightAnchor.constraint(equalToConstant: 220),

            note.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 10),
            note.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            note.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),

            buttons.topAnchor.constraint(equalTo: note.bottomAnchor, constant: 10),
            buttons.leadingAnchor.constraint(equalTo: scroll.leadingAnchor),
            buttons.trailingAnchor.constraint(equalTo: scroll.trailingAnchor),
        ])

        return root
    }

    // MARK: - Reload

    private func reloadAll() {
        if selectedProviderID.isEmpty || config.providers[selectedProviderID] == nil {
            selectedProviderID = config.activeProvider
        }
        providerTable.reloadData()
        if let row = config.orderedProviderIDs.firstIndex(of: selectedProviderID) {
            providerTable.selectRowIndexes([row], byExtendingSelection: false)
        }
        loadProviderForm()
        loadTriggerForm()
        loadRecordingForm()
        promptTextView.string = config.activePrompt
        if let index = DictationLanguage.allCases.firstIndex(of: config.language) {
            languagePopup.selectItem(at: index)
        }
        promptTextView.baseWritingDirection = config.language == .english ? .leftToRight : .rightToLeft
    }

    @objc private func languageChanged() {
        // Save any edit to the outgoing language before switching editors.
        commitPrompt()
        guard let raw = languagePopup.selectedItem?.representedObject as? String,
              let language = DictationLanguage(rawValue: raw) else { return }
        config.language = language
        onConfigChanged?(config)
        promptTextView.string = config.activePrompt
        promptTextView.baseWritingDirection = language == .english ? .leftToRight : .rightToLeft
    }

    private func loadProviderForm() {
        guard let profile = config.providers[selectedProviderID] else { return }
        displayNameField.stringValue = profile.displayName
        kindPopup.selectItem(at: ProviderKind.allCases.firstIndex(of: profile.kind) ?? 0)
        baseURLField.stringValue = profile.baseURL

        modelCombo.removeAllItems()
        modelCombo.addItems(withObjectValues: profile.modelPresets)
        modelCombo.stringValue = profile.model

        keyField.stringValue = ""
        keyField.placeholderString = Keychain.masked(forProvider: selectedProviderID)

        headersField.stringValue = profile.extraHeaders
            .map { "\($0.key): \($0.value)" }
            .sorted()
            .joined(separator: ", ")

        activeCheckbox.state = (selectedProviderID == config.activeProvider) ? .on : .off
        testResultLabel.stringValue = profile.note ?? ""
        testResultLabel.textColor = .secondaryLabelColor
    }

    private func loadTriggerForm() {
        let modes: [TriggerMode] = [.triplePress, .holdToTalk, .menuBarOnly]
        triggerPopup.selectItem(at: modes.firstIndex(of: config.trigger.mode) ?? 0)
        keyCodePopup.selectItem(withTag: config.trigger.triggerKeyCode)
        tapCountField.stringValue = String(config.trigger.tapCount)
        tapWindowField.stringValue = String(config.trigger.tapWindowSeconds)
        holdMinField.stringValue = String(config.trigger.holdMinSeconds)
    }

    private func loadRecordingForm() {
        recDevicePopup.removeAllItems()
        recDevicePopup.addItem(withTitle: "Follow system default")

        let devices = AudioDeviceManager.allInputDevices()
        for device in devices {
            recDevicePopup.addItem(
                withTitle: "\(device.name) — \(device.transport.label), \(Int(device.sampleRate)) Hz"
            )
            recDevicePopup.lastItem?.representedObject = device.uid
        }

        if config.recording.inputDevice.mode != .systemDefault,
           let uid = config.recording.inputDevice.preferredUID,
           let index = devices.firstIndex(where: { $0.uid == uid }) {
            recDevicePopup.selectItem(at: index + 1)
        } else {
            recDevicePopup.selectItem(at: 0)
        }

        maxSecondsField.stringValue = String(config.recording.maxSeconds)
        silenceStopField.stringValue = String(config.recording.silenceStopSeconds)
        minSpeechField.stringValue = String(config.recording.minSpeechSeconds)

        let uid = currentDeviceUID
        let threshold = config.recording.silenceThreshold(forDeviceUID: uid)
        thresholdSlider.doubleValue = threshold
        thresholdLabel.stringValue = String(format: "%.0f dBFS", threshold)
        meterView.threshold = Float(threshold)
    }

    private var currentDeviceUID: String? {
        AudioDeviceManager.resolveInputDevice(config.recording.inputDevice)?.uid
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int {
        config.orderedProviderIDs.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = config.orderedProviderIDs[row]
        let profile = config.providers[id]
        let marker = id == config.activeProvider ? "● " : "   "
        let keyMark = Keychain.hasKey(forProvider: id) ? "" : "  (no key)"

        let label = NSTextField(labelWithString: "\(marker)\(profile?.displayName ?? id)\(keyMark)")
        label.font = .systemFont(ofSize: 12)
        label.lineBreakMode = .byTruncatingTail
        return label
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = providerTable.selectedRow
        guard row >= 0, row < config.orderedProviderIDs.count else { return }
        selectedProviderID = config.orderedProviderIDs[row]
        loadProviderForm()
    }

    // MARK: - Provider actions

    @objc private func commitProviderEdits() {
        guard var profile = config.providers[selectedProviderID] else { return }
        profile.displayName = displayNameField.stringValue
        profile.kind = ProviderKind.allCases[max(0, kindPopup.indexOfSelectedItem)]
        profile.baseURL = baseURLField.stringValue
        profile.model = modelCombo.stringValue
        profile.extraHeaders = Self.parseHeaders(headersField.stringValue)
        config.providers[selectedProviderID] = profile
        onConfigChanged?(config)
        providerTable.reloadData()
    }

    static func parseHeaders(_ text: String) -> [String: String] {
        var headers: [String: String] = [:]
        for pair in text.split(separator: ",") {
            let parts = pair.split(separator: ":", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard parts.count == 2, !parts[0].isEmpty else { continue }
            headers[parts[0]] = parts[1]
        }
        return headers
    }

    @objc private func makeActive() {
        config.activeProvider = selectedProviderID
        onConfigChanged?(config)
        providerTable.reloadData()
    }

    @objc private func addProvider() {
        var id = "custom"
        var suffix = 1
        while config.providers[id] != nil {
            suffix += 1
            id = "custom\(suffix)"
        }
        config.providers[id] = ProviderProfile(
            displayName: "New provider",
            kind: .openAICompatible,
            baseURL: "https://",
            model: "",
            extraHeaders: [:],
            timeoutSeconds: 45,
            note: nil,
            modelPresets: []
        )
        selectedProviderID = id
        onConfigChanged?(config)
        reloadAll()
    }

    @objc private func removeProvider() {
        // Never leave the app with no provider to fall back on.
        guard config.providers.count > 1 else { return }
        let removed = selectedProviderID
        config.providers.removeValue(forKey: removed)
        Keychain.delete(forProvider: removed)
        if config.activeProvider == removed {
            config.activeProvider = config.orderedProviderIDs.first ?? ""
        }
        selectedProviderID = config.activeProvider
        onConfigChanged?(config)
        reloadAll()
    }

    @objc private func saveKey() {
        let key = keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        do {
            try Keychain.set(key, forProvider: selectedProviderID)
            keyField.stringValue = ""
            keyField.placeholderString = Keychain.masked(forProvider: selectedProviderID)
            report("Key saved. Use Test connection to verify it.", good: true)
            providerTable.reloadData()
        } catch {
            report(error.localizedDescription, good: false)
        }
    }

    @objc private func refreshModels() {
        let id = selectedProviderID
        let config = self.config
        report("Fetching models…", good: true)

        Task { @MainActor in
            do {
                let provider = try ProviderRegistry.make(profileID: id, config: config)
                let models = try await provider.listModels()
                guard !models.isEmpty else {
                    self.report("The provider returned no model list.", good: false)
                    return
                }
                let presets = config.providers[id]?.modelPresets ?? []
                let combined = presets + models.filter { !presets.contains($0) }

                let current = self.modelCombo.stringValue
                self.modelCombo.removeAllItems()
                self.modelCombo.addItems(withObjectValues: combined)
                self.modelCombo.stringValue = current
                self.report("Found \(models.count) models.", good: true)
            } catch {
                self.report(error.localizedDescription, good: false)
            }
        }
    }

    /// Sends a short generated tone through the real transcription path. It is not
    /// speech, so an empty result is a pass: it proves auth, endpoint, and that the
    /// model accepts audio at all.
    @objc private func testConnection() {
        commitProviderEdits()
        let id = selectedProviderID
        let config = self.config
        report("Testing…", good: true)

        Task { @MainActor in
            do {
                let provider = try ProviderRegistry.make(profileID: id, config: config)
                let wav = Self.silentTestWAV(seconds: 1.0)
                let result = try await provider.transcribe(wav: wav, prompt: config.activePrompt)
                self.reportSuccess(result)
            } catch ProviderError.emptyResponse {
                let model = config.providers[id]?.model ?? ""
                let tier = ProviderRegistry.isFreeTierModel(model) ? "free tier" : "paid"
                self.report("✓ Connected — \(model) (\(tier)). It accepted the audio and correctly returned no text for silence.", good: true)
            } catch {
                self.report("✗ \(error.localizedDescription)", good: false)
            }
        }
    }

    private func reportSuccess(_ result: TranscriptionResult) {
        var line = "✓ Connected — \(result.model) · \(result.tokenSummary)"
        if let cost = ProviderRegistry.estimatedCost(for: result) {
            line += " · \(cost)"
        }
        report(line, good: true)
    }

    static func silentTestWAV(seconds: Double) -> Data {
        let frames = Int(AudioRecorder.targetSampleRate * seconds)
        let pcm = Data(count: frames * 2)
        return AudioRecorder.wavData(
            fromPCM16: pcm, sampleRate: AudioRecorder.targetSampleRate, channels: 1
        )
    }

    private func report(_ text: String, good: Bool) {
        testResultLabel.stringValue = text
        testResultLabel.textColor = good ? .systemGreen : .systemRed
    }

    @objc private func showHelp(_ sender: NSButton) { onShowQuickHelp?(sender) }

    // MARK: - Trigger / recording / prompt actions

    @objc private func commitTrigger() {
        let modes: [TriggerMode] = [.triplePress, .holdToTalk, .menuBarOnly]
        config.trigger.mode = modes[max(0, min(modes.count - 1, triggerPopup.indexOfSelectedItem))]
        if let tag = keyCodePopup.selectedItem?.tag { config.trigger.triggerKeyCode = tag }
        config.trigger.tapCount = max(2, Int(tapCountField.stringValue) ?? 3)
        config.trigger.tapWindowSeconds = Double(tapWindowField.stringValue) ?? 0.6
        config.trigger.holdMinSeconds = Double(holdMinField.stringValue) ?? 0.25
        onConfigChanged?(config)
    }

    @objc private func commitRecording() {
        if recDevicePopup.indexOfSelectedItem == 0 {
            config.recording.inputDevice.mode = .systemDefault
            config.recording.inputDevice.preferredUID = nil
        } else if let uid = recDevicePopup.selectedItem?.representedObject as? String {
            config.recording.inputDevice.mode = .preferWhenAvailable
            config.recording.inputDevice.preferredUID = uid
        }
        config.recording.maxSeconds = Double(maxSecondsField.stringValue) ?? 60
        config.recording.silenceStopSeconds = Double(silenceStopField.stringValue) ?? 2.5
        config.recording.minSpeechSeconds = Double(minSpeechField.stringValue) ?? 1.0
        onConfigChanged?(config)
        loadRecordingForm()
    }

    @objc private func thresholdChanged() {
        let value = thresholdSlider.doubleValue
        thresholdLabel.stringValue = String(format: "%.0f dBFS", value)
        meterView.threshold = Float(value)
        // Saved per device, since AirPods and the built-in mic need different values.
        let key = currentDeviceUID ?? "default"
        config.recording.silenceThresholdDb[key] = value
        onConfigChanged?(config)
    }

    @objc private func toggleMeter(_ sender: NSButton) {
        if meterRecorder != nil {
            stopMeter()
            sender.title = "Start meter"
        } else {
            startMeter()
            sender.title = "Stop meter"
        }
    }

    private func startMeter() {
        let recorder = AudioRecorder()
        recorder.onLevel = { [weak self] level in self?.meterView.level = level }
        do {
            var meterConfig = config
            meterConfig.recording.maxSeconds = 600 // effectively no cap while calibrating
            meterConfig.recording.silenceStopSeconds = .greatestFiniteMagnitude
            try recorder.start(config: meterConfig)
            meterRecorder = recorder
        } catch {
            report(error.localizedDescription, good: false)
        }
    }

    private func stopMeter() {
        meterRecorder?.stop(reason: .manual)
        meterRecorder = nil
        meterView.level = -120
    }

    @objc private func restorePrompt() {
        promptTextView.string = config.activeDefaultPrompt
        commitPrompt()
    }

    @objc private func commitPromptAction() { commitPrompt() }

    private func commitPrompt() {
        guard window != nil else { return }
        let text = promptTextView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text != config.activePrompt else { return }
        config.activePrompt = text
        onConfigChanged?(config)
    }

    // MARK: - Layout helpers

    private func verticalForm() -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    private func wrap(_ stack: NSStackView) -> NSView {
        let root = NSView()
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -20),
        ])
        return root
    }

    private func labelled(_ title: String, _ control: NSView, trailing: NSView? = nil) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 12)
        label.alignment = .right
        label.translatesAutoresizingMaskIntoConstraints = false
        label.widthAnchor.constraint(equalToConstant: 170).isActive = true

        control.translatesAutoresizingMaskIntoConstraints = false
        if control is NSTextField || control is NSComboBox {
            control.widthAnchor.constraint(greaterThanOrEqualToConstant: 260).isActive = true
        }

        var views: [NSView] = [label, control]
        if let trailing { views.append(trailing) }

        let row = NSStackView(views: views)
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        return row
    }

    private func hint(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.preferredMaxLayoutWidth = 520
        return label
    }
}

// MARK: - Level meter

/// Live input level with the silence threshold drawn on it, so the threshold can
/// be set against the actual noise floor of the room and device.
final class LevelMeterView: NSView {
    var level: Float = -120 { didSet { needsDisplay = true } }
    var threshold: Float = -45 { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        let bounds = self.bounds

        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4).fill()

        // Map -70..0 dBFS across the width.
        func x(for db: Float) -> CGFloat {
            CGFloat(max(0, min(1, (db + 70) / 70))) * bounds.width
        }

        let filled = NSRect(x: 0, y: 0, width: x(for: level), height: bounds.height)
        (level > threshold ? NSColor.systemGreen : NSColor.systemGray).setFill()
        NSBezierPath(roundedRect: filled, xRadius: 4, yRadius: 4).fill()

        let markerX = x(for: threshold)
        NSColor.systemRed.setStroke()
        let line = NSBezierPath()
        line.move(to: NSPoint(x: markerX, y: 0))
        line.line(to: NSPoint(x: markerX, y: bounds.height))
        line.lineWidth = 2
        line.stroke()
    }
}
