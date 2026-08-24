import Foundation

/// Keeps embedded Latin words where they belong inside right-to-left text.
///
/// The model returns the correct *logical* order — «می‌خواهم این PDF را باز کنم»
/// really does have "PDF" in the middle. The problem is display: the Unicode
/// Bidirectional Algorithm resolves neutral characters (spaces, punctuation)
/// around a Latin run according to the surrounding context, and in a mixed
/// paragraph that routinely flings the Latin word to the visual start or end of
/// the line, changing what the sentence appears to say.
///
/// Two marks fix it:
///
///  * **RLM** (U+200F) at the front pins the paragraph's base direction to RTL,
///    so a sentence that happens to begin with a Latin word is not rendered
///    left-to-right in its entirety.
///  * **FSI…PDI** (U+2068…U+2069) around each Latin run isolates it, so the bidi
///    algorithm treats the run as a single neutral unit sitting exactly where it
///    appears in logical order, instead of letting it interact with its
///    neighbours.
///
/// Isolates are used rather than the older LRE/PDF embeddings because isolates
/// are what Unicode now recommends: they do not leak direction into surrounding
/// text.
enum BidiText {

    static let rightToLeftMark = "\u{200F}"      // RLM
    static let firstStrongIsolate = "\u{2068}"   // FSI
    static let popDirectionalIsolate = "\u{2069}" // PDI

    /// Characters that belong to a Latin "word" even though they are not letters:
    /// version numbers, file extensions, hyphenated names, URLs.
    private static let runConnectors = Set(".-_/+#@&'’:")

    /// Wraps every Latin run in isolates and pins the base direction, but only
    /// when the text is genuinely mixed. Pure Persian or pure English is returned
    /// untouched, so no invisible characters are added where they earn nothing.
    /// Applies directional marking to transcribed text.
    ///
    /// Runs whenever the text contains RTL, even with no Latin in it, because
    /// sentence-final punctuation needs fixing either way (see `terminated`).
    ///
    /// Each line is treated separately: the bidi algorithm resolves per paragraph,
    /// so a mark at the very start of a multi-line block would not govern the
    /// lines below it.
    static func directionallyMarked(_ text: String) -> String {
        guard containsRTL(text) else { return text }

        let lines = text.components(separatedBy: "\n")
        return lines.map { line -> String in
            guard containsRTL(line) else { return line }
            let isolated = containsLatin(line)
                ? isolatingLatinRuns(in: line)
                : rightToLeftMark + line
            return terminated(isolated)
        }.joined(separator: "\n")
    }

    /// Pins trailing punctuation to the correct end of the line.
    ///
    /// A sentence-final "." or "؟" is a *neutral* character: it has no direction
    /// of its own and takes it from context. At the end of a line there is no
    /// following strong character to inherit from, so it falls back to the
    /// paragraph direction — and when the host app resolves that as left-to-right,
    /// the full stop is rendered at the far right, which a Persian reader sees as
    /// the beginning of the line. Appending an RLM gives the neutral a strong
    /// right-to-left neighbour to attach to, so it stays where the sentence ends.
    private static func terminated(_ text: String) -> String {
        guard let last = text.last, isNeutralPunctuation(last) else { return text }
        return text + rightToLeftMark
    }

    private static func isNeutralPunctuation(_ character: Character) -> Bool {
        // Deliberately narrow: only the characters that actually end a sentence.
        ".!?;:،؛؟…»)]}\"'".contains(character)
    }

    static func isolatingLatinRuns(in text: String) -> String {
        guard containsRTL(text), containsLatin(text) else { return text }

        var result = rightToLeftMark
        var index = text.startIndex

        while index < text.endIndex {
            guard isLatinLetter(text[index]) || isASCIIDigit(text[index]) else {
                result.append(text[index])
                index = text.index(after: index)
                continue
            }

            let runStart = index
            var runEnd = index

            // Extend through letters, digits and connectors, but only keep a
            // connector if a Latin character follows it — otherwise a trailing
            // full stop would be swallowed into the isolate and end up misplaced.
            while runEnd < text.endIndex {
                let character = text[runEnd]
                if isLatinLetter(character) || isASCIIDigit(character) {
                    runEnd = text.index(after: runEnd)
                } else if character == " " || runConnectors.contains(character) {
                    let next = text.index(after: runEnd)
                    guard next < text.endIndex,
                          isLatinLetter(text[next]) || isASCIIDigit(text[next])
                    else { break }
                    runEnd = next
                } else {
                    break
                }
            }

            let run = String(text[runStart..<runEnd])
            result += firstStrongIsolate + run + popDirectionalIsolate
            index = runEnd
        }

        return result
    }

    /// Removes any marks we added, so round-tripping text through the app twice
    /// does not accumulate invisible characters.
    static func stripping(_ text: String) -> String {
        text.replacingOccurrences(of: rightToLeftMark, with: "")
            .replacingOccurrences(of: firstStrongIsolate, with: "")
            .replacingOccurrences(of: popDirectionalIsolate, with: "")
    }

    // MARK: - Classification

    static func containsRTL(_ text: String) -> Bool {
        text.unicodeScalars.contains(where: isRTLScalar)
    }

    static func containsLatin(_ text: String) -> Bool {
        text.contains(where: isLatinLetter)
    }

    /// Arabic, Persian, Hebrew and their supplements/presentation forms.
    private static func isRTLScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0590...0x05FF,   // Hebrew
             0x0600...0x06FF,   // Arabic (includes Persian letters)
             0x0700...0x074F,   // Syriac
             0x0750...0x077F,   // Arabic Supplement
             0x08A0...0x08FF,   // Arabic Extended-A
             0xFB50...0xFDFF,   // Arabic Presentation Forms-A
             0xFE70...0xFEFF:   // Arabic Presentation Forms-B
            return true
        default:
            return false
        }
    }

    private static func isLatinLetter(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first,
              character.unicodeScalars.count >= 1 else { return false }
        return (scalar.value >= 0x41 && scalar.value <= 0x5A)
            || (scalar.value >= 0x61 && scalar.value <= 0x7A)
            || (scalar.value >= 0xC0 && scalar.value <= 0x24F)  // accented Latin
    }

    private static func isASCIIDigit(_ character: Character) -> Bool {
        character.isASCII && character.isNumber
    }
}
