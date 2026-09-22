import AudioToolbox
import CoreAudio

/// `onChange` fires on the main queue on any change, including a default-device switch.
final class SystemVolume {
    var onChange: ((Float) -> Void)?

    private var deviceID = AudioObjectID(kAudioObjectUnknown)
    private var volumeListener: AudioObjectPropertyListenerBlock?

    private static var volumeAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    }
    private static var defaultDeviceAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    init() {
        var address = Self.defaultDeviceAddress
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main) { [weak self] _, _ in
            self?.bindDefaultDevice()
        }
        bindDefaultDevice()
    }

    /// 0...1; nil if the device has no volume control.
    var volume: Float? {
        var address = Self.volumeAddress
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        let status = AudioHardwareServiceGetPropertyData(deviceID, &address, 0, nil, &size, &value)
        return status == noErr ? value : nil
    }

    var isAdjustable: Bool {
        var address = Self.volumeAddress
        var settable: DarwinBoolean = false
        return AudioHardwareServiceIsPropertySettable(deviceID, &address, &settable) == noErr && settable.boolValue
    }

    func setVolume(_ newValue: Float) {
        var address = Self.volumeAddress
        var value = min(max(newValue, 0), 1)
        AudioHardwareServiceSetPropertyData(deviceID, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
    }

    private func bindDefaultDevice() {
        var address = Self.volumeAddress
        if let volumeListener {
            AudioObjectRemovePropertyListenerBlock(deviceID, &address, .main, volumeListener)
        }

        var defaultAddress = Self.defaultDeviceAddress
        var newDevice = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &defaultAddress, 0, nil, &size, &newDevice)
        deviceID = newDevice

        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self, let volume = self.volume else { return }
            self.onChange?(volume)
        }
        volumeListener = listener
        AudioObjectAddPropertyListenerBlock(deviceID, &address, .main, listener)
        if let volume { onChange?(volume) }
    }
}
