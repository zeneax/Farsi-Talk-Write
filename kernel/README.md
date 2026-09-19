# kernel/

The single source of truth for everything the macOS app and the web share.

Swift does not run on Vercel, so the app cannot be imported by the Mazarix site
or the Telegram bot. What *can* be shared is small and mostly data: the prompts,
the direction algorithm's expected behaviour, and the tuned numbers. That is
what lives here.

This folder stays inside the app's repository on purpose. The Swift app and the
npm package are two consumers of one folder, in one commit, at one version. A
separate repository would put a submodule back between the app and its own
prompts, which is the exact problem this removes.

| File | What it is |
|---|---|
| `prompts.json` | The three transcription system prompts — Persian, English, and the follow-the-speaker `auto` — each with the intent behind it. |
| `timing.json` | Every tuned number that is not macOS-specific, plus the retry policy, each with the reason it is what it is. |
| `bidi-cases.json` | Input/expected pairs for the direction algorithm, run by both implementations. |

## How a change here reaches its consumers

Edit the JSON. Nothing else.

**The macOS app** — `Tools/generate-kernel.swift` writes
`Sources/FarsiTalkWrite/KernelDefaults.generated.swift`, and the `Makefile` runs
it before compiling, so a stale copy cannot survive a build:

```sh
make            # regenerates if kernel/*.json changed, then builds
make kernel     # regenerate only
```

Generated compile-time constants rather than JSON decoded at runtime, so the
defaults stay infallible — there is no failure mode where a missing or malformed
resource leaves the app with no prompt — and nothing changes about how the
bundle is laid out or signed, which TCC is sensitive to.

**The npm package** — `packages/web/scripts/sync-kernel.mjs` copies these files
in and generates a typed TypeScript module, on every build, test and `prepack`:

```sh
cd packages/web && npm test
```

Neither copy is hand-maintained. A copy made by a person drifts; a copy made by
a script cannot.

## What does not belong here

The test is: **could a browser or a Telegram bot use this?** A keycode cannot. A
silence threshold can.

So these stay in Swift, where they are: `TriggerConfig` (key codes, tap counts,
hold durations), `HUDConfig`, `InsertionConfig`, `InputDeviceConfig`,
`Permissions`, `HotkeyMonitor`, `TextInserter`, `TargetTracker`, and all of
`UI/`.

## The bidi fixture

`bidi-cases.json` is run by both implementations:

```sh
make kernel-test                 # Swift, in this repository
cd packages/web && npm test      # TypeScript
```

A case that passes in one and fails in the other is the entire reason the file
is shared rather than duplicated — two ports drift, one fixture cannot. Adding a
case must make both suites exercise it without either being edited; neither
runner contains anything case-specific.

Each case carries a `why`. Read it before "fixing" a failure — several of them
pin behaviour that looks wrong and is not, such as a trailing full stop being
deliberately left outside the isolate.

## Licence

MIT — see `LICENSE` in this folder. The application around it is GPL-3; the
kernel is deliberately more permissive so it can be used from closed or
differently licensed projects.
