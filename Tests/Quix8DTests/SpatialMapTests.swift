import XCTest
@testable import Quix8D

final class SpatialMapTests: XCTestCase {
    private let radius: CGFloat = 100

    func testCompassDirectionsLandWhereExpected() {
        let front = SpatialMap.point(for: AppPosition(azimuth: 0, distance: 5), radius: radius)
        XCTAssertEqual(front.x, 0, accuracy: 1e-6)
        XCTAssertEqual(front.y, -100, accuracy: 1e-6, "front is up")

        let right = SpatialMap.point(for: AppPosition(azimuth: 90, distance: 5), radius: radius)
        XCTAssertEqual(right.x, 100, accuracy: 1e-6)

        let left = SpatialMap.point(for: AppPosition(azimuth: 270, distance: 5), radius: radius)
        XCTAssertEqual(left.x, -100, accuracy: 1e-6)

        let behindRight = SpatialMap.point(for: AppPosition(azimuth: 137, distance: 5), radius: radius)
        XCTAssertGreaterThan(behindRight.x, 0)
        XCTAssertGreaterThan(behindRight.y, 0, "137 degrees is behind-right: lower right on the map")
    }

    func testPointAndPositionRoundTrip() {
        for azimuth in stride(from: 0.0, to: 360, by: 37) {
            for distance in [0.5, 1.5, 3, 5] {
                let original = AppPosition(azimuth: azimuth, distance: distance)
                let point = SpatialMap.point(for: original, radius: radius, innerRadius: 20)
                let back = SpatialMap.position(at: point, radius: radius, innerRadius: 20)
                XCTAssertEqual(back.azimuth, original.azimuth, accuracy: 1e-6)
                XCTAssertEqual(back.distance, original.distance, accuracy: 1e-6)
            }
        }
    }

    func testDistanceGrowsOutwardAndAnglesWrap() {
        XCTAssertLessThan(SpatialMap.radiusFraction(ofDistance: 1), SpatialMap.radiusFraction(ofDistance: 2))
        XCTAssertEqual(SpatialMap.radiusFraction(ofDistance: 0.5), 0, accuracy: 1e-9)
        XCTAssertEqual(SpatialMap.radiusFraction(ofDistance: 5), 1, accuracy: 1e-9)
        XCTAssertEqual(AppPosition(azimuth: -90).azimuth, 270)
        XCTAssertEqual(AppPosition(azimuth: 497).azimuth, 137)
    }

    func testPositionsPersist() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "SpatialMapTests-\(UUID().uuidString)"))
        let positions = ["/Applications/Spotify.app": AppPosition(azimuth: 137, distance: 2)]
        SpatialMap.save(positions, to: defaults)
        XCTAssertEqual(SpatialMap.load(from: defaults), positions)
    }
}
