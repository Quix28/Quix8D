import Foundation

enum PanLFO {
    /// Equal-power pan on a sine of `period` seconds, tapered at the extremes.
    static func gains(at time: Double, period: Double) -> (left: Float, right: Float) {
        gains(phase: 2 * Double.pi * time / period)
    }

    /// Phase in radians; accumulate it so a period change doesn't jump the pan.
    static func gains(phase: Double) -> (left: Float, right: Float) {
        let pan = sin(phase)                  // -1...1
        let theta = (pan + 1) * Double.pi / 4 // 0...pi/2
        let rawLeft = cos(theta)
        let rawRight = sin(theta)

        let maxDipLinear = 1 - pow(10, -3.0 / 20.0) // ~3 dB dip at |pan| == 1
        let taper = 1 - maxDipLinear * abs(pan)

        return (Float(rawLeft * taper), Float(rawRight * taper))
    }
}
