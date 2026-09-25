// micvol — every input device as the HAL sees it: nominal rate, input volume
// (scalar and dB), data source and hog owner. Built like micwho:
//
//   swiftc -O -framework CoreAudio Tools/micvol.swift -o /tmp/micvol && /tmp/micvol
//
// Written 2026-09-25 while chasing AirPods recordings 15-20 dB quieter than
// the same AirPods a week earlier, with the Sound-settings slider already up.
import CoreAudio
import Foundation
setbuf(stdout, nil)
func addr(_ s: AudioObjectPropertySelector, _ sc: AudioObjectPropertyScope, _ e: UInt32 = 0) -> AudioObjectPropertyAddress { .init(mSelector: s, mScope: sc, mElement: e) }
func get<T>(_ id: AudioObjectID, _ a: AudioObjectPropertyAddress, _ z: T) -> T? { var a=a; var v=z; var n=UInt32(MemoryLayout<T>.size); return AudioObjectGetPropertyData(id,&a,0,nil,&n,&v)==noErr ? v : nil }
func name(_ id: AudioObjectID) -> String { (get(id, addr(kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal), "" as CFString) as String?) ?? "?" }
var a = addr(kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal); var n: UInt32 = 0
AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &n)
var ids = [AudioObjectID](repeating: 0, count: Int(n)/4); AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &n, &ids)
let def = get(AudioObjectID(kAudioObjectSystemObject), addr(kAudioHardwarePropertyDefaultInputDevice, kAudioObjectPropertyScopeGlobal), AudioObjectID(0)) ?? 0
for id in ids {
    var sa = addr(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput); var sn: UInt32 = 0
    AudioObjectGetPropertyDataSize(id, &sa, 0, nil, &sn)
    let inputs = Int(sn) / MemoryLayout<AudioStreamID>.size
    // Devices with no input stream are listed too: a Bluetooth headset's
    // input stream can be absent until something opens the microphone, and
    // that is exactly the moment worth seeing.
    if inputs == 0 && id != def { continue }
    print("\(name(id)) (id \(id))  input streams: \(inputs)\(id == def ? "  ← default input" : "")")
    let rate = get(id, addr(kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal), Float64(0)) ?? 0
    print("   nominal rate: \(Int(rate))")
    for e: UInt32 in 0...1 {
        if let v = get(id, addr(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeInput, e), Float32(0)) {
            let db = get(id, addr(kAudioDevicePropertyVolumeDecibels, kAudioObjectPropertyScopeInput, e), Float32(0)) ?? .nan
            print(String(format: "   input volume elem %u: scalar %.2f  (%.1f dB)", e, v, db))
        }
    }
    if let src = get(id, addr(kAudioDevicePropertyDataSource, kAudioObjectPropertyScopeInput), UInt32(0)) {
        let c = withUnsafeBytes(of: src.bigEndian) { String(bytes: $0, encoding: .macOSRoman) ?? "?" }
        print("   input data source: '\(c)'")
    }
    if let hog = get(id, addr(kAudioDevicePropertyHogMode, kAudioObjectPropertyScopeGlobal), pid_t(-1)) { print("   hog pid: \(hog)") }
}
