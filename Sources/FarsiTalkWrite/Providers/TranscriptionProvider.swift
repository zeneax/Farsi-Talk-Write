//
//  TranscriptionProvider.swift
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

struct TranscriptionResult {
    let text: String
    let model: String
    let inputTokens: Int?
    let outputTokens: Int?

    var tokenSummary: String {
        switch (inputTokens, outputTokens) {
        case let (.some(input), .some(output)):
            return "\(input) in / \(output) out"
        case let (.some(input), .none):
            return "\(input) in"
        default:
            return "tokens not reported"
        }
    }
}

protocol TranscriptionProvider {
    var profileID: String { get }
    var profile: ProviderProfile { get }

    func transcribe(wav: Data, prompt: String) async throws -> TranscriptionResult
    func listModels() async throws -> [String]
}

/// Errors are written for the Setup Guide and the Settings Test button, which show
/// them verbatim to someone who has never seen an HTTP status code.
enum ProviderError: LocalizedError {
    case missingAPIKey(profileName: String)
    case badURL(String)
    case http(status: Int, body: String, model: String)
    case emptyResponse
    case malformedResponse(String)
    case network(String)

    var errorDescription: String? {
        switch self {
        case .missingAPIKey(let name):
            return "No API key saved for “\(name)”. Add one in Settings → Providers."

        case .badURL(let url):
            return "“\(url)” is not a valid endpoint URL."

        case .http(let status, let body, let model):
            return Self.explain(status: status, body: body, model: model)

        case .emptyResponse:
            return "The model returned no text. If you did not speak, this is expected."

        case .malformedResponse(let detail):
            return "Could not read the response: \(detail)"

        case .network(let detail):
            return "Network error: \(detail)"
        }
    }

    /// Whether retrying could plausibly succeed.
    ///
    /// 400 is included deliberately. In principle a bad request never fixes
    /// itself, but in practice providers return 400 for temporary server-side
    /// conditions too — this app hit exactly that with "Reasoning is mandatory
    /// for this endpoint". Given a retry costs a fraction of a cent and the
    /// alternative is discarding something the user already said out loud, the
    /// trade is worth it.
    ///
    /// Still excluded are the failures that genuinely cannot succeed on a retry:
    /// a rejected key, an unknown model, a missing key, a malformed URL.
    var isTransient: Bool {
        switch self {
        case .network:
            return true
        case .http(let status, _, _):
            switch status {
            case 401, 403, 404: return false
            case 400, 429: return true
            case 500...599: return true
            default: return true
            }
        case .malformedResponse:
            return true
        case .missingAPIKey, .badURL, .emptyResponse:
            return false
        }
    }

    /// Turns the three failures that actually happen in practice into advice.
    private static func explain(status: Int, body: String, model: String) -> String {
        let detail = body.isEmpty ? "" : "\n\n\(body.prefix(400))"
        switch status {
        case 400:
            // Lead with the provider's own message; it is nearly always more
            // specific than anything guessed from the status code alone.
            let reason = body.isEmpty ? "" : "\n\n\(body.prefix(400))"
            return "The request was rejected (HTTP 400) by the provider.\(reason)"
        case 401, 403:
            return "Key rejected (HTTP \(status)) — check that you copied the whole key, and that it belongs to the right project.\(detail)"
        case 404:
            return "Model “\(model)” not found (HTTP 404). Check the model name in Settings → Providers.\(detail)"
        case 429:
            return "Rate limit or quota reached (HTTP 429). On the free tier this means waiting, or switching to a paid profile.\(detail)"
        case 500...599:
            return "The provider had a server error (HTTP \(status)). This is usually temporary.\(detail)"
        default:
            return "Request failed (HTTP \(status)).\(detail)"
        }
    }
}

// MARK: - Shared HTTP helpers

enum ProviderHTTP {
    static func session(timeout: Double) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout + 15
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }

    /// Returns the parsed JSON as `Any`, not `[String: Any]`: the Interactions API
    /// answers with a top-level *array* in at least some cases (confirmed against
    /// the live endpoint), so callers must tolerate either shape.
    static func send(
        _ request: URLRequest,
        timeout: Double,
        model: String
    ) async throws -> Any {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session(timeout: timeout).data(for: request)
        } catch {
            throw ProviderError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw ProviderError.malformedResponse("no HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            // Error bodies are shown to the user and written to the log file. A
            // provider echoing the submitted key back in an error would otherwise
            // leak it to disk, so redact anything key-shaped first.
            throw ProviderError.http(status: http.statusCode, body: redactingSecrets(body), model: model)
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) else {
            throw ProviderError.malformedResponse("response was not valid JSON")
        }
        return json
    }

    /// Usage blocks differ between APIs and change over time; try the known
    /// spellings rather than failing a whole transcription over a token count.
    /// Walks into arrays, since usage may ride on the last chunk.
    static func tokens(from json: Any) -> (input: Int?, output: Int?) {
        if let array = json as? [Any] {
            for element in array.reversed() {
                let found = tokens(from: element)
                if found.input != nil || found.output != nil { return found }
            }
            return (nil, nil)
        }

        guard let dict = json as? [String: Any] else { return (nil, nil) }
        guard let usage = dict["usage"] as? [String: Any]
                ?? dict["usageMetadata"] as? [String: Any] else {
            return (nil, nil)
        }

        let inputKeys = ["input_tokens", "inputTokens", "prompt_tokens", "promptTokenCount"]
        let outputKeys = ["output_tokens", "outputTokens", "completion_tokens", "candidatesTokenCount"]

        let input = inputKeys.compactMap { usage[$0] as? Int }.first
        let output = outputKeys.compactMap { usage[$0] as? Int }.first
        return (input, output)
    }

    /// Masks anything shaped like an API key. Deliberately pattern-based rather
    /// than comparing against the stored key, so a key from any provider — or one
    /// the user has since rotated — is still caught.
    static func redactingSecrets(_ text: String) -> String {
        let patterns = [
            "AIza[0-9A-Za-z_\\-]{20,}",        // Google
            "sk-or-v1-[0-9a-fA-F]{20,}",       // OpenRouter
            "sk-[A-Za-z0-9]{20,}",             // OpenAI-style
            "AQ\\.[A-Za-z0-9_\\-]{20,}",       // newer Google format
            "Bearer\\s+[A-Za-z0-9._\\-]{20,}", // any bearer token
        ]

        var redacted = text
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            redacted = regex.stringByReplacingMatches(
                in: redacted,
                range: NSRange(redacted.startIndex..., in: redacted),
                withTemplate: "«redacted»"
            )
        }
        return redacted
    }

    static func url(base: String, path: String) throws -> URL {
        let trimmed = base.hasSuffix("/") ? String(base.dropLast()) : base
        guard let url = URL(string: trimmed + path) else {
            throw ProviderError.badURL(trimmed + path)
        }
        return url
    }
}
