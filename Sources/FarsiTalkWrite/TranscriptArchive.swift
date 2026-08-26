//
//  TranscriptArchive.swift
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

/// Every transcript is appended to a plain-text archive, whether or not it was
/// successfully pasted anywhere.
///
/// The reasoning is the same as the pending-recordings queue: the expensive thing
/// is the sentence the user already said out loud. Insertion can fail for reasons
/// that have nothing to do with transcription — no text field focused, the target
/// app rejected the paste, the clipboard was contended — and in every one of those
/// cases the text itself was perfectly good. Writing it down first means it is
/// never the thing that gets lost.
///
/// Files roll at `maxFileBytes` so the archive stays openable in any editor:
/// transcript-001.txt, transcript-002.txt, and so on.
enum TranscriptArchive {

    /// Roll to a new file past this size. Small enough that any editor opens it
    /// instantly, large enough that files do not proliferate.
    static let maxFileBytes = 256 * 1024

    static var directory: URL {
        ConfigStore.directory.appendingPathComponent("transcripts", isDirectory: true)
    }

    /// All archive files, oldest first.
    static func files() -> [URL] {
        let found = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )) ?? []
        return found
            .filter { $0.pathExtension == "txt" && $0.lastPathComponent.hasPrefix("transcript-") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// The file currently being written to, rolling to a new one when the current
    /// file has grown past the limit.
    static func currentFile() -> URL {
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )

        guard let last = files().last else { return url(forIndex: 1) }

        let size = (try? last.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard size >= maxFileBytes else { return last }

        let index = indexOf(last) + 1
        return url(forIndex: index)
    }

    private static func url(forIndex index: Int) -> URL {
        directory.appendingPathComponent(String(format: "transcript-%03d.txt", index))
    }

    private static func indexOf(_ url: URL) -> Int {
        let name = url.deletingPathExtension().lastPathComponent
        return Int(name.replacingOccurrences(of: "transcript-", with: "")) ?? 1
    }

    /// Appends one transcript with a timestamp footer.
    ///
    /// The timestamp goes *after* the text rather than before it, so the archive
    /// reads as a continuous document you can copy from, rather than a log you have
    /// to strip prefixes out of.
    @discardableResult
    static func append(_ text: String, model: String? = nil, delivered: Bool) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let stamp = DateFormatter.archiveStamp.string(from: Date())
        var footer = "— \(stamp)"
        if let model { footer += " · \(model)" }
        if !delivered { footer += " · not inserted" }

        let entry = "\(trimmed)\n\(footer)\n\n"
        let url = currentFile()

        do {
            if FileManager.default.fileExists(atPath: url.path) {
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(entry.utf8))
            } else {
                try Data(entry.utf8).write(to: url, options: .atomic)
            }
            return url
        } catch {
            FTWLog.error("Could not append to transcript archive: \(error.localizedDescription)")
            return nil
        }
    }

    /// Total number of transcripts recorded, for display in menus.
    static func entryCount() -> Int {
        files().reduce(0) { total, url in
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            return total + text.components(separatedBy: "\n—").count - 1
        }
    }
}

private extension DateFormatter {
    static let archiveStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()
}
