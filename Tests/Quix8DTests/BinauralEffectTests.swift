import XCTest
@testable import Quix8D

final class BinauralEffectTests: XCTestCase {
    func testItdCenterIsZero() {
        let d = BinauralEffect.itdDelaySamples(pan: 0, maxDelaySamples: 33.6)
        XCTAssertEqual(d.left, 0, accuracy: 0.001)
        XCTAssertEqual(d.right, 0, accuracy: 0.001)
    }

    func testItdFullRightDelaysLeftEar() {
        let d = BinauralEffect.itdDelaySamples(pan: 1, maxDelaySamples: 33.6)
        XCTAssertEqual(d.left, 33.6, accuracy: 0.001)
        XCTAssertEqual(d.right, 0, accuracy: 0.001)
    }

    func testItdFullLeftDelaysRightEar() {
        let d = BinauralEffect.itdDelaySamples(pan: -1, maxDelaySamples: 33.6)
        XCTAssertEqual(d.left, 0, accuracy: 0.001)
        XCTAssertEqual(d.right, 33.6, accuracy: 0.001)
    }

    func testHeadShadowCenterIsFullyOpenBothEars() {
        let c = BinauralEffect.headShadowCutoffHz(pan: 0)
        XCTAssertEqual(c.left, 20_000, accuracy: 0.001)
        XCTAssertEqual(c.right, 20_000, accuracy: 0.001)
    }

    func testHeadShadowFullRightDarkensLeftEar() {
        let c = BinauralEffect.headShadowCutoffHz(pan: 1)
        XCTAssertEqual(c.left, 4_000, accuracy: 0.001)
        XCTAssertEqual(c.right, 20_000, accuracy: 0.001)
    }

    func testFrontBackDipZeroInFront() {
        XCTAssertEqual(BinauralEffect.frontBackDipAmount(depth: 1), 0, accuracy: 0.001)
        XCTAssertEqual(BinauralEffect.frontBackDipAmount(depth: 0), 0, accuracy: 0.001)
    }

    func testFrontBackDipFullBehind() {
        XCTAssertEqual(BinauralEffect.frontBackDipAmount(depth: -1), 1, accuracy: 0.001)
        XCTAssertEqual(BinauralEffect.frontBackDipAmount(depth: -0.5), 0.5, accuracy: 0.001)
    }

    func testDepthGainFrontIsUnityBackIsQuieter() {
        XCTAssertEqual(BinauralEffect.depthGain(depth: 1), 1, accuracy: 0.0001)
        XCTAssertEqual(BinauralEffect.depthGain(depth: -1), Float(pow(10, -BinauralEffect.backAttenuationDb / 20)), accuracy: 0.0001)
    }

    func testPeakingHitsRequestedGainAtCenter() {
        let c = BinauralEffect.peakingCoefficients(centerHz: 4_000, gainDb: 6, q: 1, sampleRate: 48_000)
        XCTAssertEqual(EQ.magnitudeDb(c, hz: 4_000, sampleRate: 48_000), 6, accuracy: 0.01)
        XCTAssertEqual(EQ.magnitudeDb(c, hz: 100, sampleRate: 48_000), 0, accuracy: 0.1)
    }

    func testPeakingAtZeroGainIsIdentity() {
        let c = BinauralEffect.peakingCoefficients(centerHz: 1_000, gainDb: 0, q: 1, sampleRate: 48_000)
        XCTAssertEqual(c.b0, 1, accuracy: 1e-6)
        XCTAssertEqual(c.b1, c.a1, accuracy: 1e-6)
        XCTAssertEqual(c.b2, c.a2, accuracy: 1e-6)
    }

    func testOnePoleCoefficientHandComputedValues() {
        // Expected: 1 - exp(-2*pi*cutoff/sr), computed in Python.
        XCTAssertEqual(BinauralEffect.onePoleCoefficient(cutoffHz: 20_000, sampleRate: 48_000), 0.92705, accuracy: 0.0001)
        XCTAssertEqual(BinauralEffect.onePoleCoefficient(cutoffHz: 4_000, sampleRate: 48_000), 0.40762, accuracy: 0.0001)
        XCTAssertEqual(BinauralEffect.onePoleCoefficient(cutoffHz: 7_000, sampleRate: 48_000), 0.60000, accuracy: 0.0001)
        XCTAssertEqual(BinauralEffect.onePoleCoefficient(cutoffHz: 4_000, sampleRate: 44_100), 0.43442, accuracy: 0.0001)
    }
}
