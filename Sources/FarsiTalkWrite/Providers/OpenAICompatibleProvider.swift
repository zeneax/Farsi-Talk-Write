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
            "max_tokens": 2048,
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

        let json: Any
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

    static func extractText(from json: Any) -> String {
        guard let json = json as? [String: Any],
              let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any]
        else { return "" }

        if let content = message["content"] as? String {
            return content.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Some servers return content as an array of parts.
        if let parts = message["content"] as? [[String: Any]] {
            let joined = parts.compactMap { $0["text"] as? String }.joined()
            return joined.trimmingCharacters(in: .whitespacesAndNewlines)
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
