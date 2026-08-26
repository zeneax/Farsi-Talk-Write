//
//  GeminiInteractionsProvider.swift
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

/// Google's Interactions API:
///   POST {baseURL}/interactions   with  x-goog-api-key
///   body   { model, input: [ {type:text}, {type:audio, data, mime_type} ] }
///   text   steps[] where type == "model_output" → content[] where type == "text"
///
/// Filtering by `model_output` is what keeps a thinking model's reasoning steps
/// out of the text that gets pasted into the user's cursor.
struct GeminiInteractionsProvider: TranscriptionProvider {
    let profileID: String
    let profile: ProviderProfile
    let apiKey: String

    func transcribe(wav: Data, prompt: String) async throws -> TranscriptionResult {
        let url = try ProviderHTTP.url(base: profile.baseURL, path: "/interactions")

        let body: [String: Any] = [
            "model": profile.model,
            "input": [
                ["type": "text", "text": prompt],
                [
                    "type": "audio",
                    "data": wav.base64EncodedString(),
                    "mime_type": "audio/wav",
                ],
            ],
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        for (name, value) in profile.extraHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let json = try await ProviderHTTP.send(
            request, timeout: profile.timeoutSeconds, model: profile.model
        )

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
        // The endpoint can answer with a top-level array; concatenate its parts.
        if let array = json as? [Any] {
            let joined = array.map { extractText(from: $0) }.joined()
            return joined.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let json = json as? [String: Any] else { return "" }

        // Preferred shape: steps[] → content[] → text
        if let steps = json["steps"] as? [[String: Any]] {
            let pieces = steps
                .filter { ($0["type"] as? String) == "model_output" }
                .flatMap { ($0["content"] as? [[String: Any]]) ?? [] }
                .filter { ($0["type"] as? String) == "text" }
                .compactMap { $0["text"] as? String }

            let joined = pieces.joined()
            if !joined.isEmpty { return joined.trimmingCharacters(in: .whitespacesAndNewlines) }
        }

        // Convenience field some SDK-shaped responses include.
        if let direct = json["output_text"] as? String, !direct.isEmpty {
            return direct.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Fallback for the older generateContent shape, in case a base URL is
        // pointed at a v1beta models endpoint instead.
        if let candidates = json["candidates"] as? [[String: Any]],
           let first = candidates.first,
           let content = first["content"] as? [String: Any],
           let parts = content["parts"] as? [[String: Any]] {
            let joined = parts.compactMap { $0["text"] as? String }.joined()
            return joined.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return ""
    }

    func listModels() async throws -> [String] {
        let url = try ProviderHTTP.url(base: profile.baseURL, path: "/models")

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        for (name, value) in profile.extraHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }

        let json = try await ProviderHTTP.send(
            request, timeout: profile.timeoutSeconds, model: profile.model
        )

        guard let dict = json as? [String: Any],
              let models = dict["models"] as? [[String: Any]] else { return [] }
        return models
            .compactMap { $0["name"] as? String }
            // Names come back as "models/gemini-3.7-flash"; the request wants the bare id.
            .map { $0.hasPrefix("models/") ? String($0.dropFirst("models/".count)) : $0 }
            .sorted()
    }
}
