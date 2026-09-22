import XCTest
@testable import Quix8D

final class PanLFOTests: XCTestCase {
    func testCenterAtTimeZero() {
        let (left, right) = PanLFO.gains(at: 0, period: 8)
        XCTAssertEqual(left, 0.7071, accuracy: 0.001)
        XCTAssertEqual(right, 0.7071, accuracy: 0.001)
    }

    func testFullRightAtQuarterPeriod() {
        let (left, right) = PanLFO.gains(at: 2, period: 8)
        XCTAssertEqual(left, 0.0, accuracy: 0.001)
        XCTAssertEqual(right, 0.7079, accuracy: 0.001) // full pan, taper applied
    }

    func testFullLeftAtThreeQuarterPeriod() {
        let (left, right) = PanLFO.gains(at: 6, period: 8)
        XCTAssertEqual(left, 0.7079, accuracy: 0.001)
        XCTAssertEqual(right, 0.0, accuracy: 0.001)
    }

    func testPeriodic() {
        let a = PanLFO.gains(at: 3.3, period: 8)
        let b = PanLFO.gains(at: 3.3 + 8, period: 8)
        XCTAssertEqual(a.left, b.left, accuracy: 0.0001)
        XCTAssertEqual(a.right, b.right, accuracy: 0.0001)
    }

    func testCenterAtPhaseZero() {
        let (left, right) = PanLFO.gains(phase: 0)
        XCTAssertEqual(left, 0.7071, accuracy: 0.001)
        XCTAssertEqual(right, 0.7071, accuracy: 0.001)
    }

    func testFullRightAtQuarterTurnPhase() {
        let (left, right) = PanLFO.gains(phase: .pi / 2)
        XCTAssertEqual(left, 0.0, accuracy: 0.001)
        XCTAssertEqual(right, 0.7079, accuracy: 0.001) // full pan, taper applied
    }

    /// So a live period change can't make the pan jump.
    func testPhaseIsPeriodIndependent() {
        let viaShortPeriod = PanLFO.gains(at: 1.5, period: 8)  // phase = 3pi/8
        let viaLongPeriod = PanLFO.gains(at: 2.25, period: 12) // phase = 3pi/8
        let viaPhase = PanLFO.gains(phase: 3 * .pi / 8)
        XCTAssertEqual(viaShortPeriod.left, viaPhase.left, accuracy: 0.0001)
        XCTAssertEqual(viaLongPeriod.right, viaPhase.right, accuracy: 0.0001)
    }
}
