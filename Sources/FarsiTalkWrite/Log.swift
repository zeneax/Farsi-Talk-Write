import Foundation
import os

/// Dual-purpose logging: os_log for Console.app when running as a bundled agent,
/// stderr for the CLI test subcommands where the user is watching a terminal.
enum FTWLog {
    private static let logger = Logger(subsystem: "com.shahram.farsitalkwrite", category: "app")

    /// Set by the CLI entry points so diagnostics appear in the terminal.
    nonisolated(unsafe) static var echoToStderr = false

    static func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
        echo("  \(message)")
        appendToFile("INFO", message)
    }

    static func warn(_ message: String) {
        logger.warning("\(message, privacy: .public)")
        echo("  ! \(message)")
        appendToFile("WARN", message)
    }

    static func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
        echo("  ✗ \(message)")
        appendToFile("ERROR", message)
    }

    private static func echo(_ line: String) {
        guard echoToStderr else { return }
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    // MARK: - File log
    //
    // os_log alone proved impossible to read back reliably for a bundled agent, and
    // a menu bar app has no console. A plain rolling file is what actually makes
    // problems diagnosable after the fact.

    static var logFileURL: URL {
        ConfigStore.directory.appendingPathComponent("farsitalkwrite.log")
    }

    private static let fileQueue = DispatchQueue(label: "com.shahram.farsitalkwrite.log")

    private static func appendToFile(_ level: String, _ message: String) {
        fileQueue.async {
            let stamp = ISO8601DateFormatter().string(from: Date())
            let line = "\(stamp) [\(level)] \(message)\n"
            guard let data = line.data(using: .utf8) else { return }

            let url = logFileURL
            try? FileManager.default.createDirectory(
                at: ConfigStore.directory, withIntermediateDirectories: true
            )

            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                // Keep the file from growing without bound across long uptimes.
                if (try? handle.seekToEnd()) ?? 0 > 512_000 {
                    try? handle.truncate(atOffset: 0)
                }
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url)
            }
        }
    }
}

/// Terminal output for CLI subcommands. Separate from FTWLog so that normal
/// command results are not tangled up with diagnostics.
enum Term {
    static func out(_ s: String = "") {
        print(s)
    }

    static func heading(_ s: String) {
        print("\n\(s)")
        print(String(repeating: "─", count: max(s.count, 8)))
    }

    static func row(_ label: String, _ value: String, ok: Bool? = nil) {
        let mark = switch ok {
        case .some(true): "✓"
        case .some(false): "✗"
        case .none: " "
        }
        print("  \(mark) \(label.padding(toLength: 24, withPad: " ", startingAt: 0)) \(value)")
    }
}
