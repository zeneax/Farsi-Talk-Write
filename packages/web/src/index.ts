/**
 * The shared kernel behind FarsiTalkWrite.
 *
 * Everything here is generated or ported from `kernel/` at the root of the
 * FarsiTalkWrite repository, which the macOS app reads from the same commit.
 * The point is that the app, this package, and anything built on it cannot
 * disagree about a prompt, a tuned number, or how mixed Persian/Latin text is
 * marked up.
 *
 * ```ts
 * import { promptFor, timing, effectiveTimeoutSeconds } from "@mazarix/voice-kernel";
 * import { directionallyMarked, stripping } from "@mazarix/voice-kernel/bidi";
 * ```
 */

export { prompts, timing, bidiFixture } from "./kernel.generated.js";

export type {
  Prompt,
  Prompts,
  PromptLanguage,
  RecordingTiming,
  ChunkingTiming,
  RetryPolicy,
  RequestTiming,
  AudioTiming,
  Timing,
  BidiCase,
  BidiFixture,
} from "./types.js";

export * from "./bidi.js";

import { prompts, timing } from "./kernel.generated.js";
import type { PromptLanguage } from "./types.js";

/**
 * The prompt text for a language.
 *
 * `"auto"` deliberately follows the speaker rather than picking one output
 * language: someone dictating in Persian who says an English sentence should
 * get that sentence in English, not transliterated.
 */
export function promptFor(language: PromptLanguage): string {
  return prompts.prompts[language].text;
}

/**
 * Bytes of audio per second at the kernel's target encoding.
 *
 * 16 kHz mono PCM16 — the smallest encoding that loses nothing for speech, and
 * what every provider here wants.
 */
export const bytesPerAudioSecond: number =
  timing.audio.sampleRate * timing.audio.channels * (timing.audio.bitsPerSample / 8);

/**
 * How long to wait for a transcription of a payload of this size.
 *
 * The timeout scales with the payload rather than being flat. A flat timeout
 * cannot upload a 2.4 MB clip on a slow link, so the longer you spoke the more
 * likely you were to lose it — exactly backwards.
 *
 * @param wavByteLength Size of the WAV payload, header included.
 */
export function effectiveTimeoutSeconds(wavByteLength: number): number {
  const payload = Math.max(0, wavByteLength - timing.audio.wavHeaderBytes);
  const seconds = payload / bytesPerAudioSecond;
  return (
    timing.request.baseTimeoutSeconds +
    seconds * timing.request.timeoutSecondsPerAudioSecond
  );
}

/**
 * Whether an HTTP status is worth another attempt.
 *
 * 400 is retryable deliberately. In principle a bad request never fixes itself,
 * but in practice providers return 400 for temporary server-side conditions too
 * — the macOS app hit exactly that with "Reasoning is mandatory for this
 * endpoint". 401/403/404 are not: a rejected key cannot change its mind and an
 * unknown model will not appear.
 *
 * An unrecognised status is treated as retryable, on the grounds that an
 * unfamiliar one is more likely transient than permanent.
 */
export function allowsRetry(status: number): boolean {
  const { retryable, notRetryable } = timing.request.retry;
  if (notRetryable.httpStatus.includes(status)) return false;
  if (retryable.httpStatus.includes(status)) return true;
  for (const range of retryable.httpStatusRanges) {
    const low = range[0];
    const high = range[1];
    if (low !== undefined && high !== undefined && status >= low && status <= high) {
      return true;
    }
  }
  return retryable.unknownHttpStatus;
}

/**
 * Whether a clip is silent, decided locally rather than by asking the model.
 *
 * Both measurements must be below their threshold. Deciding here is instant and
 * free; the alternative was a provider answering 200-with-empty and a retry
 * round trip to reconfirm it.
 *
 * @param peakDb Peak level in dBFS.
 * @param meanDb Mean (RMS) level in dBFS.
 */
export function seemsSilent(peakDb: number, meanDb: number): boolean {
  return (
    peakDb < timing.recording.silenceGate.peakDb &&
    meanDb < timing.recording.silenceGate.meanDb
  );
}

/**
 * The silence threshold for a capture device, falling back to `default`.
 *
 * Per device, not global: AirPods run hotter and noisier than a built-in mic.
 * A consumer with no device identity passes nothing and gets the default.
 */
export function silenceThresholdDb(deviceId?: string): number {
  if (deviceId !== undefined) {
    const specific = timing.recording.silenceThresholdDb[deviceId];
    if (specific !== undefined) return specific;
  }
  return timing.recording.silenceThresholdDb.default;
}
