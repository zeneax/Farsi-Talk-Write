//
//  ProviderRegistry.swift
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

/// Turns config profiles into live provider instances. The two `kind` values cover
/// every endpoint we ship, so adding a provider is normally a config edit rather
/// than new Swift.
enum ProviderRegistry {

    static func make(profileID: String, config: Config) throws -> TranscriptionProvider {
        guard let profile = config.providers[profileID] else {
            throw ProviderError.badURL("unknown provider “\(profileID)”")
        }
        guard let key = Keychain.get(forProvider: profileID) else {
            throw ProviderError.missingAPIKey(profileName: profile.displayName)
        }

        switch profile.kind {
        case .geminiInteractions:
            return GeminiInteractionsProvider(profileID: profileID, profile: profile, apiKey: key)
        case .openAICompatible:
            return OpenAICompatibleProvider(profileID: profileID, profile: profile, apiKey: key)
        }
    }

    static func makeActive(config: Config) throws -> TranscriptionProvider {
        try make(profileID: config.activeProvider, config: config)
    }

    /// Transcribes with the active provider, falling back once to
    /// `fallbackProvider` if one is configured, and — when the final answer is
    /// still not a transcript — sending the same audio to the kernel's rescue
    /// engine. A Google outage, a free-tier rate limit or Gemini's safety filter
    /// then becomes a log line rather than a failed dictation.
    static func transcribe(
        wav: Data,
        config: Config,
        onAttempt: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> TranscriptionResult {
        do {
            return try await transcribeFirstEngine(wav: wav, config: config, onAttempt: onAttempt)
        } catch {
            // Which outcomes go to the second engine is kernel data, not a
            // judgement made here; the shape of the failure is all this decides.
            guard let outcome = rescueOutcome(for: error),
                  KernelDefaults.Rescue.on.contains(outcome) else { throw error }
            guard let profile = config.activeProfile, profile.supportsRescue else {
                FTWLog.info("First engine ended with \(outcome); \(config.activeProvider) has no \(KernelDefaults.Rescue.endpoint) endpoint, so there is no rescue.")
                throw error
            }
            FTWLog.warn("First engine ended with \(outcome); sending the same audio to \(KernelDefaults.Rescue.engine).")
            do {
                return try await rescue(wav: wav, config: config)
            } catch {
                FTWLog.warn("Rescue engine failed too: \(error.localizedDescription)")
            }
            // The original failure is the one to explain — and for a filtered
            // stop it carries whatever the first engine wrote before stopping.
            throw error
        }
    }

    /// The kernel's name for a final failure, or nil when no second engine
    /// could change the answer: a rejected key, an unknown model, a bad URL, and
    /// truncation, which has its own cure in the provider.
    static func rescueOutcome(for error: Error) -> String? {
        guard let error = error as? ProviderError else { return nil }
        switch error {
        case .filtered: return "filtered"
        case .emptyResponse: return "empty"
        case .network: return "transport"
        // A response that could not be read three times running is the
        // provider misbehaving, which is the same class as a network failure.
        case .malformedResponse: return "transport"
        case .http(let status, _, _):
            return KernelDefaults.Retry.allowsRetry(status: status) ? "transport" : nil
        case .truncated, .missingAPIKey, .badURL: return nil
        }
    }

    /// The second engine: the same bytes to the provider's transcription
    /// endpoint, which serves dedicated speech-to-text models with no safety
    /// filter, no prompt and no reasoning. What it loses against Gemini is
    /// orthography — a worse sentence rather than a lost one. The engine, the
    /// endpoint, the attempt count and the language hint are all kernel data.
    static func rescue(wav: Data, config: Config) async throws -> TranscriptionResult {
        guard let profile = config.activeProfile, profile.supportsRescue else {
            throw ProviderError.badURL("\(config.activeProvider) does not serve \(KernelDefaults.Rescue.endpoint)")
        }
        guard let key = Keychain.get(forProvider: config.activeProvider) else {
            throw ProviderError.missingAPIKey(profileName: profile.displayName)
        }

        let url = try ProviderHTTP.url(base: profile.baseURL, path: "/" + KernelDefaults.Rescue.endpoint)
        var body: [String: Any] = [
            "model": KernelDefaults.Rescue.engine,
            "input_audio": ["data": wav.base64EncodedString(), "format": "wav"],
        ]
        // Empty in the kernel means omit the field and let the engine detect,
        // which is what "auto" asks for.
        if let hint = KernelDefaults.Rescue.languageHint(forLanguage: config.language.rawValue) {
            body["language"] = hint
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        for (name, value) in profile.extraHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let attempts = max(1, KernelDefaults.Rescue.attempts)
        for attempt in 1...attempts {
            do {
                let json = try await ProviderHTTP.send(
                    request, timeout: profile.timeout(forAudioBytes: wav.count), model: KernelDefaults.Rescue.engine
                )
                let text = ((json as? [String: Any])?["text"] as? String)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !text.isEmpty else { throw ProviderError.emptyResponse }
                let tokens = ProviderHTTP.tokens(from: json)
                FTWLog.info("Rescue engine \(KernelDefaults.Rescue.engine) answered on attempt \(attempt)/\(attempts): \(text.count) characters.")
                return TranscriptionResult(
                    text: text, model: KernelDefaults.Rescue.engine,
                    inputTokens: tokens.input, outputTokens: tokens.output
                )
            } catch let error as ProviderError {
                // One more try on transport or a server-side status; none on
                // anything the request itself caused. 400 is retryable in the
                // generic policy for the reasoning-field case, which cannot
                // arise here — a 400 from this body is this body's fault.
                let again: Bool
                switch error {
                case .network, .malformedResponse: again = true
                case .http(let status, _, _): again = status != 400 && KernelDefaults.Retry.allowsRetry(status: status)
                default: again = false
                }
                guard again, attempt < attempts else { throw error }
                FTWLog.warn("Rescue attempt \(attempt)/\(attempts) failed: \(error.localizedDescription)")
                try? await Task.sleep(nanoseconds: 700_000_000)
            }
        }
        throw ProviderError.emptyResponse
    }

    /// The first engine: the active provider with its retries, then the
    /// configured fallback provider once.
    private static func transcribeFirstEngine(
        wav: Data,
        config: Config,
        onAttempt: (@Sendable (Int, Int) -> Void)?
    ) async throws -> TranscriptionResult {
        let provider = try makeActive(config: config)

        // Transient network failures are common on VPNs and flaky links, and the
        // cost of giving up is the user's whole sentence. Retry the active
        // provider before falling back or surfacing an error.
        let attempts = max(1, config.retryAttempts)
        var lastError: Error?

        for attempt in 1...attempts {
            onAttempt?(attempt, attempts)
            do {
                let result = try await provider.transcribe(wav: wav, prompt: config.activePrompt)
                if attempt > 1 {
                    FTWLog.info("Transcription succeeded on attempt \(attempt)/\(attempts).")
                }
                return result
            } catch let error as ProviderError {
                guard error.isTransient else { throw error }
                lastError = error
                FTWLog.warn("Transcription attempt \(attempt)/\(attempts) failed: \(error.localizedDescription)")
            } catch {
                lastError = error
                FTWLog.warn("Transcription attempt \(attempt)/\(attempts) failed: \(error.localizedDescription)")
            }

            if attempt < attempts {
                // Back off a little between tries so a rate limit has a chance to
                // clear rather than being hammered.
                try? await Task.sleep(nanoseconds: UInt64(attempt) * 700_000_000)
            }
        }

        if let fallbackID = config.fallbackProvider,
           fallbackID != config.activeProvider,
           config.providers[fallbackID] != nil,
           Keychain.hasKey(forProvider: fallbackID) {
            FTWLog.warn("Active provider exhausted; trying fallback “\(fallbackID)”.")
            let fallback = try make(profileID: fallbackID, config: config)
            return try await fallback.transcribe(wav: wav, prompt: config.activePrompt)
        }

        throw lastError ?? ProviderError.emptyResponse
    }

    /// Transcribes a recording, splitting it at silence when it is long enough that
    /// a single upload would be slow or timeout-prone.
    ///
    /// Pieces are sent **concurrently** and reassembled in order: a 60-second
    /// recording then costs roughly the time of its slowest piece rather than the
    /// sum of all of them. Order is preserved by index, not by completion.
    static func transcribeChunked(
        wav: Data,
        config: Config,
        onProgress: ((Int, Int) -> Void)? = nil,
        onAttempt: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> TranscriptionResult {

        let chunks = AudioChunker.split(
            wav: wav,
            targetSeconds: config.recording.chunkTargetSeconds,
            maxSeconds: config.recording.chunkMaxSeconds,
            silenceThresholdDb: config.recording.silenceThreshold(forDeviceUID: nil)
        )

        // Short recording: one request, full context, best possible accuracy.
        guard chunks.count > 1 else {
            return try await transcribe(wav: wav, config: config, onAttempt: onAttempt)
        }

        FTWLog.info("Split \(String(format: "%.1f", Double(wav.count - 44) / 32000))s recording into \(chunks.count) pieces at silence boundaries")
        onProgress?(0, chunks.count)

        var completed = 0
        let results = try await withThrowingTaskGroup(of: (Int, TranscriptionResult).self) { group -> [(Int, TranscriptionResult)] in
            // Bounded concurrency: enough to be fast, not enough to trip rate limits.
            let limit = 3
            var next = 0

            func addTask(_ i: Int) {
                group.addTask {
                    do {
                        FTWLog.info("Chunk \(i + 1)/\(chunks.count) sending (\(chunks[i].wav.count / 1024) KB)…")
                        let r = try await transcribe(wav: chunks[i].wav, config: config)
                        FTWLog.info("Chunk \(i + 1)/\(chunks.count) returned \(r.text.count) characters")
                        return (i, r)
                    } catch ProviderError.emptyResponse {
                        // A chunk that lands on a pause legitimately has nothing in
                        // it. Treating that as a failure would abort the sibling
                        // chunks too and lose a recording that mostly *did* contain
                        // speech — so an empty piece contributes an empty string.
                        FTWLog.info("Chunk \(i + 1)/\(chunks.count) contained no speech; continuing.")
                        return (i, TranscriptionResult(text: "", model: "", inputTokens: nil, outputTokens: nil))
                    }
                }
            }
            while next < min(limit, chunks.count) { addTask(next); next += 1 }

            var collected: [(Int, TranscriptionResult)] = []
            while let done = try await group.next() {
                collected.append(done)
                completed += 1
                onProgress?(completed, chunks.count)
                if next < chunks.count { addTask(next); next += 1 }
            }
            return collected
        }

        let ordered = results.sorted { $0.0 < $1.0 }.map(\.1)
        let text = ordered
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        // Only genuinely empty when *every* piece was empty.
        guard !text.isEmpty else { throw ProviderError.emptyResponse }

        let spoken = ordered.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
        if spoken < ordered.count {
            FTWLog.info("\(spoken)/\(ordered.count) chunks contained speech; joined what was there.")
        }

        return TranscriptionResult(
            text: text,
            model: ordered.first?.model ?? "",
            inputTokens: ordered.compactMap(\.inputTokens).reduce(0, +),
            outputTokens: ordered.compactMap(\.outputTokens).reduce(0, +)
        )
    }

    // MARK: - Cost estimation

    /// Published prices per 1M tokens, used only for the Test button's estimate.
    /// Unknown models simply report no estimate rather than guessing.
    private static let pricing: [String: (input: Double, output: Double)] = [
        "gemini-3.1-pro-preview": (2.00, 12.00),
        "gemini-3.7-flash": (0.75, 3.75),
        "gemini-3.6-flash": (0.75, 3.75),
        "gemini-3.5-flash": (1.50, 9.00),
        "gemini-3.5-flash-lite": (0.30, 2.50),
        "gemini-3.1-flash-lite": (0.50, 1.50),
    ]

    /// OpenRouter resells some models below Google's list price, so a shared table
    /// keyed only on the bare model name would overstate cost there.
    private static let openRouterPricing: [String: (input: Double, output: Double)] = [
        "google/gemini-3.7-flash": (0.375, 1.875),
        "google/gemini-3.6-flash": (0.75, 3.75),
        "google/gemini-3.5-flash": (1.50, 9.00),
        "google/gemini-3.1-flash-lite": (0.25, 1.50),
        "google/gemini-3.1-pro-preview": (2.00, 12.00),
    ]

    static func estimatedCost(for result: TranscriptionResult) -> String? {
        let bareModel = result.model.contains("/")
            ? String(result.model.split(separator: "/").last!)
            : result.model

        guard let price = openRouterPricing[result.model] ?? pricing[bareModel],
              let input = result.inputTokens,
              let output = result.outputTokens
        else { return nil }

        let cost = Double(input) / 1_000_000 * price.input
                 + Double(output) / 1_000_000 * price.output

        if cost < 0.01 {
            return String(format: "~$%.4f", cost)
        }
        return String(format: "~$%.2f", cost)
    }

    /// Models known to be free on Google's tier, for the Setup Guide's plain-language
    /// confirmation. Pro left the free tier on 2026-04-01.
    static let freeTierModels: Set<String> = [
        "gemini-3.7-flash",
        "gemini-3.5-flash",
        "gemini-3.5-flash-lite",
        "gemini-3.1-flash-lite",
    ]

    static func isFreeTierModel(_ model: String) -> Bool {
        freeTierModels.contains(model)
    }
}
