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
///
/// Main-actor isolated deliberately: every observer of `state` drives AppKit, and
/// AppKit traps when touched off the main thread. Declaring the isolation makes the
/// compiler enforce what was previously only a convention — a background callback
/// mutating `state` is now a build error rather than a crash at runtime.
@MainActor
final class DictationController {

    enum State: Equatable {
        case idle
        case recording(elapsed: TimeInterval, level: Float)
        /// `attempt` and `of` drive the "trying again" messages, so a slow retry
        /// reads as progress rather than a hang.
        case transcribing(attempt: Int, of: Int, elapsed: TimeInterval)
        /// A long recording split into pieces; `done` of `of` have come back.
        case transcribingChunks(done: Int, of: Int)
        case inserted
        /// Nothing could be typed into, so the text is on the clipboard instead.
        case copiedToClipboard
        case failed(String)

        var isRecording: Bool {
            if case .recording = self { return true }
            return false
        }

        var isBusy: Bool {
            switch self {
            case .recording, .transcribing, .transcribingChunks: return true
            default: return false
            }
        }
    }

    /// Observers of this all drive AppKit. The class is `@MainActor`, so the
    /// compiler now guarantees mutations happen on the main actor — the runtime
    /// thread checks this code used to carry are no longer needed, and a violation
    /// is a build error rather than a crash.
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
        /// Re-sent from the Recordings window. There is no meaningful cursor to
        /// target — the user is looking at our own window — so the text always
        /// goes to the clipboard, and is additionally typed if some other app
        /// does happen to be focused.
        case clipboard
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
            MainActor.assumeIsolated {
                guard let self, case .recording(let elapsed, _) = self.state else { return }
                self.state = .recording(elapsed: elapsed, level: level)
            }
        }

        recorder.onElapsed = { [weak self] elapsed in
            MainActor.assumeIsolated {
                guard let self, case .recording(_, let level) = self.state else { return }
                self.state = .recording(elapsed: elapsed, level: level)
            }
        }

        recorder.onFinished = { [weak self] recording in
            MainActor.assumeIsolated { self?.handle(recording) }
        }
    }

    private func wireHotkeys() {
        hotkeys.onTriggerStart = { [weak self] in
            MainActor.assumeIsolated {
            guard let self else { return }
            // A keyboard trigger always means "type where I am looking".
            self.destination = .cursor
            switch self.config.trigger.mode {
            case .triplePress, .holdDuration, .shiftCombo:
                // Both are "start or stop"; the difference is only in how the
                // gesture is recognised, which HotkeyMonitor has already handled.
                self.toggle()
            case .holdToTalk:
                self.start()
            case .menuBarOnly:
                break
            }
            }
        }

        hotkeys.onTriggerEnd = { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.config.trigger.mode == .holdToTalk else { return }
                self.stop()
            }
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

        beginTranscribing()
        let config = self.config

        Task { @MainActor in
            do {
                let result = try await ProviderRegistry.transcribeChunked(
                    wav: recording.wav, config: config,
                    onProgress: { @Sendable [weak self] done, total in
                        Task { @MainActor in
                            self?.state = .transcribingChunks(done: done, of: total)
                        }
                    },
                    onAttempt: { @Sendable [weak self] attempt, total in
                        Task { @MainActor in
                            self?.transcribeAttempt = attempt
                        self?.transcribeTotal = total
                        }
                    }
                )
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
                    TranscriptArchive.append(text, model: result.model, delivered: true)
                    self.state = .inserted
                case .cursor, .clipboard:
                    await self.tracker.restore()
                    self.deliver(text, config: config, model: result.model)
                }
                // Delivered successfully, so the saved copy is no longer needed.
                self.clearRetry()

                // Return to idle after the confirmation has been visible briefly.
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                switch self.state {
                case .inserted, .copiedToClipboard: self.state = .idle
                default: break
                }

            } catch {
                self.fail(error.localizedDescription)
            }
        }
    }

    // MARK: - Transcription progress

    private var transcribeStartedAt: Date?
    private var transcribeTimer: Timer?
    private var transcribeAttempt = 1
    private var transcribeTotal = 1

    /// A single request gives nothing to count, so the feedback is a running clock.
    /// Splitting the audio would produce "1/2, 2/2" — but measured against this
    /// provider that made a 12s job take 98s, so a counter is the honest way to
    /// show that something is still happening.
    private func beginTranscribing() {
        transcribeStartedAt = Date()
        transcribeAttempt = 1
        transcribeTotal = max(1, config.retryAttempts)
        state = .transcribing(attempt: 1, of: transcribeTotal, elapsed: 0)

        transcribeTimer?.invalidate()
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let started = self.transcribeStartedAt else { return }
                self.state = .transcribing(
                    attempt: self.transcribeAttempt,
                    of: self.transcribeTotal,
                    elapsed: Date().timeIntervalSince(started)
                )
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        transcribeTimer = timer
    }

    private func endTranscribing() {
        transcribeTimer?.invalidate()
        transcribeTimer = nil
        transcribeStartedAt = nil
    }

    // MARK: - Delivery

    /// Puts the transcript where it can actually be used.
    ///
    /// Insertion can fail for reasons unrelated to transcription — nothing focused,
    /// a target app that rejects synthetic paste, a contended clipboard. In every
    /// such case the text was fine, so it is archived first and copied to the
    /// clipboard as a fallback. The user is then told which happened.
    private func deliver(_ text: String, config: Config, model: String?) {
        endTranscribing()
        TranscriptArchive.append(text, model: model, delivered: true)

        // Decided per target: the same transcript is marked for Notes and left
        // plain for a terminal.
        let bundleID = tracker.targetBundleID
        let isolate = config.insertion.shouldIsolateBidi(forBundleID: bundleID)
        if !isolate, config.insertion.bidiIsolation {
            FTWLog.info("Skipping bidi marks for \(bundleID ?? "unknown") — it renders them literally.")
        }
        let prepared = isolate
            ? BidiText.directionallyMarked(BidiText.stripping(text))
            : BidiText.stripping(text)

        // Put it on the clipboard up front when that is the point of the request.
        // TextInserter snapshots and restores the pasteboard around its paste, so
        // setting it first means the text survives either outcome.
        if destination == .clipboard {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(prepared, forType: .string)
        }

        do {
            try TextInserter.insert(
                text,
                mode: config.insertion.mode,
                bidiIsolation: isolate,
                keepOnClipboard: config.insertion.alwaysCopyToClipboard || destination == .clipboard
            )
            FTWLog.info("Inserted \(text.count) characters (clipboard retained: \(config.insertion.alwaysCopyToClipboard))")
            // Even on success, say "copied" when that was the request — the user
            // asked for it on the clipboard and needs to know it is there.
            // Say "copied" whenever the clipboard is the reliable outcome — the
            // paste itself cannot be confirmed, so promising insertion would be a
            // claim the app cannot actually verify.
            state = (destination == .clipboard || config.insertion.alwaysCopyToClipboard)
                ? .copiedToClipboard : .inserted
        } catch {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(prepared, forType: .string)
            FTWLog.warn("Insertion failed (\(error.localizedDescription)); copied to clipboard instead.")
            state = .copiedToClipboard
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
        guard let url = Self.pendingRecordings().first else {
            fail("There is no saved recording to retry.")
            return
        }
        transcribeSaved(url)
    }

    /// Re-sends one specific saved recording, chosen from the Recordings window.
    func transcribeSaved(_ url: URL) {
        guard !state.isBusy else { return }
        destination = .clipboard
        guard let wav = try? Data(contentsOf: url) else {
            fail("Could not read \(url.lastPathComponent).")
            return
        }

        inFlightRecording = url
        FTWLog.info("Retrying saved recording \(url.lastPathComponent) (\(wav.count / 1024) KB)")
        destination = .cursor
        tracker.capture()
        beginTranscribing()

        let config = self.config
        Task { @MainActor in
            do {
                let result = try await ProviderRegistry.transcribeChunked(
                    wav: wav, config: config,
                    onProgress: { @Sendable [weak self] done, total in
                        Task { @MainActor in
                            self?.state = .transcribingChunks(done: done, of: total)
                        }
                    },
                    onAttempt: { @Sendable [weak self] attempt, total in
                        Task { @MainActor in
                            self?.transcribeAttempt = attempt
                        self?.transcribeTotal = total
                        }
                    }
                )
                let text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else {
                    self.state = .idle
                    return
                }
                FTWLog.info("Saved-recording transcript ready: \(text.count) characters; delivering to \(self.destination)")
                self.onTranscript?(text)
                await self.tracker.restore()
                self.deliver(text, config: config, model: result.model)
                self.clearRetry()
                FTWLog.info("Delivery finished — state \(self.state)")

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
        endTranscribing()
        FTWLog.error(message)
        // Say that the audio survived — the worst part of a failure is thinking
        // you have to say it all again.
        let count = pendingCount
        let full = count > 0
            ? "\(message)\n\n✓ Nothing was lost — your recording is saved (\(count) waiting).\nOpen Recordings from the menu to play it back and send it again."
            : message
        state = .failed(full)

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if case .failed = self.state { self.state = .idle }
        }
    }
}
