import XCTest
@testable import Quix8D

final class MenuBarStateTests: XCTestCase {
    func testUnsupportedOSDisablesRegardlessOfOtherState() {
        let state = startStopButtonState(isRunning: true, isStarting: true, osSupported: false)
        XCTAssertEqual(state.title, "Start")
        XCTAssertFalse(state.enabled)
    }

    func testStartingIsDisabled() {
        let state = startStopButtonState(isRunning: false, isStarting: true, osSupported: true)
        XCTAssertEqual(state.title, "Starting…")
        XCTAssertFalse(state.enabled)
    }

    func testIdleShowsStart() {
        let state = startStopButtonState(isRunning: false, isStarting: false, osSupported: true)
        XCTAssertEqual(state.title, "Start")
        XCTAssertTrue(state.enabled)
    }

    func testRunningShowsStop() {
        let state = startStopButtonState(isRunning: true, isStarting: false, osSupported: true)
        XCTAssertEqual(state.title, "Stop")
        XCTAssertTrue(state.enabled)
    }
}
