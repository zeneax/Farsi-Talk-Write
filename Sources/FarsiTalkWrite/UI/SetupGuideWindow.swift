//
//  SetupGuideWindow.swift
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

/// First-run, step-by-step setup. Opens by itself when there is no config or no
/// API key, and is reachable any time from the menu.
///
/// Every step verifies itself live rather than just telling you what to do, so the
/// checklist always reflects reality — which also makes it the troubleshooting tool
/// when something breaks months later.
@MainActor
final class SetupGuideWindow: NSObject, NSWindowDelegate {

    var config: Config { didSet { refresh() } }

    var onConfigChanged: ((Config) -> Void)?
    var onOpenSettings: (() -> Void)?
    /// `true` asks the controller to hand the transcript back instead of pasting it,
    /// so step 6 can show the result in its own field.
    var onRequestDictation: ((Bool) -> Void)?
    var onFinished: (() -> Void)?

    private var window: NSWindow?
    private var stepIndex = 0

    private let stepList = NSStackView()
    private let detailContainer = NSView()
    private let backButton = NSButton()
    private let nextButton = NSButton()

    // Step 2
    private let providerPopup = NSPopUpButton()
    private let modelPopup = NSPopUpButton()
    private let keyField = NSSecureTextField()
    private let keyResultLabel = NSTextField(wrappingLabelWithString: "")
    // Step 5
    private let devicePopup = NSPopUpButton()
    // Step 6
    private let practiceField = NSTextView()
    private let dictationStatusLabel = NSTextField(wrappingLabelWithString: "")

    private var refreshTimer: Timer?

    private enum Step: Int, CaseIterable {
        case apiKey, pasteKey, globeKey, permissions, microphone, tryIt

        var title: String {
            switch self {
            case .apiKey:      return "Get an API key"
            case .pasteKey:    return "Paste your key"
            case .globeKey:    return "Free the Globe key"
            case .permissions: return "Grant permissions"
            case .microphone:  return "Choose your microphone"
            case .tryIt:       return "Try it out"
            }
        }
    }

    init(config: Config) {
        self.config = config
        super.init()
    }

    // MARK: - Presentation

    func present() {
        if window == nil { build() }
        refresh()
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        // Permissions are granted in another app; poll so rows tick over without
        // the user having to come back and press anything.
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        refreshTimer?.invalidate()
        refreshTimer = nil
        onFinished?()
    }

    func receiveTranscript(_ text: String) {
        practiceField.string = text
        refresh()
    }

    /// Live pipeline state, so step 6 shows what is happening instead of looking
    /// like a button that does nothing.
    func updateDictationState(_ state: DictationController.State) {
        switch state {
        case .idle:
            dictationStatusLabel.stringValue = ""
        case .recording(let elapsed, let level):
            dictationStatusLabel.stringValue = String(
                format: "● Recording %.0fs — input level %.0f dBFS", elapsed, Double(level)
            )
            dictationStatusLabel.textColor = .systemRed
        case .transcribingChunks(let done, let total):
            dictationStatusLabel.stringValue = "Long recording split into \(total) parts — \(done) done…"
            dictationStatusLabel.textColor = .systemOrange
        case .transcribing(let attempt, let total, let elapsed):
            _ = elapsed
            dictationStatusLabel.stringValue = attempt == 1
                ? "Sending audio to \(config.activeProfile?.model ?? "the model")…"
                : "Send failed — retrying (attempt \(attempt) of \(total))…"
            dictationStatusLabel.textColor = .systemOrange
        case .inserted:
            dictationStatusLabel.stringValue = "✓ Done"
            dictationStatusLabel.textColor = .systemGreen
        case .copiedToClipboard:
            dictationStatusLabel.stringValue = "✓ Copied to clipboard (nothing was focused to type into)"
            dictationStatusLabel.textColor = .systemGreen
        case .failed(let why):
            dictationStatusLabel.stringValue = "✗ \(why)"
            dictationStatusLabel.textColor = .systemRed
        }
    }

    // MARK: - Build

    private func build() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 480),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "FarsiTalkWrite Setup"
        window.delegate = self
        window.isReleasedWhenClosed = false

        // The guide tells you to go into System Settings and come back, so it has
        // to survive losing focus. Floating keeps it on top for the duration; the
        // Dock icon (see AppDelegate.updateActivationPolicy) is the backstop.
        window.level = .floating
        window.hidesOnDeactivate = false

        let root = NSView()

        // Left: the checklist
        stepList.orientation = .vertical
        stepList.alignment = .leading
        stepList.spacing = 4
        stepList.edgeInsets = NSEdgeInsets(top: 20, left: 16, bottom: 16, right: 16)
        stepList.translatesAutoresizingMaskIntoConstraints = false

        let sidebar = NSVisualEffectView()
        sidebar.material = .sidebar
        sidebar.blendingMode = .behindWindow
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        sidebar.addSubview(stepList)

        // Right: the detail pane for the selected step
        detailContainer.translatesAutoresizingMaskIntoConstraints = false

        // Footer
        backButton.title = "Back"
        backButton.bezelStyle = .rounded
        backButton.target = self
        backButton.action = #selector(goBack)

        nextButton.title = "Next"
        nextButton.bezelStyle = .rounded
        nextButton.keyEquivalent = "\r"
        nextButton.target = self
        nextButton.action = #selector(goNext)

        let recheck = NSButton(title: "Recheck all", target: self, action: #selector(refreshNow))
        recheck.bezelStyle = .rounded

        let footer = NSStackView(views: [recheck, NSView(), backButton, nextButton])
        footer.orientation = .horizontal
        footer.spacing = 10
        footer.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(sidebar)
        root.addSubview(detailContainer)
        root.addSubview(footer)

        NSLayoutConstraint.activate([
            sidebar.topAnchor.constraint(equalTo: root.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            sidebar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 230),

            stepList.topAnchor.constraint(equalTo: sidebar.topAnchor),
            stepList.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor),
            stepList.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor),

            detailContainer.topAnchor.constraint(equalTo: root.topAnchor, constant: 20),
            detailContainer.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: 24),
            detailContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            detailContainer.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -16),

            footer.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: 24),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -20),
        ])

        window.contentView = root
        self.window = window
    }

    // MARK: - Refresh

    @objc private func refreshNow() { refresh() }

    private func refresh() {
        guard window != nil else { return }
        rebuildStepList()
        rebuildDetail()

        backButton.isEnabled = stepIndex > 0
        nextButton.title = stepIndex == Step.allCases.count - 1 ? "Done" : "Next"
    }

    private func rebuildStepList() {
        stepList.arrangedSubviews.forEach { $0.removeFromSuperview() }

        for step in Step.allCases {
            // Input Monitoring and the 🌐 key are irrelevant in menu-bar-only mode.
            // Skipped for any trigger that leaves a bare press to macOS.
            if step == .globeKey,
               !Permissions.status(triggerMode: config.trigger.mode,
                                   triggerKeyCode: config.trigger.triggerKeyCode).needsGlobeKeyFree {
                continue
            }

            let mark: String
            if step.rawValue == stepIndex {
                mark = "→"
            } else if isComplete(step) {
                mark = "✓"
            } else if step.rawValue < stepIndex {
                mark = "✗"
            } else {
                mark = "○"
            }

            let button = NSButton(
                title: "  \(mark)  \(step.rawValue + 1). \(step.title)",
                target: self, action: #selector(selectStep(_:))
            )
            button.tag = step.rawValue
            button.bezelStyle = .inline
            button.isBordered = false
            button.alignment = .left
            button.contentTintColor = step.rawValue == stepIndex ? .controlAccentColor : .labelColor
            button.font = .systemFont(
                ofSize: 13,
                weight: step.rawValue == stepIndex ? .semibold : .regular
            )
            stepList.addArrangedSubview(button)
        }
    }

    @objc private func selectStep(_ sender: NSButton) {
        stepIndex = sender.tag
        refresh()
    }

    @objc private func goBack() {
        stepIndex = max(0, stepIndex - 1)
        refresh()
    }

    @objc private func goNext() {
        if stepIndex >= Step.allCases.count - 1 {
            window?.performClose(nil)
            return
        }
        stepIndex += 1
        // Skip the 🌐 step when it does not apply.
        if Step(rawValue: stepIndex) == .globeKey, config.trigger.mode == .menuBarOnly {
            stepIndex += 1
        }
        refresh()
    }

    // MARK: - Verification

    private func isComplete(_ step: Step) -> Bool {
        switch step {
        case .apiKey, .pasteKey:
            return Keychain.hasKey(forProvider: config.activeProvider)
        case .globeKey:
            return !Permissions.status(triggerMode: config.trigger.mode,
                                       triggerKeyCode: config.trigger.triggerKeyCode).needsGlobeKeyFree
                || Permissions.fnKeyIsFree
        case .permissions:
            return Permissions.status(triggerMode: config.trigger.mode, triggerKeyCode: config.trigger.triggerKeyCode).isReady
        case .microphone:
            return AudioDeviceManager.resolveInputDevice(config.recording.inputDevice) != nil
        case .tryIt:
            return !practiceField.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    // MARK: - Detail panes

    private func rebuildDetail() {
        detailContainer.subviews.forEach { $0.removeFromSuperview() }
        guard let step = Step(rawValue: stepIndex) else { return }

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        stack.addArrangedSubview(heading(step.title))

        switch step {
        case .apiKey:      buildAPIKeyStep(into: stack)
        case .pasteKey:    buildPasteKeyStep(into: stack)
        case .globeKey:    buildGlobeKeyStep(into: stack)
        case .permissions: buildPermissionsStep(into: stack)
        case .microphone:  buildMicrophoneStep(into: stack)
        case .tryIt:       buildTryItStep(into: stack)
        }

        detailContainer.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: detailContainer.topAnchor),
            stack.leadingAnchor.constraint(equalTo: detailContainer.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: detailContainer.trailingAnchor),
        ])
    }

    /// Step 1 is spelled out literally, because this is where a new user stalls.
    private func buildAPIKeyStep(into stack: NSStackView) {
        stack.addArrangedSubview(body("""
        1.  Click Open Google AI Studio below.
        2.  Sign in with any Google account.
        3.  Click Create API key.
        4.  Choose Create API key in a new project.
        5.  Do not enable billing — that is what keeps it free.
        6.  Copy the key. It may start with “AQ.” or “AIza” — both are valid.
        """))

        let open = NSButton(title: "Open Google AI Studio", target: self, action: #selector(openAIStudio))
        open.bezelStyle = .rounded
        stack.addArrangedSubview(open)

        stack.addArrangedSubview(note("""
        Want the paid Pro model too? Repeat these steps in a project that has \
        billing enabled, and save that second key under the “Google — Paid” \
        provider. Skip this for now — the free model is good.
        """))
    }

    private func buildPasteKeyStep(into stack: NSStackView) {
        stack.addArrangedSubview(body("Paste the key you just copied. It is stored in your macOS Keychain, never in a file."))

        // Explicit provider choice: each profile keeps its own key, so it must be
        // obvious which one is being filled in — and switchable without leaving
        // the guide.
        providerPopup.removeAllItems()
        for id in config.orderedProviderIDs {
            guard let profile = config.providers[id] else { continue }
            let mark = Keychain.hasKey(forProvider: id) ? "✓ " : "   "
            providerPopup.addItem(withTitle: "\(mark)\(profile.displayName)")
            providerPopup.lastItem?.representedObject = id
        }
        if let index = config.orderedProviderIDs.firstIndex(of: config.activeProvider) {
            providerPopup.selectItem(at: index)
        }
        providerPopup.target = self
        providerPopup.action = #selector(providerChanged)

        let row = NSStackView(views: [NSTextField(labelWithString: "Provider:"), providerPopup])
        row.orientation = .horizontal
        row.spacing = 8
        stack.addArrangedSubview(row)

        if let note = config.activeProfile?.note {
            stack.addArrangedSubview(self.note(note))
        }

        keyField.placeholderString = "AQ.… or AIza…"
        keyField.translatesAutoresizingMaskIntoConstraints = false
        keyField.widthAnchor.constraint(equalToConstant: 380).isActive = true
        if Keychain.hasKey(forProvider: config.activeProvider), keyField.stringValue.isEmpty {
            keyField.placeholderString = Keychain.masked(forProvider: config.activeProvider)
        }
        stack.addArrangedSubview(keyField)

        let save = NSButton(title: "Save & Test", target: self, action: #selector(saveAndTestKey))
        save.bezelStyle = .rounded
        save.keyEquivalent = "\r"
        stack.addArrangedSubview(save)

        keyResultLabel.font = .systemFont(ofSize: 12)
        stack.addArrangedSubview(keyResultLabel)

        // Model choice lives here too, so the whole "which LLM am I using" decision
        // is visible at the moment the key is entered rather than buried elsewhere.
        modelPopup.removeAllItems()
        if let profile = config.activeProfile {
            var models = profile.modelPresets
            if !models.contains(profile.model) { models.insert(profile.model, at: 0) }
            modelPopup.addItems(withTitles: models)
            modelPopup.selectItem(withTitle: profile.model)
        }
        modelPopup.target = self
        modelPopup.action = #selector(modelChanged)

        let modelRow = NSStackView(views: [NSTextField(labelWithString: "Model:"), modelPopup])
        modelRow.orientation = .horizontal
        modelRow.spacing = 8
        stack.addArrangedSubview(modelRow)

        let settings = NSButton(
            title: "More options (Settings)…",
            target: self, action: #selector(openSettingsFromGuide)
        )
        settings.bezelStyle = .rounded
        stack.addArrangedSubview(settings)
    }

    @objc private func providerChanged() {
        guard let id = providerPopup.selectedItem?.representedObject as? String else { return }
        config.activeProvider = id
        onConfigChanged?(config)
        refresh()
    }

    @objc private func modelChanged() {
        guard let model = modelPopup.selectedItem?.title else { return }
        config.providers[config.activeProvider]?.model = model
        onConfigChanged?(config)
    }

    @objc private func openSettingsFromGuide() { onOpenSettings?() }

    private func buildGlobeKeyStep(into stack: NSStackView) {
        let current = Permissions.fnKeyUsage
        let currentLabel = current.map { "\($0.label)" } ?? "system default"

        stack.addArrangedSubview(body("""
        The 🌐 key currently does: \(currentLabel)

        FarsiTalkWrite watches this key without swallowing it, so macOS still \
        performs whatever action is assigned. Set it to “Do Nothing” or the emoji \
        picker will open every time you dictate and steal your cursor.
        """))

        stack.addArrangedSubview(note("Set: \(Permissions.SettingsPane.keyboard.clickPath) → Do Nothing"))

        let open = NSButton(title: "Open Keyboard Settings", target: self, action: #selector(openKeyboardSettings))
        open.bezelStyle = .rounded
        stack.addArrangedSubview(open)

        stack.addArrangedSubview(status(
            Permissions.fnKeyIsFree ? "✓ The 🌐 key is free." : "✗ Still set to “\(currentLabel)”.",
            good: Permissions.fnKeyIsFree
        ))

        let skip = NSButton(
            title: "Skip — use the menu bar icon instead",
            target: self, action: #selector(skipGlobeKey)
        )
        skip.bezelStyle = .rounded
        stack.addArrangedSubview(skip)
    }

    private func buildPermissionsStep(into stack: NSStackView) {
        let state = Permissions.status(triggerMode: config.trigger.mode, triggerKeyCode: config.trigger.triggerKeyCode)

        stack.addArrangedSubview(body("These are the only permissions FarsiTalkWrite needs. Each says why."))

        stack.addArrangedSubview(permissionRow(
            "Microphone", "to hear you",
            state.microphone, pane: .microphone, action: #selector(grantMicrophone)
        ))
        stack.addArrangedSubview(permissionRow(
            "Accessibility", "to type text into other apps",
            state.accessibility, pane: .accessibility, action: #selector(grantAccessibility)
        ))

        if state.needsInputMonitoring {
            stack.addArrangedSubview(permissionRow(
                "Input Monitoring", "to see the 🌐 key — only that one key",
                state.inputMonitoring, pane: .inputMonitoring, action: #selector(grantInputMonitoring)
            ))
        }

        stack.addArrangedSubview(note("""
        After granting a permission the checkmark here updates on its own.

        If Accessibility will not take — the toggle springs back, or the app is \
        not in the list — add it by hand:
          1.  Open the pane with the button below.
          2.  If “FarsiTalkWrite” is already listed, select it and press “−” to \
        remove the stale entry first.
          3.  Press “+”, then choose /Applications/FarsiTalkWrite.app.
          4.  Make sure its switch is ON.
        """))

        let revealRow = NSStackView(views: [
            NSButton(title: "Open Accessibility settings", target: self,
                     action: #selector(openAccessibilityPane)),
            NSButton(title: "Reveal app in Finder", target: self,
                     action: #selector(revealAppInFinder)),
        ])
        revealRow.orientation = .horizontal
        revealRow.spacing = 8
        stack.addArrangedSubview(revealRow)
    }

    private func buildMicrophoneStep(into stack: NSStackView) {
        stack.addArrangedSubview(body("Pick which microphone to record from."))

        devicePopup.removeAllItems()
        devicePopup.addItem(withTitle: "Follow system default")

        let devices = AudioDeviceManager.allInputDevices()
        for device in devices {
            devicePopup.addItem(
                withTitle: "\(device.name) — \(device.transport.label), \(Int(device.sampleRate)) Hz"
            )
            devicePopup.lastItem?.representedObject = device.uid
        }

        if config.recording.inputDevice.mode != .systemDefault,
           let uid = config.recording.inputDevice.preferredUID,
           let index = devices.firstIndex(where: { $0.uid == uid }) {
            devicePopup.selectItem(at: index + 1)
        } else {
            devicePopup.selectItem(at: 0)
        }

        devicePopup.target = self
        devicePopup.action = #selector(deviceChanged)
        stack.addArrangedSubview(devicePopup)

        stack.addArrangedSubview(note("""
        Choosing a specific device uses “prefer when available”: FarsiTalkWrite \
        uses it when connected and falls back to the built-in mic when it is not. \
        AirPods report a lower sample rate than the built-in mic; that is normal \
        and handled automatically.
        """))

        if let active = AudioDeviceManager.resolveInputDevice(config.recording.inputDevice) {
            stack.addArrangedSubview(status(
                "✓ Will record from: \(active.name) (\(active.transport.label))", good: true
            ))
        } else {
            stack.addArrangedSubview(status("✗ No input device found.", good: false))
        }
    }

    private func buildTryItStep(into stack: NSStackView) {
        stack.addArrangedSubview(body("""
        Start a dictation and speak a sentence in Farsi. The text appears below \
        rather than in another app, so you can confirm everything works before \
        using it for real.
        """))

        // Blocked-state warning up front, so a dead-looking button is explained
        // before it is pressed rather than after.
        var blockers: [String] = []
        if !Permissions.microphone.isGranted {
            blockers.append("Microphone permission is not granted (step 4).")
        }
        if !Keychain.hasKey(forProvider: config.activeProvider) {
            let name = config.activeProfile?.displayName ?? config.activeProvider
            blockers.append("No API key saved for “\(name)” (step 2).")
        }
        if !blockers.isEmpty {
            stack.addArrangedSubview(status(
                "Dictation cannot run yet:\n  • " + blockers.joined(separator: "\n  • "),
                good: false
            ))
        }

        let start = NSButton(title: "Start Dictation", target: self, action: #selector(tryDictation))
        start.bezelStyle = .rounded
        start.isEnabled = blockers.isEmpty
        stack.addArrangedSubview(start)

        dictationStatusLabel.font = .systemFont(ofSize: 12, weight: .medium)
        dictationStatusLabel.preferredMaxLayoutWidth = 440
        stack.addArrangedSubview(dictationStatusLabel)

        practiceField.isEditable = true
        practiceField.font = .systemFont(ofSize: 14)
        practiceField.baseWritingDirection = .rightToLeft
        practiceField.string = practiceField.string

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = practiceField
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: 120).isActive = true
        scroll.widthAnchor.constraint(equalToConstant: 440).isActive = true
        stack.addArrangedSubview(scroll)

        stack.addArrangedSubview(note("""
        Once this works, dictation goes wherever your cursor is — a Claude Code \
        prompt, a browser text box, Notes. Right-click the 🎙 in the menu bar for \
        Quick Help any time.
        """))
    }

    // MARK: - Actions

    @objc private func openAIStudio() {
        if let url = URL(string: "https://aistudio.google.com/apikey") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openKeyboardSettings() {
        dropFloatingLevelWhileGranting()
        Permissions.open(.keyboard)
    }

    @objc private func openAccessibilityPane() {
        dropFloatingLevelWhileGranting()
        Permissions.open(.accessibility)
    }

    /// Opens Finder with the app selected, so it can be dragged straight into the
    /// Accessibility list when the "+" file picker is fiddly.
    @objc private func revealAppInFinder() {
        let url = Bundle.main.bundleURL
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    @objc private func grantMicrophone() {
        Task { @MainActor in
            if Permissions.microphone == .notDetermined {
                self.dropFloatingLevelWhileGranting()
                _ = await Permissions.requestMicrophone()
            } else {
                self.dropFloatingLevelWhileGranting()
                Permissions.open(.microphone)
            }
            self.refresh()
        }
    }

    @objc private func grantAccessibility() {
        guard !Permissions.accessibility.isGranted else {
            Permissions.open(.accessibility)
            return
        }

        // Only Apple's own prompt, and nothing else. Opening System Settings at the
        // same time races it: the settings window takes the foreground and the
        // prompt is dismissed before it can be used. The prompt already contains
        // the correct "Open System Settings" button, and the side effect that
        // matters is that it registers the app in the Accessibility list at all.
        dropFloatingLevelWhileGranting()
        Permissions.requestAccessibility()
    }

    /// The guide floats above other windows so it survives a trip to System
    /// Settings, but that also puts it above the permission sheets themselves.
    /// Drop to a normal level briefly whenever we hand off to the system.
    private func dropFloatingLevelWhileGranting() {
        window?.level = .normal
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            self?.window?.level = .floating
        }
    }

    @objc private func grantInputMonitoring() {
        if Permissions.inputMonitoring == .notDetermined {
            Permissions.requestInputMonitoring()
        } else {
            Permissions.open(.inputMonitoring)
        }
    }

    @objc private func skipGlobeKey() {
        config.trigger.mode = .menuBarOnly
        onConfigChanged?(config)
        goNext()
    }

    @objc private func deviceChanged() {
        if devicePopup.indexOfSelectedItem == 0 {
            config.recording.inputDevice.mode = .systemDefault
            config.recording.inputDevice.preferredUID = nil
        } else if let uid = devicePopup.selectedItem?.representedObject as? String {
            config.recording.inputDevice.mode = .preferWhenAvailable
            config.recording.inputDevice.preferredUID = uid
        }
        onConfigChanged?(config)
    }

    @objc private func tryDictation() {
        onRequestDictation?(true)
    }

    @objc private func saveAndTestKey() {
        let key = keyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            show(result: "Enter a key first.", good: false)
            return
        }

        do {
            try Keychain.set(key, forProvider: config.activeProvider)
        } catch {
            show(result: "✗ Could not save to Keychain: \(error.localizedDescription)", good: false)
            return
        }

        keyField.stringValue = ""
        show(result: "Testing…", good: true)

        let config = self.config
        Task { @MainActor in
            do {
                let provider = try ProviderRegistry.makeActive(config: config)
                let models = try await provider.listModels()
                let model = config.activeProfile?.model ?? ""
                let tier = ProviderRegistry.isFreeTierModel(model) ? "Free tier" : "Paid"

                if models.isEmpty {
                    self.show(result: "✓ Connected. \(tier), \(model).", good: true)
                } else if models.contains(model) {
                    self.show(result: "✓ Connected. \(tier), \(model).", good: true)
                } else {
                    self.show(
                        result: "✓ Key works, but “\(model)” was not in this account’s model list. Change it in Settings if transcription fails.",
                        good: true
                    )
                }
            } catch {
                self.show(result: "✗ \(error.localizedDescription)", good: false)
            }
            self.refresh()
        }
    }

    private func show(result: String, good: Bool) {
        keyResultLabel.stringValue = result
        keyResultLabel.textColor = good ? .systemGreen : .systemRed
    }

    // MARK: - Builders

    private func heading(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 18, weight: .semibold)
        return label
    }

    private func body(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 13)
        label.preferredMaxLayoutWidth = 440
        return label
    }

    private func note(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.preferredMaxLayoutWidth = 440
        return label
    }

    private func status(_ text: String, good: Bool) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = good ? .systemGreen : .systemRed
        label.preferredMaxLayoutWidth = 440
        return label
    }

    private func permissionRow(
        _ name: String, _ why: String,
        _ state: PermissionState,
        pane: Permissions.SettingsPane,
        action: Selector
    ) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10

        let mark = NSTextField(labelWithString: state.symbol)
        mark.font = .systemFont(ofSize: 14, weight: .bold)
        mark.textColor = state.isGranted ? .systemGreen : .systemRed
        mark.widthAnchor.constraint(equalToConstant: 16).isActive = true

        let text = NSTextField(labelWithString: "\(name) — \(why)")
        text.font = .systemFont(ofSize: 13)

        let button = NSButton(
            title: state.isGranted ? "Open" : "Grant",
            target: self, action: action
        )
        button.bezelStyle = .rounded

        row.addArrangedSubview(mark)
        row.addArrangedSubview(text)
        row.addArrangedSubview(NSView())
        row.addArrangedSubview(button)
        return row
    }
}
