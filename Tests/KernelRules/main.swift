//
//  main.swift
//  FarsiTalkWrite — kernel rule checks
//
//  Copyright (C) 2026  Zeneax Lab by Shahram Mazar
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program.  If not, see <https://www.gnu.org/licenses/>.
//

// Checks the rules the app derives from kernel/timing.json against each other,
// on the generated constants the app actually compiles in. The TypeScript port
// checks the same things in packages/web/test/rescue.test.js; a rule that
// holds in one and not the other means the generator and the sync script have
// read the same file differently.
//
//     make kernel-test

import Foundation

var failures = 0
func check(_ condition: Bool, _ what: String) {
    if !condition { failures += 1; print("  ✗ \(what)") }
}

// The two halves of the rescue rule agree.
check(KernelDefaults.Rescue.on.contains("filtered"), "rescue.on names the filtered outcome")
check(KernelDefaults.Retry.filteredResponse == false, "a filtered stop is not retried as-is")
check(KernelDefaults.Retry.truncatedResponse == false, "a truncated answer is not retried as-is")
check(KernelDefaults.Retry.emptyResponse == false, "an empty answer is not retried as-is")

// The engine is a provider slug on the transcription endpoint.
check(KernelDefaults.Rescue.engine.contains("/"), "rescue.engine is a provider slug")
check(KernelDefaults.Rescue.endpoint == "audio/transcriptions", "rescue.endpoint is the transcription endpoint")
check(KernelDefaults.Rescue.attempts >= 1, "rescue.attempts is at least one")

// Every stop reason is recognised in either field, case-insensitively; a clean
// stop is not.
for reason in KernelDefaults.Rescue.stopReasons {
    check(KernelDefaults.Rescue.isFiltered(finishReason: reason, nativeFinishReason: nil), "finish_reason \(reason)")
    check(KernelDefaults.Rescue.isFiltered(finishReason: "stop", nativeFinishReason: reason.uppercased()), "native_finish_reason \(reason.uppercased())")
}
check(!KernelDefaults.Rescue.isFiltered(finishReason: "stop", nativeFinishReason: "STOP"), "a clean stop is not filtered")
check(!KernelDefaults.Rescue.isFiltered(finishReason: "length", nativeFinishReason: "MAX_TOKENS"), "truncation is not filtered")
check(!KernelDefaults.Rescue.isFiltered(finishReason: nil, nativeFinishReason: nil), "no reason is not filtered")
check(!KernelDefaults.Rescue.isFiltered(finishReason: "", nativeFinishReason: ""), "an empty reason is not filtered")

// The language hint follows the prompt language; empty means detect.
check(KernelDefaults.Rescue.languageHint(forLanguage: "farsi") == "fa", "farsi → fa")
check(KernelDefaults.Rescue.languageHint(forLanguage: "english") == "en", "english → en")
check(KernelDefaults.Rescue.languageHint(forLanguage: "auto") == nil, "auto → detect")
check(KernelDefaults.Rescue.languageHint(forLanguage: "klingon") == nil, "unknown → detect")

// The HTTP retry table is consistent across every status a server could send.
for status in 0...700 {
    let listedNo = KernelDefaults.Retry.nonRetryableStatuses.contains(status)
    let listedYes = KernelDefaults.Retry.retryableStatuses.contains(status)
        || KernelDefaults.Retry.retryableStatusRanges.contains { $0.contains(status) }
    check(!(listedNo && listedYes), "status \(status) is listed both ways")
    if listedNo { check(!KernelDefaults.Retry.allowsRetry(status: status), "status \(status) must not retry") }
    if listedYes && !listedNo { check(KernelDefaults.Retry.allowsRetry(status: status), "status \(status) must retry") }
}
check(!KernelDefaults.Retry.allowsRetry(status: 401), "401 is final")
check(KernelDefaults.Retry.allowsRetry(status: 429), "429 is worth another try")
check(KernelDefaults.Retry.allowsRetry(status: 503), "503 is worth another try")

// The output ceiling leaves room for the longest recording the app allows.
let worstTokensPerSecond = 20.0 // measured on Farsi speech; see kernel notes
check(Double(KernelDefaults.Request.maxOutputTokens) > KernelDefaults.Recording.maxSeconds * worstTokensPerSecond,
      "maxOutputTokens covers a full recording at the worst measured density")
check(KernelDefaults.Request.maxOutputTokensOnTruncation > KernelDefaults.Request.maxOutputTokens,
      "the raised ceiling is above the first one")

if failures == 0 {
    print("kernel rules: all checks pass")
    exit(0)
} else {
    print("kernel rules: \(failures) check(s) failed")
    exit(1)
}
