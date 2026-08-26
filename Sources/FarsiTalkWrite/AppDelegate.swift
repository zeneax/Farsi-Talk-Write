//
//  AppDelegate.swift
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

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var config = ConfigStore.load()

    private var controller: DictationController!
    private var statusItem: StatusItemController!
    private let hud = RecordingHUD()
    private let quickHelp = QuickHelpPopover()

    private var settingsWindow: SettingsWindow?
    private var setupGuide: SetupGuideWindow?

    private var settingsOpen = false { didSet { updateActivationPolicy() } }
    private var guideOpen = false { didSet { updateActivationPolicy() } }

    /// A menu bar agent normally has no Dock icon, which means a window that slips
    /// behind another app cannot be brought back — there is nothing to click. Show
    /// a Dock icon for as long as a window is open, then drop back to accessory
    /// mode so the app stays out of the way the rest of the time.
    private func updateActivationPolicy() {
        // Also keep the Dock icon while setup is unfinished. Until the app can
        // actually dictate, the user needs a guaranteed way back to the guide, and
        // the menu bar icon alone has proven too easy to lose.
        let wantsDockIcon = settingsOpen || guideOpen || !isReadyToDictate
            || config.ui.alwaysShowDockIcon
            || statusItemIsUnreachable
        let policy: NSApplication.ActivationPolicy = wantsDockIcon ? .regular : .accessory
        guard NSApp.activationPolicy() != policy else { return }

        NSApp.setActivationPolicy(policy)
        if wantsDockIcon {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller = DictationController(config: config)
        statusItem = StatusItemController(config: config)

        wireController()
        wireStatusItem()

        buildMainMenu()
        controller.startHotkeys()

        // Open the guide whenever the app cannot actually dictate yet. Keyed on the
        // *active* provider, not on any provider: holding a key for some other
        // profile does not make the current one usable.
        if !isReadyToDictate && !config.ui.setupDismissed {
            openSetupGuide()
        } else {
            updateActivationPolicy()
        }

        FTWLog.info("FarsiTalkWrite ready — provider \(config.activeProvider), model \(config.activeProfile?.model ?? "none")")

        // Logged from inside the running bundle on purpose. The same check run via
        // the CLI from a terminal reports the *terminal's* TCC status, because
        // macOS attributes Accessibility to the responsible process — so this is
        // the only trustworthy reading.
        let status = Permissions.status(triggerMode: config.trigger.mode)
        FTWLog.info("PERMISSIONS mic=\(status.microphone.label) accessibility=\(status.accessibility.label) inputMonitoring=\(status.inputMonitoring.label) ready=\(status.isReady)")
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.stopHotkeys()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    /// True when macOS accepted the status item but never gave it a position —
    /// the symptom of a menu bar with no room left, common on notched displays.
    /// The Dock icon is then the only dependable way back into the app.
    private var statusItemIsUnreachable: Bool {
        statusItem?.isPlacedOnMenuBar == false
    }

    /// Everything that must be true before a dictation can succeed.
    private var isReadyToDictate: Bool {
        Keychain.hasKey(forProvider: config.activeProvider)
            && Permissions.status(triggerMode: config.trigger.mode).isReady
    }

    /// Clicking the Dock icon (or the app in Finder) while it is already running
    /// must bring the guide back — otherwise a window that fell behind something
    /// is unreachable for an app with no Dock presence.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        guard !hasVisibleWindows else { return true }

        // Clicking the Dock icon starts a dictation, the same as clicking the menu
        // bar icon. With the menu bar item frequently unplaceable on a notched
        // display, the Dock is the primary trigger, so it must do the primary
        // thing. Settings lives on the Dock icon's right-click menu and ⌘,.
        if isReadyToDictate {
            controller.toggle(destination: .cursor)
        } else {
            openSetupGuide()
        }
        return true
    }

    /// Right-click menu on the Dock icon. This is what makes the Dock a complete
    /// replacement for the menu bar item when macOS refuses to place one.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()

        let toggle = NSMenuItem(
            title: controller.state.isRecording ? "Stop Recording" : "Start Dictation",
            action: #selector(dockToggleRecording), keyEquivalent: ""
        )
        toggle.target = self
        menu.addItem(toggle)

        if controller.hasRecordingToRetry {
            let count = controller.pendingCount
            let retry = NSMenuItem(
                title: count > 1 ? "Retry last recording (\(count) saved)" : "Retry last recording",
                action: #selector(dockRetry), keyEquivalent: ""
            )
            retry.target = self
            menu.addItem(retry)
        }

        menu.addItem(.separator())

        let language = NSMenuItem(title: "Language", action: nil, keyEquivalent: "")
        let languageMenu = NSMenu()
        for option in DictationLanguage.allCases {
            let entry = NSMenuItem(
                title: option.displayName,
                action: #selector(dockPickLanguage(_:)), keyEquivalent: ""
            )
            entry.target = self
            entry.representedObject = option.rawValue
            entry.state = (option == config.language) ? .on : .off
            languageMenu.addItem(entry)
        }
        language.submenu = languageMenu
        menu.addItem(language)

        // Provider and model, so the whole "which LLM" decision is reachable
        // without the menu bar icon.
        let provider = NSMenuItem(title: "Provider", action: nil, keyEquivalent: "")
        let providerMenu = NSMenu()
        for id in config.orderedProviderIDs {
            guard let profile = config.providers[id] else { continue }
            let hasKey = Keychain.hasKey(forProvider: id)
            let entry = NSMenuItem(
                title: hasKey ? profile.displayName : "\(profile.displayName) — no key",
                action: #selector(dockPickProvider(_:)), keyEquivalent: ""
            )
            entry.target = self
            entry.representedObject = id
            entry.state = (id == config.activeProvider) ? .on : .off
            providerMenu.addItem(entry)
        }
        provider.submenu = providerMenu
        menu.addItem(provider)

        if let profile = config.activeProfile {
            let model = NSMenuItem(title: "Model", action: nil, keyEquivalent: "")
            let modelMenu = NSMenu()
            var models = profile.modelPresets
            if !models.contains(profile.model) { models.insert(profile.model, at: 0) }
            for name in models {
                let entry = NSMenuItem(title: name, action: #selector(dockPickModel(_:)), keyEquivalent: "")
                entry.target = self
                entry.representedObject = name
                entry.state = (name == profile.model) ? .on : .off
                modelMenu.addItem(entry)
            }
            model.submenu = modelMenu
            menu.addItem(model)
        }

        menu.addItem(.separator())

        let settings = NSMenuItem(title: "Settings…", action: #selector(menuSettings), keyEquivalent: "")
        settings.target = self
        menu.addItem(settings)

        let guide = NSMenuItem(title: "Setup Guide…", action: #selector(menuSetupGuide), keyEquivalent: "")
        guide.target = self
        menu.addItem(guide)

        return menu
    }

    @objc private func dockToggleRecording() { controller.toggle(destination: .cursor) }
    @objc private func dockRetry() { controller.retryLastRecording() }

    @objc private func dockPickProvider(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        config.activeProvider = id
        persist()
    }

    @objc private func dockPickLanguage(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let language = DictationLanguage(rawValue: raw) else { return }
        config.language = language
        persist()
        FTWLog.info("Dictation language -> \(language.rawValue)")
    }

    @objc private func dockPickModel(_ sender: NSMenuItem) {
        guard let model = sender.representedObject as? String else { return }
        config.providers[config.activeProvider]?.model = model
        persist()
    }

    // MARK: - Wiring

    private func wireController() {
        controller.onStateChange = { [weak self] state in
            guard let self else { return }
            self.statusItem.pendingRetryCount = self.controller.pendingCount
            self.statusItem.update(state: state)
            self.setupGuide?.updateDictationState(state)

            guard self.config.hud.enabled else { return }
            if case .recording(let elapsed, _) = state, elapsed < 0.3 {
                self.hud.show(maxSeconds: self.config.recording.maxSeconds)
            }
            self.hud.update(state: state)
        }

        controller.onTranscript = { [weak self] text in
            self?.setupGuide?.receiveTranscript(text)
        }
    }

    private func wireStatusItem() {
        statusItem.onToggleRecording = { [weak self] in
            // Clicking the menu bar always dictates at the cursor, never into the
            // Setup Guide, regardless of what was used previously.
            self?.controller.toggle(destination: .cursor)
        }

        statusItem.onSelectProvider = { [weak self] id in
            guard let self else { return }
            self.config.activeProvider = id
            self.persist()
            FTWLog.info("Switched provider to \(id)")
        }

        statusItem.onSelectModel = { [weak self] model in
            guard let self else { return }
            self.config.providers[self.config.activeProvider]?.model = model
            self.persist()
            FTWLog.info("Switched model to \(model)")
        }

        statusItem.onSelectTrigger = { [weak self] mode in
            guard let self else { return }
            self.config.trigger.mode = mode
            self.persist()
            self.controller.applyTriggerConfig()

            // Switching to a key-based mode without permission is a dead end;
            // send the user somewhere that can fix it.
            if mode != .menuBarOnly, !Permissions.inputMonitoring.isGranted {
                self.openSetupGuide()
            }
        }

        statusItem.onSelectLanguage = { [weak self] language in
            guard let self else { return }
            self.config.language = language
            self.persist()
            FTWLog.info("Dictation language -> \(language.rawValue)")
        }

        statusItem.onToggleHUD = { [weak self] in
            guard let self else { return }
            self.config.hud.enabled.toggle()
            self.persist()
        }

        statusItem.onPlacementChecked = { [weak self] _ in
            // Re-evaluate once macOS has decided whether the item got a slot.
            self?.updateActivationPolicy()
        }
        statusItem.onRetryLast = { [weak self] in self?.controller.retryLastRecording() }
        statusItem.onOpenSettings = { [weak self] in self?.openSettings() }
        statusItem.onOpenSetupGuide = { [weak self] in self?.openSetupGuide() }
        statusItem.onOpenQuickHelp = { [weak self] button in
            self?.quickHelp.show(from: button)
        }
        statusItem.onQuit = { NSApp.terminate(nil) }
    }

    // MARK: - Config propagation

    /// Single place that saves and pushes config to everything holding a copy.
    private func persist() {
        do {
            try ConfigStore.save(config)
        } catch {
            FTWLog.error("Could not save config: \(error.localizedDescription)")
        }
        controller.config = config
        statusItem.config = config
        settingsWindow?.config = config
        setupGuide?.config = config
    }

    private func adopt(_ updated: Config) {
        config = updated
        persist()
        controller.applyTriggerConfig()
    }

    // MARK: - Main menu

    /// Whenever a window is open the app runs as .regular, which means it gets a
    /// real menu bar. Populating it gives Settings a discoverable, standard home
    /// (⌘,) instead of living only behind the status item.
    private func buildMainMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About FarsiTalkWrite", action: #selector(showAbout), keyEquivalent: "")
            .target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…", action: #selector(menuSettings), keyEquivalent: ",")
            .target = self
        appMenu.addItem(withTitle: "Setup Guide…", action: #selector(menuSetupGuide), keyEquivalent: "")
            .target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide FarsiTalkWrite", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit FarsiTalkWrite", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        // Paste in particular: without an Edit menu, ⌘V does not reach text fields
        // in a programmatically built AppKit app.
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        NSApp.mainMenu = mainMenu
    }

    @objc private func menuSettings() { openSettings() }
    @objc private func menuSetupGuide() { openSetupGuide() }

    @objc private func showAbout() {
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "FarsiTalkWrite",
            .credits: NSAttributedString(
                string: "Farsi push-to-talk dictation.\nActive provider: \(config.activeProfile?.displayName ?? config.activeProvider)\nModel: \(config.activeProfile?.model ?? "—")",
                attributes: [.font: NSFont.systemFont(ofSize: 11)]
            ),
        ])
    }

    // MARK: - Windows

    private func openSettings() {
        if settingsWindow == nil {
            let window = SettingsWindow(config: config)
            window.onConfigChanged = { [weak self] updated in self?.adopt(updated) }
            window.onOpenSetupGuide = { [weak self] in self?.openSetupGuide() }
            window.onShowQuickHelp = { [weak self] view in self?.quickHelp.show(from: view) }
            window.onClosed = { [weak self] in self?.settingsOpen = false }
            settingsWindow = window
        }
        settingsOpen = true
        settingsWindow?.config = config
        settingsWindow?.present()
    }

    private func openSetupGuide() {
        if setupGuide == nil {
            let guide = SetupGuideWindow(config: config)
            guide.onConfigChanged = { [weak self] updated in self?.adopt(updated) }
            guide.onOpenSettings = { [weak self] in self?.openSettings() }
            guide.onRequestDictation = { [weak self] intoPracticeField in
                guard let self else { return }
                self.controller.toggle(destination: intoPracticeField ? .practiceField : .cursor)
            }
            guide.onFinished = { [weak self] in
                guard let self else { return }
                self.guideOpen = false
                // Remember the dismissal so the guide stops reopening on launch.
                if !self.config.ui.setupDismissed {
                    self.config.ui.setupDismissed = true
                    self.persist()
                }
            }
            setupGuide = guide
        }
        guideOpen = true
        setupGuide?.config = config
        setupGuide?.present()
    }
}
