//
//  DictationController.swift
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

/// The state machine that ties trigger → record → transcribe → insert together.
/// Everything else (menu bar, HUD, Setup Guide) observes `state` and renders it.
final class DictationController {

    enum State: Equatable {
        case idle
        case recording(elapsed: TimeInterval, level: Float)
        case transcribing
        case inserted
        case failed(String)

        var isRecording: Bool {
            if case .recording = self { return true }
            return false
        }

        var isBusy: Bool {
            switch self {
            case .recording, .transcribing: return true
            default: return false
            }
        }
    }

    private(set) var state: State = .idle {
        didSet {
            guard state != oldValue else { return }
            onStateChange?(state)
        }
    }

    var onStateChange: ((State) -> Void)?
    /// Emitted when a transcription successfully lands, for the Setup Guide's
    /// "try it out" step to display without touching the pasteboard path.
    var onTranscript: ((String) -> Void)?

    var config: Config {
        didSet { applyTriggerConfig() }
    }

    private let recorder = AudioRecorder()
    private let tracker = TargetTracker()
    private let hotkeys = HotkeyMonitor()

    /// Where the next transcript should go.
    ///
    /// Set explicitly by every trigger rather than left as sticky state: a flag
    /// that only the Setup Guide cleared meant that after one practice dictation,
    /// every later dictation was still being diverted into the guide's text box
    /// instead of the user's cursor.
    enum Destination {
        /// Paste at the cursor in whichever app was frontmost when the trigger fired.
        case cursor
        /// Hand back to the Setup Guide's practice field.
        case practiceField
    }

    private(set) var destination: Destination = .cursor

    /// Begins a dictation with an explicit destination.
    func toggle(destination: Destination) {
        self.destination = destination
        toggle()
    }

    private var maxSeconds: TimeInterval { config.recording.maxSeconds }

    init(config: Config) {
        self.config = config
        wireRecorder()
        wireHotkeys()
    }

    // MARK: - Public control

    func start() {
        FTWLog.info("DICTATION start() requested — state=\(state)")
        guard !state.isBusy else {
            FTWLog.info("DICTATION start() ignored, already busy")
            return
        }

        guard Permissions.microphone.isGranted else {
            requestMicrophoneThenStart()
            return
        }

        tracker.capture()
        do {
            try recorder.start(config: config)
            state = .recording(elapsed: 0, level: -120)
        } catch {
            fail(error.localizedDescription)
        }
    }

    func stop() {
        FTWLog.info("DICTATION stop() requested — state=\(state)\n\(Thread.callStackSymbols.prefix(6).joined(separator: "\n"))")
        guard state.isRecording else { return }
        recorder.stop(reason: .manual)
    }

    func toggle() {
        FTWLog.info("DICTATION toggle() — state=\(state)")
        if state.isRecording { stop() } else { start() }
    }

    /// Re-installs the event tap after a trigger-mode or key-code change.
    func applyTriggerConfig() {
        hotkeys.stop()
        guard config.trigger.mode != .menuBarOnly else { return }
        do {
            try hotkeys.start(config: config.trigger)
        } catch {
            FTWLog.warn("Hotkey monitor unavailable: \(error.localizedDescription)")
        }
    }

    func startHotkeys() { applyTriggerConfig() }
    func stopHotkeys() { hotkeys.stop() }

    // MARK: - Wiring

    private func wireRecorder() {
        recorder.onLevel = { [weak self] level in
            guard let self, case .recording(let elapsed, _) = self.state else { return }
            self.state = .recording(elapsed: elapsed, level: level)
        }

        recorder.onElapsed = { [weak self] elapsed in
            guard let self, case .recording(_, let level) = self.state else { return }
            self.state = .recording(elapsed: elapsed, level: level)
        }

        recorder.onFinished = { [weak self] recording in
            self?.handle(recording)
        }
    }

    private func wireHotkeys() {
        hotkeys.onTriggerStart = { [weak self] in
            guard let self else { return }
            // A keyboard trigger always means "type where I am looking".
            self.destination = .cursor
            switch self.config.trigger.mode {
            case .triplePress:
                self.toggle()
            case .holdToTalk:
                self.start()
            case .menuBarOnly:
                break
            }
        }

        hotkeys.onTriggerEnd = { [weak self] in
            guard let self, self.config.trigger.mode == .holdToTalk else { return }
            self.stop()
        }
    }

    // MARK: - Pipeline

    private func handle(_ recording: AudioRecorder.Recording) {
        if case .failed(let why) = recording.reason {
            fail(why)
            return
        }

        // A recording with essentially no audio is a mis-trigger, not an error.
        guard recording.duration >= 0.4 else {
            FTWLog.info("Recording too short (\(String(format: "%.2f", recording.duration))s); ignoring.")
            state = .idle
            return
        }

        // Persist before doing anything that can fail. If transcription dies —
        // network drop, timeout, quota — the audio is still on disk and can be
        // retried instead of the sentence being lost.
        inFlightRecording = saveForRetry(recording.wav)

        state = .transcribing
        let config = self.config

        Task { @MainActor in
            do {
                let result = try await ProviderRegistry.transcribe(wav: recording.wav, config: config)
                let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)

                guard !text.isEmpty else {
                    FTWLog.info("Model returned empty text; nothing to insert.")
                    self.state = .idle
                    return
                }

                FTWLog.info("Transcribed \(text.count) characters via \(result.model) (\(result.tokenSummary))")
                self.onTranscript?(text)

                switch self.destination {
                case .practiceField:
                    self.state = .inserted
                case .cursor:
                    await self.tracker.restore()
                    try TextInserter.insert(text, mode: config.insertion.mode, bidiIsolation: config.insertion.bidiIsolation)
                    self.state = .inserted
                }
                // Delivered successfully, so the saved copy is no longer needed.
                self.clearRetry()

                // Return to idle after the confirmation has been visible briefly.
                try? await Task.sleep(nanoseconds: 900_000_000)
                if case .inserted = self.state { self.state = .idle }

            } catch {
                self.fail(error.localizedDescription)
            }
        }
    }

    // MARK: - Retry of a failed recording

    /// Recordings that have not yet been successfully transcribed.
    ///
    /// A single "last recording" slot was not enough: dictate twice while the
    /// network is down and the first recording is overwritten and gone. Each
    /// recording gets its own timestamped file, deleted only once its text has
    /// actually been delivered.
    static var pendingDirectory: URL {
        ConfigStore.directory.appendingPathComponent("pending", isDirectory: true)
    }

    /// Newest first.
    static func pendingRecordings() -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: pendingDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey]
        )) ?? []

        return files
            .filter { $0.pathExtension == "wav" }
            .sorted { lhs, rhs in
                let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                return l > r
            }
    }

    var hasRecordingToRetry: Bool { !Self.pendingRecordings().isEmpty }
    var pendingCount: Int { Self.pendingRecordings().count }

    /// The file backing the in-flight transcription, so it can be removed on success.
    private var inFlightRecording: URL?

    @discardableResult
    private func saveForRetry(_ wav: Data) -> URL? {
        try? FileManager.default.createDirectory(
            at: Self.pendingDirectory, withIntermediateDirectories: true
        )
        let stamp = Int(Date().timeIntervalSince1970 * 1000)
        let url = Self.pendingDirectory.appendingPathComponent("recording-\(stamp).wav")

        do {
            try wav.write(to: url, options: .atomic)
            prunePending()
            return url
        } catch {
            FTWLog.error("Could not save recording for retry: \(error.localizedDescription)")
            return nil
        }
    }

    private func clearRetry() {
        guard let url = inFlightRecording else { return }
        try? FileManager.default.removeItem(at: url)
        inFlightRecording = nil
    }

    /// Keep the queue bounded so a long outage cannot fill the disk.
    private func prunePending() {
        let files = Self.pendingRecordings()
        guard files.count > 20 else { return }
        for url in files.dropFirst(20) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Re-sends the last recording. Used by the menu item that appears after a
    /// failure, so a network blip costs a click rather than the whole sentence.
    func retryLastRecording() {
        guard !state.isBusy else { return }
        guard let url = Self.pendingRecordings().first,
              let wav = try? Data(contentsOf: url) else {
            fail("There is no saved recording to retry.")
            return
        }

        inFlightRecording = url
        FTWLog.info("Retrying saved recording \(url.lastPathComponent) (\(wav.count / 1024) KB)")
        destination = .cursor
        tracker.capture()
        state = .transcribing

        let config = self.config
        Task { @MainActor in
            do {
                let result = try await ProviderRegistry.transcribe(wav: wav, config: config)
                let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else {
                    self.state = .idle
                    return
                }
                self.onTranscript?(text)
                await self.tracker.restore()
                try TextInserter.insert(text, mode: config.insertion.mode, bidiIsolation: config.insertion.bidiIsolation)
                self.clearRetry()
                self.state = .inserted

                try? await Task.sleep(nanoseconds: 900_000_000)
                if case .inserted = self.state { self.state = .idle }
            } catch {
                self.fail(error.localizedDescription)
            }
        }
    }

    private func requestMicrophoneThenStart() {
        Task { @MainActor in
            let granted = await Permissions.requestMicrophone()
            if granted {
                self.start()
            } else {
                self.fail("Microphone access was denied. Grant it in \(Permissions.SettingsPane.microphone.clickPath).")
            }
        }
    }

    private func fail(_ message: String) {
        FTWLog.error(message)
        // Say that the audio survived — the worst part of a failure is thinking
        // you have to say it all again.
        let count = pendingCount
        let full = count > 0
            ? "\(message)\n\nYour recording was saved (\(count) waiting) — use “Retry last recording”."
            : message
        state = .failed(full)

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if case .failed = self.state { self.state = .idle }
        }
    }
}
