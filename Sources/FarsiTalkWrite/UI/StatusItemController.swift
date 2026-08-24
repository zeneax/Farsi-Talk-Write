import AppKit

/// The menu bar icon. It is both a status readout and a fully independent trigger,
/// so the app is usable before the fn key permissions are sorted out.
///
/// Left-click toggles recording outright rather than opening a menu — that is what
/// makes it a real trigger. The menu lives on right-click.
final class StatusItemController {

    var onToggleRecording: (() -> Void)?
    var onRetryLast: (() -> Void)?
    /// How many recordings are saved but not yet successfully transcribed.
    var pendingRetryCount = 0
    var hasRecordingToRetry: Bool { pendingRetryCount > 0 }
    var onSelectProvider: ((String) -> Void)?
    var onSelectModel: ((String) -> Void)?
    var onSelectTrigger: ((TriggerMode) -> Void)?
    var onSelectLanguage: ((DictationLanguage) -> Void)?
    var onToggleHUD: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onOpenSetupGuide: (() -> Void)?
    var onOpenQuickHelp: ((NSStatusBarButton) -> Void)?
    var onQuit: (() -> Void)?

    var config: Config

    private let statusItem: NSStatusItem
    private var state: DictationController.State = .idle
    private var pulseTimer: Timer?
    private var pulsePhase = 0

    init(config: Config) {
        self.config = config
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        statusItem.isVisible = true

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(buttonClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        } else {
            FTWLog.error("Status item has no button — the menu bar icon will not appear.")
        }
        render()

        // Where macOS actually placed the item. On a notched MacBook a crowded
        // menu bar can push new items underneath the notch, where they exist and
        // report themselves visible but cannot be seen or clicked. Comparing the
        // button's screen frame against the screen width is the only way to tell
        // that apart from a rendering failure.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.checkPlacement()
        }
    }

    /// Whether the item actually made it onto the visible menu bar.
    private(set) var isPlacedOnMenuBar = true

    /// Called after layout has settled. A status item on a full menu bar is still
    /// created and still reports `isVisible == true`; the giveaway is that its
    /// button is never assigned a real on-screen position.
    var onPlacementChecked: ((Bool) -> Void)?

    private func checkPlacement() {
        guard let button = statusItem.button, let window = button.window else {
            isPlacedOnMenuBar = false
            onPlacementChecked?(false)
            return
        }

        let onScreen = window.convertToScreen(button.convert(button.bounds, to: nil))
        let screenWidth = NSScreen.main?.frame.width ?? 0
        let rightArea = NSScreen.main?.auxiliaryTopRightArea?.width

        // A placed item has a positive x somewhere along the bar and a y up at the
        // top of the screen. Origin-ish coordinates mean it was never laid out.
        let placed = onScreen.origin.x > 0 && onScreen.origin.y > 0
        isPlacedOnMenuBar = placed

        FTWLog.info("""
        STATUSITEM placed=\(placed) length=\(statusItem.length) visible=\(statusItem.isVisible) \
        hasImage=\(button.image != nil) buttonFrame=\(NSStringFromRect(onScreen)) \
        screenWidth=\(screenWidth) menuBarRightArea=\(rightArea.map(String.init) ?? "none")
        """)

        if !placed {
            FTWLog.warn("""
            The menu bar icon could not be placed — the menu bar is full (likely \
            hidden behind the notch). Keeping a Dock icon so the app stays reachable.
            """)
        }
        onPlacementChecked?(placed)
    }

    // MARK: - Click routing

    @objc private func buttonClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        let isRightClick = event?.type == .rightMouseUp
            || event?.modifierFlags.contains(.command) == true

        if isRightClick {
            showMenu()
        } else {
            onToggleRecording?()
        }
    }

    private func showMenu() {
        let menu = buildMenu()
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        // Detach immediately so the next left-click reaches our action again
        // instead of re-opening the menu.
        statusItem.menu = nil
    }

    // MARK: - State rendering

    func update(state: DictationController.State) {
        self.state = state
        switch state {
        case .recording, .transcribing: startPulse()
        default: stopPulse()
        }
        render()
    }

    private func render() {
        guard let button = statusItem.button else { return }

        let symbol: String
        let tint: NSColor?
        var title = ""

        switch state {
        case .idle:
            symbol = "mic"
            tint = nil
        case .recording(let elapsed, _):
            symbol = "mic.fill"
            tint = .systemRed
            // Elapsed shown here too, so the countdown is visible even with the
            // HUD switched off.
            title = " \(Self.mmss(elapsed))"
        case .transcribing:
            symbol = "waveform"
            tint = .systemOrange
        case .inserted:
            symbol = "checkmark.circle.fill"
            tint = .systemGreen
        case .failed:
            symbol = "exclamationmark.triangle.fill"
            tint = .systemRed
        }

        button.contentTintColor = tint

        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "FarsiTalkWrite") {
            image.isTemplate = (tint == nil)
            button.image = image
            button.title = title
            button.imagePosition = title.isEmpty ? .imageOnly : .imageLeading
        } else {
            // An image-only button with a nil image is zero-width and therefore
            // invisible in the menu bar, which looks exactly like a crash. Always
            // leave something drawable behind.
            FTWLog.warn("SF Symbol “\(symbol)” unavailable; falling back to a text status item.")
            button.image = nil
            button.imagePosition = .noImage
            button.title = title.isEmpty ? "ف" : "ف\(title)"
        }

        if case .failed(let why) = state {
            button.toolTip = why
        } else {
            button.toolTip = "FarsiTalkWrite — click to dictate, right-click for options"
        }
    }

    private func startPulse() {
        guard pulseTimer == nil else { return }
        pulseTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            guard let self, let button = self.statusItem.button else { return }
            self.pulsePhase = (self.pulsePhase + 1) % 2
            button.alphaValue = self.pulsePhase == 0 ? 1.0 : 0.55
        }
    }

    private func stopPulse() {
        pulseTimer?.invalidate()
        pulseTimer = nil
        statusItem.button?.alphaValue = 1.0
    }

    // MARK: - Menu

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        menu.addItem(disabledItem(statusLine))
        menu.addItem(.separator())

        let toggle = NSMenuItem(
            title: state.isRecording ? "Stop Recording" : "Start Recording",
            action: #selector(menuToggle), keyEquivalent: ""
        )
        toggle.target = self
        menu.addItem(toggle)

        if hasRecordingToRetry {
            let retry = NSMenuItem(
                title: pendingRetryCount > 1
                    ? "Retry last recording (\(pendingRetryCount) saved)"
                    : "Retry last recording",
                action: #selector(menuRetry), keyEquivalent: ""
            )
            retry.target = self
            menu.addItem(retry)
        }

        menu.addItem(.separator())
        menu.addItem(languageMenuItem())
        menu.addItem(providerMenuItem())
        menu.addItem(modelMenuItem())
        menu.addItem(triggerMenuItem())

        let hud = NSMenuItem(title: "Show Timer HUD", action: #selector(menuToggleHUD), keyEquivalent: "")
        hud.target = self
        hud.state = config.hud.enabled ? .on : .off
        menu.addItem(hud)

        menu.addItem(.separator())
        menu.addItem(item("Quick Help", #selector(menuQuickHelp)))
        menu.addItem(item("Setup Guide…", #selector(menuSetupGuide)))
        menu.addItem(item("Settings…", #selector(menuSettings), key: ","))

        menu.addItem(.separator())
        menu.addItem(item("Quit FarsiTalkWrite", #selector(menuQuit), key: "q"))

        return menu
    }

    private var statusLine: String {
        switch state {
        case .idle:
            let profile = config.activeProfile
            return "Ready · \(config.language.displayName) · \(profile?.model ?? "no provider")"
        case .recording(let elapsed, _):
            return "Recording \(Self.mmss(elapsed)) / \(Self.mmss(config.recording.maxSeconds))"
        case .transcribing:
            return "Transcribing…"
        case .inserted:
            return "Inserted ✓"
        case .failed(let why):
            return "Error: \(why.prefix(60))"
        }
    }

    private func languageMenuItem() -> NSMenuItem {
        let parent = NSMenuItem(title: "Language", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for language in DictationLanguage.allCases {
            let entry = NSMenuItem(
                title: language.displayName,
                action: #selector(menuPickLanguage(_:)), keyEquivalent: ""
            )
            entry.target = self
            entry.representedObject = language.rawValue
            entry.state = (language == config.language) ? .on : .off
            submenu.addItem(entry)
        }
        parent.submenu = submenu
        return parent
    }

    @objc private func menuPickLanguage(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let language = DictationLanguage(rawValue: raw) else { return }
        onSelectLanguage?(language)
    }

    private func providerMenuItem() -> NSMenuItem {
        let parent = NSMenuItem(title: "Provider", action: nil, keyEquivalent: "")
        let submenu = NSMenu()

        for id in config.orderedProviderIDs {
            guard let profile = config.providers[id] else { continue }
            let hasKey = Keychain.hasKey(forProvider: id)
            let title = hasKey ? profile.displayName : "\(profile.displayName) — no key"

            let entry = NSMenuItem(title: title, action: #selector(menuPickProvider(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = id
            entry.state = (id == config.activeProvider) ? .on : .off
            // Deliberately selectable even without a key: you have to be able to
            // switch to a provider in order to configure one. The "— no key"
            // suffix carries the warning instead of a disabled row.
            entry.isEnabled = true
            submenu.addItem(entry)
        }

        submenu.addItem(.separator())
        submenu.addItem(item("Manage Providers…", #selector(menuSettings)))

        parent.submenu = submenu
        return parent
    }

    private func modelMenuItem() -> NSMenuItem {
        let parent = NSMenuItem(title: "Model", action: nil, keyEquivalent: "")
        let submenu = NSMenu()

        guard let profile = config.activeProfile else {
            submenu.addItem(disabledItem("No active provider"))
            parent.submenu = submenu
            return parent
        }

        // Presets, plus the current model if it is something hand-typed.
        var models = profile.modelPresets
        if !models.contains(profile.model) { models.insert(profile.model, at: 0) }

        for model in models {
            let entry = NSMenuItem(title: model, action: #selector(menuPickModel(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = model
            entry.state = (model == profile.model) ? .on : .off
            submenu.addItem(entry)
        }

        submenu.addItem(.separator())
        submenu.addItem(item("Choose Another…", #selector(menuSettings)))

        parent.submenu = submenu
        return parent
    }

    private func triggerMenuItem() -> NSMenuItem {
        let parent = NSMenuItem(title: "Trigger", action: nil, keyEquivalent: "")
        let submenu = NSMenu()

        let keyName = HotkeyMonitor.keyName(for: config.trigger.triggerKeyCode)
        let options: [(TriggerMode, String)] = [
            (.triplePress, "Triple-press \(keyName)"),
            (.holdToTalk, "Hold \(keyName)"),
            (.menuBarOnly, "Menu bar only"),
        ]

        for (mode, title) in options {
            let entry = NSMenuItem(title: title, action: #selector(menuPickTrigger(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = mode.rawValue
            entry.state = (mode == config.trigger.mode) ? .on : .off
            submenu.addItem(entry)
        }

        parent.submenu = submenu
        return parent
    }

    // MARK: - Menu helpers

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
        entry.target = self
        return entry
    }

    private func disabledItem(_ title: String) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        entry.isEnabled = false
        return entry
    }

    // MARK: - Actions

    @objc private func menuToggle() { onToggleRecording?() }
    @objc private func menuRetry() { onRetryLast?() }
    @objc private func menuToggleHUD() { onToggleHUD?() }
    @objc private func menuSettings() { onOpenSettings?() }
    @objc private func menuSetupGuide() { onOpenSetupGuide?() }
    @objc private func menuQuit() { onQuit?() }

    @objc private func menuQuickHelp() {
        guard let button = statusItem.button else { return }
        onOpenQuickHelp?(button)
    }

    @objc private func menuPickProvider(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        onSelectProvider?(id)
    }

    @objc private func menuPickModel(_ sender: NSMenuItem) {
        guard let model = sender.representedObject as? String else { return }
        onSelectModel?(model)
    }

    @objc private func menuPickTrigger(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = TriggerMode(rawValue: raw) else { return }
        onSelectTrigger?(mode)
    }

    static func mmss(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
