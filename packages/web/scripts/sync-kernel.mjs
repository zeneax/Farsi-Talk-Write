// Copies kernel/*.json in from the repository root and generates the typed
// TypeScript module that wraps it.
//
// The kernel is NOT hand-maintained here. A second copy edited by a person
// drifts from the first; a copy made by a script cannot. This runs on `prepack`
// (so a published tarball always carries the kernel as it was at that commit)
// and on every `build` and `test`, so a stale copy cannot survive a run.
//
// The generated module exists so a consumer gets a compile error rather than
// `undefined` when a key is renamed: the data is emitted as a `Timing`/`Prompts`
// value, and if the JSON no longer matches those interfaces, tsc fails here
// rather than at some call site months later.
//
//     node scripts/sync-kernel.mjs

import { mkdir, readFile, writeFile, readdir } from "node:fs/promises";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const packageRoot = join(here, "..");
const repoRoot = join(packageRoot, "..", "..");
const kernelSource = join(repoRoot, "kernel");
const kernelTarget = join(packageRoot, "kernel");

const wanted = ["prompts.json", "timing.json", "bidi-cases.json"];

await mkdir(kernelTarget, { recursive: true });

let present;
try {
  present = await readdir(kernelSource);
} catch {
  throw new Error(
    `cannot read ${kernelSource}. This package is built from inside the ` +
      `FarsiTalkWrite repository, where kernel/ is the source of truth.`,
  );
}

const missing = wanted.filter((name) => !present.includes(name));
if (missing.length > 0) {
  throw new Error(`kernel/ is missing ${missing.join(", ")}`);
}

/** @type {Record<string, unknown>} */
const loaded = {};
for (const name of wanted) {
  const raw = await readFile(join(kernelSource, name), "utf8");
  JSON.parse(raw); // fail here rather than shipping a broken file
  await writeFile(join(kernelTarget, name), raw);
  loaded[name] = raw;
}

const banner = `// GENERATED — do not edit.
//
// Written by scripts/sync-kernel.mjs from kernel/prompts.json and
// kernel/timing.json at the repository root, which are the single source of
// truth for every value below and are shared verbatim with the macOS app.
//
// To change a prompt or a tuned number, edit the JSON in kernel/ and rebuild.
// Editing this file directly is overwritten on the next build, and silently
// desynchronises this package from the app.
`;

// Annotated rather than `as const satisfies`. The annotation is what turns a
// renamed or missing key in kernel/*.json into a compile error here — and it
// keeps the declared interface (index signatures included) rather than
// narrowing every value to its own literal type, which would make
// `silenceThresholdDb[someDeviceId]` unindexable for consumers.
const generated = `${banner}
import type { Prompts, Timing, BidiFixture } from "./types.js";

export const prompts: Prompts = ${loaded["prompts.json"].trimEnd()};

export const timing: Timing = ${loaded["timing.json"].trimEnd()};

export const bidiFixture: BidiFixture = ${loaded["bidi-cases.json"].trimEnd()};
`;

const outputPath = join(packageRoot, "src", "kernel.generated.ts");
let existing = null;
try {
  existing = await readFile(outputPath, "utf8");
} catch {
  // first run
}

if (existing === generated) {
  console.log("kernel: src/kernel.generated.ts up to date");
} else {
  await writeFile(outputPath, generated);
  console.log("kernel: wrote src/kernel.generated.ts");
}
console.log(`kernel: copied ${wanted.join(", ")} into packages/web/kernel/`);
