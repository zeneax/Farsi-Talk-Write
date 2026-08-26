//
//  RecordingsWindow.swift
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
import AVFoundation

/// Lists recordings that have not been successfully transcribed, so they can be
/// played back, chosen from, and re-sent.
///
/// The queue on disk was already the safety net; this makes it usable. Without a
/// way to hear what is in it, "3 saved" is just a number — the user cannot tell
/// which recording is the one worth resending, or whether a file is a real
/// sentence or an accidental trigger.
@MainActor
final class RecordingsWindow: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {

    /// Asks the controller to transcribe one file. The window does not talk to
    /// providers itself; it only decides *which* audio matters.
    var onTranscribe: ((URL) -> Void)?
    var onClosed: (() -> Void)?

    private var window: NSWindow?
    private let table = NSTableView()
    private let statusLabel = NSTextField(labelWithString: "")
    private var rows: [URL] = []

    private var player: AVAudioPlayer?
    private var playingIndex: Int?
    private var playbackTimer: Timer?

    // MARK: - Presentation

    func present() {
        if window == nil { build() }
        reload()
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        stopPlayback()
        onClosed?()
    }

    private func build() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 420),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "Recordings"
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 520, height: 300)

        table.dataSource = self
        table.delegate = self
        table.rowHeight = 30
        table.allowsMultipleSelection = true
        table.usesAlternatingRowBackgroundColors = true

        for (id, title, width) in [
            ("when", "Recorded", CGFloat(190)),
            ("duration", "Length", CGFloat(80)),
            ("size", "Size", CGFloat(80)),
            ("play", "", CGFloat(90)),
        ] {
            let column = NSTableColumn(identifier: .init(id))
            column.title = title
            column.width = width
            table.addTableColumn(column)
        }

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let transcribe = button("Transcribe Selected", #selector(transcribeSelected))
        transcribe.keyEquivalent = "\r"
        let delete = button("Delete", #selector(deleteSelected))
        let reveal = button("Show in Finder", #selector(revealSelected))
        let transcripts = button("Open Transcripts…", #selector(openTranscripts))

        let buttons = NSStackView(views: [transcribe, delete, reveal, NSView(), transcripts])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        let hint = NSTextField(wrappingLabelWithString:
            "These are recordings that have not been transcribed successfully. "
            + "Play one to hear it, then send it again. Nothing is deleted until you say so.")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView()
        root.addSubview(hint)
        root.addSubview(scroll)
        root.addSubview(buttons)
        root.addSubview(statusLabel)

        NSLayoutConstraint.activate([
            hint.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            hint.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            hint.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),

            scroll.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            scroll.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -12),

            buttons.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            buttons.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            buttons.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -8),

            statusLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            statusLabel.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
        ])

        window.contentView = root
        self.window = window
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        return b
    }

    // MARK: - Data

    func reload() {
        rows = DictationController.pendingRecordings()
        table.reloadData()
        statusLabel.stringValue = rows.isEmpty
            ? "No recordings waiting — everything has been transcribed."
            : "\(rows.count) recording\(rows.count == 1 ? "" : "s") waiting · stored in ~/.config/farsitalkwrite/pending"
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < rows.count, let id = tableColumn?.identifier.rawValue else { return nil }
        let url = rows[row]

        if id == "play" {
            let b = NSButton(
                title: playingIndex == row ? "◼ Stop" : "▶ Play",
                target: self, action: #selector(togglePlay(_:))
            )
            b.bezelStyle = .rounded
            b.tag = row
            b.font = .systemFont(ofSize: 11)
            return b
        }

        let text: String
        switch id {
        case "when":     text = Self.recordedAt(url)
        case "duration": text = Self.durationText(url)
        case "size":     text = Self.sizeText(url)
        default:         text = ""
        }

        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12)
        return label
    }

    // MARK: - Playback

    @objc private func togglePlay(_ sender: NSButton) {
        let row = sender.tag
        guard row < rows.count else { return }

        if playingIndex == row {
            stopPlayback()
            return
        }
        stopPlayback()

        do {
            let p = try AVAudioPlayer(contentsOf: rows[row])
            p.prepareToPlay()
            p.play()
            player = p
            playingIndex = row

            // Reset the button when playback finishes on its own.
            playbackTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let player = self.player else { return }
                    if !player.isPlaying { self.stopPlayback() }
                }
            }
            table.reloadData()
            statusLabel.stringValue = "Playing \(Self.recordedAt(rows[row]))…"
        } catch {
            statusLabel.stringValue = "Could not play this file: \(error.localizedDescription)"
        }
    }

    private func stopPlayback() {
        player?.stop()
        player = nil
        playingIndex = nil
        playbackTimer?.invalidate()
        playbackTimer = nil
        table.reloadData()
    }

    // MARK: - Actions

    private var selectedURLs: [URL] {
        table.selectedRowIndexes.compactMap { $0 < rows.count ? rows[$0] : nil }
    }

    @objc private func transcribeSelected() {
        let targets = selectedURLs.isEmpty ? Array(rows.prefix(1)) : selectedURLs
        guard !targets.isEmpty else {
            statusLabel.stringValue = "Nothing selected."
            return
        }
        stopPlayback()
        statusLabel.stringValue = "Sending \(targets.count) recording\(targets.count == 1 ? "" : "s")…"
        for url in targets { onTranscribe?(url) }
    }

    @objc private func deleteSelected() {
        let targets = selectedURLs
        guard !targets.isEmpty else {
            statusLabel.stringValue = "Nothing selected."
            return
        }

        // Deleting audio the user has not heard back is irreversible, so confirm.
        let alert = NSAlert()
        alert.messageText = "Delete \(targets.count) recording\(targets.count == 1 ? "" : "s")?"
        alert.informativeText = "The audio will be permanently removed. This cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        stopPlayback()
        for url in targets { try? FileManager.default.removeItem(at: url) }
        reload()
    }

    @objc private func revealSelected() {
        let targets = selectedURLs.isEmpty ? rows : selectedURLs
        guard !targets.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(targets)
    }

    @objc private func openTranscripts() {
        let dir = TranscriptArchive.directory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let latest = TranscriptArchive.files().last {
            NSWorkspace.shared.activateFileViewerSelecting([latest])
        } else {
            NSWorkspace.shared.open(dir)
        }
    }

    // MARK: - Formatting

    private static func recordedAt(_ url: URL) -> String {
        let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? Date()
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter.string(from: date)
    }

    private static func durationText(_ url: URL) -> String {
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        let seconds = Double(max(0, bytes - 44)) / (16_000 * 2)
        return String(format: "%.1fs", seconds)
    }

    private static func sizeText(_ url: URL) -> String {
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}
