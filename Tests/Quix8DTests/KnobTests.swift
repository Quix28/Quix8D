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
