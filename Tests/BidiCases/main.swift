//
//  main.swift
//  FarsiTalkWrite — shared bidi fixture runner
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

// Runs kernel/bidi-cases.json against BidiText.
//
// The same fixture is run by the TypeScript port in packages/web. A case that
// passes in one implementation and fails in the other is the entire reason the
// file is shared rather than duplicated — two ports drift, one fixture cannot.
//
// Adding a case to the JSON must make both suites exercise it with no edit to
// either. Nothing here is case-specific; keep it that way.
//
//     make kernel-test

import Foundation

struct BidiCase: Decodable {
    let name: String
    let input: String
    let expected: String
}

struct Fixture: Decodable {
    let cases: [BidiCase]
    let strippingCases: [BidiCase]
}

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: bidi-cases <bidi-cases.json>\n".utf8))
    exit(2)
}

let fixtureURL = URL(fileURLWithPath: CommandLine.arguments[1])
guard let data = try? Data(contentsOf: fixtureURL),
      let fixture = try? JSONDecoder().decode(Fixture.self, from: data) else {
    FileHandle.standardError.write(Data("cannot read \(fixtureURL.path)\n".utf8))
    exit(2)
}

/// The marks are invisible by design, so a failure that printed them raw would
/// be unreadable — and on a terminal, actively misleading, since a terminal
/// renders them as literal escapes anyway.
func visible(_ text: String) -> String {
    text.unicodeScalars.map { scalar -> String in
        switch scalar.value {
        case 0x200F: return "<RLM>"
        case 0x2068: return "<FSI>"
        case 0x2069: return "<PDI>"
        case 0x000A: return "<NL>"
        default:     return String(scalar)
        }
    }.joined()
}

var failures: [String] = []

func check(_ label: String, _ name: String, got: String, want: String) {
    guard got != want else { return }
    failures.append("""
      \(label) \(name)
        expected: \(visible(want))
        got:      \(visible(got))
    """)
}

for testCase in fixture.cases {
    check("mark ", testCase.name,
          got: BidiText.directionallyMarked(testCase.input),
          want: testCase.expected)

    // Marking is not idempotent — it does not strip first, so marking already
    // marked text doubles every mark. The real pipeline is strip-then-mark, and
    // that is what must round-trip. Asserted for every case automatically, so a
    // new case is covered without touching this file.
    check("round", testCase.name,
          got: BidiText.directionallyMarked(BidiText.stripping(testCase.expected)),
          want: testCase.expected)
}

for testCase in fixture.strippingCases {
    check("strip", testCase.name,
          got: BidiText.stripping(testCase.input),
          want: testCase.expected)
}

if failures.isEmpty {
    print("bidi: \(fixture.cases.count) cases + \(fixture.strippingCases.count) stripping cases pass")
    exit(0)
} else {
    print("bidi: \(failures.count) failure(s)\n")
    failures.forEach { print($0) }
    exit(1)
}
