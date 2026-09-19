/**
 * Keeps embedded Latin words where they belong inside right-to-left text.
 *
 * A port of `Sources/FarsiTalkWrite/BidiText.swift`, held to that behaviour by
 * `kernel/bidi-cases.json` — a fixture both implementations run. A case that
 * passes in one and fails in the other is the entire reason the file is shared.
 *
 * The problem: a transcription model returns the correct *logical* order —
 * «می‌خواهم این PDF را باز کنم» really does have "PDF" in the middle. Display is
 * where it goes wrong. The Unicode Bidirectional Algorithm resolves neutral
 * characters (spaces, punctuation) around a Latin run from the surrounding
 * context, and in a mixed paragraph that routinely flings the Latin word to the
 * visual start or end of the line, changing what the sentence appears to say.
 *
 * Two marks fix it:
 *
 *  - **RLM** (U+200F) at the front pins the paragraph's base direction to RTL,
 *    so a sentence that happens to begin with a Latin word is not rendered
 *    left-to-right in its entirety.
 *  - **FSI…PDI** (U+2068…U+2069) around each Latin run isolates it, so the
 *    algorithm treats the run as a single neutral unit sitting exactly where it
 *    appears in logical order, instead of letting it interact with its
 *    neighbours.
 *
 * Isolates rather than the older LRE/PDF embeddings, because isolates are what
 * Unicode now recommends: they do not leak direction into surrounding text.
 *
 * **Do not send marked text to a terminal, a code editor, or a plain-text log.**
 * Those render the marks as literal `⁨` escapes instead of applying them. Send
 * {@link stripping} output there and marked output only to a surface that
 * actually implements bidi. See the package README.
 */

/** U+200F RIGHT-TO-LEFT MARK. */
export const RIGHT_TO_LEFT_MARK = "‏";
/** U+2068 FIRST STRONG ISOLATE. */
export const FIRST_STRONG_ISOLATE = "⁨";
/** U+2069 POP DIRECTIONAL ISOLATE. */
export const POP_DIRECTIONAL_ISOLATE = "⁩";

/**
 * Characters that belong to a Latin "word" even though they are not letters:
 * version numbers, file extensions, hyphenated names, URLs.
 *
 * The space is handled alongside these by the same rule.
 */
const RUN_CONNECTORS = new Set([
  ".", "-", "_", "/", "+", "#", "@", "&", "'", "’", ":",
]);

/**
 * Characters that end a sentence. Deliberately narrow — only what actually
 * terminates a line, not all punctuation.
 */
const NEUTRAL_PUNCTUATION = new Set([
  ".", "!", "?", ";", ":", "،", "؛", "؟", "…", "»", ")", "]", "}", '"', "'",
]);

/**
 * Swift iterates `Character`, which is an extended grapheme cluster, not a code
 * point. Splitting on code points instead would break a decomposed "e + U+0301"
 * in the middle of a Latin run and diverge from the app on exactly the kind of
 * text this library exists for. `Intl.Segmenter` implements the same UAX #29
 * rules, so the two walk the string identically.
 */
const graphemes = new Intl.Segmenter(undefined, { granularity: "grapheme" });

function characters(text: string): string[] {
  return Array.from(graphemes.segment(text), (segment) => segment.segment);
}

/** Arabic, Persian, Hebrew and their supplements/presentation forms. */
function isRTLCodePoint(codePoint: number): boolean {
  return (
    (codePoint >= 0x0590 && codePoint <= 0x05ff) || // Hebrew
    (codePoint >= 0x0600 && codePoint <= 0x06ff) || // Arabic (includes Persian letters)
    (codePoint >= 0x0700 && codePoint <= 0x074f) || // Syriac
    (codePoint >= 0x0750 && codePoint <= 0x077f) || // Arabic Supplement
    (codePoint >= 0x08a0 && codePoint <= 0x08ff) || // Arabic Extended-A
    (codePoint >= 0xfb50 && codePoint <= 0xfdff) || // Arabic Presentation Forms-A
    (codePoint >= 0xfe70 && codePoint <= 0xfeff) //    Arabic Presentation Forms-B
  );
}

/**
 * Narrower than a `\p{Latin}` regex on purpose: the ranges are the ones the
 * Swift implementation uses, and widening them changes which runs get isolated.
 * Check `kernel/bidi-cases.json` before touching this.
 *
 * Matches Swift's `character.unicodeScalars.first` — the cluster's base
 * character decides, so "e" with a combining acute is still Latin.
 */
function isLatinLetter(character: string): boolean {
  const codePoint = character.codePointAt(0);
  if (codePoint === undefined) return false;
  return (
    (codePoint >= 0x41 && codePoint <= 0x5a) ||
    (codePoint >= 0x61 && codePoint <= 0x7a) ||
    (codePoint >= 0xc0 && codePoint <= 0x24f) // accented Latin
  );
}

function isASCIIDigit(character: string): boolean {
  return character.length === 1 && character >= "0" && character <= "9";
}

function startsRun(character: string): boolean {
  return isLatinLetter(character) || isASCIIDigit(character);
}

/** Whether the text contains any right-to-left script. */
export function containsRTL(text: string): boolean {
  for (const character of text) {
    const codePoint = character.codePointAt(0);
    if (codePoint !== undefined && isRTLCodePoint(codePoint)) return true;
  }
  return false;
}

/** Whether the text contains any Latin letter. */
export function containsLatin(text: string): boolean {
  return characters(text).some(isLatinLetter);
}

/**
 * Pins trailing punctuation to the correct end of the line.
 *
 * A sentence-final "." or "؟" is a *neutral* character: it has no direction of
 * its own and takes it from context. At the end of a line there is no following
 * strong character to inherit from, so it falls back to the paragraph direction
 * — and when the host resolves that as left-to-right, the full stop renders at
 * the far right, which a Persian reader sees as the beginning of the line.
 * Appending an RLM gives the neutral a strong right-to-left neighbour.
 */
function terminated(text: string): string {
  const all = characters(text);
  const last = all[all.length - 1];
  if (last === undefined || !NEUTRAL_PUNCTUATION.has(last)) return text;
  return text + RIGHT_TO_LEFT_MARK;
}

/**
 * Wraps every Latin run in isolates and pins the base direction.
 *
 * Exported because it is occasionally useful alone, but
 * {@link directionallyMarked} is what callers normally want — this one does not
 * handle the per-line split or the sentence-final terminator.
 */
export function isolatingLatinRuns(text: string): string {
  if (!containsRTL(text) || !containsLatin(text)) return text;

  const all = characters(text);
  let result = RIGHT_TO_LEFT_MARK;
  let index = 0;

  while (index < all.length) {
    const character = all[index] as string;
    if (!startsRun(character)) {
      result += character;
      index += 1;
      continue;
    }

    const runStart = index;
    let runEnd = index;

    // Extend through letters, digits and connectors, but only keep a connector
    // if a Latin character follows it — otherwise a trailing full stop would be
    // swallowed into the isolate and end up misplaced.
    while (runEnd < all.length) {
      const current = all[runEnd] as string;
      if (startsRun(current)) {
        runEnd += 1;
      } else if (current === " " || RUN_CONNECTORS.has(current)) {
        const next = all[runEnd + 1];
        if (next === undefined || !startsRun(next)) break;
        runEnd += 1;
      } else {
        break;
      }
    }

    const run = all.slice(runStart, runEnd).join("");
    result += FIRST_STRONG_ISOLATE + run + POP_DIRECTIONAL_ISOLATE;
    index = runEnd;
  }

  return result;
}

/**
 * Applies directional marking to transcribed text.
 *
 * Runs whenever the text contains RTL, even with no Latin in it, because
 * sentence-final punctuation needs fixing either way (see `terminated`). Text
 * with no RTL at all — pure English — is returned untouched, and pure Persian
 * gets the base-direction mark and the terminator only. No marks are added
 * where they earn nothing.
 *
 * Each line is treated separately: the bidi algorithm resolves per paragraph,
 * so a mark at the very start of a multi-line block would not govern the lines
 * below it.
 *
 * **Not idempotent.** This does not strip first, so marking already-marked text
 * doubles every mark. The pipeline is always strip, then mark:
 *
 * ```ts
 * directionallyMarked(stripping(text));
 * ```
 */
export function directionallyMarked(text: string): string {
  if (!containsRTL(text)) return text;

  return text
    .split("\n")
    .map((line) => {
      if (!containsRTL(line)) return line;
      const isolated = containsLatin(line)
        ? isolatingLatinRuns(line)
        : RIGHT_TO_LEFT_MARK + line;
      return terminated(isolated);
    })
    .join("\n");
}

/**
 * Removes every mark this module adds, so text round-tripping twice does not
 * accumulate invisible characters.
 *
 * This is also what you send to a terminal, a code editor, or a plain-text log,
 * which render the marks as literal escapes rather than applying them.
 */
export function stripping(text: string): string {
  return text
    .replaceAll(RIGHT_TO_LEFT_MARK, "")
    .replaceAll(FIRST_STRONG_ISOLATE, "")
    .replaceAll(POP_DIRECTIONAL_ISOLATE, "");
}
