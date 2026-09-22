import Foundation

/// Plain values only, so the audio thread can copy it without allocating.
struct EffectsSettings: Equatable, Codable {
    struct Reverb: Equatable, Codable {
        var isOn = false
        var mix = 0.3
        var size = 0.6
        var damping = 0.5
    }

    struct Delay: Equatable, Codable {
        var isOn = false
        var time = 0.35 // seconds
        var feedback = 0.35
        var mix = 0.3
    }

    struct Compressor: Equatable, Codable {
        var isOn = false
        var threshold = -18.0 // dBFS
        var ratio = 4.0
        var makeup = 6.0 // dB
    }

    struct Widener: Equatable, Codable {
        var isOn = false
        var width = 1.5 // 0 = mono, 1 = unchanged, 2 = double side
    }

    struct BassEnhancer: Equatable, Codable {
        var isOn = false
        var amount = 0.5
        var frequency = 120.0 // Hz
    }

    struct Chorus: Equatable, Codable {
        var isOn = false
        var rate = 0.8 // Hz
        var depth = 0.5
        var mix = 0.5
    }

    var reverb = Reverb()
    var delay = Delay()
    var compressor = Compressor()
    var widener = Widener()
    var bassEnhancer = BassEnhancer()
    var chorus = Chorus()

    var anyOn: Bool {
        reverb.isOn || delay.isOn || compressor.isOn || widener.isOn || bassEnhancer.isOn || chorus.isOn
    }
}

private struct Comb {
    let buffer: UnsafeMutablePointer<Float>
    let size: Int
    var index = 0
    var store: Float = 0

    mutating func process(_ x: Float, feedback: Float, damp: Float) -> Float {
        let out = buffer[index]
        store = out * (1 - damp) + store * damp
        buffer[index] = x + store * feedback
        index = index + 1 == size ? 0 : index + 1
        return out
    }
}

private struct Allpass {
    let buffer: UnsafeMutablePointer<Float>
    let size: Int
    var index = 0

    mutating func process(_ x: Float) -> Float {
        let delayed = buffer[index]
        buffer[index] = x + delayed * 0.5
        index = index + 1 == size ? 0 : index + 1
        return delayed - x
    }
}

private struct DelayLine {
    let buffer: UnsafeMutablePointer<Float>
    let size: Int
    var writeIndex = 0

    /// `delay` must be in 1 ... size - 2.
    func read(delay: Float) -> Float {
        var position = Float(writeIndex) - delay
        if position < 0 { position += Float(size) }
        let base = Int(position)
        let fraction = position - Float(base)
        let next = base + 1 == size ? 0 : base + 1
        return buffer[base] * (1 - fraction) + buffer[next] * fraction
    }

    mutating func write(_ x: Float) {
        buffer[writeIndex] = x
        writeIndex = writeIndex + 1 == size ? 0 : writeIndex + 1
    }
}

final class EffectsProcessor {
    typealias Buffer = BinauralProcessor.Buffer

    private static let combTunings = [1116, 1188, 1277, 1356, 1422, 1491, 1557, 1617]
    private static let allpassTunings = [556, 441, 341, 225]
    private static let stereoSpread = 23
    private static let maxDelaySeconds = 2.0
    private static let chorusBufferSeconds = 0.05

    private let sampleRate: Double
    private var allocations: [UnsafeMutablePointer<Float>] = []

    private let combsLeft: UnsafeMutablePointer<Comb>
    private let combsRight: UnsafeMutablePointer<Comb>
    private let allpassesLeft: UnsafeMutablePointer<Allpass>
    private let allpassesRight: UnsafeMutablePointer<Allpass>
    private var delayLeft: DelayLine
    private var delayRight: DelayLine
    private var chorusLeft: DelayLine
    private var chorusRight: DelayLine

    private var smoothedDelaySamples: Float = 0
    private var chorusPhase: Double = 0
    private var envelope: Float = 0
    private let attackCoefficient: Float
    private let releaseCoefficient: Float
    private var bassState = BiquadState()
    private var bassCoefficients = BinauralEffect.Biquad(b0: 1, b1: 0, b2: 0, a1: 0, a2: 0)
    private var bassFrequency = -1.0

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
        var allocations: [UnsafeMutablePointer<Float>] = []
        func zeroed(_ count: Int) -> UnsafeMutablePointer<Float> {
            let buffer = UnsafeMutablePointer<Float>.allocate(capacity: count)
            buffer.initialize(repeating: 0, count: count)
            allocations.append(buffer)
            return buffer
        }
        let scale = sampleRate / 44_100
        func combs(spread: Int) -> UnsafeMutablePointer<Comb> {
            let combs = UnsafeMutablePointer<Comb>.allocate(capacity: Self.combTunings.count)
            for (index, tuning) in Self.combTunings.enumerated() {
                let size = Int(Double(tuning + spread) * scale)
                combs.advanced(by: index).initialize(to: Comb(buffer: zeroed(size), size: size))
            }
            return combs
        }
        func allpasses(spread: Int) -> UnsafeMutablePointer<Allpass> {
            let allpasses = UnsafeMutablePointer<Allpass>.allocate(capacity: Self.allpassTunings.count)
            for (index, tuning) in Self.allpassTunings.enumerated() {
                let size = Int(Double(tuning + spread) * scale)
                allpasses.advanced(by: index).initialize(to: Allpass(buffer: zeroed(size), size: size))
            }
            return allpasses
        }
        combsLeft = combs(spread: 0)
        combsRight = combs(spread: Self.stereoSpread)
        allpassesLeft = allpasses(spread: 0)
        allpassesRight = allpasses(spread: Self.stereoSpread)

        let delaySize = Int(sampleRate * Self.maxDelaySeconds)
        delayLeft = DelayLine(buffer: zeroed(delaySize), size: delaySize)
        delayRight = DelayLine(buffer: zeroed(delaySize), size: delaySize)
        let chorusSize = Int(sampleRate * Self.chorusBufferSeconds)
        chorusLeft = DelayLine(buffer: zeroed(chorusSize), size: chorusSize)
        chorusRight = DelayLine(buffer: zeroed(chorusSize), size: chorusSize)

        attackCoefficient = Float(exp(-1 / (0.005 * sampleRate)))
        releaseCoefficient = Float(exp(-1 / (0.1 * sampleRate)))
        self.allocations = allocations
    }

    deinit {
        allocations.forEach { $0.deallocate() }
        combsLeft.deallocate()
        combsRight.deallocate()
        allpassesLeft.deallocate()
        allpassesRight.deallocate()
    }

    static func compressorGainDb(levelDb: Float, threshold: Float, ratio: Float) -> Float {
        let over = levelDb - threshold
        return over > 0 ? -over * (1 - 1 / ratio) : 0
    }

    func process(left: Buffer, right: Buffer, settings: EffectsSettings) {
        let frames = min(left.frames, right.frames)
        let rate = Float(sampleRate)

        let compressor = settings.compressor
        let threshold = Float(compressor.threshold)
        let ratio = Float(max(compressor.ratio, 1))
        let makeupDb = Float(compressor.makeup)

        let bass = settings.bassEnhancer
        if bass.isOn, bass.frequency != bassFrequency {
            bassFrequency = bass.frequency
            bassCoefficients = EQ.passCoefficients(highPass: false, frequency: bass.frequency, sampleRate: sampleRate)
        }
        let bassAmount = Float(bass.amount)

        let chorus = settings.chorus
        let chorusIncrement = 2 * Double.pi * chorus.rate / sampleRate
        let chorusBase = 0.02 * rate
        let chorusSwing = Float(chorus.depth) * 0.005 * rate
        let chorusMix = Float(chorus.mix)

        let delay = settings.delay
        let targetDelay = min(max(Float(delay.time) * rate, 1), Float(delayLeft.size - 2))
        if smoothedDelaySamples == 0 { smoothedDelaySamples = targetDelay }
        let feedback = Float(min(max(delay.feedback, 0), 0.9))
        let delayMix = Float(delay.mix)

        let reverb = settings.reverb
        let roomFeedback = Float(0.7 + reverb.size * 0.28)
        let damp = Float(reverb.damping * 0.4)
        let reverbWet = Float(reverb.mix) * 1.5
        let reverbDry = 1 - Float(reverb.mix) * 0.5

        let width = Float(settings.widener.width)

        for frame in 0..<frames {
            let leftIndex = frame * left.stride
            let rightIndex = frame * right.stride
            var l = left.samples[leftIndex]
            var r = right.samples[rightIndex]

            if compressor.isOn {
                let level = max(abs(l), abs(r))
                let coefficient = level > envelope ? attackCoefficient : releaseCoefficient
                envelope = level + coefficient * (envelope - level)
                let levelDb = 20 * log10f(envelope + 1e-9)
                let gain = powf(10, (Self.compressorGainDb(levelDb: levelDb, threshold: threshold, ratio: ratio) + makeupDb) / 20)
                l *= gain
                r *= gain
            }

            if bass.isOn {
                // Saturation adds harmonics heard as bass even where speakers can't play the fundamental.
                let low = bassState.process(0.5 * (l + r), bassCoefficients)
                let harmonics = bassAmount * 0.5 * tanhf(4 * low)
                l += harmonics
                r += harmonics
            }

            if chorus.isOn {
                let sweep = sin(chorusPhase)
                let wetLeft = chorusLeft.read(delay: chorusBase + chorusSwing * Float(sweep))
                let wetRight = chorusRight.read(delay: chorusBase + chorusSwing * Float(cos(chorusPhase)))
                chorusLeft.write(l)
                chorusRight.write(r)
                chorusPhase += chorusIncrement
                if chorusPhase > 2 * Double.pi { chorusPhase -= 2 * Double.pi }
                l = l * (1 - 0.5 * chorusMix) + wetLeft * 0.5 * chorusMix
                r = r * (1 - 0.5 * chorusMix) + wetRight * 0.5 * chorusMix
            }

            if delay.isOn {
                // Glide: jumping to a new time clicks.
                smoothedDelaySamples += (targetDelay - smoothedDelaySamples) * 0.0002
                let echoLeft = delayLeft.read(delay: smoothedDelaySamples)
                let echoRight = delayRight.read(delay: smoothedDelaySamples)
                delayLeft.write(l + echoLeft * feedback)
                delayRight.write(r + echoRight * feedback)
                l += echoLeft * delayMix
                r += echoRight * delayMix
            }

            if reverb.isOn {
                let input = (l + r) * 0.015
                var outLeft: Float = 0
                var outRight: Float = 0
                for index in 0..<Self.combTunings.count {
                    outLeft += combsLeft[index].process(input, feedback: roomFeedback, damp: damp)
                    outRight += combsRight[index].process(input, feedback: roomFeedback, damp: damp)
                }
                for index in 0..<Self.allpassTunings.count {
                    outLeft = allpassesLeft[index].process(outLeft)
                    outRight = allpassesRight[index].process(outRight)
                }
                l = l * reverbDry + outLeft * reverbWet
                r = r * reverbDry + outRight * reverbWet
            }

            if settings.widener.isOn {
                let mid = 0.5 * (l + r)
                let side = 0.5 * (l - r) * width
                l = mid + side
                r = mid - side
            }

            left.samples[leftIndex] = l
            right.samples[rightIndex] = r
        }
    }
}
