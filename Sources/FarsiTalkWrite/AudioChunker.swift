//
//  AudioChunker.swift
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

/// Splits a long recording into pieces small enough to upload reliably.
///
/// A single 60-second clip is a 2.4 MB upload. On a slow or filtered link that is
/// exactly the request that times out — and the longer someone spoke, the more they
/// lose. Sending several small requests instead means each one completes quickly,
/// text appears as it arrives rather than all at the end, and a failure costs one
/// segment rather than the whole recording.
///
/// **Splitting happens at silence, never at a fixed interval.** Cutting audio every
/// N seconds regardless of content slices words in half, and a model handed half a
/// word transcribes it as a different word — so fixed chunking trades one problem
/// for a worse one. This finds the quietest gap near the target length and cuts
/// there, falling back to a hard cut only when someone talks continuously past the
/// maximum.
enum AudioChunker {

    struct Chunk {
        let wav: Data
        let index: Int
        let total: Int
        let duration: TimeInterval
    }

    static let sampleRate: Double = 16_000
    private static let headerBytes = 44

    /// Returns the whole recording as one chunk when it is short enough to send in
    /// a single request, otherwise splits it at silence boundaries.
    ///
    /// - Parameters:
    ///   - targetSeconds: preferred chunk length; a cut is sought near here.
    ///   - maxSeconds: hard ceiling — cut regardless of whether silence was found.
    ///   - minSeconds: never emit a fragment shorter than this.
    static func split(
        wav: Data,
        targetSeconds: Double = 12,
        maxSeconds: Double = 20,
        minSeconds: Double = 2,
        silenceThresholdDb: Double = -45
    ) -> [Chunk] {
        let pcm = wav.count > headerBytes ? wav.subdata(in: headerBytes..<wav.count) : Data()
        let totalSamples = pcm.count / 2
        let totalSeconds = Double(totalSamples) / sampleRate

        // Short enough to send whole: one request, full context, best accuracy.
        guard totalSeconds > maxSeconds else {
            return [Chunk(wav: wav, index: 1, total: 1, duration: totalSeconds)]
        }

        let samples = pcm.withUnsafeBytes { raw -> [Int16] in
            Array(raw.bindMemory(to: Int16.self))
        }

        var bounds: [Int] = [0]
        var cursor = 0

        while cursor < totalSamples {
            let remaining = totalSamples - cursor
            if Double(remaining) / sampleRate <= maxSeconds {
                break // last piece takes whatever is left
            }

            let target = cursor + Int(targetSeconds * sampleRate)
            let limit = min(cursor + Int(maxSeconds * sampleRate), totalSamples)
            let earliest = cursor + Int(minSeconds * sampleRate)

            let cut = quietestPoint(
                in: samples,
                from: max(earliest, target - Int(4 * sampleRate)),
                to: limit,
                thresholdDb: silenceThresholdDb
            ) ?? limit

            bounds.append(cut)
            cursor = cut
        }
        bounds.append(totalSamples)

        // Build a self-contained WAV per piece so each is a valid standalone upload.
        var chunks: [Chunk] = []
        for index in 0..<(bounds.count - 1) {
            let start = bounds[index], end = bounds[index + 1]
            guard end > start else { continue }

            let slice = pcm.subdata(in: (start * 2)..<(end * 2))
            let seconds = Double(end - start) / sampleRate
            chunks.append(Chunk(
                wav: AudioRecorder.wavData(fromPCM16: slice, sampleRate: sampleRate, channels: 1),
                index: chunks.count + 1,
                total: 0,
                duration: seconds
            ))
        }

        // Fill in the total now that it is known.
        return chunks.map {
            Chunk(wav: $0.wav, index: $0.index, total: chunks.count, duration: $0.duration)
        }
    }

    /// Finds the centre of the longest quiet run in a range — the safest place to
    /// cut, because it is furthest from any speech on either side.
    private static func quietestPoint(
        in samples: [Int16],
        from start: Int,
        to end: Int,
        thresholdDb: Double
    ) -> Int? {
        guard start < end, end <= samples.count else { return nil }

        let window = Int(0.02 * sampleRate)          // 20 ms
        let threshold = pow(10, thresholdDb / 20) * 32768.0

        var bestStart = -1, bestLength = 0
        var runStart = -1

        var position = start
        while position + window < end {
            var sum = 0.0
            for offset in position..<(position + window) {
                let value = Double(samples[offset])
                sum += value * value
            }
            let rms = (sum / Double(window)).squareRoot()

            if rms < threshold {
                if runStart < 0 { runStart = position }
                let length = position + window - runStart
                if length > bestLength { bestLength = length; bestStart = runStart }
            } else {
                runStart = -1
            }
            position += window
        }

        // Require a real pause, not just a momentary dip between syllables.
        guard bestStart >= 0, bestLength >= Int(0.15 * sampleRate) else { return nil }
        return bestStart + bestLength / 2
    }
}
