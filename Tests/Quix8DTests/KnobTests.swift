import XCTest
@testable import Quix8D

final class KnobTests: XCTestCase {
    func testUpwardDragIncreasesAndFullDragCoversRange() {
        let up = Knob.value(from: 0, verticalTranslation: -Knob.dragPointsForFullRange / 2, in: -0.5...0.5)
        XCTAssertEqual(up, 0.5, accuracy: 1e-9)
        let down = Knob.value(from: 0.5, verticalTranslation: Knob.dragPointsForFullRange, in: -0.5...0.5)
        XCTAssertEqual(down, -0.5, accuracy: 1e-9)
    }

    func testDragClampsToRange() {
        XCTAssertEqual(Knob.value(from: 0.9, verticalTranslation: -1_000, in: 0...1), 1)
        XCTAssertEqual(Knob.value(from: 0.1, verticalTranslation: 1_000, in: 0...1), 0)
    }
}

final class VerticalFaderTests: XCTestCase {
    func testTopIsFullBottomIsSilentAndClamps() {
        XCTAssertEqual(VerticalFader.value(atY: 0, height: 150), 1)
        XCTAssertEqual(VerticalFader.value(atY: 150, height: 150), 0)
        XCTAssertEqual(VerticalFader.value(atY: 75, height: 150), 0.5, accuracy: 1e-6)
        XCTAssertEqual(VerticalFader.value(atY: -40, height: 150), 1)
        XCTAssertEqual(VerticalFader.value(atY: 400, height: 150), 0)
    }
}

final class FaderTaperTests: XCTestCase {
    func testEndpointsAreUnityAndSilence() {
        XCTAssertEqual(FaderTaper.gain(atPosition: 1), 1)
        XCTAssertEqual(FaderTaper.gain(atPosition: 0), 0)
        XCTAssertEqual(FaderTaper.position(ofGain: 1), 1)
        XCTAssertEqual(FaderTaper.position(ofGain: 0), 0)
        XCTAssertEqual(FaderTaper.gain(atPosition: 1.5), 1)
        XCTAssertEqual(FaderTaper.gain(atPosition: -0.5), 0)
    }

    func testPositionGainPositionRoundTrips() {
        for step in 0...100 {
            let position = Float(step) / 100
            XCTAssertEqual(FaderTaper.position(ofGain: FaderTaper.gain(atPosition: position)), position, accuracy: 1e-5)
        }
    }

    func testTaperIsMonotonicAndHalvingTravelIsMinus10dB() {
        let gains = (0...1_000).map { FaderTaper.gain(atPosition: Float($0) / 1_000) }
        XCTAssertTrue(zip(gains, gains.dropFirst()).allSatisfy { $0 < $1 })
        XCTAssertEqual(20 * log10(FaderTaper.gain(atPosition: 0.5)), -10, accuracy: 0.01)
        XCTAssertEqual(20 * log10(FaderTaper.gain(atPosition: 0.25)), -20, accuracy: 0.01)
        XCTAssertEqual(20 * log10(FaderTaper.gain(atPosition: 0.1)), -33.2, accuracy: 0.1)
    }

    func testReadoutShowsDecibels() {
        XCTAssertEqual(FaderTaper.text(forGain: 1), "0 dB")
        XCTAssertEqual(FaderTaper.text(forGain: 0.999), "0 dB")
        XCTAssertEqual(FaderTaper.text(forGain: 0.5), "-6 dB")
        XCTAssertEqual(FaderTaper.text(forGain: 0), "−∞ dB")
    }
}
