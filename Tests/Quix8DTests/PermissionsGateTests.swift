import XCTest
@testable import Quix8D

final class PermissionsGateTests: XCTestCase {
    func testSupportsExactMinimumVersion() {
        let v = OperatingSystemVersion(majorVersion: 14, minorVersion: 4, patchVersion: 0)
        XCTAssertTrue(PermissionsGate.isOSVersionSupported(v))
    }

    func testSupportsNewerMajorVersion() {
        let v = OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0)
        XCTAssertTrue(PermissionsGate.isOSVersionSupported(v))
    }

    func testRejectsOlderMinorVersion() {
        let v = OperatingSystemVersion(majorVersion: 14, minorVersion: 3, patchVersion: 0)
        XCTAssertFalse(PermissionsGate.isOSVersionSupported(v))
    }

    func testRejectsOlderMajorVersion() {
        let v = OperatingSystemVersion(majorVersion: 13, minorVersion: 9, patchVersion: 0)
        XCTAssertFalse(PermissionsGate.isOSVersionSupported(v))
    }
}
