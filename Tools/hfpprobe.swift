// hfpprobe — why AVAudioEngine refuses to start on AirPods.
//
// Build and run with the AirPods connected and selected as the input:
//
//   swiftc -O -framework CoreAudio -framework AVFoundation Tools/hfpprobe.swift -o /tmp/hfpprobe
//   /tmp/hfpprobe            # default input device
//   /tmp/hfpprobe AirPods    # first device whose name contains this
//
// It alternates two ways of opening the same device, pausing between them so
// the Bluetooth link can fall back from HFP to A2DP the way it does after a
// real recording:
//
//   A  what the app does: AVAudioEngine, bind the device to inputNode, start.
//      On macOS inputNode and outputNode are ONE AUHAL, so this also points
//      the unit's *output* side at the device.
//   B  an AUHAL with output disabled and input enabled — capture only.
//
// Before every attempt it prints the device's own input and output stream
// formats as the HAL reports them. If A fails where B does not, the output
// side is the root cause.

import AVFoundation
import CoreAudio
import Darwin

setbuf(stdout, nil)

func hal<T>(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope, _ zero: T) -> T? {
    var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    var value = zero
    var size = UInt32(MemoryLayout<T>.size)
    return AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr ? value : nil
}

func name(_ id: AudioObjectID) -> String {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var cf: CFString = "" as CFString
    var size = UInt32(MemoryLayout<CFString>.size)
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &cf) == noErr else { return "?" }
    return cf as String
}

func allDevices() -> [AudioObjectID] {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size)
    var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids)
    return ids
}

func streamFormat(_ id: AudioObjectID, _ scope: AudioObjectPropertyScope) -> String {
    guard let f = hal(id, kAudioDevicePropertyStreamFormat, scope, AudioStreamBasicDescription()) else { return "none" }
    return String(format: "%.0f Hz, %u ch", f.mSampleRate, f.mChannelsPerFrame)
}

func describe(_ id: AudioObjectID) {
    let rate = hal(id, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, Float64(0)) ?? 0
    print(String(format: "    HAL now: nominal %.0f Hz | input stream %@ | output stream %@",
                 rate, streamFormat(id, kAudioObjectPropertyScopeInput), streamFormat(id, kAudioObjectPropertyScopeOutput)))
}

// MARK: - A: AVAudioEngine, the way the app does it

func attemptEngine(_ id: AudioObjectID) {
    let engine = AVAudioEngine()
    let node = engine.inputNode
    var dev = id
    if let au = node.audioUnit {
        let s = AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &dev, UInt32(MemoryLayout<AudioDeviceID>.size))
        if s != noErr { print("    bind failed: \(s)") }
    }
    // Deliberately never touches engine.outputNode: doing so enables the output
    // side of the shared AUHAL, and on a device with no output stream (the
    // built-in mic) start() then fails with '!dev'. The app never touches it.
    print("    node believes: input \(node.outputFormat(forBus: 0))")
    node.installTap(onBus: 0, bufferSize: 1024, format: nil) { _, _ in }
    engine.prepare()
    if let au = node.audioUnit {
        var inOn: UInt32 = 9, outOn: UInt32 = 9, sz = UInt32(4)
        AudioUnitGetProperty(au, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &inOn, &sz)
        AudioUnitGetProperty(au, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &outOn, &sz)
        var outFmt = AudioStreamBasicDescription(); var fsz = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        AudioUnitGetProperty(au, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &outFmt, &fsz)
        print(String(format: "    shared AUHAL after prepare(): input IO=%u, output IO=%u, output-side client format %.0f Hz, %u ch",
                     inOn, outOn, outFmt.mSampleRate, outFmt.mChannelsPerFrame))
    }
    do {
        try engine.start()
        print("  A AVAudioEngine.start(): OK")
        Thread.sleep(forTimeInterval: 1.5)
        describe(id)
    } catch {
        print("  A AVAudioEngine.start(): FAILED — \(error.localizedDescription)")
    }
    node.removeTap(onBus: 0)
    engine.stop()
}

// MARK: - B: AUHAL, input only

func attemptInputOnlyAUHAL(_ id: AudioObjectID) {
    var desc = AudioComponentDescription(componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput,
                                         componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
    guard let comp = AudioComponentFindNext(nil, &desc) else { print("  B no AUHAL"); return }
    var unit: AudioUnit?
    AudioComponentInstanceNew(comp, &unit)
    guard let au = unit else { print("  B instance failed"); return }
    defer { AudioComponentInstanceDispose(au) }

    var on: UInt32 = 1, off: UInt32 = 0
    AudioUnitSetProperty(au, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &on, 4)
    AudioUnitSetProperty(au, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &off, 4)
    var dev = id
    AudioUnitSetProperty(au, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &dev, UInt32(MemoryLayout<AudioDeviceID>.size))

    // Ask the unit what the device gives it on the input side, then ask for the
    // same rate, mono float, on the client side — never a cached number.
    var devFmt = AudioStreamBasicDescription()
    var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    AudioUnitGetProperty(au, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 1, &devFmt, &size)
    var client = AudioStreamBasicDescription(mSampleRate: devFmt.mSampleRate, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 4, mFramesPerPacket: 1,
        mBytesPerFrame: 4, mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
    AudioUnitSetProperty(au, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &client, size)
    print(String(format: "    unit sees device input %.0f Hz, %u ch", devFmt.mSampleRate, devFmt.mChannelsPerFrame))

    var cb = AURenderCallbackStruct(inputProc: { _, _, _, _, _, _ in noErr }, inputProcRefCon: nil)
    AudioUnitSetProperty(au, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &cb, UInt32(MemoryLayout<AURenderCallbackStruct>.size))

    let initStatus = AudioUnitInitialize(au)
    guard initStatus == noErr else { print("  B AudioUnitInitialize: FAILED \(initStatus)"); return }
    let startStatus = AudioOutputUnitStart(au)
    if startStatus == noErr {
        print("  B input-only AUHAL start: OK")
        Thread.sleep(forTimeInterval: 1.5)
        describe(id)
        AudioOutputUnitStop(au)
    } else {
        print("  B input-only AUHAL start: FAILED \(startStatus)")
    }
    AudioUnitUninitialize(au)
}

// MARK: - main

let wanted = CommandLine.arguments.dropFirst().first
let device: AudioObjectID? = {
    if let wanted {
        return allDevices().first { name($0).localizedCaseInsensitiveContains(wanted) }
    }
    return hal(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice, kAudioObjectPropertyScopeGlobal, AudioObjectID(0))
}()
guard let id = device, id != 0 else { print("no such device"); exit(1) }
print("Device: \(name(id)) (id \(id))")

let pause: TimeInterval = 4
for round in 1...3 {
    print("\n— round \(round) —")
    describe(id); attemptEngine(id)
    print("  (waiting \(Int(pause))s for the link to settle)"); Thread.sleep(forTimeInterval: pause)
    describe(id); attemptInputOnlyAUHAL(id)
    print("  (waiting \(Int(pause))s)"); Thread.sleep(forTimeInterval: pause)
    describe(id); attemptEngine(id)
    print("  (waiting \(Int(pause))s)"); Thread.sleep(forTimeInterval: pause)
}
