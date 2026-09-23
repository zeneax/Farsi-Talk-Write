//
//  micwho.swift
//  FarsiTalkWrite — Farsi push-to-talk dictation for macOS
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

// Who is recording from the microphone right now?
//
// Asks CoreAudio the same question Control Center asks for its orange
// indicator — kAudioHardwarePropertyProcessObjectList filtered by
// kAudioProcessPropertyIsRunningInput — and prints a line whenever the answer
// changes. That is the whole tool, and it is what found Siri: pressing the 🌐
// key pre-arms corespeechd's microphone alongside this app's, which showed as
// a second microphone icon and as configuration-change notifications that a
// flat cap of three turned into a recording cut off mid-sentence.
//
//     swiftc -O -framework CoreAudio -framework AppKit Tools/micwho.swift -o /tmp/micwho
//     /tmp/micwho 120        # sample for two minutes, then dictate
//
// Needs macOS 14 or later for the process-object properties.

import CoreAudio
import Foundation
import AppKit

func data<T>(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector, _ type: T.Type) -> T? {
    var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(MemoryLayout<T>.size)
    let p = UnsafeMutablePointer<T>.allocate(capacity: 1); defer { p.deallocate() }
    guard AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, p) == noErr else { return nil }
    return p.pointee
}
func processes() -> [AudioObjectID] {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr else { return [] }
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else { return [] }
    return ids
}
func snapshot() -> [String] {
    processes().compactMap { obj in
        guard let running = data(obj, kAudioProcessPropertyIsRunningInput, UInt32.self), running != 0 else { return nil }
        let pid = data(obj, kAudioProcessPropertyPID, pid_t.self) ?? -1
        let bundle = (data(obj, kAudioProcessPropertyBundleID, Unmanaged<CFString>?.self).flatMap { $0 }?.takeUnretainedValue() as String?) ?? "?"
        var name = ""
        if let p = NSRunningApplication(processIdentifier: pid)?.localizedName { name = p } else {
            var buf = [CChar](repeating: 0, count: 1024); if proc_name(pid, &buf, UInt32(buf.count)) > 0 { name = String(cString: buf) }
        }
        return "pid \(pid) \(name) [\(bundle)]"
    }.sorted()
}
let seconds = Double(CommandLine.arguments.dropFirst().first ?? "60") ?? 60
let f = DateFormatter(); f.dateFormat = "HH:mm:ss.S"
var last: [String] = ["<start>"]
let end = Date().addingTimeInterval(seconds)
print("\(f.string(from: Date())) sampling for \(Int(seconds))s …"); fflush(stdout)
while Date() < end {
    let now = snapshot()
    if now != last {
        print("\(f.string(from: Date())) input capture: " + (now.isEmpty ? "(nobody)" : now.joined(separator: " | ")))
        fflush(stdout); last = now
    }
    usleep(200_000)
}
print("\(f.string(from: Date())) done")
