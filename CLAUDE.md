# CLAUDE.md

Guidance for working in this repository.

## What this is

A macOS menu bar agent for Farsi (and English) push-to-talk dictation. Press ⇧🌐 or
click the Dock/menu bar icon, speak, and the transcript is pasted at the cursor in
whatever app is frontmost.

Swift + AppKit, ~7,500 lines, **no external dependencies**, strict concurrency clean.

## Build

**Do not use SwiftPM.** There is no `Package.swift`. The Command Line Tools install
this was developed against shipped a broken `libPackageDescription` that could not
link even an empty manifest. `swiftc` is driven directly from the `Makefile`, which
also gives exact control over the bundle layout and signing — both of which macOS
is fussy about here.

```sh
make doctor     # verify the toolchain before anything else
make            # build + bundle + sign
make install    # → /Applications
make icon       # regenerate AppIcon.icns from Tools/make-icon.swift
make clean
```

`make doctor` exists because a mismatched compiler/SDK pair (different CLT builds
merged on top of each other) breaks *every* compile with a confusing error. If
Foundation won't import, run it first.

### Universal build

`make universal` produces a dual-architecture (`x86_64` + `arm64`) bundle at
`build/universal/` with a macOS 12 floor — the newest release 2015 Macs can run.
The source compiles unmodified at that target; nothing uses a macOS 13/14 API.

It is deliberately isolated from the normal build: separate output directory, and
it patches `LSMinimumSystemVersion` in its *copy* of Info.plist rather than the
source. `make` and `make install` are unaffected. Keep it that way — the everyday
build should stay arm64/macOS 14.

### Signing matters more than it looks

macOS binds TCC grants (Microphone, Accessibility, Input Monitoring) **and**
Keychain ACLs to the code signature. Ad-hoc signing (`-`) produces a new identity
on every build, so permissions must be re-granted after each rebuild and the
Keychain re-prompts constantly.

The Makefile auto-detects a self-signed certificate named `FarsiTalkWrite Dev` and
uses it. Create it once with `make signing-cert`. Note that macOS Security cannot
read OpenSSL 3's default PKCS#12 encryption — the recipe passes legacy algorithms
deliberately.

**Never add `--options runtime`** (hardened runtime). It requires an entitlement
for every protected capability and fails *silently* when one is missing: the
microphone request never reaches TCC, so the app doesn't even appear in Privacy &
Security. Hardened runtime only matters for notarised distribution, which this is
not. The `audio-input` entitlement in `Resources/FarsiTalkWrite.entitlements` is
still required and the build verifies it is present on every sign.

## Architecture

```
trigger ─→ DictationController ─→ AudioRecorder ─→ ProviderRegistry ─→ TextInserter
              (state machine)      (16kHz WAV)      (retry/fallback)     (⌘V paste)
```

| File | Role |
|---|---|
| `DictationController` | The state machine. Owns `destination` (cursor vs the Setup Guide's practice field) and the pending-recording queue. |
| `AudioRecorder` | AVAudioEngine → 16 kHz mono Int16 WAV. Silence/cap/manual stop conditions. |
| `AudioDeviceManager` | CoreAudio enumeration, transport detection, AirPods "prefer when available". |
| `Providers/` | `TranscriptionProvider` protocol + two wire formats. Adding a provider is normally config, not code. |
| `BidiText` | Unicode isolation for mixed Farsi/Latin text. |
| `TextInserter` | Clipboard + synthetic ⌘V; leaves the transcript on the clipboard. |
| `TranscriptArchive` | Appends every transcript to a rolling timestamped file. |
| `AudioChunker` | Silence-boundary splitting. Present but disabled — see gotchas. |
| `HotkeyMonitor` | Listen-only `CGEventTap` on one modifier key. |
| `UI/` | Status item, Dock menu, Setup Guide, Settings, HUD, Quick Help, Recordings. |

State lives in `Config`, held by `AppDelegate` and pushed to every component via
`persist()`. Components never write config directly — they call `onConfigChanged`.

## Hard-won gotchas

These each cost real debugging time. Do not undo them without reading why.

**AVAudioEngine `installTap` throws Objective-C exceptions, which Swift cannot
catch — they abort the process.** Never pass an explicit format. After binding a
specific input device the node briefly reports a *stale* format, and handing that
to `installTap` crashes the app. Pass `format: nil` and build the `AVAudioConverter`
lazily from the first buffer's own format.

**Opening the mic on Bluetooth fires a configuration-change notification
immediately.** Switching the link into HFP voice mode *is* an audio configuration
change. Treating it as "the device disconnected" aborted every AirPods recording at
0.0s. Check whether the device actually disappeared; if not, rebuild the tap and
continue.

**Never cache the input sample rate.** AirPods present 16/24 kHz where the built-in
mic presents 48 kHz. A cached rate produces chipmunked or slowed audio.

**Every Keychain read can raise a system prompt.** The UI polls permission state on
a timer; without the cache in `Keychain.swift` that becomes a stream of "wants to
use your confidential information" dialogs. Reads happen once per provider per
launch; writes and deletes invalidate.

**`--check` from a terminal reports the *terminal's* TCC status**, not the app's,
because macOS attributes Accessibility to the responsible process. The authoritative
reading is the `PERMISSIONS` line the app logs at launch.

**A status item on a full menu bar still reports `isVisible == true`.** On notched
MacBooks macOS silently gives it no position (`buttonFrame` origin ≈ `{0, -32.5}`).
`StatusItemController.checkPlacement()` detects this and the app keeps a Dock icon
so it stays reachable.

**The 🌐 key only needs freeing for *bare-press* triggers.** The event tap is
listen-only, so with `.triplePress` or `.holdToTalk` every press also fires the
system action, which steals the paste target — those need `AppleFnUsageType = 0`.
`.shiftCombo` (the default) and `.holdDuration` deliberately leave a plain press to
macOS so the key keeps switching input source; `Permissions.Status.needsGlobeKeyFree`
encodes this, and also checks the key code so retargeting to Right ⌘ drops the
requirement entirely. Setting it to "Do Nothing" unconditionally silently cost the
user their language switching.

**Mixed Farsi/Latin text needs Unicode isolation.** The model returns the correct
*logical* order; the bidi algorithm reorders it visually, flinging English words
and sentence-final punctuation to the wrong end of the line. See `BidiText`.

**But the marks are per-destination.** Terminals and code editors render them as
literal `\u2068` escapes. Claude Code runs *inside* VS Code, so both report
`com.microsoft.VSCode` and cannot be distinguished — the whole bundle id is skipped.
Fixing the escapes by skipping a broad category once reintroduced the reordering bug
everywhere; keep `skipBidiForApps` narrow and evidence-based.

**Synthetic ⌘V cannot report failure.** `CGEvent` posts the keystroke and returns
successfully whether or not anything received it. There is no way to detect a paste
that landed nowhere, which is why the transcript is always left on the clipboard —
and why restoring the previous clipboard afterwards (the original behaviour)
destroyed transcripts that missed their target.

**Concurrent requests to one provider key are queued upstream.** Chunk splitting was
built on the assumption they run in parallel; measured against OpenRouter, two pieces
of a 27.8s recording took 46s and 98s against ~12s for the whole clip. It is disabled
by a threshold above `maxSeconds`. Do not re-enable it without measuring first.

**An empty response is not necessarily silence.** A provider under upstream rate
limiting answers 200 with empty content rather than 429, so `emptyResponse` is
retryable.

## Providers

Two `kind` values cover everything shipped:

- `geminiInteractions` — `POST {baseURL}/interactions`, `x-goog-api-key`, text at
  `steps[].content[].text` where `step.type == "model_output"`. Filtering by step
  type is what keeps a thinking model's reasoning out of the user's text field.
  Note the endpoint can answer with a **top-level JSON array**.
- `openAICompatible` — `POST {baseURL}/chat/completions`, Bearer auth, audio as an
  `input_audio` part. Used for OpenRouter and anything OpenAI-shaped.

**Gemini 3.x refuses to have reasoning disabled** ("Reasoning is mandatory for this
endpoint"). Use `reasoning: {effort: "low"}` — measured 5.5s vs 8.1s. The provider
retries without the field if it is rejected.

Google's inference endpoint is unreachable from some networks: it accepts the
request and then never responds (60s timeout, zero bytes), while `GET /models` and
`countTokens` work fine. That is why OpenRouter is the default.

## Data locations

```
~/.config/farsitalkwrite/config.json          settings (0600, no secrets)
~/.config/farsitalkwrite/farsitalkwrite.log   rolling log — read this first
~/.config/farsitalkwrite/pending/*.wav        recordings not yet transcribed
~/.config/farsitalkwrite/transcripts/*.txt    every transcript, timestamped
```

**Never edit `config.json` while the app is running.** It holds the settings in
memory and writes them back, so an external edit is silently overwritten — and a
half-written file leaves a `config.json.broken-*` backup. Quit first, edit, relaunch.

API keys live in the Keychain, one generic-password item per provider (service
`com.shahram.farsitalkwrite`, account = provider id) so switching providers never
disturbs another key.

Recordings are written to `pending/` **before** transcription is attempted and
deleted only once the text has been delivered. A single "last recording" slot was
not enough — two failures in a row lost the first one.

## Testing

Each CLI flag exercises one layer, so failures localise:

```sh
FarsiTalkWrite --check                    # permissions, keys, device
FarsiTalkWrite --list-devices             # inputs + sample rates
FarsiTalkWrite --test-audio --seconds 5   # → /tmp/ftw-test.wav
FarsiTalkWrite --test-transcribe FILE --provider openrouter
FarsiTalkWrite --test-insert "سلام دنیا"
FarsiTalkWrite --test-hotkey
```

There is no test target. `BidiText` is pure and worth exercising by compiling it
standalone with a small harness — that is how its seven cases were verified.

When debugging a live problem, read `farsitalkwrite.log` first. It traces every
step: trigger fired, device and rate, stop reason, attempt counts, and where the
text was sent.

## Secrets

This repo is public. Keep it that way:

- **API keys live only in the Keychain**, one generic-password item per provider.
  `Config` has no key field and `config.json` never contains one.
- **Nothing logs a key.** `Keychain.masked()` returns `AIza••••••••wXyZ`, never the
  full value.
- **HTTP error bodies are redacted before they are shown or logged** —
  `ProviderHTTP.redactingSecrets` pattern-matches key shapes rather than comparing
  against the stored value, so a rotated or third-party key is still caught. Error
  bodies reach both the UI and the log file, so anything added to that path must
  stay redacted.
- `.gitignore` excludes `build/`, `*.p12`/`*.pem`, and stray copies of
  `config.json`, `*.wav`, and the log.

Before publishing, re-run:

```sh
grep -rInE 'AIza[0-9A-Za-z_-]{30,}|sk-or-v1-[0-9a-f]{40,}|AQ\.[A-Za-z0-9_-]{20,}' \
  --include='*.swift' --include='*.md' --include='*.json' .
```

## Docs

`README.md` (English) and `README.fa.md` (Farsi) are parallel and both
user-facing — update them together when features change. The Farsi one wraps
content in `<div dir="rtl">` with LTR islands around code blocks, which is what
GitHub needs to render mixed-direction Markdown correctly.

## Conventions

- Comments explain **why**, especially where the code looks wrong but is
  deliberately working around a platform behaviour. The gotchas above are all
  documented at their call sites.
- Errors reaching the user are plain language, never raw JSON or status codes —
  see `ProviderError.explain`.
- Prefer making behaviour configurable over hardcoding a judgement call; the
  provider/model/language/prompt system exists because every such choice turned out
  to need changing.
