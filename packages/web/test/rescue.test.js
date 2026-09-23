// The two halves of the rescue rule, read from the kernel and checked against
// each other: the retry policy says a filtered stop is not worth an identical
// attempt, and the rescue block says where the audio goes instead.
//
//     npm test

import test from "node:test";
import assert from "node:assert/strict";

import { timing, wasFiltered, rescueLanguageHint } from "../dist/index.js";

test("wasFiltered reads either spelling, case-insensitively", () => {
  assert.equal(wasFiltered("content_filter"), true);
  assert.equal(wasFiltered("stop", "SAFETY"), true);
  assert.equal(wasFiltered("STOP", "safety"), true);
  assert.equal(wasFiltered("stop", "STOP"), false);
  assert.equal(wasFiltered("length"), false);
  assert.equal(wasFiltered(undefined), false);
  assert.equal(wasFiltered(null, null), false);
  assert.equal(wasFiltered(""), false);
});

test("every kernel stop reason is recognised in either field", () => {
  for (const reason of timing.request.rescue.stopReasons) {
    assert.equal(wasFiltered(reason), true, `finish_reason ${reason}`);
    assert.equal(wasFiltered("stop", reason), true, `native_finish_reason ${reason}`);
  }
});

test("the language hint follows the prompt language", () => {
  assert.equal(rescueLanguageHint("farsi"), "fa");
  assert.equal(rescueLanguageHint("english"), "en");
  assert.equal(rescueLanguageHint("auto"), undefined);
});

test("the two halves of the rule agree", () => {
  assert.ok(timing.request.rescue.on.includes("filtered"));
  assert.equal(timing.request.retry.notRetryable.filteredResponse, true);
});

test("the engine is a provider slug, not a bare name", () => {
  const engine = timing.request.rescue.engine;
  assert.ok(engine.length > 0);
  assert.ok(engine.includes("/"), engine);
  assert.equal(timing.request.rescue.endpoint, "audio/transcriptions");
  assert.ok(timing.request.rescue.attempts >= 1);
});
