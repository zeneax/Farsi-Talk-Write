# FarsiTalkWrite

*[فارسی](README.fa.md) · English*

**Push-to-talk dictation for macOS that actually speaks Persian.**

Press 🌐 three times, say what you're thinking, and clean Farsi text appears at your
cursor — in a browser textarea, Notes, Slack, a terminal, anywhere you can type.

macOS dictation has never supported Persian. FarsiTalkWrite captures the audio
itself and sends it to a model that does, then handles the parts everyone else gets
wrong: mixed Farsi/English sentences, right-to-left punctuation, نیم‌فاصله, and
AirPods.

---

## Why this exists

Three problems make Persian dictation on a Mac harder than it looks:

1. **Apple doesn't support it.** No Persian voice, no Persian dictation. Not in
   Sequoia, not before it.
2. **Mixed-script text renders wrong.** Say *«می‌خواهم این PDF را باز کنم»* and a
   naive implementation shows the English word flung to the far end of the line,
   changing what the sentence means. That's the Unicode bidirectional algorithm,
   not the model — and it needs explicit handling.
3. **Persian orthography has rules a generic transcriber ignores** — Persian ی/ک
   rather than Arabic ي/ك, and نیم‌فاصله in می‌خواهم / کتاب‌ها / نمی‌شود.

All three are addressed here.

---

## Features

### Dictation

- **Two triggers** — triple-press the 🌐/fn key, or click the menu bar / Dock icon.
  Both are independent, so the app is usable even before keyboard permissions are
  granted.
- **Three stop conditions** — press again, stop talking (2.5s of silence), or hit
  the 60-second cap. It can never get stuck recording.
- **Hold-to-talk mode** as an alternative to press-to-toggle.
- **Retargetable trigger key** — 🌐 by default, or Right ⌘ / Right ⌥ / any modifier
  if the Globe key is inconvenient.
- **Inserts wherever your cursor is.** Remembers which app was frontmost when the
  trigger fired and restores focus before pasting, so clicking a menu never sends
  your text to the wrong window.

### Languages

| Mode | Behaviour |
|---|---|
| **Auto-detect** *(default)* | Transcribes in whatever language you spoke. Farsi in → Farsi out; English in → English out. Never translates. |
| **فارسی** | Always Persian, with ی/ک and نیم‌فاصله rules |
| **English** | Always English, with correct capitalisation |

Each language has its **own editable prompt**, because the rules genuinely differ —
Persian has no capitalisation, English has no نیم‌فاصله.

### Right-to-left text, done properly

- **English words stay where you said them.** Every Latin run is wrapped in Unicode
  isolates (`U+2068…U+2069`) so «می‌خواهم این PDF را باز کنم» keeps *PDF* in the
  middle instead of the bidi algorithm relocating it.
- **Sentence-final punctuation lands at the correct end** of the line. A trailing
  «.» is a directionally-neutral character; without a right-to-left mark it drifts
  to the visual start.
- Multi-word runs stay intact (*Claude Code*), version numbers survive
  (*Xcode 16.2*), and trailing punctuation is never swallowed into an isolate.
- Pure Persian and pure English get **no invisible characters at all**, and it can
  be disabled entirely for targets that mishandle them.

### Audio

- **AirPods and Bluetooth handled explicitly.** Opening the mic on a Bluetooth
  device makes macOS switch the link into HFP voice mode, which changes the sample
  rate mid-stream and fires a configuration-change event. Naive implementations
  abort the recording; this one re-establishes and keeps going.
- **Sample rate read per recording, never cached** — AirPods report 16/24 kHz where
  the built-in mic reports 48 kHz.
- **Bluetooth lead-in discarded** (350 ms vs 150 ms wired) while the codec
  negotiates, so your first syllable isn't clipped.
- **Per-device silence thresholds** — AirPods run hotter and noisier than the
  built-in mic, so one global value cannot serve both. Calibrate each with a live
  meter in Settings.
- **"Prefer this device when available"** — pick your AirPods once; the app uses
  them when connected and falls back to built-in when not.

### Never loses what you said

- Every recording is written to disk **before** transcription is attempted.
- **3 automatic retries** with backoff — for failures that can plausibly succeed
  (network drops, 429, 5xx, and 400, which providers do return for transient
  conditions). A rejected key or unknown model fails fast instead of wasting
  attempts.
- Failed recordings **accumulate in a queue** rather than overwriting each other,
  with **Retry last recording** in the menu showing how many are waiting.
- Files are deleted only once their text has actually been delivered.

### Providers — nothing is hardcoded

Three profiles ship ready to use, switchable from a menu with no restart:

| Profile | Model | Notes |
|---|---|---|
| **OpenRouter** *(default)* | `google/gemini-3.7-flash` | ~$0.001/dictation |
| Google — Free | `gemini-3.7-flash` | Free tier |
| Google — Paid | `gemini-3.1-pro-preview` | Highest quality |

- **Each profile keeps its own API key** in the Keychain, so switching never makes
  you re-enter anything.
- **Model discovery** — refresh the list live from the provider's API; any model id
  the API accepts works, including ones released after this app was built.
- **Add your own provider** by pasting a base URL. Two wire formats
  (`geminiInteractions`, `openAICompatible`) cover Google, OpenRouter, Groq,
  together.ai, LM Studio, and most local servers — no code needed.
- **Test connection** button reports auth, model validity, audio support, token
  counts and estimated cost in plain language.
- **Optional fallback provider** — if the active one fails, retry on another
  automatically.

### Interface

- **Menu bar icon** showing live state: 🎙 ready, ● recording with elapsed time,
  ∿ transcribing, ✓ inserted.
- **Dock icon** with a full right-click menu — Start Dictation, Retry, Language,
  Provider, Model, Settings. macOS silently refuses to place status items on a full
  menu bar (common on notched MacBooks); the app **detects this** and keeps a Dock
  icon so it stays reachable.
- **Floating timer HUD** — elapsed/cap countdown that turns amber in the last 10
  seconds, plus a live input-level meter. Deliberately never takes keyboard focus,
  so your cursor stays where it is.
- **First-run Setup Guide** — six steps that each verify themselves live, including
  literal instructions for getting an API key and buttons that deep-link to the
  right System Settings pane.
- **Quick Help** — one-screen cheat sheet.
- **Settings** — Providers, Trigger, Recording, and Prompt tabs.

---

## Requirements

- macOS 14 or later (developed on Sequoia 15, Apple Silicon)
- Xcode Command Line Tools
- An API key from [OpenRouter](https://openrouter.ai) or
  [Google AI Studio](https://aistudio.google.com/apikey)

No Xcode.app, no SwiftPM, no external dependencies.

---

## Install

```sh
git clone https://github.com/zeneax/Farsi-Talk-Write.git
cd Farsi-Talk-Write

make doctor          # verify the toolchain compiles
make signing-cert    # once — see "Signing" below
make install         # → /Applications/FarsiTalkWrite.app

open /Applications/FarsiTalkWrite.app
```

The **Setup Guide opens automatically** on first run and walks through the rest.

### Signing

macOS binds permissions *and* Keychain access to the code signature. With ad-hoc
signing, every rebuild produces a new identity — so you'd re-grant Microphone,
Accessibility and Input Monitoring each time, and get repeated Keychain prompts.

`make signing-cert` creates a self-signed certificate once; the Makefile picks it up
automatically and your grants persist.

### Building for another Mac (including Intel)

```sh
make universal       # → build/universal/FarsiTalkWrite.app
```

Produces **one bundle containing both architectures** — `x86_64` and `arm64` — with
a macOS 12 minimum, which covers every Mac back to 2015. macOS picks the matching
slice automatically at launch; the person using it never chooses anything.

This is a separate output. It installs nothing and does not affect `make install`.

On the receiving Mac the app is signed with a certificate that machine doesn't
know, so the first launch needs **right-click → Open** once, or:

```sh
xattr -dr com.apple.quarantine /Applications/FarsiTalkWrite.app
```

An Apple Developer Program membership plus notarisation removes that step.

---

## Setup

**1. Get an API key.** OpenRouter needs prepaid credit (~$5 lasts thousands of
dictations). Google AI Studio has a free tier — create the key in a project with
**billing disabled**.

**2. Free the 🌐 key.** System Settings → Keyboard → *Press 🌐 to:* → **Do Nothing**.
The event tap is listen-only by design, so any other setting means the emoji picker
opens on every trigger and steals your cursor.

**3. Grant three permissions:**

| Permission | Why |
|---|---|
| Microphone | to hear you |
| Accessibility | to type text into other apps |
| Input Monitoring | to see the 🌐 key — only that one key |

Input Monitoring isn't needed in **menu-bar-only** trigger mode.

---

## Cost

A 30-second dictation is roughly 960 audio tokens (Gemini bills audio at a flat
32 tokens/second) plus prompt and output.

| Model | Per 30s dictation |
|---|---|
| `google/gemini-3.7-flash` via OpenRouter | **~$0.001** |
| `gemini-3.7-flash` via Google | free tier, or ~$0.002 paid |
| `gemini-3.1-pro-preview` | ~$0.007 |

$5 of OpenRouter credit is roughly 4,000 dictations.

---

## Configuration

Everything is editable in **Settings (⌘,)**. The file lives at
`~/.config/farsitalkwrite/config.json` and holds no secrets — API keys are stored in
the macOS Keychain, one item per provider.

Settings with no UI, edited in the file directly:

| Key | Purpose |
|---|---|
| `retryAttempts` | Transcription attempts before giving up (default 3) |
| `insertion.bidiIsolation` | Unicode isolation for mixed text (default true) |
| `insertion.mode` | `paste` or `type` (unicode keystrokes) |
| `recording.leadInDiscardMs` | Per-transport lead-in trim |
| `providers.*.reasoningEffort` | `low`/`medium`/`high` — low is ~30% faster |
| `fallbackProvider` | Provider to try if the active one fails |

---

## Command line

Each flag exercises one layer, so failures localise instead of appearing as
"dictation doesn't work":

```sh
FarsiTalkWrite --check                    # permissions, keys, audio device
FarsiTalkWrite --list-devices             # inputs, transports, sample rates
FarsiTalkWrite --test-audio --seconds 5   # record to /tmp/ftw-test.wav
FarsiTalkWrite --test-transcribe FILE --provider openrouter
FarsiTalkWrite --test-insert "سلام دنیا"
FarsiTalkWrite --test-hotkey              # log key events and trigger fires
FarsiTalkWrite --set-key --provider openrouter
```

---

## Troubleshooting

**Read the log first** — it traces every step:

```sh
tail -f ~/.config/farsitalkwrite/farsitalkwrite.log
```

| Symptom | Cause |
|---|---|
| No menu bar icon | Menu bar is full — macOS gives new items no slot on notched displays. Free space in Control Center, or use the Dock icon. |
| Text lands in the wrong app | The 🌐 key isn't set to "Do Nothing", so the emoji picker is stealing focus. |
| Recording ends instantly | Older builds aborted on the Bluetooth HFP switch. Fixed — make sure you're running a current build. |
| Requests hang then time out | Some networks null-route Google's inference endpoint while its metadata endpoints still work. Use OpenRouter. |
| Repeated Keychain prompts | Keychain items created by a differently-signed build. Re-save the key, and use `make signing-cert`. |
| `--check` shows permissions denied | Running it from a terminal reports the *terminal's* TCC status. Trust the `PERMISSIONS` line the app logs at launch. |

---

## How it works

```
🌐🌐🌐  or  click 🎙
   │
   ├─ AudioRecorder ────── 16 kHz mono WAV
   │     stops on: trigger · 2.5s silence · 60s cap
   │
   ├─ saved to pending/ ── survives any failure below
   │
   ├─ TranscriptionProvider ── OpenRouter / Google, 3 retries, optional fallback
   │
   ├─ BidiText ─────────── Unicode isolation for mixed Farsi/Latin
   │
   └─ TextInserter ─────── clipboard + ⌘V at your cursor, clipboard restored
```

See [CLAUDE.md](CLAUDE.md) for architecture notes and the platform gotchas behind
several non-obvious implementation choices.

---

## Licence

MIT © 2026 Zeneax Lab by Shahram Mazar
