/**
 * Shapes for the kernel data.
 *
 * These exist so a consumer gets a compile error rather than `undefined` when a
 * key is renamed. `src/kernel.generated.ts` declares the data
 * `satisfies Timing` / `satisfies Prompts`, so a rename in `kernel/*.json`
 * fails this package's build rather than surfacing months later at a call site.
 */

/** A single transcription system prompt. */
export interface Prompt {
  /** BCP-47-ish tag, or `"auto"` for the follow-the-speaker prompt. */
  readonly language: string;
  readonly displayName: string;
  /** Why this prompt says what it says. Not sent to the model. */
  readonly intent: string;
  /** The prompt text itself, exactly as the macOS app sends it. */
  readonly text: string;
}

export interface Prompts {
  readonly version: number;
  readonly note: string;
  readonly prompts: {
    readonly farsi: Prompt;
    readonly english: Prompt;
    readonly auto: Prompt;
  };
}

/** Which prompt to use. Matches the app's `DictationLanguage`. */
export type PromptLanguage = "farsi" | "english" | "auto";

export interface RecordingTiming {
  /** Hard ceiling on a single recording. */
  readonly maxSeconds: number;
  /** How long a pause ends a recording. */
  readonly silenceStopSeconds: number;
  /** Silence-stop arms only after this much speech has been heard. */
  readonly minSpeechSeconds: number;
  /**
   * Keyed by capture-device identifier, with a required `default` entry.
   * A consumer with no device identity uses `default`.
   */
  readonly silenceThresholdDb: {
    readonly default: number;
    readonly [deviceId: string]: number;
  };
  /** Lead-in to discard, per transport. Bluetooth (HFP) needs longer. */
  readonly leadInDiscardMs: {
    readonly default: number;
    readonly bluetooth: number;
  };
  /** A clip is silent when peak is below `peakDb` AND mean is below `meanDb`. */
  readonly silenceGate: {
    readonly peakDb: number;
    readonly meanDb: number;
  };
  readonly notes: Readonly<Record<string, string>>;
}

export interface ChunkingTiming {
  readonly targetSeconds: number;
  readonly maxSeconds: number;
  /** False, deliberately. See `notes.enabled` before changing it. */
  readonly enabled: boolean;
  readonly notes: Readonly<Record<string, string>>;
}

/** Which failures are worth another attempt. */
export interface RetryPolicy {
  readonly retryable: {
    readonly httpStatus: readonly number[];
    /** Inclusive `[low, high]` pairs. */
    readonly httpStatusRanges: readonly (readonly number[])[];
    readonly network: boolean;
    readonly malformedResponse: boolean;
    /** An unfamiliar status is more likely transient than permanent. */
    readonly unknownHttpStatus: boolean;
  };
  readonly notRetryable: {
    readonly httpStatus: readonly number[];
    /** True meaning "an empty 200 is NOT retryable". */
    readonly emptyResponse: boolean;
    readonly missingApiKey: boolean;
    readonly badUrl: boolean;
  };
  readonly notes: Readonly<Record<string, string>>;
}

export interface RequestTiming {
  readonly baseTimeoutSeconds: number;
  /** Seconds of timeout headroom per second of audio uploaded. */
  readonly timeoutSecondsPerAudioSecond: number;
  readonly retryAttempts: number;
  /** `"low" | "medium" | "high"`, or `""` to omit the field entirely. */
  readonly reasoningEffort: string;
  readonly notes: Readonly<Record<string, string>>;
  readonly retry: RetryPolicy;
}

export interface AudioTiming {
  readonly sampleRate: number;
  readonly channels: number;
  readonly bitsPerSample: number;
  /** A minimal RIFF/WAVE header, subtracted to get the payload size. */
  readonly wavHeaderBytes: number;
  readonly notes: Readonly<Record<string, string>>;
}

export interface Timing {
  readonly version: number;
  readonly note: string;
  readonly recording: RecordingTiming;
  readonly chunking: ChunkingTiming;
  readonly request: RequestTiming;
  readonly audio: AudioTiming;
}

/** One input/expected pair from the shared bidi fixture. */
export interface BidiCase {
  readonly name: string;
  readonly input: string;
  readonly expected: string;
  /** Why this case exists. Read it before "fixing" a failure. */
  readonly why: string;
}

export interface BidiFixture {
  readonly version: number;
  readonly note: string;
  readonly marks: {
    readonly RLM: string;
    readonly FSI: string;
    readonly PDI: string;
  };
  readonly invariants: readonly string[];
  /** Run through `directionallyMarked`. */
  readonly cases: readonly BidiCase[];
  /** Run through `stripping`. */
  readonly strippingCases: readonly BidiCase[];
}
