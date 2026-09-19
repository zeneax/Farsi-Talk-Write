//
//  AudioRecorder.swift
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

import Foundation
import AVFoundation
import CoreAudio
import AudioToolbox

/// Records microphone audio and produces a 16 kHz mono 16-bit WAV, which is what
/// the transcription providers want. Handles the three stop conditions and the
/// Bluetooth quirks described in the plan.
final class AudioRecorder {

    enum StopReason: Equatable {
        case manual
        case silence
        case cap
        case configurationChange
        case failed(String)

        var label: String {
            switch self {
            case .manual: return "stopped"
            case .silence: return "silence"
            case .cap: return "time cap"
            case .configurationChange: return "audio device changed"
            case .failed(let why): return "failed: \(why)"
            }
        }
    }

    struct Recording {
        let wav: Data
        let duration: TimeInterval
        let device: AudioInputDevice?
        let reason: StopReason
        /// Loudest single sample of the whole recording, in dBFS.
        let peakDb: Float
        /// RMS of the whole recording, in dBFS.
        let meanDb: Float

        /// Roughly what the provider will bill: audio is 32 tokens/second.
        var estimatedAudioTokens: Int { Int(duration * 32) }

        /// Does this recording contain speech at all?
        ///
        /// The check has to be deterministic and happen *here*, before the audio
        /// is ever sent. Asked to transcribe silence, the model does not answer
        /// "silence" — it writes a fluent, invented sentence that lands at the
        /// user's cursor looking exactly like something they said.
        ///
        /// The obvious alternative — telling the model in the prompt to return
        /// nothing when it hears nothing — is worse, and was tried: it makes the
        /// model refuse perfectly good long recordings instead.
        ///
        /// Thresholds measured the way ffmpeg's `volumedetect` reports them: an
        /// empty room is about -32 dB peak / -50 dB mean, actual speech about
        /// -0 / -20. Both conditions must hold, so one loud noise in an otherwise
        /// silent room still counts as something worth sending.
        var seemsSilent: Bool {
            peakDb < Float(KernelDefaults.Recording.silenceGatePeakDb)
                && meanDb < Float(KernelDefaults.Recording.silenceGateMeanDb)
        }
    }

    enum RecorderError: LocalizedError {
        case noInputDevice
        case formatUnavailable
        case converterUnavailable
        case engineFailed(String)

        var errorDescription: String? {
            switch self {
            case .noInputDevice:
                return "No audio input device is available."
            case .formatUnavailable:
                return "The input device did not report a usable audio format."
            case .converterUnavailable:
                return "Could not create an audio converter for this input format."
            case .engineFailed(let why):
                return "Audio engine failed to start: \(why)"
            }
        }
    }

    static let targetSampleRate: Double = KernelDefaults.Audio.sampleRate

    // Callbacks are delivered on the main queue.
    var onLevel: ((Float) -> Void)?          // current level in dBFS
    var onElapsed: ((TimeInterval) -> Void)? // seconds recorded so far
    var onFinished: ((Recording) -> Void)?

    private(set) var isRecording = false

    /// Guards the two pieces of state that genuinely cross threads: the capture
    /// flag, which the audio thread reads on every buffer, and the resolved
    /// device, which the engine queue writes and the main thread reads.
    ///
    /// A lock is affordable on the tap's path because that path is already far
    /// from lock-free — it allocates an `AVAudioPCMBuffer` and a `Data` per
    /// buffer, and each of those costs more than an uncontended `NSLock`.
    ///
    /// `isStarting` and `startWasCancelled` are deliberately *not* here. Both are
    /// touched only on the main thread, which the asserts in `start` and `stop`
    /// state outright; putting them under a lock would suggest a sharing that
    /// does not exist.
    private let stateLock = NSLock()

    /// An open slower than this is worth saying out loud in the log.
    private static let slowOpenSeconds: TimeInterval = 2

    private var _currentDevice: AudioInputDevice?
    /// The device the current recording is bound to.
    var currentDevice: AudioInputDevice? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _currentDevice
    }

    private func setCurrentDevice(_ device: AudioInputDevice?) {
        stateLock.lock()
        defer { stateLock.unlock() }
        _currentDevice = device
    }

    private var engine: AVAudioEngine?
    private var converter: AVAudioConverter?
    /// The format the current converter was built for, so we can tell when the
    /// hardware has switched under us and rebuild.
    private var converterInputFormat: AVAudioFormat?
    private var targetFormat: AVAudioFormat?

    private var pcm = Data()
    private let pcmQueue = DispatchQueue(label: "com.shahram.farsitalkwrite.pcm")

    private var startedAt: Date?
    private var tickTimer: Timer?
    private var configObserver: NSObjectProtocol?

    /// Every CoreAudio call the engine makes runs here, never on the caller's
    /// thread. Serial on purpose: it is also what guarantees one engine is fully
    /// torn down before the next one is built.
    private let engineQueue = DispatchQueue(
        label: "com.shahram.farsitalkwrite.engine", qos: .userInitiated
    )
    /// The engine is being brought up on `engineQueue` and is not capturing yet.
    private var isStarting = false
    /// `stop()` arrived during that bring-up; discard the engine when it lands.
    private var startWasCancelled = false
    /// The tap is live. Distinct from `isRecording`, which only turns true once
    /// the main thread has been told, and false the instant a stop is asked for —
    /// this one is what keeps buffers from an engine being torn down out of the
    /// next recording. Guarded by `stateLock`, because the audio thread reads it
    /// on every buffer while main and the engine queue both write it.
    private var _isCapturing = false
    private var isCapturing: Bool {
        get {
            stateLock.lock()
            defer { stateLock.unlock() }
            return _isCapturing
        }
        set {
            stateLock.lock()
            defer { stateLock.unlock() }
            _isCapturing = newValue
        }
    }

    // Silence detection state
    private var silenceThresholdDb: Double = -45
    private var silenceStopSeconds: Double = 2.5
    private var minSpeechSeconds: Double = 1.0
    private var maxSeconds: Double = 60
    private var speechSecondsSeen: Double = 0
    private var silentSecondsSeen: Double = 0
    private var framesToDiscard: Int = 0

    // Running loudness over the whole recording, so the pre-flight silence check
    // costs nothing: the per-buffer level meter already walks these samples.
    private var sumOfSquares: Double = 0
    private var framesAnalysed: Int = 0
    private var peakAmplitude: Double = 0

    // Retained so the tap can be rebuilt after a device reconfiguration.
    private var reconfigureCount = 0
    private var leadInDefaultMs: Int = 150
    private var leadInBluetoothMs: Int = 350

    private func leadInDiscardMs(isBluetooth: Bool) -> Int {
        isBluetooth ? leadInBluetoothMs : leadInDefaultMs
    }

    // MARK: - Start

    /// Begins recording. Returns at once; `completion` runs on the main queue
    /// when the engine is really capturing, or when it has failed.
    ///
    /// That it does not block is the whole point. Bringing an AVAudioEngine up is
    /// not local work: `engine.inputNode` instantiates the AUHAL, binding a device
    /// sets a property on it, and `start()` opens the stream — each one a
    /// synchronous Mach round trip to `coreaudiod`, answered when that daemon is
    /// ready and not before. Run from the trigger handler on the main thread, as
    /// this used to be, a slow answer is a frozen app: a 7.6-second hang report,
    /// every sample of it parked inside `AVAudioEngine.inputNode` waiting on
    /// `mach_msg2_trap`, is what prompted this shape. Nothing here was wrong —
    /// the audio server was slow and the UI thread was the one waiting.
    ///
    /// `completion` is not called if `stop()` lands before the engine came up. The
    /// abandoned engine tears itself down and `onFinished` reports the empty
    /// recording, which is what the caller asked for when it stopped.
    func start(config: Config, completion: ((Result<AudioInputDevice, Error>) -> Void)? = nil) {
        assert(Thread.isMainThread, "start() drives isStarting, which is main-thread-only state")
        guard !isRecording, !isStarting else { return }
        isStarting = true
        startWasCancelled = false

        // Reset everything the tap accumulates here, before any of it can be
        // running, so a start that is abandoned cannot hand back the previous
        // recording's audio.
        speechSecondsSeen = 0
        silentSecondsSeen = 0
        sumOfSquares = 0
        framesAnalysed = 0
        peakAmplitude = 0
        reconfigureCount = 0
        setCurrentDevice(nil)
        pcmQueue.sync { pcm = Data() }

        let settings = config.recording
        engineQueue.async { [weak self] in
            guard let self else { return }
            let result: Result<AudioInputDevice, Error>
            do {
                result = .success(try self.bringUpEngine(settings))
            } catch {
                result = .failure(error)
            }
            DispatchQueue.main.async { self.startDidFinish(result, completion: completion) }
        }
    }

    /// The CoreAudio half of `start`, on `engineQueue`. Every field the tap reads
    /// is assigned before the tap can deliver its first buffer.
    private func bringUpEngine(_ settings: RecordingConfig) throws -> AudioInputDevice {
        let beganAt = Date()

        guard let device = AudioDeviceManager.resolveInputDevice(settings.inputDevice) else {
            throw RecorderError.noInputDevice
        }
        setCurrentDevice(device)

        silenceThresholdDb = settings.silenceThreshold(forDeviceUID: device.uid)
        silenceStopSeconds = settings.silenceStopSeconds
        minSpeechSeconds = settings.minSpeechSeconds
        maxSeconds = settings.maxSeconds
        leadInDefaultMs = settings.leadInDiscardMs.defaultMs
        leadInBluetoothMs = settings.leadInDiscardMs.bluetoothMs

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Self.targetSampleRate,
            channels: AVAudioChannelCount(KernelDefaults.Audio.channels),
            interleaved: true
        ) else {
            throw RecorderError.formatUnavailable
        }
        self.targetFormat = targetFormat

        let engine = AVAudioEngine()

        // Touching inputNode instantiates the AUHAL; the device must be bound
        // before the format is read or the engine is started.
        let inputNode = engine.inputNode
        try bind(device: device, to: inputNode)

        // The converter is built lazily from the first buffer's own format rather
        // than from a format read off the node here. Binding a specific input
        // device leaves the node briefly reporting a stale format, and handing a
        // mismatched format to installTap raises an Objective-C exception — which
        // Swift cannot catch, so it terminates the whole app. Letting the buffers
        // declare their format removes that failure mode entirely.
        converter = nil
        converterInputFormat = nil

        // Bluetooth (HFP) links emit silence or noise while the codec negotiates.
        let discardMs = settings.leadInDiscard(isBluetooth: device.isBluetooth)
        framesToDiscard = Int(Self.targetSampleRate * Double(discardMs) / 1000.0)

        // Registered before the stream opens: on Bluetooth the HFP switch is
        // reported within milliseconds of it opening, and an observer added a
        // main-queue hop later would miss it.
        observeConfigurationChanges(on: engine)

        // format: nil means "whatever this node is actually producing". Passing an
        // explicit format here is what raised the uncatchable ObjC exception.
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
            self?.process(buffer: buffer)
        }

        isCapturing = true
        engine.prepare()
        do {
            try engine.start()
        } catch {
            isCapturing = false
            inputNode.removeTap(onBus: 0)
            removeConfigurationObserver()
            throw RecorderError.engineFailed(error.localizedDescription)
        }

        self.engine = engine

        // What CoreAudio actually cost, every single time.
        //
        // It is normally a fraction of a second, and it has been measured at nine
        // — which, before the bring-up moved off the main thread, was nine seconds
        // of frozen app. It no longer freezes anything, but the recording still
        // starts that late and the user still loses the words they said in the
        // meantime. The number is the only way to tell an unlucky day from a
        // developing problem, so it is recorded on every start rather than
        // guessed at afterwards.
        let openSeconds = Date().timeIntervalSince(beganAt)
        let opened = String(format: "%.2f", openSeconds)

        // The real sample rate is logged by process(buffer:) once the first buffer
        // arrives — that is the only value guaranteed to be accurate.
        FTWLog.info("Recording from \(device.name) [\(device.transport.label)], device opened in \(opened)s, discarding \(discardMs) ms lead-in")

        if openSeconds >= Self.slowOpenSeconds {
            FTWLog.warn("Opening \(device.name) took \(opened)s. CoreAudio was slow, not the app — but the recording began that late, so anything said before the start cue was not captured.")
        }
        return device
    }

    /// Back on the main queue with whatever the engine queue managed.
    private func startDidFinish(
        _ result: Result<AudioInputDevice, Error>,
        completion: ((Result<AudioInputDevice, Error>) -> Void)?
    ) {
        isStarting = false

        // A stop landed while the engine was still coming up. Honour it now that
        // there is something to tear down, and tell nobody it ever started.
        if startWasCancelled {
            startWasCancelled = false
            // The bring-up turned this on after the stop had already turned it
            // off; the tap is live and feeding a recording nobody wants.
            isCapturing = false
            removeConfigurationObserver()
            discardEngine()
            return
        }

        if case .success = result {
            isRecording = true
            startedAt = Date()
            startTicking()
        }
        completion?(result)
    }

    /// Binds the engine's input to a specific CoreAudio device. Without this the
    /// engine always follows the system default, so "prefer AirPods" would not work.
    private func bind(device: AudioInputDevice, to inputNode: AVAudioInputNode) throws {
        guard let audioUnit = inputNode.audioUnit else { return }
        var deviceID = device.id
        let status = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        if status != noErr {
            // Not fatal: fall back to the system default rather than refusing to record.
            FTWLog.warn("Could not bind input to \(device.name) (OSStatus \(status)); using system default.")
        }
    }

    // MARK: - Stop

    func stop(reason: StopReason = .manual) {
        // A stop can land while the engine is still being built — two quick
        // triggers, or a change of mind. Cancel the bring-up rather than ignoring
        // the stop; `startDidFinish` discards the engine when it arrives.
        assert(Thread.isMainThread, "stop() drives isStarting, which is main-thread-only state")
        let cancellingStart = isStarting
        guard isRecording || cancellingStart else { return }
        if cancellingStart { startWasCancelled = true }
        isRecording = false
        isCapturing = false

        tickTimer?.invalidate()
        tickTimer = nil

        if !cancellingStart {
            removeConfigurationObserver()
            discardEngine()
        }

        let samples = pcmQueue.sync { pcm }
        let duration = Double(samples.count / (KernelDefaults.Audio.bitsPerSample / 8))
            / Self.targetSampleRate
        let wav = Self.wavData(
            fromPCM16: samples,
            sampleRate: Self.targetSampleRate,
            channels: KernelDefaults.Audio.channels
        )

        let peakDb = Self.dB(peakAmplitude)
        let meanDb = Self.dBFS(sumOfSquares: sumOfSquares, frameCount: framesAnalysed)

        let result = Recording(
            wav: wav,
            duration: duration,
            // Nothing was captured and the engine queue may still be resolving a
            // device, so do not claim one.
            device: cancellingStart ? nil : currentDevice,
            reason: reason,
            peakDb: peakDb,
            meanDb: meanDb
        )

        FTWLog.info(String(
            format: "Recording finished: %.1fs (%@), peak %.0f dBFS / mean %.0f dBFS",
            duration, reason.label, Double(peakDb), Double(meanDb)
        ))

        startedAt = nil
        onMain { self.onFinished?(result) }
    }

    /// Stopping an engine is as synchronous as starting one, so it happens on the
    /// engine queue too. The engine is captured here rather than read there: by
    /// the time the block runs, `self.engine` is already the next recording's.
    private func discardEngine() {
        guard let engine else { return }
        self.engine = nil
        converter = nil
        converterInputFormat = nil
        engineQueue.async {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
    }

    // MARK: - Buffer processing

    private func process(buffer: AVAudioPCMBuffer) {
        // Buffers stay in flight for a moment after a stop is asked for. Dropping
        // them here is what keeps the tail of one recording out of the next.
        guard isCapturing, let targetFormat else { return }

        // Build (or rebuild) the converter from the buffer's own format. This is
        // the only format guaranteed to be correct, and it costs one comparison
        // per buffer.
        if converter == nil || converterInputFormat != buffer.format {
            guard buffer.format.sampleRate > 0, buffer.format.channelCount > 0,
                  let fresh = AVAudioConverter(from: buffer.format, to: targetFormat)
            else {
                FTWLog.warn("Cannot convert from \(buffer.format); dropping buffer.")
                return
            }
            fresh.sampleRateConverterQuality = AVAudioQuality.high.rawValue
            converter = fresh
            converterInputFormat = buffer.format
            FTWLog.info("Audio converter built for \(Int(buffer.format.sampleRate)) Hz, \(buffer.format.channelCount) ch")
        }
        guard let converter else { return }

        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else {
            return
        }

        var consumed = false
        var conversionError: NSError?
        converter.convert(to: output, error: &conversionError) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }

        if let conversionError {
            FTWLog.warn("Audio conversion error: \(conversionError.localizedDescription)")
            return
        }
        guard output.frameLength > 0, let channel = output.int16ChannelData else { return }

        var frameCount = Int(output.frameLength)
        var pointer = channel[0]

        // Drop the Bluetooth lead-in before it reaches the buffer or the level meter.
        if framesToDiscard > 0 {
            let drop = min(framesToDiscard, frameCount)
            framesToDiscard -= drop
            frameCount -= drop
            pointer = pointer.advanced(by: drop)
            guard frameCount > 0 else { return }
        }

        let loudness = Self.loudness(pointer, frameCount: frameCount)
        sumOfSquares += loudness.sumOfSquares
        framesAnalysed += frameCount
        peakAmplitude = max(peakAmplitude, loudness.peak)

        let level = Self.dBFS(sumOfSquares: loudness.sumOfSquares, frameCount: frameCount)
        let seconds = Double(frameCount) / Self.targetSampleRate
        updateSilenceState(level: level, seconds: seconds)

        let bytes = Data(bytes: pointer, count: frameCount * MemoryLayout<Int16>.size)
        pcmQueue.async { self.pcm.append(bytes) }

        onMain { self.onLevel?(level) }
    }

    /// Sum of squares and peak amplitude in one pass, so the level meter and the
    /// whole-recording loudness are paid for together rather than twice.
    private static func loudness(
        _ samples: UnsafePointer<Int16>, frameCount: Int
    ) -> (sumOfSquares: Double, peak: Double) {
        var sum: Double = 0
        var peak: Double = 0
        for index in 0..<frameCount {
            let value = Double(samples[index]) / 32768.0
            sum += value * value
            peak = max(peak, abs(value))
        }
        return (sum, peak)
    }

    private static func dBFS(sumOfSquares: Double, frameCount: Int) -> Float {
        guard frameCount > 0 else { return -120 }
        return dB((sumOfSquares / Double(frameCount)).squareRoot())
    }

    private static func dB(_ amplitude: Double) -> Float {
        guard amplitude > 0 else { return -120 }
        return Float(max(-120, 20 * log10(amplitude)))
    }

    /// Silence-stop only arms after enough speech has been heard, so a long pause
    /// before you start talking cannot end the recording prematurely.
    private func updateSilenceState(level: Float, seconds: Double) {
        if Double(level) > silenceThresholdDb {
            speechSecondsSeen += seconds
            silentSecondsSeen = 0
        } else if speechSecondsSeen >= minSpeechSeconds {
            silentSecondsSeen += seconds
            if silentSecondsSeen >= silenceStopSeconds {
                onMain { self.stop(reason: .silence) }
            }
        }
    }

    // MARK: - Timers and device changes

    private func startTicking() {
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, let startedAt = self.startedAt else { return }
            let elapsed = Date().timeIntervalSince(startedAt)
            self.onElapsed?(elapsed)
            if elapsed >= self.maxSeconds {
                self.stop(reason: .cap)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        tickTimer = timer
    }

    /// Audio configuration changes are NOT automatically a disconnection.
    ///
    /// Opening the microphone on a Bluetooth device makes macOS switch the link
    /// into HFP voice mode, and that switch is itself a configuration change —
    /// delivered a fraction of a second after the engine starts, every single
    /// time. Treating it as "the device went away" aborts every AirPods recording
    /// at 0.0s.
    ///
    /// So: if the device is still present, rebuild the tap around the new format
    /// and keep going. Only give up when the device is genuinely gone.
    private func observeConfigurationChanges(on engine: AVAudioEngine) {
        removeConfigurationObserver()
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.isCapturing else { return }
            self.handleConfigurationChange()
        }
    }

    private func removeConfigurationObserver() {
        guard let observer = configObserver else { return }
        NotificationCenter.default.removeObserver(observer)
        configObserver = nil
    }

    private func handleConfigurationChange() {
        guard let device = currentDevice else {
            FTWLog.warn("Audio configuration changed and no device is resolvable; finishing.")
            stop(reason: .configurationChange)
            return
        }

        // Only re-establish a limited number of times, so a device that flaps
        // cannot spin here forever.
        guard reconfigureCount < 3 else {
            FTWLog.warn("Audio configuration changed repeatedly; finishing with what was captured.")
            stop(reason: .configurationChange)
            return
        }
        reconfigureCount += 1

        // Both halves are CoreAudio and both can block: asking whether the device
        // is still there is a property query, and rebuilding the tap closes and
        // reopens the stream. This notification arrives on every Bluetooth start
        // and on every device change, so it is exactly as capable of freezing the
        // app as starting the engine was.
        engineQueue.async { [weak self] in
            guard let self else { return }

            // Is it still connected, or did it actually disappear?
            guard AudioDeviceManager.device(withUID: device.uid) != nil else {
                FTWLog.warn("\(device.name) disconnected mid-recording; finishing with what was captured.")
                DispatchQueue.main.async { self.stop(reason: .configurationChange) }
                return
            }

            do {
                try self.reinstallTap()
                FTWLog.info("Audio configuration changed (\(device.name)); re-established tap and continued recording.")
            } catch {
                FTWLog.warn("Could not re-establish audio after configuration change: \(error.localizedDescription)")
                DispatchQueue.main.async { self.stop(reason: .configurationChange) }
            }
        }
    }

    /// Rebuilds the tap and converter against whatever format the device now
    /// reports, without discarding audio already captured.
    /// On `engineQueue`, like everything else that touches the engine.
    private func reinstallTap() throws {
        // The recording ended while this was queued behind the bring-up.
        guard isCapturing, let engine else { return }

        engine.inputNode.removeTap(onBus: 0)
        if engine.isRunning { engine.stop() }

        let inputNode = engine.inputNode

        // Force the converter to be rebuilt from the next buffer's real format.
        converter = nil
        converterInputFormat = nil

        // The link has just been renegotiated, so skip its lead-in too.
        if let device = currentDevice {
            let discardMs = leadInDiscardMs(isBluetooth: device.isBluetooth)
            framesToDiscard = Int(Self.targetSampleRate * Double(discardMs) / 1000.0)
        }

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
            self?.process(buffer: buffer)
        }

        engine.prepare()
        try engine.start()
    }

    private func onMain(_ block: @escaping () -> Void) {
        if Thread.isMainThread { block() } else { DispatchQueue.main.async(execute: block) }
    }

    // MARK: - WAV

    /// Minimal 44-byte RIFF/WAVE header around raw little-endian PCM16.
    static func wavData(fromPCM16 pcm: Data, sampleRate: Double, channels: Int) -> Data {
        var data = Data()
        let byteRate = Int(sampleRate) * channels * 2
        let blockAlign = channels * 2

        func append32(_ value: UInt32) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        func append16(_ value: UInt16) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }

        data.append(contentsOf: Array("RIFF".utf8))
        append32(UInt32(36 + pcm.count))
        data.append(contentsOf: Array("WAVE".utf8))

        data.append(contentsOf: Array("fmt ".utf8))
        append32(16)                       // PCM chunk size
        append16(1)                        // format = PCM
        append16(UInt16(channels))
        append32(UInt32(sampleRate))
        append32(UInt32(byteRate))
        append16(UInt16(blockAlign))
        append16(16)                       // bits per sample

        data.append(contentsOf: Array("data".utf8))
        append32(UInt32(pcm.count))
        data.append(pcm)

        return data
    }
}
