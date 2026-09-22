import AudioToolbox
import Foundation

/// AUSpatialMixer pulled synchronously from the IO proc.
/// Buses 0-1: the rotating unplaced "bed". Buses 2+2k / 3+2k: placed app slot k.
/// `process()` doesn't allocate or lock.
final class HRTFRenderer {
    typealias Buffer = BinauralProcessor.Buffer

    /// Azimuth: degrees, 0 = front, clockwise.
    struct Slot {
        var azimuth: Float32
        var distance: Float32
        var left: Buffer
        var right: Buffer
    }

    static let maxSlots = 16
    private static let busCount = 2 + 2 * maxSlots

    /// Wider keeps more width but smears direction.
    static let stereoSpreadDegrees: Float32 = 20
    static let slotSpreadDegrees: Float32 = 20
    /// 0...100 wet; a little room helps externalize.
    static let reverbBlend: Float32 = 25
    /// blend = base + perMetre * distance.
    static let slotReverbBase: Float32 = 10
    static let slotReverbPerMetre: Float32 = 8
    private static let sourceDistanceMetres: Float32 = 1.5
    private static let maxFrames = 4096

    private var unit: AudioUnit?
    private let outputList: UnsafeMutableAudioBufferListPointer
    private let outputLeft = UnsafeMutablePointer<Float32>.allocate(capacity: maxFrames)
    private let outputRight = UnsafeMutablePointer<Float32>.allocate(capacity: maxFrames)
    private var sampleTime: Float64 = 0

    // Valid only during one AudioUnitRender call; nil = silence.
    private let busSources = UnsafeMutablePointer<Buffer?>.allocate(capacity: HRTFRenderer.busCount)
    private var pendingOffset = 0

    init?(sampleRate: Double) {
        outputList = AudioBufferList.allocate(maximumBuffers: 2)
        for index in 0..<2 {
            outputList[index].mNumberChannels = 1
        }
        busSources.initialize(repeating: nil, count: Self.busCount)

        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Mixer, componentSubType: kAudioUnitSubType_SpatialMixer,
            componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &description),
              AudioComponentInstanceNew(component, &unit) == noErr, let unit,
              configure(unit, sampleRate: sampleRate)
        else { return nil }
    }

    deinit {
        if let unit {
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
        }
        outputLeft.deallocate()
        outputRight.deallocate()
        busSources.deallocate()
        free(outputList.unsafeMutablePointer)
    }

    /// Replaces the destinations. `gainDb`: exaggerated front/back loudness cue.
    func process(
        azimuthDegrees: Float32,
        gainDb: Float32 = 0,
        left: (source: Buffer, destination: Buffer),
        right: (source: Buffer, destination: Buffer)
    ) {
        process(bed: (azimuthDegrees, gainDb, left.source, right.source), slots: nil, slotCount: 0,
                into: (left.destination, right.destination), adding: false)
    }

    func process(
        bed: (azimuth: Float32, gainDb: Float32, left: Buffer, right: Buffer)?,
        slots: UnsafePointer<Slot>?,
        slotCount: Int,
        into destination: (left: Buffer, right: Buffer),
        adding: Bool
    ) {
        guard let unit else { return }
        var frames = min(destination.left.frames, destination.right.frames)

        func setBus(_ bus: Int, source: Buffer?, azimuth: Float32) {
            busSources[bus] = source
            let element = AudioUnitElement(bus)
            AudioUnitSetParameter(unit, kSpatialMixerParam_Enable, kAudioUnitScope_Input, element, source == nil ? 0 : 1, 0)
            if let source {
                frames = min(frames, source.frames)
                AudioUnitSetParameter(unit, kSpatialMixerParam_Azimuth, kAudioUnitScope_Input, element, remainder(azimuth, 360), 0)
            }
        }

        let bedHalf = Self.stereoSpreadDegrees / 2
        setBus(0, source: bed?.left, azimuth: (bed?.azimuth ?? 0) - bedHalf)
        setBus(1, source: bed?.right, azimuth: (bed?.azimuth ?? 0) + bedHalf)
        if let bed {
            for bus: AudioUnitElement in 0..<2 {
                AudioUnitSetParameter(unit, kSpatialMixerParam_Gain, kAudioUnitScope_Input, bus, bed.gainDb, 0)
            }
        }

        let slotHalf = Self.slotSpreadDegrees / 2
        let used = min(slotCount, Self.maxSlots)
        for index in 0..<Self.maxSlots {
            let slot = index < used ? slots?[index] : nil
            let leftBus = 2 + 2 * index
            setBus(leftBus, source: slot?.left, azimuth: (slot?.azimuth ?? 0) - slotHalf)
            setBus(leftBus + 1, source: slot?.right, azimuth: (slot?.azimuth ?? 0) + slotHalf)
            if let slot {
                let reverb = min(Self.slotReverbBase + Self.slotReverbPerMetre * slot.distance, 100)
                for bus in leftBus...(leftBus + 1) {
                    let element = AudioUnitElement(bus)
                    AudioUnitSetParameter(unit, kSpatialMixerParam_Distance, kAudioUnitScope_Input, element, slot.distance, 0)
                    AudioUnitSetParameter(unit, kSpatialMixerParam_ReverbBlend, kAudioUnitScope_Input, element, reverb, 0)
                }
            }
        }
        defer {
            for bus in 0..<Self.busCount { busSources[bus] = nil }
        }

        var offset = 0
        while offset < frames {
            let chunk = min(Self.maxFrames, frames - offset)
            pendingOffset = offset
            let byteSize = UInt32(chunk * MemoryLayout<Float32>.size)
            outputList[0].mData = UnsafeMutableRawPointer(outputLeft)
            outputList[0].mDataByteSize = byteSize
            outputList[1].mData = UnsafeMutableRawPointer(outputRight)
            outputList[1].mDataByteSize = byteSize

            var flags = AudioUnitRenderActionFlags()
            var timeStamp = AudioTimeStamp()
            timeStamp.mSampleTime = sampleTime
            timeStamp.mFlags = .sampleTimeValid
            let status = AudioUnitRender(unit, &flags, &timeStamp, 0, UInt32(chunk), outputList.unsafeMutablePointer)
            sampleTime += Float64(chunk)

            for frame in 0..<chunk {
                let target = offset + frame
                let renderedLeft = status == noErr ? outputLeft[frame] : 0
                let renderedRight = status == noErr ? outputRight[frame] : 0
                let leftIndex = target * destination.left.stride
                let rightIndex = target * destination.right.stride
                destination.left.samples[leftIndex] = adding ? destination.left.samples[leftIndex] + renderedLeft : renderedLeft
                destination.right.samples[rightIndex] = adding ? destination.right.samples[rightIndex] + renderedRight : renderedRight
            }
            offset += chunk
        }
    }

    private static let inputCallback: AURenderCallback = { refCon, _, _, bus, frameCount, ioData in
        let renderer = Unmanaged<HRTFRenderer>.fromOpaque(refCon).takeUnretainedValue()
        guard let ioData, let data = UnsafeMutableAudioBufferListPointer(ioData).first?.mData else { return noErr }
        let destination = data.assumingMemoryBound(to: Float32.self)
        guard Int(bus) < busCount, let source = renderer.busSources[Int(bus)] else {
            destination.update(repeating: 0, count: Int(frameCount))
            return noErr
        }
        let available = max(0, min(Int(frameCount), source.frames - renderer.pendingOffset))
        for frame in 0..<Int(frameCount) {
            destination[frame] = frame < available
                ? source.samples[(renderer.pendingOffset + frame) * source.stride] : 0
        }
        return noErr
    }

    private func configure(_ unit: AudioUnit, sampleRate: Double) -> Bool {
        func set<T>(_ property: AudioUnitPropertyID, _ scope: AudioUnitScope, _ element: AudioUnitElement, _ value: T) -> Bool {
            var value = value
            return AudioUnitSetProperty(unit, property, scope, element, &value, UInt32(MemoryLayout<T>.size)) == noErr
        }
        func format(channels: UInt32) -> AudioStreamBasicDescription {
            AudioStreamBasicDescription(
                mSampleRate: sampleRate, mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved,
                mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
                mChannelsPerFrame: channels, mBitsPerChannel: 32, mReserved: 0)
        }

        guard set(kAudioUnitProperty_ElementCount, kAudioUnitScope_Input, 0, UInt32(Self.busCount)),
              set(kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, format(channels: 2)),
              set(kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, UInt32(Self.maxFrames)),
              set(kAudioUnitProperty_SpatialMixerOutputType, kAudioUnitScope_Global, 0,
                  AUSpatialMixerOutputType.spatialMixerOutputType_Headphones.rawValue)
        else { return false }

        let callback = AURenderCallbackStruct(
            inputProc: Self.inputCallback, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        for bus in 0..<AudioUnitElement(Self.busCount) {
            guard set(kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, bus, format(channels: 1)),
                  set(kAudioUnitProperty_SpatializationAlgorithm, kAudioUnitScope_Input, bus,
                      AUSpatializationAlgorithm.spatializationAlgorithm_UseOutputType.rawValue),
                  set(kAudioUnitProperty_SpatialMixerSourceMode, kAudioUnitScope_Input, bus,
                      AUSpatialMixerSourceMode.spatialMixerSourceMode_PointSource.rawValue),
                  set(kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, bus, callback)
            else { return false }
        }

        let slotFlags = AUSpatialMixerRenderingFlags(rawValue: 1 << 0 | 1 << 2) // InterAuralDelay | DistanceAttenuation
        let distanceParams = MixerDistanceParams(mReferenceDistance: 1, mMaxDistance: 10, mMaxAttenuation: 18)
        for bus in 2..<AudioUnitElement(Self.busCount) {
            _ = set(kAudioUnitProperty_SpatialMixerRenderingFlags, kAudioUnitScope_Input, bus, slotFlags.rawValue)
            _ = set(kAudioUnitProperty_SpatialMixerDistanceParams, kAudioUnitScope_Input, bus, distanceParams)
        }

        // Nice-to-haves: the mixer still renders HRTF if these are refused.
        _ = set(kAudioUnitProperty_SpatialMixerPersonalizedHRTFMode, kAudioUnitScope_Global, 0,
                AUSpatialMixerPersonalizedHRTFMode.auto.rawValue)
        // Head tracking separates front from back; no-op without supported headphones.
        _ = set(kAudioUnitProperty_SpatialMixerEnableHeadTracking, kAudioUnitScope_Global, 0, UInt32(1))
        _ = set(kAudioUnitProperty_UsesInternalReverb, kAudioUnitScope_Global, 0, UInt32(1))
        _ = set(kAudioUnitProperty_ReverbRoomType, kAudioUnitScope_Global, 0, AUReverbRoomType.reverbRoomType_SmallRoom.rawValue)

        guard AudioUnitInitialize(unit) == noErr else { return false }

        for bus: AudioUnitElement in 0..<2 {
            AudioUnitSetParameter(unit, kSpatialMixerParam_Distance, kAudioUnitScope_Input, bus, Self.sourceDistanceMetres, 0)
            AudioUnitSetParameter(unit, kSpatialMixerParam_ReverbBlend, kAudioUnitScope_Input, bus, Self.reverbBlend, 0)
        }
        for bus in 0..<AudioUnitElement(Self.busCount) {
            AudioUnitSetParameter(unit, kSpatialMixerParam_Enable, kAudioUnitScope_Input, bus, 0, 0)
        }
        return true
    }
}
