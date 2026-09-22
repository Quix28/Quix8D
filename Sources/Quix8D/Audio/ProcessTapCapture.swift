import AudioToolbox
import CoreAudio
import Foundation

final class ProcessTapCapture {
    enum Error: Swift.Error {
        case tapCreationFailed(OSStatus)
        case aggregateCreationFailed(OSStatus)
        case noDefaultOutputDevice
    }

    private(set) var tapIDs: [AudioObjectID] = []
    /// Tap i is stereo pair i of the tap inputs (after any sub-device inputs).
    private(set) var tapAppIDs: [String] = []
    static let aggregateUID = "com.quix28.quix8d.aggregate"
    private(set) var aggregateDeviceID: AudioObjectID?

    private(set) var tappedProcessIDs: Set<AudioObjectID> = []

    var nominalSampleRate: Double? {
        guard let aggregateDeviceID else { return nil }
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(aggregateDeviceID, &address, 0, nil, &size, &rate)
        return status == noErr ? rate : nil
    }

    /// Taps specific processes, not globally: a global `.mutedWhenTapped`
    /// tap mutes the physical device, including our own output.
    func start() throws -> AudioDeviceID {
        guard tapIDs.isEmpty else { throw Error.tapCreationFailed(-1) }
        guard #available(macOS 14.2, *) else { throw Error.tapCreationFailed(-1) }

        // One tap per app for per-app volume; an empty tap keeps the aggregate valid.
        var groups = AudioApps.current().map { (id: $0.app.id, processes: $0.processes) }
        if groups.isEmpty { groups = [(id: "", processes: [])] }

        var tapUIDs: [String] = []
        for group in groups {
            let description = CATapDescription(stereoMixdownOfProcesses: group.processes)
            description.muteBehavior = .mutedWhenTapped
            var newTapID: AudioObjectID = 0
            let tapStatus = AudioHardwareCreateProcessTap(description, &newTapID)
            guard tapStatus == noErr else {
                stop()
                throw Error.tapCreationFailed(tapStatus)
            }
            tapIDs.append(newTapID)
            tapAppIDs.append(group.id)
            tapUIDs.append(description.uuid.uuidString)
        }
        tappedProcessIDs = Set(groups.flatMap(\.processes))

        guard let outputDeviceID = Self.defaultOutputDeviceID() else {
            stop()
            throw Error.noDefaultOutputDevice
        }
        let outputUID = Self.deviceUID(for: outputDeviceID)
        let aggregateUID = Self.aggregateUID

        // A crashed run can leave this fixed-UID aggregate registered.
        if let staleID = Self.existingDeviceID(forUID: aggregateUID) {
            AudioHardwareDestroyAggregateDevice(staleID)
        }

        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Quix8D Aggregate",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            // Load-bearing: without it the aggregate has no input stream.
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID, kAudioSubDeviceDriftCompensationKey: true]
            ],
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: tapUIDs.map {
                [kAudioSubTapUIDKey: $0, kAudioSubTapDriftCompensationKey: true]
            },
        ]

        var newAggregateID: AudioObjectID = 0
        let aggregateStatus = AudioHardwareCreateAggregateDevice(
            aggregateDescription as CFDictionary, &newAggregateID
        )
        guard aggregateStatus == noErr else {
            stop()
            throw Error.aggregateCreationFailed(aggregateStatus)
        }
        aggregateDeviceID = newAggregateID
        return newAggregateID
    }

    func stop() {
        if let aggregateDeviceID {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
        }
        aggregateDeviceID = nil
        if #available(macOS 14.2, *) {
            tapIDs.forEach { AudioHardwareDestroyProcessTap($0) }
        }
        tapIDs = []
        tapAppIDs = []
        tappedProcessIDs = []
    }

    /// Polled: Apple's property listener for this is unreliable on macOS 26.
    func hasNewUnmutedProcess() -> Bool {
        !Set(Self.currentAudioProcesses().map(\.object)).subtracting(tappedProcessIDs).isEmpty
    }

    static func currentAudioProcesses() -> [(object: AudioObjectID, pid: pid_t)] {
        var listAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &listAddress, 0, nil, &size) == noErr else {
            return []
        }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var processes = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &listAddress, 0, nil, &size, &processes) == noErr else {
            return []
        }

        let ownPID = ProcessInfo.processInfo.processIdentifier
        var result: [(object: AudioObjectID, pid: pid_t)] = []
        for process in processes {
            var pid: pid_t = 0
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            var pidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyPID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            guard AudioObjectGetPropertyData(process, &pidAddress, 0, nil, &pidSize, &pid) == noErr,
                  pid != ownPID
            else { continue }

            var isRunningOutput: UInt32 = 0
            var runningSize = UInt32(MemoryLayout<UInt32>.size)
            var runningAddress = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyIsRunningOutput,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            guard AudioObjectGetPropertyData(process, &runningAddress, 0, nil, &runningSize, &isRunningOutput) == noErr,
                  isRunningOutput != 0
            else { continue }

            result.append((process, pid))
        }
        return result
    }

    static func defaultOutputDeviceID() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
        )
        return status == noErr ? deviceID : nil
    }

    private static func existingDeviceID(forUID uid: String) -> AudioDeviceID? {
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var uidCF = uid as CFString
        let status = withUnsafeMutablePointer(to: &uidCF) { uidPtr in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address,
                UInt32(MemoryLayout<CFString>.size), uidPtr, &size, &deviceID
            )
        }
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    static func deviceUID(for deviceID: AudioDeviceID) -> String {
        var uid: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        withUnsafeMutablePointer(to: &uid) {
            _ = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, $0)
        }
        return uid as String? ?? ""
    }
}
