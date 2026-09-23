import Foundation

/// Stereo-linked look-ahead peak limiter. Output never exceeds `ceiling`, and
/// signals already below it pass through unchanged, only delayed by `lookahead`.
/// Real-time safe: all memory is allocated at init.
final class Limiter {
    typealias Buffer = BinauralProcessor.Buffer

    static let ceiling: Float = 0.944 // -0.5 dBFS
    private static let lookaheadSeconds = 0.005
    private static let releaseSeconds = 0.15

    let lookahead: Int
    private let releaseCoefficient: Float

    private let delayLeft: UnsafeMutablePointer<Float>
    private let delayRight: UnsafeMutablePointer<Float>
    private let averageWindow: UnsafeMutablePointer<Float>
    private var writeIndex = 0
    private var windowSum: Double

    // Monotonic deque of (required gain, sample index) for the running minimum
    // over the last lookahead + 1 samples.
    private let minimumCapacity: Int
    private let minimumGains: UnsafeMutablePointer<Float>
    private let minimumIndices: UnsafeMutablePointer<Int>
    private var minimumHead = 0
    private var minimumCount = 0
    private var sampleIndex = 0

    private var gain: Float = 1

    init(sampleRate: Double) {
        lookahead = max(1, Int(sampleRate * Self.lookaheadSeconds))
        releaseCoefficient = Float(1 - exp(-1 / (sampleRate * Self.releaseSeconds)))
        delayLeft = .allocate(capacity: lookahead)
        delayRight = .allocate(capacity: lookahead)
        averageWindow = .allocate(capacity: lookahead)
        delayLeft.initialize(repeating: 0, count: lookahead)
        delayRight.initialize(repeating: 0, count: lookahead)
        averageWindow.initialize(repeating: 1, count: lookahead)
        windowSum = Double(lookahead)
        minimumCapacity = lookahead + 1
        minimumGains = .allocate(capacity: minimumCapacity)
        minimumIndices = .allocate(capacity: minimumCapacity)
    }

    deinit {
        [delayLeft, delayRight, averageWindow, minimumGains].forEach { $0.deallocate() }
        minimumIndices.deallocate()
    }

    /// Applies `inputGain`, then limits both channels in place.
    // The gain applied to a delayed sample is an average of window minimums that
    // all include that sample's own requirement, so it can't overshoot.
    func process(left: Buffer, right: Buffer, inputGain: Float) {
        for frame in 0..<min(left.frames, right.frames) {
            let leftIndex = frame * left.stride
            let rightIndex = frame * right.stride
            let leftIn = left.samples[leftIndex] * inputGain
            let rightIn = right.samples[rightIndex] * inputGain

            let peak = max(abs(leftIn), abs(rightIn))
            let required = peak > Self.ceiling ? Self.ceiling / peak : 1
            let held = pushMinimum(required)

            windowSum += Double(held - averageWindow[writeIndex])
            averageWindow[writeIndex] = held
            let target = min(1, Float(windowSum / Double(lookahead)))
            gain = target < gain ? target : gain + (target - gain) * releaseCoefficient

            left.samples[leftIndex] = delayLeft[writeIndex] * gain
            right.samples[rightIndex] = delayRight[writeIndex] * gain
            delayLeft[writeIndex] = leftIn
            delayRight[writeIndex] = rightIn
            writeIndex = writeIndex + 1 == lookahead ? 0 : writeIndex + 1
        }
    }

    private func pushMinimum(_ value: Float) -> Float {
        if minimumCount > 0, minimumIndices[minimumHead] < sampleIndex - lookahead {
            minimumHead = slot(1)
            minimumCount -= 1
        }
        while minimumCount > 0, minimumGains[slot(minimumCount - 1)] >= value {
            minimumCount -= 1
        }
        minimumGains[slot(minimumCount)] = value
        minimumIndices[slot(minimumCount)] = sampleIndex
        minimumCount += 1
        sampleIndex += 1
        return minimumGains[minimumHead]
    }

    private func slot(_ offset: Int) -> Int {
        (minimumHead + offset) % minimumCapacity
    }
}
