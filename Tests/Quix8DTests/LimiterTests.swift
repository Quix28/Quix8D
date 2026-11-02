import XCTest
@testable import Quix8D

final class LimiterTests: XCTestCase {
    private let sampleRate = 48_000.0

    private func limit(_ left: [Float], _ right: [Float], gain: Float, ceiling: Float = Limiter.ceiling, block: Int = 512) -> (left: [Float], right: [Float]) {
        let limiter = Limiter(sampleRate: sampleRate)
        var left = left, right = right
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                var start = 0
                while start < l.count {
                    let frames = min(block, l.count - start)
                    limiter.process(left: (l.baseAddress! + start, 1, frames), right: (r.baseAddress! + start, 1, frames), inputGain: gain, ceiling: ceiling)
                    start += frames
                }
            }
        }
        return (left, right)
    }

    private func sine(peak: Float, hz: Double = 1_000, seconds: Double = 1) -> [Float] {
        (0..<Int(sampleRate * seconds)).map { peak * Float(sin(2 * Double.pi * hz * Double($0) / sampleRate)) }
    }

    /// Harmonics 2...19 relative to the fundamental, over the last `count` samples.
    private func thd(_ signal: [Float], hz: Double, count: Int = 48_000 / 2) -> Double {
        let tail = signal.suffix(count).map(Double.init)
        func magnitude(_ f: Double) -> Double {
            var re = 0.0, im = 0.0
            for (n, x) in tail.enumerated() {
                let w = 0.5 - 0.5 * cos(2 * Double.pi * Double(n) / Double(count))
                re += w * x * cos(2 * Double.pi * f * Double(n) / sampleRate)
                im -= w * x * sin(2 * Double.pi * f * Double(n) / sampleRate)
            }
            return (re * re + im * im).squareRoot()
        }
        let harmonics = (2..<20).map { magnitude(hz * Double($0)) }
        return (harmonics.map { $0 * $0 }.reduce(0, +)).squareRoot() / magnitude(hz)
    }

    func testQuietSignalPassesThroughDelayedAndUnchanged() {
        let input = sine(peak: 0.5, seconds: 0.1)
        let output = limit(input, input, gain: 1).left
        let delay = Limiter(sampleRate: sampleRate).lookahead
        for index in delay..<input.count {
            XCTAssertEqual(output[index], input[index - delay], accuracy: 1e-6)
        }
    }

    func testBoostedLoudMusicNeverExceedsCeiling() {
        let left = sine(peak: 0.9, hz: 220), right = sine(peak: 0.6, hz: 3_300)
        let output = limit(left, right, gain: 6)
        let peak = (output.left + output.right).map(abs).max()!
        XCTAssertLessThanOrEqual(peak, Limiter.ceiling + 1e-4)
    }

    func testSuddenTransientIsCaughtByLookahead() {
        var input = [Float](repeating: 0, count: 4_800)
        for index in 2_000..<2_010 { input[index] = index.isMultiple(of: 2) ? 1 : -1 }
        let output = limit(input, input, gain: 6, block: 37)
        XCTAssertLessThanOrEqual(output.left.map(abs).max()!, Limiter.ceiling + 1e-4)
    }

    func testSustainedBoostStaysClean() {
        // The old soft clipper measured ~38% THD here.
        let output = limit(sine(peak: 0.89), sine(peak: 0.89), gain: 6).left
        XCTAssertLessThan(thd(output, hz: 1_000), 0.01)
    }

    func testHearingCapHoldsLowerCeilingAndClampsHigherOne() {
        let cap = Float(pow(10, -12.0 / 20))
        let capped = limit(sine(peak: 0.9), sine(peak: 0.9), gain: 6, ceiling: cap).left
        XCTAssertLessThanOrEqual(capped.map(abs).max()!, cap + 1e-4)
        XCTAssertGreaterThan(capped.map(abs).max()!, cap * 0.9)

        let unclamped = limit(sine(peak: 0.9), sine(peak: 0.9), gain: 6, ceiling: 2).left
        XCTAssertLessThanOrEqual(unclamped.map(abs).max()!, Limiter.ceiling + 1e-4)
    }

    func testHearingCeilingTracksVolume() {
        // 110 dB headphones at full volume, 75 dB cap: 35 dB of headroom to remove.
        XCTAssertEqual(Limiter.hearingCeiling(capSPL: 75, fullVolumeSPL: 110, attenuationDb: 0),
                       Float(pow(10, -35.0 / 20)), accuracy: 1e-6)
        // Volume 20 dB down: the signal may be 20 dB hotter.
        XCTAssertEqual(Limiter.hearingCeiling(capSPL: 75, fullVolumeSPL: 110, attenuationDb: -20),
                       Float(pow(10, -15.0 / 20)), accuracy: 1e-6)
        // Volume so low the cap can't be reached: plain limiter ceiling.
        XCTAssertEqual(Limiter.hearingCeiling(capSPL: 75, fullVolumeSPL: 110, attenuationDb: -40), Limiter.ceiling)
    }
}
