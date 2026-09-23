//
//  OpenAICompatibleProvider.swift
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

/// The OpenAI chat-completions shape, which OpenRouter, Groq, together.ai, LM Studio
/// and most local servers all speak:
///   POST {baseURL}/chat/completions   with  Authorization: Bearer
///   audio as an `input_audio` content part
///   text  at choices[0].message.content
///
/// Not every server of this shape accepts audio; the Settings Test button is what
/// surfaces that, rather than discovering it mid-dictation.
struct OpenAICompatibleProvider: TranscriptionProvider {
    let profileID: String
    let profile: ProviderProfile
    let apiKey: String

    func transcribe(wav: Data, prompt: String) async throws -> TranscriptionResult {
        let url = try ProviderHTTP.url(base: profile.baseURL, path: "/chat/completions")

        var body: [String: Any] = [
            "model": profile.model,
            // Bounded so a confused model cannot run away and stall the round-trip.
            // A ceiling, not a budget — see kernel/timing.json. If the model does
            // hit it, the answer below is to raise it and re-send, not to paste
            // half a sentence.
            "max_tokens": KernelDefaults.Request.maxOutputTokens,
            "temperature": 0,
            "messages": [
                [
                    "role": "user",
                    "content": [
                        ["type": "text", "text": prompt],
                        [
                            "type": "input_audio",
                            "input_audio": [
                                "data": wav.base64EncodedString(),
                                "format": "wav",
                            ],
                        ],
                    ],
                ]
            ],
        ]

        // Transcription needs no deliberation, and the thinking tokens are pure
        // latency — measured 8.1s with default reasoning versus 5.5s at "low".
        // Gemini 3.x refuses to have reasoning disabled outright ("Reasoning is
        // mandatory for this endpoint"), so the lever is effort, not on/off.
        // An empty string omits the field entirely for providers that dislike it.
        if !profile.reasoningEffort.isEmpty {
            body["reasoning"] = ["effort": profile.reasoningEffort]
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        for (name, value) in profile.extraHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        var json: Any
        do {
            json = try await ProviderHTTP.send(
                request, timeout: profile.timeout(forAudioBytes: wav.count), model: profile.model
            )
        } catch ProviderError.http(let status, let responseBody, _)
                    where status == 400 && responseBody.lowercased().contains("reasoning") {
            // The provider objected specifically to the reasoning field. Rather
            // than fail the user's dictation, resend without it.
            FTWLog.warn("Provider rejected the reasoning setting; retrying without it.")
            body.removeValue(forKey: "reasoning")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            json = try await ProviderHTTP.send(
                request, timeout: profile.timeout(forAudioBytes: wav.count), model: profile.model
            )
        }

        // Truncation is the only failure in this path that arrives disguised as a
        // success: HTTP 200, plausible Persian, and a sentence that simply stops.
        // Pasted unchecked it reads as a complete transcript, so the user has no
        // way to know the model was cut off. Re-sending identically would truncate
        // in the same place at temperature 0 — the fix is a bigger ceiling.
        if Self.hitOutputCeiling(json) {
            FTWLog.warn("""
                Model stopped at the \(KernelDefaults.Request.maxOutputTokens)-token ceiling; \
                re-sending with \(KernelDefaults.Request.maxOutputTokensOnTruncation).
                """)
            body["max_tokens"] = KernelDefaults.Request.maxOutputTokensOnTruncation
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            json = try await ProviderHTTP.send(
                request, timeout: profile.timeout(forAudioBytes: wav.count), model: profile.model
            )
            // Still truncated at twice the room means the model is looping rather
            // than transcribing, and more room would only produce more nonsense.
            if Self.hitOutputCeiling(json) { throw ProviderError.truncated }
        }

        // A safety stop is checked before the empty-text branch, because a stop
        // with no words written looks exactly like an empty answer and the two
        // want opposite handling: empty is final, filtered goes to the rescue
        // engine. Gemini trips this on ordinary speech at temperature 0 — 1 of
        // 51 dictations and 9 of 37 meeting pieces on the Mazarix site.
        let reasons = Self.finishReasons(from: json)
        if KernelDefaults.Rescue.isFiltered(finishReason: reasons.finish, nativeFinishReason: reasons.native) {
            let partial = Self.extractText(from: json)
            FTWLog.warn("Provider stopped on content (\(reasons.finish ?? "?") / \(reasons.native ?? "?")); \(partial.isEmpty ? "nothing" : "\(partial.count) characters") written before the stop.")
            throw ProviderError.filtered(partial: partial)
        }

        let text = Self.extractText(from: json)
        guard !text.isEmpty else { throw ProviderError.emptyResponse }

        let tokens = ProviderHTTP.tokens(from: json)
        return TranscriptionResult(
            text: text,
            model: profile.model,
            inputTokens: tokens.input,
            outputTokens: tokens.output
        )
    }

    /// Whether the model stopped because it ran out of room rather than because
    /// it had finished.
    ///
    /// Both spellings are checked: OpenRouter normalises this to `finish_reason`
    /// = "length", and also passes the upstream verdict through untouched as
    /// `native_finish_reason`, which on Gemini is "MAX_TOKENS". A server that
    /// reports only the native form would otherwise look like a clean stop.
    static func hitOutputCeiling(_ json: Any) -> Bool {
        let reasons = finishReasons(from: json)
        return [reasons.finish, reasons.native]
            .compactMap { $0?.lowercased() }
            .contains { $0 == "length" || $0 == "max_tokens" }
    }

    /// Both finish-reason fields of the first choice, untouched. `finish_reason`
    /// is the OpenAI-compatible word; `native_finish_reason` is the upstream
    /// model's own verdict passed through, and for Gemini it is the one that
    /// actually says what happened ("MAX_TOKENS", "SAFETY").
    static func finishReasons(from json: Any) -> (finish: String?, native: String?) {
        guard let json = json as? [String: Any],
              let choice = (json["choices"] as? [[String: Any]])?.first
        else { return (nil, nil) }
        return (choice["finish_reason"] as? String, choice["native_finish_reason"] as? String)
    }

    static func extractText(from json: Any) -> String {
        guard let json = json as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any]
        else { return "" }

        if let content = message["content"] as? String {
            return content.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Some servers return content as an array of parts. Take the last one
        // rather than joining them all: on Gemini 3 a thought summary arrives as
        // an ordinary text part, not a reasoning part, and joining glues the
        // model's internal monologue onto the front of the transcript — which
        // then gets pasted at the user's cursor. With reasoning at minimum there
        // is normally one part and this returns it unchanged; it earns its keep
        // on the runs where the model narrates itself anyway.
        if let parts = message["content"] as? [[String: Any]] {
            let texts = parts.compactMap { $0["text"] as? String }.filter { !$0.isEmpty }
            return (texts.last ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ""
    }

    func listModels() async throws -> [String] {
        let url = try ProviderHTTP.url(base: profile.baseURL, path: "/models")

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        for (name, value) in profile.extraHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }

        let json = try await ProviderHTTP.send(
            request, timeout: profile.timeoutSeconds, model: profile.model
        )

        guard let dict = json as? [String: Any],
              let models = dict["data"] as? [[String: Any]] else { return [] }
        return models.compactMap { $0["id"] as? String }.sorted()
    }
}
