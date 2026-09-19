//
//  generate-kernel.swift
//  FarsiTalkWrite — build-time code generation from kernel/
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

// Reads kernel/prompts.json and kernel/timing.json and writes
// Sources/FarsiTalkWrite/KernelDefaults.generated.swift.
//
// The kernel is shared with the npm package in packages/web, which carries the
// same JSON. Generating the Swift constants rather than decoding the JSON at
// runtime is deliberate:
//
//   * Defaults stay compile-time constants. There is no new runtime failure mode
//     where a missing or malformed resource leaves the app with no prompt.
//   * Nothing changes about how the app is bundled or signed, which CLAUDE.md
//     warns is load-bearing for TCC grants and Keychain ACLs.
//   * The generator is what guarantees the two copies agree, and it runs on
//     every build rather than when someone remembers.
//
// A missing or mistyped key is a hard failure here, so renaming something in the
// JSON breaks the build loudly instead of silently reintroducing a literal.
//
//     swift Tools/generate-kernel.swift <kernel-dir> <output-file>

import Foundation

// MARK: - Reading

/// Every lookup failure ends the build with the JSON path that was missing.
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("generate-kernel: \(message)\n".utf8))
    exit(1)
}

func loadJSON(_ url: URL) -> [String: Any] {
    guard let data = try? Data(contentsOf: url) else {
        fail("cannot read \(url.path)")
    }
    guard let object = try? JSONSerialization.jsonObject(with: data),
          let dictionary = object as? [String: Any] else {
        fail("\(url.lastPathComponent) is not a JSON object")
    }
    return dictionary
}

/// Walks a dotted key path, failing with the full path rather than a nil.
func value(_ root: [String: Any], _ path: String, file: String) -> Any {
    var current: Any = root
    var walked: [String] = []
    for component in path.split(separator: ".").map(String.init) {
        guard let dictionary = current as? [String: Any],
              let next = dictionary[component] else {
            walked.append(component)
            fail("\(file): no value at \(walked.joined(separator: "."))")
        }
        walked.append(component)
        current = next
    }
    return current
}

func string(_ root: [String: Any], _ path: String, file: String) -> String {
    guard let v = value(root, path, file: file) as? String else {
        fail("\(file): \(path) is not a string")
    }
    return v
}

func double(_ root: [String: Any], _ path: String, file: String) -> Double {
    guard let v = value(root, path, file: file) as? NSNumber else {
        fail("\(file): \(path) is not a number")
    }
    return v.doubleValue
}

func int(_ root: [String: Any], _ path: String, file: String) -> Int {
    guard let v = value(root, path, file: file) as? NSNumber else {
        fail("\(file): \(path) is not a number")
    }
    return v.intValue
}

func intArray(_ root: [String: Any], _ path: String, file: String) -> [Int] {
    guard let v = value(root, path, file: file) as? [NSNumber] else {
        fail("\(file): \(path) is not an array of numbers")
    }
    return v.map(\.intValue)
}

func bool(_ root: [String: Any], _ path: String, file: String) -> Bool {
    guard let v = value(root, path, file: file) as? NSNumber else {
        fail("\(file): \(path) is not a boolean")
    }
    return v.boolValue
}

// MARK: - Emitting

/// A Swift string literal. Non-ASCII is left as-is so the Persian prompts stay
/// readable in the generated file and diff legibly.
func literal(_ text: String) -> String {
    var out = "\""
    for character in text {
        switch character {
        case "\\": out += "\\\\"
        case "\"": out += "\\\""
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        default:   out.append(character)
        }
    }
    return out + "\""
}

/// Doubles that are whole numbers still need a decimal point to type as Double.
func number(_ value: Double) -> String {
    value == value.rounded() && abs(value) < 1e15
        ? String(format: "%.1f", value)
        : String(value)
}

// MARK: - Main

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    fail("usage: generate-kernel <kernel-dir> <output-file>")
}
let kernelDirectory = URL(fileURLWithPath: arguments[1], isDirectory: true)
let outputURL = URL(fileURLWithPath: arguments[2])

let promptsFile = "prompts.json"
let timingFile = "timing.json"
let prompts = loadJSON(kernelDirectory.appendingPathComponent(promptsFile))
let timing = loadJSON(kernelDirectory.appendingPathComponent(timingFile))

let farsiPrompt = string(prompts, "prompts.farsi.text", file: promptsFile)
let englishPrompt = string(prompts, "prompts.english.text", file: promptsFile)
let autoPrompt = string(prompts, "prompts.auto.text", file: promptsFile)

let maxSeconds = double(timing, "recording.maxSeconds", file: timingFile)
let silenceStopSeconds = double(timing, "recording.silenceStopSeconds", file: timingFile)
let minSpeechSeconds = double(timing, "recording.minSpeechSeconds", file: timingFile)
let silenceThresholdDb = double(timing, "recording.silenceThresholdDb.default", file: timingFile)
let leadInDefaultMs = int(timing, "recording.leadInDiscardMs.default", file: timingFile)
let leadInBluetoothMs = int(timing, "recording.leadInDiscardMs.bluetooth", file: timingFile)
let silenceGatePeakDb = double(timing, "recording.silenceGate.peakDb", file: timingFile)
let silenceGateMeanDb = double(timing, "recording.silenceGate.meanDb", file: timingFile)

let chunkTargetSeconds = double(timing, "chunking.targetSeconds", file: timingFile)
let chunkMaxSeconds = double(timing, "chunking.maxSeconds", file: timingFile)

let baseTimeoutSeconds = double(timing, "request.baseTimeoutSeconds", file: timingFile)
let timeoutPerAudioSecond = double(timing, "request.timeoutSecondsPerAudioSecond", file: timingFile)
let retryAttempts = int(timing, "request.retryAttempts", file: timingFile)
let reasoningEffort = string(timing, "request.reasoningEffort", file: timingFile)

let retryableStatuses = intArray(timing, "request.retry.retryable.httpStatus", file: timingFile)
let nonRetryableStatuses = intArray(timing, "request.retry.notRetryable.httpStatus", file: timingFile)
let retryNetwork = bool(timing, "request.retry.retryable.network", file: timingFile)
let retryMalformed = bool(timing, "request.retry.retryable.malformedResponse", file: timingFile)
let retryUnknownStatus = bool(timing, "request.retry.retryable.unknownHttpStatus", file: timingFile)
// Stored under notRetryable, so the flag is inverted to match the "is this
// worth another attempt?" sense the other Retry members carry.
let emptyResponseIsRetryable = !bool(timing, "request.retry.notRetryable.emptyResponse", file: timingFile)

guard let statusRanges = value(timing, "request.retry.retryable.httpStatusRanges", file: timingFile) as? [[NSNumber]],
      statusRanges.allSatisfy({ $0.count == 2 }) else {
    fail("\(timingFile): request.retry.retryable.httpStatusRanges must be pairs of numbers")
}

let sampleRate = double(timing, "audio.sampleRate", file: timingFile)
let channels = int(timing, "audio.channels", file: timingFile)
let bitsPerSample = int(timing, "audio.bitsPerSample", file: timingFile)
let wavHeaderBytes = int(timing, "audio.wavHeaderBytes", file: timingFile)

let rangeLiterals = statusRanges
    .map { "\($0[0].intValue)...\($0[1].intValue)" }
    .joined(separator: ", ")

let source = """
//
//  KernelDefaults.generated.swift
//  FarsiTalkWrite
//
//  GENERATED — do not edit.
//
//  Written by Tools/generate-kernel.swift from kernel/prompts.json and
//  kernel/timing.json, which are the single source of truth for every value
//  below. `make` regenerates this file whenever either JSON changes.
//
//  To change a prompt or a tuned number, edit the JSON in kernel/ and rebuild.
//  Editing this file directly is overwritten on the next build, and worse, it
//  silently desynchronises the Mac app from the npm package in packages/web,
//  which ships the same kernel to the web and the Telegram bot.
//

import Foundation

enum KernelDefaults {

    /// The transcription system prompts. See kernel/prompts.json for the intent
    /// behind each one — in particular that Latin words embedded in Persian must
    /// stay in Latin script, in place, neither translated nor transliterated.
    enum Prompts {
        static let farsi = \(literal(farsiPrompt))

        static let english = \(literal(englishPrompt))

        static let auto = \(literal(autoPrompt))
    }

    enum Recording {
        static let maxSeconds: Double = \(number(maxSeconds))
        /// How long a pause ends a recording. Dead air the user sits through
        /// after every sentence, so it is as short as it can be without clipping
        /// someone who pauses mid-thought.
        static let silenceStopSeconds: Double = \(number(silenceStopSeconds))
        /// Silence-stop arms only after this much speech, so the pause before you
        /// start talking cannot end the recording immediately.
        static let minSpeechSeconds: Double = \(number(minSpeechSeconds))
        /// The "default" entry of the per-device threshold table. AirPods run
        /// hotter and noisier than a built-in mic, so one global value does not
        /// work — this is the fallback, not the answer.
        static let silenceThresholdDb: Double = \(number(silenceThresholdDb))
        /// A Bluetooth (HFP) link needs time to negotiate; without discarding the
        /// lead-in the first syllable is noise.
        static let leadInDefaultMs: Int = \(leadInDefaultMs)
        static let leadInBluetoothMs: Int = \(leadInBluetoothMs)
        /// A clip is silent when peak is below this AND mean is below the next.
        /// Decided locally, before anything is uploaded.
        static let silenceGatePeakDb: Double = \(number(silenceGatePeakDb))
        static let silenceGateMeanDb: Double = \(number(silenceGateMeanDb))
    }

    enum Chunking {
        /// Above `Recording.maxSeconds` on purpose, so splitting never engages.
        /// See kernel/timing.json: concurrent requests on one key queue upstream,
        /// and two chunks of a 27.8s clip took 46s and 98s against ~12s whole.
        static let targetSeconds: Double = \(number(chunkTargetSeconds))
        static let maxSeconds: Double = \(number(chunkMaxSeconds))
    }

    enum Request {
        static let baseTimeoutSeconds: Double = \(number(baseTimeoutSeconds))
        /// Seconds of timeout headroom per second of audio uploaded. A flat
        /// timeout cannot upload a 2.4 MB clip on a slow link, so the longer you
        /// spoke the more likely you were to lose it — exactly backwards.
        static let timeoutSecondsPerAudioSecond: Double = \(number(timeoutPerAudioSecond))
        static let retryAttempts: Int = \(retryAttempts)
        /// "low", "medium", "high", or "" to omit the field. Gemini 3.x refuses
        /// to have reasoning disabled outright.
        static let reasoningEffort = \(literal(reasoningEffort))
    }

    /// The retry policy, as data, so the web and Telegram consumers match it.
    enum Retry {
        static let retryableStatuses: Set<Int> = [\(retryableStatuses.map(String.init).joined(separator: ", "))]
        /// A rejected key cannot change its mind and an unknown model will not
        /// appear. These are the only statuses that genuinely cannot succeed.
        static let nonRetryableStatuses: Set<Int> = [\(nonRetryableStatuses.map(String.init).joined(separator: ", "))]
        static let retryableStatusRanges: [ClosedRange<Int>] = [\(rangeLiterals)]
        static let network = \(retryNetwork)
        static let malformedResponse = \(retryMalformed)
        /// An unfamiliar status is more likely transient than permanent.
        static let unknownStatus = \(retryUnknownStatus)
        /// Whether an empty 200 is worth another attempt. It is not:
        /// temperature 0 means re-sending identical bytes returns an identical
        /// empty answer, so three attempts and two seconds of backoff only
        /// reconfirm what the first one said. Silence is decided locally now, so
        /// this no longer covers the case it was originally added for.
        static let emptyResponse = \(emptyResponseIsRetryable)

        /// Whether an HTTP status is worth another attempt.
        static func allowsRetry(status: Int) -> Bool {
            if nonRetryableStatuses.contains(status) { return false }
            if retryableStatuses.contains(status) { return true }
            if retryableStatusRanges.contains(where: { $0.contains(status) }) { return true }
            return unknownStatus
        }
    }

    enum Audio {
        /// Never cache the capture device's own rate — AirPods present 16/24 kHz
        /// where a built-in mic presents 48 kHz, and a cached rate produces
        /// chipmunked or slowed audio. Resample to this target instead.
        static let sampleRate: Double = \(number(sampleRate))
        static let channels: Int = \(channels)
        static let bitsPerSample: Int = \(bitsPerSample)
        /// A minimal RIFF/WAVE header, subtracted to get the payload size.
        static let wavHeaderBytes: Int = \(wavHeaderBytes)
        /// Bytes per second of audio at the target encoding.
        static let bytesPerSecond: Double = sampleRate * Double(channels) * Double(bitsPerSample / 8)
    }
}

"""

// Only write when the content actually changes, so an unchanged kernel does not
// touch the file's mtime and force swiftc to rebuild everything.
let existing = try? String(contentsOf: outputURL, encoding: .utf8)
if existing == source {
    print("kernel: KernelDefaults.generated.swift up to date")
} else {
    do {
        try source.write(to: outputURL, atomically: true, encoding: .utf8)
        print("kernel: wrote \(outputURL.lastPathComponent)")
    } catch {
        fail("cannot write \(outputURL.path): \(error.localizedDescription)")
    }
}
