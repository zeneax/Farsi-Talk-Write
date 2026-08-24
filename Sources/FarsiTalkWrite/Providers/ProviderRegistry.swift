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
    /// `fallbackProvider` if one is configured. A Google outage or a free-tier
    /// rate limit then becomes invisible rather than a failed dictation.
    static func transcribe(wav: Data, config: Config) async throws -> TranscriptionResult {
        let provider = try makeActive(config: config)

        // Transient network failures are common on VPNs and flaky links, and the
        // cost of giving up is the user's whole sentence. Retry the active
        // provider before falling back or surfacing an error.
        let attempts = max(1, config.retryAttempts)
        var lastError: Error?

        for attempt in 1...attempts {
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
