import CoreAudio

/// `onChange` fires on the main queue when the default or device list changes.
final class OutputDevices {
    struct Device: Identifiable, Equatable {
        let id: AudioDeviceID
        let name: String
    }

    var onChange: (() -> Void)?

    init() {
        for selector in [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDevices] {
            var address = Self.systemAddress(selector)
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main) { [weak self] _, _ in
                self?.onChange?()
            }
        }
    }

    var current: AudioDeviceID? { ProcessTapCapture.defaultOutputDeviceID() }

    /// Excludes our private aggregate.
    var all: [Device] {
        var address = Self.systemAddress(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr
        else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr
        else { return [] }

        return ids
            .filter { Self.hasOutputStreams($0) && ProcessTapCapture.deviceUID(for: $0) != ProcessTapCapture.aggregateUID }
            .map { Device(id: $0, name: Self.name(of: $0)) }
    }

    func select(_ device: AudioDeviceID) {
        var address = Self.systemAddress(kAudioHardwarePropertyDefaultOutputDevice)
        var id = device
        AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                                   UInt32(MemoryLayout<AudioDeviceID>.size), &id)
    }

    private static func systemAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    private static func hasOutputStreams(_ device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func name(of device: AudioDeviceID) -> String {
        var address = systemAddress(kAudioObjectPropertyName)
        var name: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        withUnsafeMutablePointer(to: &name) {
            _ = AudioObjectGetPropertyData(device, &address, 0, nil, &size, $0)
        }
        return name as String? ?? "Unknown device"
    }
}
