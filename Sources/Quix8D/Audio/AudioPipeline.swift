import CoreAudio
import AudioToolbox
import Darwin

final class AudioPipeline {
    enum Error: Swift.Error {
        case ioProcRegistrationFailed(OSStatus)
        case deviceStartFailed(OSStatus)
    }

    // Must be explicit: a nil queue silently never fires once NSApplication exists.
    private static let ioQueue = DispatchQueue(label: "com.quix28.quix8d.audio-io", qos: .userInteractive)

    // Serializes start/stop/refresh timer over tap/aggregate/IOProc state.
    private let controlQueue = DispatchQueue(label: "com.quix28.quix8d.control")
    private var refreshTimer: DispatchSourceTimer?

    private let capture = ProcessTapCapture()
    private var ioProcID: AudioDeviceIOProcID?
    private var aggregateDeviceID: AudioDeviceID?
    private var phase: Double = 0

    // Audio thread touches only mixLeft/mixRight/rampGains/frameGains.
    private static let maxTaps = 32
    private static let mixCapacity = 8192
    private let mixLeft = UnsafeMutablePointer<Float32>.allocate(capacity: AudioPipeline.mixCapacity)
    private let mixRight = UnsafeMutablePointer<Float32>.allocate(capacity: AudioPipeline.mixCapacity)
    private let targetGains = AudioPipeline.unityGains()  // guarded by controlsLock
    private let frameGains = AudioPipeline.unityGains()   // audio thread: this callback's targets
    private let rampGains = AudioPipeline.unityGains()    // audio thread: last callback's end gains
    private var _tapCount = 1                    // guarded by controlsLock
    private var _tapAppIDs: [String] = []        // guarded by controlsLock
    private var _appVolumes: [String: Float] = [:] // guarded by controlsLock

    // frame* copies and slot buffers are audio-thread only.
    private static let maxSlots = HRTFRenderer.maxSlots
    private var _appPositions: [String: AppPosition] = [:] // guarded by controlsLock
    private var _placementEnabled = true                   // guarded by controlsLock
    private var _slotCount = 0                             // guarded by controlsLock
    private let tapSlot = AudioPipeline.filled(-1, count: AudioPipeline.maxTaps)            // guarded
    private let slotAzimuth = AudioPipeline.filled(Float(0), count: AudioPipeline.maxSlots)  // guarded
    private let slotDistance = AudioPipeline.filled(Float(1), count: AudioPipeline.maxSlots) // guarded
    private let frameTapSlot = AudioPipeline.filled(-1, count: AudioPipeline.maxTaps)
    private let frameSlotAzimuth = AudioPipeline.filled(Float(0), count: AudioPipeline.maxSlots)
    private let frameSlotDistance = AudioPipeline.filled(Float(1), count: AudioPipeline.maxSlots)
    private let slotLeft = AudioPipeline.filled(Float32(0), count: AudioPipeline.maxSlots * AudioPipeline.mixCapacity)
    private let slotRight = AudioPipeline.filled(Float32(0), count: AudioPipeline.maxSlots * AudioPipeline.mixCapacity)
    private let frameSlots = AudioPipeline.filled(
        HRTFRenderer.Slot(azimuth: 0, distance: 1, left: (UnsafeMutablePointer<Float32>(bitPattern: 1)!, 1, 0),
                          right: (UnsafeMutablePointer<Float32>(bitPattern: 1)!, 1, 0)),
        count: AudioPipeline.maxSlots)

    private static func filled<T>(_ value: T, count: Int) -> UnsafeMutablePointer<T> {
        let pointer = UnsafeMutablePointer<T>.allocate(capacity: count)
        pointer.initialize(repeating: value, count: count)
        return pointer
    }

    /// Keyed by AudioApp.id.
    func setAppPositions(_ positions: [String: AppPosition], enabled: Bool) {
        var old = positions
        os_unfair_lock_lock(&controlsLock)
        swap(&old, &_appPositions)
        _placementEnabled = enabled
        publishPlacementLocked()
        os_unfair_lock_unlock(&controlsLock)
        _ = old // released here, outside the lock the audio thread takes
    }

    /// Caller holds controlsLock.
    private func publishPlacementLocked() {
        _slotCount = 0
        for tap in 0..<_tapCount {
            if _placementEnabled, tap < _tapAppIDs.count, _slotCount < Self.maxSlots,
               let position = _appPositions[_tapAppIDs[tap]] {
                tapSlot[tap] = _slotCount
                slotAzimuth[_slotCount] = Float(position.azimuth)
                slotDistance[_slotCount] = Float(position.distance)
                _slotCount += 1
            } else {
                tapSlot[tap] = -1
            }
        }
    }

    // EQ filter state is audio-thread only.
    private static let eqBandCount = EQSettings.stageCount
    private var _eq = EQSettings()                // guarded by controlsLock
    private var _eqEnabled = true                 // guarded by controlsLock
    private var _eqActive = false                 // guarded by controlsLock
    private var _sampleRate: Double = 48_000      // guarded by controlsLock
    private let eqCoefficients = UnsafeMutablePointer<BinauralEffect.Biquad>.allocate(capacity: AudioPipeline.eqBandCount)
    private let frameEQCoefficients = UnsafeMutablePointer<BinauralEffect.Biquad>.allocate(capacity: AudioPipeline.eqBandCount)
    private let eqBandActive = UnsafeMutablePointer<Bool>.allocate(capacity: AudioPipeline.eqBandCount)
    private let frameEQBandActive = UnsafeMutablePointer<Bool>.allocate(capacity: AudioPipeline.eqBandCount)
    private let eqLeftState = AudioPipeline.biquadStates()
    private let eqRightState = AudioPipeline.biquadStates()

    // Per-app EQ, one bank of bands per tap, applied before mixing.
    private static let tapEQStages = AudioPipeline.maxTaps * AudioPipeline.eqBandCount
    private var _appEQs: [String: EQSettings] = [:]  // guarded by controlsLock
    private var _anyTapEQ = false                     // guarded by controlsLock
    private let tapEQActive = AudioPipeline.filled(false, count: AudioPipeline.maxTaps)          // guarded
    private let tapEQCoefficients = AudioPipeline.filled(BinauralEffect.Biquad(b0: 1, b1: 0, b2: 0, a1: 0, a2: 0),
                                                         count: AudioPipeline.tapEQStages)        // guarded
    private let tapEQBandActive = AudioPipeline.filled(false, count: AudioPipeline.tapEQStages)  // guarded
    private let frameTapEQActive = AudioPipeline.filled(false, count: AudioPipeline.maxTaps)
    private let frameTapEQCoefficients = AudioPipeline.filled(BinauralEffect.Biquad(b0: 1, b1: 0, b2: 0, a1: 0, a2: 0),
                                                              count: AudioPipeline.tapEQStages)
    private let frameTapEQBandActive = AudioPipeline.filled(false, count: AudioPipeline.tapEQStages)
    private let tapEQLeftState = AudioPipeline.filled(BiquadState(), count: AudioPipeline.tapEQStages)
    private let tapEQRightState = AudioPipeline.filled(BiquadState(), count: AudioPipeline.tapEQStages)
    private let tapScratchLeft = AudioPipeline.filled(Float32(0), count: AudioPipeline.mixCapacity)
    private let tapScratchRight = AudioPipeline.filled(Float32(0), count: AudioPipeline.mixCapacity)

    // Audio thread writes via try-lock (never waits); UI reads under the same lock.
    private var analyzerLock = os_unfair_lock()
    private let analyzerRing = AudioPipeline.silentRing()
    private var analyzerWriteIndex = 0                // guarded by analyzerLock
    private var _isAnalyzerOn = false                 // guarded by controlsLock

    var isAnalyzerOn: Bool {
        get { os_unfair_lock_lock(&controlsLock); defer { os_unfair_lock_unlock(&controlsLock) }; return _isAnalyzerOn }
        set { os_unfair_lock_lock(&controlsLock); defer { os_unfair_lock_unlock(&controlsLock) }; _isAnalyzerOn = newValue }
    }

    /// Oldest first.
    func analyzerSnapshot() -> (samples: [Float], sampleRate: Double) {
        var samples = [Float](repeating: 0, count: SpectrumAnalyzer.size)
        os_unfair_lock_lock(&analyzerLock)
        let start = analyzerWriteIndex
        let tail = SpectrumAnalyzer.size - start
        samples.withUnsafeMutableBufferPointer { out in
            out.baseAddress!.update(from: analyzerRing + start, count: tail)
            (out.baseAddress! + tail).update(from: analyzerRing, count: start)
        }
        os_unfair_lock_unlock(&analyzerLock)
        os_unfair_lock_lock(&controlsLock)
        let sampleRate = _sampleRate
        os_unfair_lock_unlock(&controlsLock)
        return (samples, sampleRate)
    }

    func feedAnalyzer(
        left: (samples: UnsafeMutablePointer<Float32>, stride: Int, frames: Int),
        right: (samples: UnsafeMutablePointer<Float32>, stride: Int, frames: Int)
    ) {
        guard os_unfair_lock_trylock(&analyzerLock) else { return }
        for frame in 0..<min(left.frames, right.frames) {
            analyzerRing[analyzerWriteIndex] =
                0.5 * (left.samples[frame * left.stride] + right.samples[frame * right.stride])
            analyzerWriteIndex = (analyzerWriteIndex + 1) % SpectrumAnalyzer.size
        }
        os_unfair_lock_unlock(&analyzerLock)
    }

    private static func silentRing() -> UnsafeMutablePointer<Float> {
        let ring = UnsafeMutablePointer<Float>.allocate(capacity: SpectrumAnalyzer.size)
        ring.initialize(repeating: 0, count: SpectrumAnalyzer.size)
        return ring
    }

    private static func biquadStates() -> UnsafeMutablePointer<BiquadState> {
        let states = UnsafeMutablePointer<BiquadState>.allocate(capacity: eqBandCount)
        states.initialize(repeating: BiquadState(), count: eqBandCount)
        return states
    }

    private static func unityGains() -> UnsafeMutablePointer<Float> {
        let gains = UnsafeMutablePointer<Float>.allocate(capacity: maxTaps)
        gains.initialize(repeating: 1, count: maxTaps)
        return gains
    }

    deinit {
        [mixLeft, mixRight, targetGains, frameGains, rampGains].forEach { $0.deallocate() }
        [slotAzimuth, slotDistance, frameSlotAzimuth, frameSlotDistance].forEach { $0.deallocate() }
        [slotLeft, slotRight].forEach { $0.deallocate() }
        tapSlot.deallocate()
        frameTapSlot.deallocate()
        frameSlots.deallocate()
        eqCoefficients.deallocate()
        frameEQCoefficients.deallocate()
        eqBandActive.deallocate()
        frameEQBandActive.deallocate()
        analyzerRing.deallocate()
        eqLeftState.deallocate()
        eqRightState.deallocate()
        [tapEQActive, frameTapEQActive, tapEQBandActive, frameTapEQBandActive].forEach { $0.deallocate() }
        [tapEQCoefficients, frameTapEQCoefficients].forEach { $0.deallocate() }
        [tapEQLeftState, tapEQRightState].forEach { $0.deallocate() }
        [tapScratchLeft, tapScratchRight].forEach { $0.deallocate() }
    }
    private var lastCallbackTime: CFAbsoluteTime?
    private var hrtfRenderer: HRTFRenderer?
    // Fallback when the HRTF mixer can't start.
    private var binauralProcessor: BinauralProcessor?

    // Main thread writes, audio thread reads every callback.
    private var controlsLock = os_unfair_lock()
    /// Rotations per second; positive = clockwise seen from above.
    private var _speed: Double = 0.125
    private var _isBypassed: Bool = false
    /// Linear gain after effects, then peak-limited.
    private var _boost: Float = 1
    private var _pan: Float = 0
    private var _effects = EffectsSettings()   // guarded by controlsLock
    private var _effectsEnabled = true         // guarded by controlsLock
    private var effectsProcessor: EffectsProcessor?
    private var limiter: Limiter?

    func setEffects(_ effects: EffectsSettings, enabled: Bool) {
        os_unfair_lock_lock(&controlsLock)
        _effects = effects
        _effectsEnabled = enabled
        os_unfair_lock_unlock(&controlsLock)
    }

    var pan: Float {
        get { os_unfair_lock_lock(&controlsLock); defer { os_unfair_lock_unlock(&controlsLock) }; return _pan }
        set { os_unfair_lock_lock(&controlsLock); defer { os_unfair_lock_unlock(&controlsLock) }; _pan = newValue }
    }

    static func balanceGains(pan: Float) -> (left: Float, right: Float) {
        (min(1, 1 - pan), min(1, 1 + pan))
    }

    var speed: Double {
        get { os_unfair_lock_lock(&controlsLock); defer { os_unfair_lock_unlock(&controlsLock) }; return _speed }
        set { os_unfair_lock_lock(&controlsLock); defer { os_unfair_lock_unlock(&controlsLock) }; _speed = newValue }
    }
    var isBypassed: Bool {
        get { os_unfair_lock_lock(&controlsLock); defer { os_unfair_lock_unlock(&controlsLock) }; return _isBypassed }
        set { os_unfair_lock_lock(&controlsLock); defer { os_unfair_lock_unlock(&controlsLock) }; _isBypassed = newValue }
    }

    var boost: Float {
        get { os_unfair_lock_lock(&controlsLock); defer { os_unfair_lock_unlock(&controlsLock) }; return _boost }
        set { os_unfair_lock_lock(&controlsLock); defer { os_unfair_lock_unlock(&controlsLock) }; _boost = newValue }
    }

    /// 0...1 keyed by AudioApp.id; unlisted apps play at 1.
    func setAppVolumes(_ volumes: [String: Float]) {
        var old = volumes
        os_unfair_lock_lock(&controlsLock)
        swap(&old, &_appVolumes)
        publishGainsLocked()
        os_unfair_lock_unlock(&controlsLock)
        _ = old // released here, outside the lock the audio thread takes
    }

    func setEQ(_ eq: EQSettings, enabled: Bool) {
        os_unfair_lock_lock(&controlsLock)
        _eq = eq
        _eqEnabled = enabled
        publishEQLocked()
        publishTapEQLocked()
        os_unfair_lock_unlock(&controlsLock)
    }

    /// Keyed by AudioApp.id; follows the master EQ's on/off switch.
    func setAppEQs(_ eqs: [String: EQSettings]) {
        var old = eqs
        os_unfair_lock_lock(&controlsLock)
        swap(&old, &_appEQs)
        publishTapEQLocked()
        os_unfair_lock_unlock(&controlsLock)
        _ = old // released here, outside the lock the audio thread takes
    }

    /// Caller holds controlsLock.
    private func publishTapEQLocked() {
        _anyTapEQ = false
        for tap in 0..<_tapCount {
            guard _eqEnabled, tap < _tapAppIDs.count, let eq = _appEQs[_tapAppIDs[tap]], !eq.isFlat else {
                tapEQActive[tap] = false
                continue
            }
            tapEQActive[tap] = true
            _anyTapEQ = true
            for (index, stage) in eq.stages(sampleRate: _sampleRate).prefix(Self.eqBandCount).enumerated() {
                tapEQCoefficients[tap * Self.eqBandCount + index] = stage.coefficients
                tapEQBandActive[tap * Self.eqBandCount + index] = stage.isActive
            }
        }
    }

    /// Caller holds controlsLock.
    private func publishEQLocked() {
        _eqActive = _eqEnabled && !_eq.isFlat
        for (index, stage) in _eq.stages(sampleRate: _sampleRate).prefix(Self.eqBandCount).enumerated() {
            eqCoefficients[index] = stage.coefficients
            eqBandActive[index] = stage.isActive
        }
    }

    /// Caller holds controlsLock.
    private func publishGainsLocked() {
        _tapCount = max(1, min(_tapAppIDs.count, Self.maxTaps))
        for index in 0..<_tapCount {
            targetGains[index] = index < _tapAppIDs.count ? (_appVolumes[_tapAppIDs[index]] ?? 1) : 1
        }
    }

    /// Also copies per-tap gains and EQ into the frame buffers.
    private func currentControls() -> (
        speed: Double, isBypassed: Bool, boost: Float, tapCount: Int, eqActive: Bool, analyzerOn: Bool, pan: Float,
        effects: EffectsSettings?, slotCount: Int
    ) {
        os_unfair_lock_lock(&controlsLock)
        defer { os_unfair_lock_unlock(&controlsLock) }
        frameGains.update(from: targetGains, count: _tapCount)
        frameTapSlot.update(from: tapSlot, count: _tapCount)
        frameSlotAzimuth.update(from: slotAzimuth, count: _slotCount)
        frameSlotDistance.update(from: slotDistance, count: _slotCount)
        if _eqActive {
            frameEQCoefficients.update(from: eqCoefficients, count: Self.eqBandCount)
            frameEQBandActive.update(from: eqBandActive, count: Self.eqBandCount)
        }
        if _anyTapEQ {
            frameTapEQActive.update(from: tapEQActive, count: _tapCount)
            frameTapEQCoefficients.update(from: tapEQCoefficients, count: _tapCount * Self.eqBandCount)
            frameTapEQBandActive.update(from: tapEQBandActive, count: _tapCount * Self.eqBandCount)
        } else {
            frameTapEQActive.update(repeating: false, count: _tapCount)
        }
        let effects = _effectsEnabled && _effects.anyOn ? _effects : nil
        return (_speed, _isBypassed, _boost, _tapCount, _eqActive, _isAnalyzerOn, _pan, effects, _slotCount)
    }

    func start(speed: Double) throws {
        try controlQueue.sync { try startLocked(speed: speed) }
    }

    func stop() {
        controlQueue.sync { stopLocked() }
    }

    func restart() throws {
        try controlQueue.sync {
            let currentSpeed = speed
            stopLocked()
            try startLocked(speed: currentSpeed)
        }
    }

    private func startLocked(speed: Double) throws {
        self.speed = speed
        let deviceID = try capture.start()
        aggregateDeviceID = deviceID
        prepare(sampleRate: capture.nominalSampleRate ?? 48_000, tapAppIDs: capture.tapAppIDs)

        do {
            let procID = try Self.registerIOProc(on: deviceID) { [weak self] inputData, outputData in
                self?.render(input: inputData, output: outputData)
            }
            ioProcID = procID

            let startStatus = AudioDeviceStart(deviceID, procID)
            guard startStatus == noErr else {
                throw Error.deviceStartFailed(startStatus)
            }
        } catch {
            stopLocked()
            throw error
        }

        // Poll for new apps: no reliable property listener on macOS 26.
        let timer = DispatchSource.makeTimerSource(queue: controlQueue)
        timer.schedule(deadline: .now() + 1.5, repeating: 1.5)
        timer.setEventHandler { [weak self] in
            guard let self, self.capture.hasNewUnmutedProcess() else { return }
            let currentSpeed = self.speed
            self.stopLocked()
            try? self.startLocked(speed: currentSpeed)
        }
        timer.resume()
        refreshTimer = timer
    }

    private func stopLocked() {
        refreshTimer?.cancel()
        refreshTimer = nil
        if let deviceID = aggregateDeviceID, let procID = ioProcID {
            AudioDeviceStop(deviceID, procID)
            AudioDeviceDestroyIOProcID(deviceID, procID)
        }
        ioProcID = nil
        aggregateDeviceID = nil
        lastCallbackTime = nil
        hrtfRenderer = nil
        binauralProcessor = nil
        effectsProcessor = nil
        limiter = nil
        capture.stop()
    }

    /// Also the benchmark's entry point.
    func prepare(sampleRate: Double, tapAppIDs: [String]) {
        os_unfair_lock_lock(&controlsLock)
        _tapAppIDs = tapAppIDs
        publishGainsLocked()
        publishPlacementLocked()
        // IO proc not running yet, so resetting ramp state is safe.
        rampGains.update(from: targetGains, count: _tapCount)
        _sampleRate = sampleRate
        publishEQLocked()
        publishTapEQLocked()
        eqLeftState.update(repeating: BiquadState(), count: Self.eqBandCount)
        eqRightState.update(repeating: BiquadState(), count: Self.eqBandCount)
        tapEQLeftState.update(repeating: BiquadState(), count: Self.tapEQStages)
        tapEQRightState.update(repeating: BiquadState(), count: Self.tapEQStages)
        os_unfair_lock_unlock(&controlsLock)

        hrtfRenderer = HRTFRenderer(sampleRate: sampleRate)
        if hrtfRenderer == nil {
            binauralProcessor = BinauralProcessor(sampleRate: sampleRate)
        }
        effectsProcessor = EffectsProcessor(sampleRate: sampleRate)
        limiter = Limiter(sampleRate: sampleRate)
    }

    func render(input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>) {
        let inputList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outputList = UnsafeMutableAudioBufferListPointer(output)
        guard Self.channelCount(inputList) >= 2, Self.channelCount(outputList) >= 2 else { return }

        guard let leftDestination = Self.channel(0, in: outputList), let rightDestination = Self.channel(1, in: outputList)
        else { return }

        let controls = currentControls()
        let frames = min(leftDestination.frames, rightDestination.frames, Self.mixCapacity)
        let slotCount = hrtfRenderer == nil ? 0 : controls.slotCount
        mixTaps(inputList, count: controls.tapCount, frames: frames, placing: slotCount > 0)
        for slot in 0..<slotCount {
            frameSlots[slot] = HRTFRenderer.Slot(
                azimuth: frameSlotAzimuth[slot], distance: frameSlotDistance[slot],
                left: (slotLeft + slot * Self.mixCapacity, 1, frames),
                right: (slotRight + slot * Self.mixCapacity, 1, frames))
        }
        let leftSource = (samples: mixLeft, stride: 1, frames: frames)
        let rightSource = (samples: mixRight, stride: 1, frames: frames)

        // Accumulated so a speed change doesn't jump the pan position.
        let now = CFAbsoluteTimeGetCurrent()
        let dt = lastCallbackTime.map { now - $0 } ?? 0
        lastCallbackTime = now
        phase += 2 * Double.pi * dt * controls.speed
        phase = phase.truncatingRemainder(dividingBy: 2 * Double.pi)

        if controls.isBypassed {
            // No array literal: heap allocation on the audio thread.
            for frame in 0..<min(leftSource.frames, leftDestination.frames) {
                leftDestination.samples[frame * leftDestination.stride] = leftSource.samples[frame * leftSource.stride]
            }
            for frame in 0..<min(rightSource.frames, rightDestination.frames) {
                rightDestination.samples[frame * rightDestination.stride] = rightSource.samples[frame * rightSource.stride]
            }
            if slotCount > 0, let hrtfRenderer {
                hrtfRenderer.process(bed: nil, slots: frameSlots, slotCount: slotCount,
                                     into: (leftDestination, rightDestination), adding: true)
            }
        } else if let hrtfRenderer {
            let bed = (azimuth: Float32(phase * 180 / Double.pi),
                       gainDb: Float32(BinauralEffect.depthGainDb(depth: cos(phase))),
                       left: leftSource, right: rightSource)
            hrtfRenderer.process(bed: bed, slots: frameSlots, slotCount: slotCount,
                                 into: (leftDestination, rightDestination), adding: false)
        } else {
            binauralProcessor?.process(
                phase: phase,
                left: (leftSource, leftDestination),
                right: (rightSource, rightDestination),
                ildGains: PanLFO.gains(phase: phase)
            )
        }

        if let effects = controls.effects {
            effectsProcessor?.process(left: leftDestination, right: rightDestination, settings: effects)
        }

        if controls.eqActive {
            applyEQ(left: leftDestination, right: rightDestination)
        }

        if controls.pan != 0 {
            let balance = Self.balanceGains(pan: controls.pan)
            Self.applyGain(balance.left, to: leftDestination)
            Self.applyGain(balance.right, to: rightDestination)
        }

        // Always on, so EQ and effects can't clip the output either.
        limiter?.process(left: leftDestination, right: rightDestination, inputGain: controls.boost)

        if controls.analyzerOn {
            feedAnalyzer(left: leftDestination, right: rightDestination)
        }
    }

    /// Gains ramp from the last callback so volume moves don't click.
    /// Tap channels are the aggregate's last 2*count inputs.
    private func mixTaps(_ inputList: UnsafeMutableAudioBufferListPointer, count: Int, frames: Int, placing: Bool) {
        mixLeft.update(repeating: 0, count: frames)
        mixRight.update(repeating: 0, count: frames)
        let inputChannels = Self.channelCount(inputList)
        let tapCount = min(count, inputChannels / 2)
        let firstTapChannel = inputChannels - 2 * tapCount
        for tap in 0..<tapCount {
            guard let left = Self.channel(firstTapChannel + 2 * tap, in: inputList),
                  let right = Self.channel(firstTapChannel + 2 * tap + 1, in: inputList)
            else { continue }
            let tapFrames = min(frames, left.frames, right.frames)
            let start = rampGains[tap]
            let step = (frameGains[tap] - start) / Float(max(tapFrames, 1))
            let slot = placing ? frameTapSlot[tap] : -1
            let outLeft = slot >= 0 ? slotLeft + slot * Self.mixCapacity : mixLeft
            let outRight = slot >= 0 ? slotRight + slot * Self.mixCapacity : mixRight
            if slot >= 0 {
                outLeft.update(repeating: 0, count: frames)
                outRight.update(repeating: 0, count: frames)
            }
            if frameTapEQActive[tap] {
                for frame in 0..<tapFrames {
                    let gain = start + step * Float(frame)
                    tapScratchLeft[frame] = left.samples[frame * left.stride] * gain
                    tapScratchRight[frame] = right.samples[frame * right.stride] * gain
                }
                applyTapEQ(tap, frames: tapFrames)
                for frame in 0..<tapFrames {
                    outLeft[frame] += tapScratchLeft[frame]
                    outRight[frame] += tapScratchRight[frame]
                }
            } else {
                for frame in 0..<tapFrames {
                    let gain = start + step * Float(frame)
                    outLeft[frame] += left.samples[frame * left.stride] * gain
                    outRight[frame] += right.samples[frame * right.stride] * gain
                }
            }
            rampGains[tap] = frameGains[tap]
        }
    }

    private func applyEQ(
        left: (samples: UnsafeMutablePointer<Float32>, stride: Int, frames: Int),
        right: (samples: UnsafeMutablePointer<Float32>, stride: Int, frames: Int)
    ) {
        let frames = min(left.frames, right.frames)
        for band in 0..<Self.eqBandCount where frameEQBandActive[band] {
            BiquadState.processStereo(
                left: (left.samples, left.stride), leftState: &eqLeftState[band],
                right: (right.samples, right.stride), rightState: &eqRightState[band],
                frames: frames, frameEQCoefficients[band])
        }
    }

    private func applyTapEQ(_ tap: Int, frames: Int) {
        for band in 0..<Self.eqBandCount {
            let stage = tap * Self.eqBandCount + band
            guard frameTapEQBandActive[stage] else { continue }
            BiquadState.processStereo(
                left: (tapScratchLeft, 1), leftState: &tapEQLeftState[stage],
                right: (tapScratchRight, 1), rightState: &tapEQRightState[stage],
                frames: frames, frameTapEQCoefficients[stage])
        }
    }

    private static func applyGain(
        _ gain: Float, to buffer: (samples: UnsafeMutablePointer<Float32>, stride: Int, frames: Int)
    ) {
        for frame in 0..<buffer.frames {
            buffer.samples[frame * buffer.stride] *= gain
        }
    }

    private static func channelCount(_ list: UnsafeMutableAudioBufferListPointer) -> Int {
        list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    /// Handles interleaved and per-buffer layouts; format depends on the device.
    private static func channel(
        _ index: Int, in list: UnsafeMutableAudioBufferListPointer
    ) -> (samples: UnsafeMutablePointer<Float32>, stride: Int, frames: Int)? {
        var remaining = index
        for buffer in list {
            let channels = Int(buffer.mNumberChannels)
            guard channels > 0 else { continue }
            if remaining < channels {
                guard let data = buffer.mData else { return nil }
                let frames = Int(buffer.mDataByteSize) / MemoryLayout<Float32>.size / channels
                return (data.assumingMemoryBound(to: Float32.self) + remaining, channels, frames)
            }
            remaining -= channels
        }
        return nil
    }

    private static func registerIOProc(
        on deviceID: AudioDeviceID,
        _ block: @escaping (UnsafePointer<AudioBufferList>, UnsafeMutablePointer<AudioBufferList>) -> Void
    ) throws -> AudioDeviceIOProcID {
        var procID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, deviceID, ioQueue) { _, inputData, _, outputData, _ in
            block(inputData, outputData)
        }
        guard status == noErr, let procID else {
            throw Error.ioProcRegistrationFailed(status)
        }
        return procID
    }
}
