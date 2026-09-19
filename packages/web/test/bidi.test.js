// Runs kernel/bidi-cases.json against the TypeScript port.
//
// The same fixture is run by the Swift implementation in this repository
// (`make kernel-test`). A case that passes in one and fails in the other is the
// entire reason the file is shared rather than duplicated — two ports drift,
// one fixture cannot.
//
// Adding a case to the JSON must make both suites exercise it with no edit to
// either. Nothing below is case-specific; keep it that way.
//
//     npm test

import test from "node:test";
import assert from "node:assert/strict";

import { bidiFixture } from "../dist/index.js";
import { directionallyMarked, stripping } from "../dist/bidi.js";

/**
 * The marks are invisible by design, so an assertion that printed them raw
 * would be unreadable — and in a terminal, actively misleading, since a
 * terminal renders them as literal escapes anyway.
 */
function visible(text) {
  return Array.from(text, (character) => {
    switch (character) {
      case "‏": return "<RLM>";
      case "⁨": return "<FSI>";
      case "⁩": return "<PDI>";
      case "\n":     return "<NL>";
      default:       return character;
    }
  }).join("");
}

function equal(actual, expected, why) {
  assert.equal(visible(actual), visible(expected), why);
}

test("directionallyMarked matches the shared fixture", async (t) => {
  for (const testCase of bidiFixture.cases) {
    await t.test(testCase.name, () => {
      equal(directionallyMarked(testCase.input), testCase.expected, testCase.why);
    });
  }
});

test("marks never accumulate across a round trip", async (t) => {
  // Marking is not idempotent — it does not strip first, so marking already
  // marked text doubles every mark. The real pipeline is strip-then-mark, and
  // that is what must round-trip. Asserted for every case automatically, so a
  // new case is covered without touching this file.
  for (const testCase of bidiFixture.cases) {
    await t.test(testCase.name, () => {
      equal(
        directionallyMarked(stripping(testCase.expected)),
        testCase.expected,
        "strip-then-mark must be stable",
      );
    });
  }
});

test("stripping matches the shared fixture", async (t) => {
  for (const testCase of bidiFixture.strippingCases) {
    await t.test(testCase.name, () => {
      equal(stripping(testCase.input), testCase.expected, testCase.why);
    });
  }
});

test("the fixture is not empty", () => {
  // A misread fixture would otherwise make every suite above pass vacuously.
  assert.ok(bidiFixture.cases.length > 0, "no marking cases loaded");
  assert.ok(bidiFixture.strippingCases.length > 0, "no stripping cases loaded");
});
