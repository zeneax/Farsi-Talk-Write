//
//  RecordingHUD.swift
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

/// A small floating readout showing elapsed time against the cap, the live mic
/// level, and the current stage.
///
/// The critical property is that it never takes keyboard focus: `.nonactivatingPanel`
/// plus `orderFrontRegardless()`. If this window ever became key, the text field
/// being dictated into would lose its caret and the paste would land elsewhere.
final class RecordingHUD {

    private var panel: NSPanel?
    private let contentView = HUDContentView()
    private var fadeTimer: Timer?

    private let width: CGFloat = 260
    private let height: CGFloat = 62

    // MARK: - Presentation

    func show(maxSeconds: TimeInterval) {
        contentView.maxSeconds = maxSeconds
        ensurePanel()
        fadeTimer?.invalidate()

        guard let panel else { return }
        position(panel)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
    }

    func update(state: DictationController.State) {
        contentView.apply(state)
        switch state {
        case .idle:
            hide(after: 0)
        case .inserted:
            hide(after: 0.9)
        case .failed:
            hide(after: 4.0)
        case .recording, .transcribing:
            break
        }
    }

    func hide(after delay: TimeInterval) {
        fadeTimer?.invalidate()
        guard delay > 0 else { return fadeOut() }
        fadeTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.fadeOut()
        }
    }

    private func fadeOut() {
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            panel.animator().alphaValue = 0
        } completionHandler: {
            panel.orderOut(nil)
        }
    }

    // MARK: - Panel

    private func ensurePanel() {
        guard panel == nil else { return }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [
            .canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary,
        ]
        panel.contentView = contentView

        self.panel = panel
    }

    /// Bottom-centre of whichever screen currently holds the pointer.
    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }

        let origin = NSPoint(
            x: frame.midX - width / 2,
            y: frame.minY + 120
        )
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: width, height: height)), display: false)
    }
}

// MARK: - Drawing

private final class HUDContentView: NSView {

    var maxSeconds: TimeInterval = 60
    private var elapsed: TimeInterval = 0
    private var level: Float = -120
    private var stage: Stage = .recording
    private var message: String = ""
    private var pulse: CGFloat = 0
    private var pulseTimer: Timer?

    private enum Stage {
        case recording, transcribing, done, failed
    }

    override var isFlipped: Bool { true }

    func apply(_ state: DictationController.State) {
        switch state {
        case .idle:
            stopPulse()
        case .recording(let seconds, let db):
            stage = .recording
            elapsed = seconds
            level = db
            startPulse()
        case .transcribing:
            stage = .transcribing
            message = "در حال رونویسی…"
            startPulse()
        case .inserted:
            stage = .done
            message = "✓"
            stopPulse()
        case .failed(let why):
            stage = .failed
            message = why
            stopPulse()
        }
        needsDisplay = true
    }

    private func startPulse() {
        guard pulseTimer == nil else { return }
        pulseTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.pulse += 0.05
            self.needsDisplay = true
        }
        if let pulseTimer { RunLoop.main.add(pulseTimer, forMode: .common) }
    }

    private func stopPulse() {
        pulseTimer?.invalidate()
        pulseTimer = nil
    }

    override func draw(_ dirtyRect: NSRect) {
        let bounds = self.bounds

        // Card
        let card = NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12)
        NSColor.black.withAlphaComponent(0.82).setFill()
        card.fill()

        switch stage {
        case .recording:   drawRecording(in: bounds)
        case .transcribing: drawMessage(message, in: bounds, color: .systemOrange)
        case .done:        drawMessage(message, in: bounds, color: .systemGreen)
        case .failed:      drawMessage(message, in: bounds, color: .systemRed)
        }
    }

    private func drawRecording(in bounds: NSRect) {
        let inset: CGFloat = 14

        // Pulsing dot
        let alpha = 0.55 + 0.45 * abs(sin(pulse * 2))
        NSColor.systemRed.withAlphaComponent(alpha).setFill()
        NSBezierPath(ovalIn: NSRect(x: inset, y: 15, width: 9, height: 9)).fill()

        // Elapsed / cap
        let clock = "\(Self.mmss(elapsed)) / \(Self.mmss(maxSeconds))"
        draw(clock, at: NSPoint(x: inset + 18, y: 11),
             size: 13, weight: .medium, color: .white)

        // Level meter, right-aligned
        drawLevelMeter(in: bounds, inset: inset)

        // Countdown bar
        let remaining = max(0, maxSeconds - elapsed)
        let fraction = maxSeconds > 0 ? remaining / maxSeconds : 0
        // Amber warning for the last 10 seconds before the cap.
        let barColor: NSColor = remaining <= 10 ? .systemOrange : .white
        drawBar(in: bounds, inset: inset, fraction: CGFloat(fraction), color: barColor)
    }

    private func drawLevelMeter(in bounds: NSRect, inset: CGFloat) {
        // -60 dBFS .. 0 dBFS mapped across 7 bars.
        let normalized = max(0, min(1, (Double(level) + 60) / 60))
        let barCount = 7
        let lit = Int((Double(barCount) * normalized).rounded())

        var x = bounds.width - inset - CGFloat(barCount) * 6
        for index in 0..<barCount {
            let height: CGFloat = 4 + CGFloat(index) * 2
            let color: NSColor = index < lit ? .systemGreen : NSColor.white.withAlphaComponent(0.18)
            color.setFill()
            NSBezierPath(
                roundedRect: NSRect(x: x, y: 24 - height, width: 3, height: height),
                xRadius: 1.5, yRadius: 1.5
            ).fill()
            x += 6
        }
    }

    private func drawBar(in bounds: NSRect, inset: CGFloat, fraction: CGFloat, color: NSColor) {
        let barRect = NSRect(x: inset, y: 38, width: bounds.width - inset * 2, height: 5)

        NSColor.white.withAlphaComponent(0.15).setFill()
        NSBezierPath(roundedRect: barRect, xRadius: 2.5, yRadius: 2.5).fill()

        guard fraction > 0 else { return }
        let filled = NSRect(x: barRect.minX, y: barRect.minY,
                            width: barRect.width * fraction, height: barRect.height)
        color.setFill()
        NSBezierPath(roundedRect: filled, xRadius: 2.5, yRadius: 2.5).fill()
    }

    private func drawMessage(_ text: String, in bounds: NSRect, color: NSColor) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byTruncatingTail

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: color,
            .paragraphStyle: paragraph,
        ]
        let rect = bounds.insetBy(dx: 12, dy: 0)
        let height: CGFloat = 34
        let target = NSRect(x: rect.minX, y: (bounds.height - height) / 2,
                            width: rect.width, height: height)
        (text as NSString).draw(in: target, withAttributes: attributes)
    }

    private func draw(
        _ text: String, at point: NSPoint,
        size: CGFloat, weight: NSFont.Weight, color: NSColor
    ) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight),
            .foregroundColor: color,
        ]
        (text as NSString).draw(at: point, withAttributes: attributes)
    }

    static func mmss(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
