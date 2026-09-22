import CoreGraphics
import Foundation

/// Where an app sits around the listener. Azimuth: 0 = front, degrees
/// clockwise (90 = right, 180 = behind, 270 = left). Distance in metres.
struct AppPosition: Codable, Equatable {
    var azimuth: Double
    var distance: Double

    static let distanceRange = 0.5...5.0
    static let defaultDistance = 1.5

    init(azimuth: Double, distance: Double = AppPosition.defaultDistance) {
        self.azimuth = SpatialMap.normalized(azimuth: azimuth)
        self.distance = min(max(distance, Self.distanceRange.lowerBound), Self.distanceRange.upperBound)
    }
}

enum SpatialMap {
    static let storeKey = "appPositions"

    static func normalized(azimuth: Double) -> Double {
        let wrapped = azimuth.truncatingRemainder(dividingBy: 360)
        return wrapped < 0 ? wrapped + 360 : wrapped
    }

    /// Logarithmic, so the space near the head gets more room.
    static func radiusFraction(ofDistance distance: Double) -> Double {
        let range = AppPosition.distanceRange
        let clamped = min(max(distance, range.lowerBound), range.upperBound)
        return log(clamped / range.lowerBound) / log(range.upperBound / range.lowerBound)
    }

    static func distance(atRadiusFraction fraction: Double) -> Double {
        let range = AppPosition.distanceRange
        return range.lowerBound * pow(range.upperBound / range.lowerBound, min(max(fraction, 0), 1))
    }

    /// y grows downward; `innerRadius` keeps tokens off the head.
    static func point(for position: AppPosition, radius: CGFloat, innerRadius: CGFloat = 0) -> CGPoint {
        let r = innerRadius + (radius - innerRadius) * CGFloat(radiusFraction(ofDistance: position.distance))
        let angle = position.azimuth * .pi / 180
        return CGPoint(x: r * CGFloat(sin(angle)), y: -r * CGFloat(cos(angle)))
    }

    static func position(at offset: CGPoint, radius: CGFloat, innerRadius: CGFloat = 0) -> AppPosition {
        let r = (offset.x * offset.x + offset.y * offset.y).squareRoot()
        let azimuth = atan2(Double(offset.x), Double(-offset.y)) * 180 / .pi
        let fraction = Double((r - innerRadius) / max(radius - innerRadius, 1))
        return AppPosition(azimuth: azimuth, distance: distance(atRadiusFraction: fraction))
    }

    static func load(from defaults: UserDefaults = .standard) -> [String: AppPosition] {
        guard let data = defaults.data(forKey: storeKey) else { return [:] }
        return (try? JSONDecoder().decode([String: AppPosition].self, from: data)) ?? [:]
    }

    static func save(_ positions: [String: AppPosition], to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(positions) {
            defaults.set(data, forKey: storeKey)
        }
    }
}
