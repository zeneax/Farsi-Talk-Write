import AppKit
import CoreGraphics

/// Puts transcribed Farsi at the user's cursor, wherever that is.
enum TextInserter {

    enum InsertError: LocalizedError {
        case accessibilityDenied
        case eventCreationFailed

        var errorDescription: String? {
            switch self {
            case .accessibilityDenied:
                return "Accessibility permission is required to type into other apps."
            case .eventCreationFailed:
                return "Could not create the keyboard event."
            }
        }
    }

    private static let virtualKeyV: CGKeyCode = 9

    static func insert(_ text: String, mode: InsertionMode, bidiIsolation: Bool = true) throws {
        guard !text.isEmpty else { return }
        guard Permissions.accessibility.isGranted else { throw InsertError.accessibilityDenied }

        // Strip first so re-inserting previously produced text cannot accumulate
        // layers of invisible marks.
        let cleaned = BidiText.stripping(text)
        let prepared = bidiIsolation ? BidiText.directionallyMarked(cleaned) : cleaned

        switch mode {
        case .paste: try paste(prepared)
        case .type:  try typeUnicode(prepared)
        }
    }

    // MARK: - Paste (default)

    /// Clipboard round-trip is the reliable path for RTL Farsi: synthetic ⌘V is
    /// handled correctly by essentially every app, where synthesised key events
    /// for non-Latin text are not.
    private static func paste(_ text: String) throws {
        let pasteboard = NSPasteboard.general
        let saved = snapshot(pasteboard)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let ourChangeCount = pasteboard.changeCount

        try postCommandV()

        // Restore the user's clipboard, but only if nothing else has written to it
        // in the meantime — otherwise we would clobber something they just copied.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            guard pasteboard.changeCount == ourChangeCount else {
                FTWLog.info("Clipboard changed during paste; leaving the new contents alone.")
                return
            }
            restore(saved, to: pasteboard)
        }
    }

    private static func postCommandV() throws {
        let source = CGEventSource(stateID: .combinedSessionState)

        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: virtualKeyV, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: virtualKeyV, keyDown: false)
        else { throw InsertError.eventCreationFailed }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }

    private static func snapshot(_ pasteboard: NSPasteboard) -> [[String: Data]] {
        (pasteboard.pasteboardItems ?? []).map { item in
            var stored: [String: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    stored[type.rawValue] = data
                }
            }
            return stored
        }
    }

    private static func restore(_ snapshot: [[String: Data]], to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !snapshot.isEmpty else { return }

        let items: [NSPasteboardItem] = snapshot.map { stored in
            let item = NSPasteboardItem()
            for (type, data) in stored {
                item.setData(data, forType: NSPasteboard.PasteboardType(type))
            }
            return item
        }
        pasteboard.writeObjects(items)
    }

    // MARK: - Unicode typing (fallback)

    /// For apps that mishandle synthetic paste. Slower, but types Farsi correctly.
    /// CGEvent accepts at most a small number of UTF-16 units per event, so the
    /// string is sent in chunks.
    private static func typeUnicode(_ text: String) throws {
        let source = CGEventSource(stateID: .combinedSessionState)
        let units = Array(text.utf16)
        let chunkSize = 16

        var index = 0
        while index < units.count {
            let end = min(index + chunkSize, units.count)
            var chunk = Array(units[index..<end])

            guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            else { throw InsertError.eventCreationFailed }

            keyDown.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
            keyUp.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)

            keyDown.post(tap: .cghidEventTap)
            keyUp.post(tap: .cghidEventTap)

            index = end
            usleep(2000) // let the target app keep up
        }
    }
}
