//
//  KernelDefaults.generated.swift
//  FarsiTalkWrite
//
//  GENERATED — do not edit.
//
//  Written by Tools/generate-kernel.swift from kernel/prompts.json and
//  kernel/timing.json, which are the single source of truth for every value
//  below. `make` regenerates this file whenever either JSON changes.
//
//  To change a prompt or a tuned number, edit the JSON in kernel/ and rebuild.
//  Editing this file directly is overwritten on the next build, and worse, it
//  silently desynchronises the Mac app from the npm package in packages/web,
//  which ships the same kernel to the web and the Telegram bot.
//

import Foundation

enum KernelDefaults {

    /// The transcription system prompts. See kernel/prompts.json for the intent
    /// behind each one — in particular that Latin words embedded in Persian must
    /// stay in Latin script, in place, neither translated nor transliterated.
    enum Prompts {
        static let farsi = "تو یک سیستم رونویسی گفتار فارسی هستی.\n- فقط متنِ گفته‌شده را بنویس. هیچ توضیح، مقدمه یا پاسخی اضافه نکن.\n- علائم نگارشی (، . ؟ !) و پاراگراف‌بندی درست را اضافه کن.\n- کلمات پرکننده («اِاِ»، «یعنی»، «چیز»، تکرارها و لکنت‌ها) را حذف کن.\n- از «ی» و «ک» فارسی استفاده کن، نه عربیِ ي/ك.\n- نیم‌فاصله را درست به کار ببر: می‌خواهم، کتاب‌ها، نمی‌شود.\n- کلمات انگلیسی (مثل PDF، Slack، Claude Code) را به همان خط لاتین بنویس و دقیقاً در همان جایی بگذار که گفته شده‌اند. آن‌ها را به اول یا آخر جمله منتقل نکن و به فارسی ترجمه یا آوانویسی نکن."

        static let english = "You are a speech transcription system.\n- Write only what was said. Add no explanation, preamble, or reply.\n- Add correct punctuation, capitalisation, and paragraph breaks.\n- Remove filler words (\"um\", \"uh\", \"you know\", \"like\"), false starts, stutters, and repeated words.\n- Keep technical terms, product names, and acronyms in their normal written form (PDF, GitHub, OAuth, macOS)."

        static let auto = "You are a speech transcription system. Transcribe the audio in the language it was actually spoken in — do not translate.\n\n- Write only what was said. Add no explanation, preamble, or reply.\n- Add correct punctuation and paragraph breaks for that language.\n- Remove filler words, false starts, stutters, and repetitions.\n- If the speech is in English, use normal English capitalisation and keep technical terms in their standard written form (PDF, GitHub, macOS).\n- اگر گفتار فارسی است: از «ی» و «ک» فارسی استفاده کن (نه ي/ك عربی)، نیم‌فاصله را درست به کار ببر (می‌خواهم، کتاب‌ها، نمی‌شود)، و علائم نگارشی فارسی (، ؛ ؟) را رعایت کن.\n- کلمات انگلیسی داخل جملهٔ فارسی را به همان خط لاتین و دقیقاً در همان جای گفته‌شده بنویس؛ آن‌ها را ترجمه یا آوانویسی نکن و جابه‌جا نکن."
    }

    enum Recording {
        static let maxSeconds: Double = 30.0
        /// How long a pause ends a recording. Dead air the user sits through
        /// after every sentence, so it is as short as it can be without clipping
        /// someone who pauses mid-thought.
        static let silenceStopSeconds: Double = 1.4
        /// Silence-stop arms only after this much speech, so the pause before you
        /// start talking cannot end the recording immediately.
        static let minSpeechSeconds: Double = 0.8
        /// The "default" entry of the per-device threshold table. AirPods run
        /// hotter and noisier than a built-in mic, so one global value does not
        /// work — this is the fallback, not the answer.
        static let silenceThresholdDb: Double = -45.0
        /// A Bluetooth (HFP) link needs time to negotiate; without discarding the
        /// lead-in the first syllable is noise.
        static let leadInDefaultMs: Int = 150
        static let leadInBluetoothMs: Int = 350
        /// A clip is silent when peak is below this AND mean is below the next.
        /// Decided locally, before anything is uploaded.
        static let silenceGatePeakDb: Double = -30.0
        static let silenceGateMeanDb: Double = -45.0
    }

    enum Chunking {
        /// Above `Recording.maxSeconds` on purpose, so splitting never engages.
        /// See kernel/timing.json: concurrent requests on one key queue upstream,
        /// and two chunks of a 27.8s clip took 46s and 98s against ~12s whole.
        static let targetSeconds: Double = 60.0
        static let maxSeconds: Double = 120.0
    }

    enum Request {
        static let baseTimeoutSeconds: Double = 60.0
        /// Seconds of timeout headroom per second of audio uploaded. A flat
        /// timeout cannot upload a 2.4 MB clip on a slow link, so the longer you
        /// spoke the more likely you were to lose it — exactly backwards.
        static let timeoutSecondsPerAudioSecond: Double = 3.0
        static let retryAttempts: Int = 3
        /// "low", "medium", "high", or "" to omit the field. Gemini 3.x refuses
        /// to have reasoning disabled outright.
        static let reasoningEffort = "low"
        /// A ceiling, not a budget: it stops a confused model from running away
        /// and stalling the round trip. Farsi speech costs at most about 20
        /// output tokens per second of audio, so this is deliberately generous —
        /// a runaway is recoverable, a silently truncated sentence is not.
        static let maxOutputTokens: Int = 2048
        /// Raised to this and re-sent once when the provider says it hit the
        /// ceiling. Truncation is the one failure whose cause and cure are both
        /// known, so the answer is a different request, not the same one again.
        static let maxOutputTokensOnTruncation: Int = 4096
    }

    /// The retry policy, as data, so the web and Telegram consumers match it.
    enum Retry {
        static let retryableStatuses: Set<Int> = [400, 429]
        /// A rejected key cannot change its mind and an unknown model will not
        /// appear. These are the only statuses that genuinely cannot succeed.
        static let nonRetryableStatuses: Set<Int> = [401, 403, 404]
        static let retryableStatusRanges: [ClosedRange<Int>] = [500...599]
        static let network = true
        static let malformedResponse = true
        /// An unfamiliar status is more likely transient than permanent.
        static let unknownStatus = true
        /// Whether an empty 200 is worth another attempt. It is not:
        /// temperature 0 means re-sending identical bytes returns an identical
        /// empty answer, so three attempts and two seconds of backoff only
        /// reconfirm what the first one said. Silence is decided locally now, so
        /// this no longer covers the case it was originally added for.
        static let emptyResponse = false
        /// Whether a truncated answer is worth another identical attempt. It is
        /// not — at temperature 0 it truncates in the same place. The provider
        /// re-sends once with a raised ceiling instead, which is a different
        /// request and so can actually succeed.
        static let truncatedResponse = false

        /// Whether an HTTP status is worth another attempt.
        static func allowsRetry(status: Int) -> Bool {
            if nonRetryableStatuses.contains(status) { return false }
            if retryableStatuses.contains(status) { return true }
            if retryableStatusRanges.contains(where: { $0.contains(status) }) { return true }
            return unknownStatus
        }
    }

    enum Audio {
        /// Never cache the capture device's own rate — AirPods present 16/24 kHz
        /// where a built-in mic presents 48 kHz, and a cached rate produces
        /// chipmunked or slowed audio. Resample to this target instead.
        static let sampleRate: Double = 16000.0
        static let channels: Int = 1
        static let bitsPerSample: Int = 16
        /// A minimal RIFF/WAVE header, subtracted to get the payload size.
        static let wavHeaderBytes: Int = 44
        /// Bytes per second of audio at the target encoding.
        static let bytesPerSecond: Double = sampleRate * Double(channels) * Double(bitsPerSample / 8)
    }
}
