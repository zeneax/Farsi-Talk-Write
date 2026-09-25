// The silence threshold resolves device, then transport, then default — the
// same order as the Swift app's Config.silenceThreshold, read from the same
// kernel file. A Bluetooth consumer that forgets the transport gets the old
// behaviour, which is a dictation ending mid-sentence; the test below is what
// keeps the transport entry from silently vanishing from the kernel.
//
//     npm test

import test from "node:test";
import assert from "node:assert/strict";

import { timing, silenceThresholdDb } from "../dist/index.js";

const table = timing.recording.silenceThresholdDb;

test("no identity resolves to default", () => {
  assert.equal(silenceThresholdDb(), table.default);
  assert.equal(silenceThresholdDb(undefined, undefined), table.default);
});

test("a Bluetooth transport resolves to the kernel's bluetooth entry", () => {
  assert.equal(typeof table.bluetooth, "number");
  assert.equal(silenceThresholdDb(undefined, "bluetooth"), table.bluetooth);
  assert.equal(silenceThresholdDb("A4-16-C0-7B-59-6F:input", "bluetooth"), table.bluetooth);
});

test("the bluetooth entry is lower than default, because HFP speech is quiet", () => {
  assert.ok(table.bluetooth < table.default, `${table.bluetooth} < ${table.default}`);
});

test("a device's own entry wins over its transport", () => {
  // The kernel ships no per-device entries, so use the two it does ship as
  // keys: asking for "default" as a device id must return default even on
  // Bluetooth, which is exactly the precedence a user's own entry would get.
  assert.equal(silenceThresholdDb("default", "bluetooth"), table.default);
});

test("an unknown transport falls through to default", () => {
  assert.equal(silenceThresholdDb(undefined, "usb"), table.default);
  assert.equal(silenceThresholdDb("nobody", "nowhere"), table.default);
});
