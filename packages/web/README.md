# @mazarix/voice-kernel

Built and maintained by **[Mazarix](https://mazarix.com)** — Zeneax Lab by Shahram
Mazar.

The shared kernel behind [FarsiTalkWrite](https://github.com/zeneax/Farsi-Talk-Write),
a macOS push-to-talk Persian dictation app: the transcription prompts, the tuned
recording and retry constants, and the bidi isolation algorithm that keeps
embedded Latin words where they were actually spoken.

Swift does not run on Vercel, so the app itself cannot be imported. This is the
part that can be: small, mostly data, and the part that took the longest to get
right.

```sh
npm install @mazarix/voice-kernel
```

## ⚠️ Read this before you render marked text

`directionallyMarked` inserts invisible Unicode marks. **Terminals, code
editors, and plain-text logs render those as literal `⁨` escapes instead of
applying them.** This has already bitten a downstream consumer.

Send marked text only to a surface that actually implements the bidi algorithm —
a browser, a Telegram message, a rich text field. Everywhere else, send
`stripping(text)`.

```ts
import { directionallyMarked, stripping } from "@mazarix/voice-kernel/bidi";

renderInBrowser(directionallyMarked(transcript)); // marks applied
writeToLogFile(stripping(transcript));            // marks would show as escapes
```

## Why the marks exist

A transcription model returns the correct *logical* order — «می‌خواهم این PDF را
باز کنم» really does have `PDF` in the middle. Display is where it goes wrong.
The Unicode Bidirectional Algorithm resolves neutral characters (spaces,
punctuation) around a Latin run from the surrounding context, and in a mixed
paragraph that routinely flings the Latin word to the visual start or end of the
line — changing what the sentence appears to say.

Two marks fix it:

| Mark | Where | What it does |
|---|---|---|
| RLM `U+200F` | line start | Pins the paragraph's base direction to RTL, so a line that happens to begin with a Latin word is not rendered left-to-right in its entirety. |
| FSI…PDI `U+2068`…`U+2069` | around each Latin run | Isolates the run so it sits exactly where it appears in logical order instead of interacting with its neighbours. |

Isolates rather than the older LRE/PDF embeddings, because isolates are what
Unicode now recommends: they do not leak direction into surrounding text.

A trailing RLM is also appended when a line ends in `.` `!` `?` `;` `:` `،` `؛`
`؟` `…` `»` `)` `]` `}` `"` `'`. A sentence-final neutral has no following
strong character to take direction from, so it falls back to paragraph direction
and renders at the wrong end — which a Persian reader sees as the *start* of the
line.

Nothing is added where it earns nothing: pure Persian with no Latin gets the RLM
and the terminator only, and pure English is returned completely untouched.

### `directionallyMarked` is not idempotent

It does not strip first, so marking already-marked text doubles every mark. The
pipeline is always strip, then mark:

```ts
directionallyMarked(stripping(text));
```

## Bidi API

```ts
import {
  directionallyMarked,
  stripping,
  isolatingLatinRuns,
  containsRTL,
  containsLatin,
  RIGHT_TO_LEFT_MARK,
  FIRST_STRONG_ISOLATE,
  POP_DIRECTIONAL_ISOLATE,
} from "@mazarix/voice-kernel/bidi";

directionallyMarked("می‌خواهم این PDF را باز کنم");
// "‏می‌خواهم این ⁨PDF⁩ را باز کنم"

directionallyMarked("Hello world.");
// "Hello world."  — no RTL, nothing to fix, nothing added
```

## Prompts

```ts
import { prompts, promptFor } from "@mazarix/voice-kernel";

promptFor("farsi");    // Persian output
promptFor("english");  // English output
promptFor("auto");     // follows the speaker's language

prompts.prompts.farsi.intent; // why this prompt says what it says
```

The Persian prompt enforces Persian ی/ک rather than Arabic ي/ك, correct
نیم‌فاصله, and filler-word removal — and crucially instructs that Latin words
stay in Latin script, in place, neither translated nor transliterated nor moved
to the end of the sentence.

`auto` deliberately instructs the model to follow the speaker rather than pick a
single output language: someone dictating in Persian who says an English
sentence should get that sentence in English, not transliterated.

## Timing, retries and audio

```ts
import {
  timing,
  effectiveTimeoutSeconds,
  allowsRetry,
  wasFiltered,
  rescueLanguageHint,
  seemsSilent,
  silenceThresholdDb,
  bytesPerAudioSecond,
} from "@mazarix/voice-kernel";
```

Every number carries the reason it is what it is, in a `notes` field beside it.
The reasons are the actual asset — each one cost real debugging. A few worth
knowing before you build on them:

- **The timeout scales with payload.** `effectiveTimeoutSeconds(bytes)` returns
  `60 + (audioSeconds × 3)`. A flat timeout cannot upload a 2.4 MB clip on a
  slow link, so the longer you spoke the more likely you were to lose it —
  exactly backwards.
- **Chunking is off on purpose.** `timing.chunking.maxSeconds` (120) is the gate,
  and `timing.recording.maxSeconds` (60) is half of it, so nothing a recorder
  produces is ever long enough to split. It was built,
  measured, and disabled: concurrent requests on one API key queue upstream, so
  two chunks of a 27.8s clip took 46s and 98s where the whole clip takes ~12s.
  Do not "fix" this by lowering it without measuring first.
- **An empty 200 is not retryable.** Requests go out at temperature 0, so
  re-sending identical bytes returns an identical empty answer. `allowsRetry`
  covers HTTP statuses; 400 and 429 are retryable, 401/403/404 are not.
- **A truncated answer is re-sent with room, not retried.** `maxOutputTokens`
  is a ceiling against a runaway model, not a budget; when a provider reports
  it was hit, the same request goes again at `maxOutputTokensOnTruncation`.
  `truncatedResponse` is not retryable as-is, because at temperature 0 it
  truncates in the same place.
- **A filtered stop is not retried and not the end.** Gemini's safety filter
  stops a transcript on content it dislikes, on ordinary speech, at temperature
  0 — the same bytes meet the same filter, so `filteredResponse` is not
  retryable. `timing.request.rescue` names a second engine on the provider's
  transcription endpoint, which has no filter; send the same audio there
  (`wasFiltered()` recognises the stop, `rescueLanguageHint()` gives the
  language field) and keep whatever the first engine wrote before it stopped.
- **Silence is decided locally**, before anything is uploaded:
  `seemsSilent(peakDb, meanDb)`. The alternative was paying a round trip for a
  provider to tell you the room was quiet.
- **Silence threshold is per device.** `silenceThresholdDb(deviceId?)` falls
  back to `default`. AirPods run hotter and noisier than a built-in mic.

The raw JSON is exported too, if you would rather read it than import it:

```ts
import timing from "@mazarix/voice-kernel/timing.json" with { type: "json" };
```

## Where this comes from

`kernel/` at the root of the FarsiTalkWrite repository is the single source of
truth. The macOS app generates Swift constants from it at build time; this
package copies it in and generates a typed TypeScript module from it at pack
time. Neither copy is hand-maintained, so they cannot drift — one commit, one
version, one set of values.

`kernel/bidi-cases.json` is a fixture run by **both** implementations: a Swift
suite in that repository and this package's `npm test`. A case that passes in
one and fails in the other is the whole reason it is shared. Adding a case makes
both suites exercise it with no edit to either.

To change a prompt or a number, edit `kernel/*.json` in that repository and
rebuild. Do not patch the generated files.

## Licence

MIT. Note that the macOS app it was extracted from is GPL-3 — this package is
deliberately more permissive so it can be used from closed or differently
licensed projects.
