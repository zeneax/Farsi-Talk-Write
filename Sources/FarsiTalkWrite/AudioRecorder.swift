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

        /// Roughly what the provider will bill: audio is 32 tokens/second.
        var estimatedAudioTokens: Int { Int(duration * 32) }
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

    static let targetSampleRate: Double = 16_000

    // Callbacks are delivered on the main queue.
    var onLevel: ((Float) -> Void)?          // current level in dBFS
    var onElapsed: ((TimeInterval) -> Void)? // seconds recorded so far
    var onFinished: ((Recording) -> Void)?

    private(set) var isRecording = false
    private(set) var currentDevice: AudioInputDevice?

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

    // Silence detection state
    private var silenceThresholdDb: Double = -45
    private var silenceStopSeconds: Double = 2.5
    private var minSpeechSeconds: Double = 1.0
    private var maxSeconds: Double = 60
    private var speechSecondsSeen: Double = 0
    private var silentSecondsSeen: Double = 0
    private var framesToDiscard: Int = 0

    // Retained so the tap can be rebuilt after a device reconfiguration.
    private var reconfigureCount = 0
    private var leadInDefaultMs: Int = 150
    private var leadInBluetoothMs: Int = 350

    private func leadInDiscardMs(isBluetooth: Bool) -> Int {
        isBluetooth ? leadInBluetoothMs : leadInDefaultMs
    }

    // MARK: - Start

    func start(config: Config) throws {
        guard !isRecording else { return }

        guard let device = AudioDeviceManager.resolveInputDevice(config.recording.inputDevice) else {
            throw RecorderError.noInputDevice
        }
        currentDevice = device

        let recording = config.recording
        silenceThresholdDb = recording.silenceThreshold(forDeviceUID: device.uid)
        silenceStopSeconds = recording.silenceStopSeconds
        minSpeechSeconds = recording.minSpeechSeconds
        maxSeconds = recording.maxSeconds
        speechSecondsSeen = 0
        silentSecondsSeen = 0
        reconfigureCount = 0
        leadInDefaultMs = recording.leadInDiscardMs.defaultMs
        leadInBluetoothMs = recording.leadInDiscardMs.bluetoothMs

        let engine = AVAudioEngine()
        self.engine = engine

        // Touching inputNode instantiates the AUHAL; the device must be bound
        // before the format is read or the engine is started.
        let inputNode = engine.inputNode
        try bind(device: device, to: inputNode)

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Self.targetSampleRate,
            channels: 1,
            interleaved: true
        ) else {
            throw RecorderError.formatUnavailable
        }
        self.targetFormat = targetFormat

        // The converter is built lazily from the first buffer's own format rather
        // than from a format read off the node here. Binding a specific input
        // device leaves the node briefly reporting a stale format, and handing a
        // mismatched format to installTap raises an Objective-C exception — which
        // Swift cannot catch, so it terminates the whole app. Letting the buffers
        // declare their format removes that failure mode entirely.
        converter = nil
        converterInputFormat = nil

        // Bluetooth (HFP) links emit silence or noise while the codec negotiates.
        let discardMs = recording.leadInDiscard(isBluetooth: device.isBluetooth)
        framesToDiscard = Int(Self.targetSampleRate * Double(discardMs) / 1000.0)

        pcmQueue.sync { pcm = Data() }

        // format: nil means "whatever this node is actually producing". Passing an
        // explicit format here is what raised the uncatchable ObjC exception.
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
            self?.process(buffer: buffer)
        }

        engine.prepare()
        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            self.engine = nil
            throw RecorderError.engineFailed(error.localizedDescription)
        }

        isRecording = true
        startedAt = Date()

        observeConfigurationChanges()
        startTicking()

        // The real sample rate is logged by process(buffer:) once the first buffer
        // arrives — that is the only value guaranteed to be accurate.
        FTWLog.info("Recording from \(device.name) [\(device.transport.label)], discarding \(discardMs) ms lead-in")
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
        guard isRecording else { return }
        isRecording = false

        tickTimer?.invalidate()
        tickTimer = nil

        if let observer = configObserver {
            NotificationCenter.default.removeObserver(observer)
            configObserver = nil
        }

        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        converter = nil

        let samples = pcmQueue.sync { pcm }
        let duration = Double(samples.count / 2) / Self.targetSampleRate
        let wav = Self.wavData(fromPCM16: samples, sampleRate: Self.targetSampleRate, channels: 1)

        let result = Recording(
            wav: wav,
            duration: duration,
            device: currentDevice,
            reason: reason
        )

        FTWLog.info(String(format: "Recording finished: %.1fs (%@)", duration, reason.label))

        startedAt = nil
        onMain { self.onFinished?(result) }
    }

    // MARK: - Buffer processing

    private func process(buffer: AVAudioPCMBuffer) {
        guard let targetFormat else { return }

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

        let level = Self.dBFS(pointer, frameCount: frameCount)
        let seconds = Double(frameCount) / Self.targetSampleRate
        updateSilenceState(level: level, seconds: seconds)

        let bytes = Data(bytes: pointer, count: frameCount * MemoryLayout<Int16>.size)
        pcmQueue.async { self.pcm.append(bytes) }

        onMain { self.onLevel?(level) }
    }

    private static func dBFS(_ samples: UnsafePointer<Int16>, frameCount: Int) -> Float {
        guard frameCount > 0 else { return -120 }
        var sum: Double = 0
        for index in 0..<frameCount {
            let value = Double(samples[index]) / 32768.0
            sum += value * value
        }
        let rms = (sum / Double(frameCount)).squareRoot()
        guard rms > 0 else { return -120 }
        return Float(max(-120, 20 * log10(rms)))
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
    private func observeConfigurationChanges() {
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.isRecording else { return }
            self.handleConfigurationChange()
        }
    }

    private func handleConfigurationChange() {
        guard let device = currentDevice else {
            FTWLog.warn("Audio configuration changed and no device is resolvable; finishing.")
            stop(reason: .configurationChange)
            return
        }

        // Is it still connected, or did it actually disappear?
        let stillPresent = AudioDeviceManager.device(withUID: device.uid) != nil
        guard stillPresent else {
            FTWLog.warn("\(device.name) disconnected mid-recording; finishing with what was captured.")
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

        do {
            try reinstallTap()
            FTWLog.info("Audio configuration changed (\(device.name)); re-established tap and continued recording.")
        } catch {
            FTWLog.warn("Could not re-establish audio after configuration change: \(error.localizedDescription)")
            stop(reason: .configurationChange)
        }
    }

    /// Rebuilds the tap and converter against whatever format the device now
    /// reports, without discarding audio already captured.
    private func reinstallTap() throws {
        guard let engine else { throw RecorderError.engineFailed("engine went away") }

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
