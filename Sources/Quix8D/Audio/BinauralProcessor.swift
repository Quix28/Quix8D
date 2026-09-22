import Foundation

struct BiquadState {
    var z1: Float32 = 0
    var z2: Float32 = 0

    mutating func process(_ x: Float32, _ c: BinauralEffect.Biquad) -> Float32 {
        let y = c.b0 * x + z1
        z1 = c.b1 * x - c.a1 * y + z2
        z2 = c.b2 * x - c.a2 * y
        return y
    }

    /// Copies state into locals: `samples` may alias `self`, which would force
    /// a reload every sample.
    mutating func process(_ samples: UnsafeMutablePointer<Float32>, stride: Int, frames: Int, _ c: BinauralEffect.Biquad) {
        let (b0, b1, b2, a1, a2) = (c.b0, c.b1, c.b2, c.a1, c.a2)
        var (s1, s2) = (z1, z2)
        for frame in 0..<frames {
            let index = frame * stride
            let x = samples[index]
            let y = b0 * x + s1
            s1 = b1 * x - a1 * y + s2
            s2 = b2 * x - a2 * y
            samples[index] = y
        }
        (z1, z2) = (s1, s2)
    }

    /// SIMD2 over both channels: the recursion is latency-bound, so this nearly
    /// halves the cost.
    static func processStereo(
        left: (samples: UnsafeMutablePointer<Float32>, stride: Int), leftState: inout BiquadState,
        right: (samples: UnsafeMutablePointer<Float32>, stride: Int), rightState: inout BiquadState,
        frames: Int, _ c: BinauralEffect.Biquad
    ) {
        let (b0, b1, b2, a1, a2) = (SIMD2(repeating: c.b0), SIMD2(repeating: c.b1), SIMD2(repeating: c.b2),
                                    SIMD2(repeating: c.a1), SIMD2(repeating: c.a2))
        var s1 = SIMD2(leftState.z1, rightState.z1)
        var s2 = SIMD2(leftState.z2, rightState.z2)
        for frame in 0..<frames {
            let x = SIMD2(left.samples[frame * left.stride], right.samples[frame * right.stride])
            let y = b0 * x + s1
            s1 = b1 * x - a1 * y + s2
            s2 = b2 * x - a2 * y
            left.samples[frame * left.stride] = y.x
            right.samples[frame * right.stride] = y.y
        }
        (leftState.z1, rightState.z1) = (s1.x, s1.y)
        (leftState.z2, rightState.z2) = (s2.x, s2.y)
    }
}

/// ITD -> head shadow -> front/back dip -> directional EQ -> ILD gain (last, so filter state ignores it).
/// Real-time safe: no allocation, locking or blocking in `process`.
final class BinauralProcessor {
    typealias Buffer = (samples: UnsafeMutablePointer<Float32>, stride: Int, frames: Int)

    private struct ChannelState {
        var ring: [Float32]
        var writeIndex: Int = 0
        var headShadowState: Float32 = 0
        var frontBackState: Float32 = 0
        var frontBand = BiquadState()
        var backBand = BiquadState()
    }

    private var left: ChannelState
    private var right: ChannelState
    private let sampleRate: Double
    private let maxDelaySamples: Double
    private let ringCapacity: Int
    private let frontBackCoeff: Float32

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
        self.maxDelaySamples = sampleRate * BinauralEffect.maxITDMilliseconds / 1000
        // +8 headroom so index math never special-cases rounding.
        self.ringCapacity = Int(maxDelaySamples.rounded(.up)) + 8
        self.left = ChannelState(ring: Array(repeating: 0, count: ringCapacity))
        self.right = ChannelState(ring: Array(repeating: 0, count: ringCapacity))
        self.frontBackCoeff = Float32(BinauralEffect.onePoleCoefficient(
            cutoffHz: BinauralEffect.frontBackDipHz, sampleRate: sampleRate))
    }

    /// `phase` is AudioPipeline's LFO phase: pan = sin(phase), depth = cos(phase).
    func process(
        phase: Double,
        left leftBuffers: (source: Buffer, destination: Buffer),
        right rightBuffers: (source: Buffer, destination: Buffer),
        ildGains: (left: Float, right: Float)
    ) {
        let pan = sin(phase)
        let depth = cos(phase)
        let delay = BinauralEffect.itdDelaySamples(pan: pan, maxDelaySamples: maxDelaySamples)
        let cutoff = BinauralEffect.headShadowCutoffHz(pan: pan)
        let dipAmount = BinauralEffect.frontBackDipAmount(depth: depth)
        let frontGain = BinauralEffect.depthGain(depth: depth)
        // Shared by both ears: a pinna cue, not a left/right one.
        let bands = (
            front: BinauralEffect.peakingCoefficients(
                centerHz: BinauralEffect.frontBandHz, gainDb: BinauralEffect.frontBandPeakDb * max(0, depth),
                q: BinauralEffect.directionalBandQ, sampleRate: sampleRate),
            back: BinauralEffect.peakingCoefficients(
                centerHz: BinauralEffect.backBandHz, gainDb: BinauralEffect.backBandPeakDb * max(0, -depth),
                q: BinauralEffect.directionalBandQ, sampleRate: sampleRate))

        processChannel(&left, source: leftBuffers.source, destination: leftBuffers.destination,
                       delaySamples: Int(delay.left.rounded()),
                       headShadowCoeff: Float32(BinauralEffect.onePoleCoefficient(cutoffHz: cutoff.left, sampleRate: sampleRate)),
                       dipAmount: dipAmount, bands: bands, ildGain: ildGains.left * frontGain)
        processChannel(&right, source: rightBuffers.source, destination: rightBuffers.destination,
                       delaySamples: Int(delay.right.rounded()),
                       headShadowCoeff: Float32(BinauralEffect.onePoleCoefficient(cutoffHz: cutoff.right, sampleRate: sampleRate)),
                       dipAmount: dipAmount, bands: bands, ildGain: ildGains.right * frontGain)
    }

    private func processChannel(
        _ state: inout ChannelState, source: Buffer, destination: Buffer,
        delaySamples: Int, headShadowCoeff: Float32, dipAmount: Float32,
        bands: (front: BinauralEffect.Biquad, back: BinauralEffect.Biquad), ildGain: Float32
    ) {
        let frameCount = min(source.frames, destination.frames)
        let capacity = ringCapacity
        for frame in 0..<frameCount {
            let raw = source.samples[frame * source.stride]
            state.ring[state.writeIndex] = raw
            let readIndex = (state.writeIndex - delaySamples + capacity) % capacity
            let delayed = state.ring[readIndex]
            state.writeIndex = (state.writeIndex + 1) % capacity

            state.headShadowState += headShadowCoeff * (delayed - state.headShadowState)
            let shadowed = state.headShadowState

            // Filter always runs so re-engaging the dip has no transient; only the blend moves.
            state.frontBackState += frontBackCoeff * (shadowed - state.frontBackState)
            let blended = shadowed * (1 - dipAmount) + state.frontBackState * dipAmount

            let banded = state.backBand.process(state.frontBand.process(blended, bands.front), bands.back)

            destination.samples[frame * destination.stride] = banded * ildGain
        }
    }
}
