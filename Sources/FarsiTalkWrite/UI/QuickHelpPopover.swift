import AppKit

/// One screen, no scrolling — the reminder you want on day 30. The Setup Guide is
/// the version you want on day 1.
final class QuickHelpPopover {

    var onOpenSetupGuide: (() -> Void)?
    var onOpenSettings: (() -> Void)?

    private let popover = NSPopover()
    private var built = false

    func show(from view: NSView) {
        if !built { build(); built = true }
        popover.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
    }

    func close() { popover.performClose(nil) }

    private func build() {
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 340, height: 340)

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 340))
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)
        stack.translatesAutoresizingMaskIntoConstraints = false

        stack.addArrangedSubview(title("FarsiTalkWrite"))
        stack.addArrangedSubview(separator())

        stack.addArrangedSubview(row("START", "press 🌐 three times fast\nor click the 🎙 in the menu bar"))
        stack.addArrangedSubview(row("STOP", "same again · 2.5s silence · 60s cap"))
        stack.addArrangedSubview(row("RESULT", "Farsi text appears at your cursor"))

        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(caption("Menu bar icon"))
        stack.addArrangedSubview(mono("🎙 ready    ● recording    ∿ transcribing"))

        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(row("Switch model", "right-click 🎙 → Model"))
        stack.addArrangedSubview(row("Free ↔ paid", "right-click 🎙 → Provider"))
        stack.addArrangedSubview(row("Change the key", "right-click 🎙 → Settings"))

        stack.addArrangedSubview(separator())

        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 10

        let guide = NSButton(title: "Full Setup Guide", target: self, action: #selector(openGuide))
        let settings = NSButton(title: "Open Settings", target: self, action: #selector(openSettings))
        buttons.addArrangedSubview(guide)
        buttons.addArrangedSubview(settings)
        stack.addArrangedSubview(buttons)

        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
        ])

        let viewController = NSViewController()
        viewController.view = content
        popover.contentViewController = viewController
    }

    @objc private func openGuide() {
        close()
        onOpenSetupGuide?()
    }

    @objc private func openSettings() {
        close()
        onOpenSettings?()
    }

    // MARK: - Small builders

    private func title(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 14, weight: .semibold)
        return label
    }

    private func caption(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 10, weight: .semibold)
        label.textColor = .tertiaryLabelColor
        return label
    }

    private func mono(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func row(_ key: String, _ value: String) -> NSView {
        let container = NSStackView()
        container.orientation = .horizontal
        container.alignment = .top
        container.spacing = 12

        let keyLabel = NSTextField(labelWithString: key)
        keyLabel.font = .systemFont(ofSize: 10, weight: .semibold)
        keyLabel.textColor = .tertiaryLabelColor
        keyLabel.alignment = .right
        keyLabel.setContentHuggingPriority(.required, for: .horizontal)
        keyLabel.widthAnchor.constraint(equalToConstant: 90).isActive = true

        let valueLabel = NSTextField(wrappingLabelWithString: value)
        valueLabel.font = .systemFont(ofSize: 12)

        container.addArrangedSubview(keyLabel)
        container.addArrangedSubview(valueLabel)
        return container
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }
}
