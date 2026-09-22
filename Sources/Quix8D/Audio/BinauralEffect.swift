import Foundation

/// Stateless binaural-cue math; BinauralProcessor holds the state.
enum BinauralEffect {
    /// Real ears top out ~0.6-0.7 ms.
    static let maxITDMilliseconds: Double = 0.7

    static let headShadowOpenHz: Double = 20_000
    static let headShadowMinHz: Double = 4_000

    static let frontBackDipHz: Double = 2_500

    /// Blauert bands: a ~4 kHz peak reads as front, ~1 kHz as behind. Gains are tuning knobs.
    static let frontBandHz: Double = 4_000
    static let frontBandPeakDb: Double = 9
    static let backBandHz: Double = 1_000
    static let backBandPeakDb: Double = 8
    static let directionalBandQ: Double = 1

    /// Normalized (a0 == 1).
    struct Biquad {
        var b0: Float32, b1: Float32, b2: Float32, a1: Float32, a2: Float32
    }

    /// RBJ cookbook peaking filter; 0 dB is an exact identity.
    static func peakingCoefficients(centerHz: Double, gainDb: Double, q: Double, sampleRate: Double) -> Biquad {
        let a = pow(10, gainDb / 40)
        let w0 = 2 * Double.pi * centerHz / sampleRate
        let alpha = sin(w0) / (2 * q)
        let cosW0 = cos(w0)
        let a0 = 1 + alpha / a
        return Biquad(
            b0: Float32((1 + alpha * a) / a0), b1: Float32(-2 * cosW0 / a0), b2: Float32((1 - alpha * a) / a0),
            a1: Float32(-2 * cosW0 / a0), a2: Float32((1 - alpha / a) / a0))
    }

    /// pan > 0 = right louder (PanLFO convention), so left is the far, delayed ear.
    static func itdDelaySamples(pan: Double, maxDelaySamples: Double) -> (left: Double, right: Double) {
        let magnitude = min(abs(pan), 1) * maxDelaySamples
        return pan >= 0 ? (left: magnitude, right: 0) : (left: 0, right: magnitude)
    }

    /// Near ear stays open (~20 kHz), so both ears run one filter with no branch or jump at pan 0.
    static func headShadowCutoffHz(pan: Double) -> (left: Double, right: Double) {
        let magnitude = min(abs(pan), 1)
        let farCutoff = headShadowOpenHz - (headShadowOpenHz - headShadowMinHz) * magnitude
        return pan >= 0 ? (left: farCutoff, right: headShadowOpenHz)
                        : (left: headShadowOpenHz, right: farCutoff)
    }

    /// depth = cos(phase): +1 front (no dip), -1 back (full dip).
    static func frontBackDipAmount(depth: Double) -> Float {
        Float(max(0, -depth))
    }

    static let backAttenuationDb: Double = 7

    /// Linear in dB from 0 (front) to -backAttenuationDb (behind), so it stays click-free.
    static func depthGain(depth: Double) -> Float {
        Float(pow(10, depthGainDb(depth: depth) / 20))
    }

    static func depthGainDb(depth: Double) -> Double {
        -backAttenuationDb * (1 - depth) / 2
    }

    /// One-pole lowpass alpha for y[n] += alpha*(x[n]-y[n-1]).
    static func onePoleCoefficient(cutoffHz: Double, sampleRate: Double) -> Double {
        1 - exp(-2 * Double.pi * cutoffHz / sampleRate)
    }
}
