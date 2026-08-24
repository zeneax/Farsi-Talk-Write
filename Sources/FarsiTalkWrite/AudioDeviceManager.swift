import Foundation
import CoreAudio
import AudioToolbox

/// A CoreAudio input device. `uid` is the stable identifier we persist in config
/// (device IDs are reassigned across reboots and reconnections; UIDs are not).
struct AudioInputDevice: Equatable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let transport: Transport
    let sampleRate: Double

    enum Transport: String {
        case builtIn
        case bluetooth
        case usb
        case displayPort
        case virtual
        case other

        var label: String {
            switch self {
            case .builtIn: return "Built-in"
            case .bluetooth: return "Bluetooth"
            case .usb: return "USB"
            case .displayPort: return "DisplayPort"
            case .virtual: return "Virtual"
            case .other: return "Other"
            }
        }
    }

    /// Bluetooth mics run over HFP, which needs a lead-in before audio is usable
    /// and presents a lower sample rate than the built-in mic.
    var isBluetooth: Bool { transport == .bluetooth }
}

enum AudioDeviceManager {

    // MARK: - Enumeration

    static func allInputDevices() -> [AudioInputDevice] {
        deviceIDs()
            .filter { hasInputStreams($0) }
            .compactMap { describe($0) }
    }

    static func defaultInputDevice() -> AudioInputDevice? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        )
        guard status == noErr, deviceID != 0 else { return nil }
        return describe(deviceID)
    }

    static func device(withUID uid: String) -> AudioInputDevice? {
        allInputDevices().first { $0.uid == uid }
    }

    /// Applies the configured selection policy. Falls back to the system default
    /// whenever the preferred device is absent, so unplugging AirPods never leaves
    /// the app without a microphone.
    static func resolveInputDevice(_ config: InputDeviceConfig) -> AudioInputDevice? {
        switch config.mode {
        case .systemDefault:
            return defaultInputDevice()

        case .preferWhenAvailable:
            if let uid = config.preferredUID, let device = device(withUID: uid) {
                return device
            }
            return defaultInputDevice()

        case .pinned:
            guard let uid = config.preferredUID else { return defaultInputDevice() }
            if let device = device(withUID: uid) { return device }
            FTWLog.warn("Pinned input device \(uid) is not connected; using system default.")
            return defaultInputDevice()
        }
    }

    // MARK: - Low-level property access

    private static func deviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size
        ) == noErr else { return [] }

        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return [] }

        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids
        ) == noErr else { return [] }

        return ids
    }

    private static func hasInputStreams(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else {
            return false
        }

        let buffer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { buffer.deallocate() }

        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, buffer) == noErr else {
            return false
        }

        let list = UnsafeMutableAudioBufferListPointer(
            buffer.assumingMemoryBound(to: AudioBufferList.self)
        )
        return list.contains { $0.mNumberChannels > 0 }
    }

    private static func describe(_ id: AudioDeviceID) -> AudioInputDevice? {
        guard let uid = stringProperty(id, kAudioDevicePropertyDeviceUID),
              let name = stringProperty(id, kAudioObjectPropertyName)
        else { return nil }

        return AudioInputDevice(
            id: id,
            uid: uid,
            name: name,
            transport: transport(id),
            sampleRate: nominalSampleRate(id)
        )
    }

    private static func stringProperty(
        _ id: AudioDeviceID, _ selector: AudioObjectPropertySelector
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        // CoreAudio hands back a +1 retained CFString. Taking the address of a
        // bare `CFString` var would be forming a raw pointer to an object
        // reference; Unmanaged is the correct bridge, and takeRetainedValue
        // consumes the reference CoreAudio gave us.
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)

        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr,
              let string = value?.takeRetainedValue()
        else { return nil }

        return string as String
    }

    private static func transport(_ id: AudioDeviceID) -> AudioInputDevice.Transport {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var raw: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)

        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &raw) == noErr else {
            return .other
        }

        switch raw {
        case kAudioDeviceTransportTypeBuiltIn: return .builtIn
        case kAudioDeviceTransportTypeBluetooth,
             kAudioDeviceTransportTypeBluetoothLE: return .bluetooth
        case kAudioDeviceTransportTypeUSB: return .usb
        case kAudioDeviceTransportTypeDisplayPort,
             kAudioDeviceTransportTypeHDMI: return .displayPort
        case kAudioDeviceTransportTypeVirtual,
             kAudioDeviceTransportTypeAggregate: return .virtual
        default: return .other
        }
    }

    private static func nominalSampleRate(_ id: AudioDeviceID) -> Double {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)

        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &rate) == noErr else {
            return 0
        }
        return Double(rate)
    }

    // MARK: - Change notification

    /// Fires when devices appear or disappear (AirPods connecting, a headset being
    /// unplugged). Used to re-resolve the input device between recordings.
    static func observeDeviceListChanges(_ handler: @escaping () -> Void) -> AudioObjectPropertyListenerBlock {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            DispatchQueue.main.async { handler() }
        }
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block
        )
        return block
    }

    static func removeDeviceListObserver(_ block: @escaping AudioObjectPropertyListenerBlock) {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main, block
        )
    }
}
