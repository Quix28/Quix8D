import XCTest
@testable import Quix8D

final class BinauralProcessorTests: XCTestCase {
    private let sampleRate = 48_000.0

    private func run(
        _ processor: BinauralProcessor, phase: Double,
        inputLeft: [Float32], inputRight: [Float32],
        ildGains: (left: Float, right: Float) = (1, 1)
    ) -> (left: [Float32], right: [Float32]) {
        var outLeft = [Float32](repeating: 0, count: inputLeft.count)
        var outRight = [Float32](repeating: 0, count: inputRight.count)
        var inL = inputLeft
        var inR = inputRight
        inL.withUnsafeMutableBufferPointer { inLPtr in
        inR.withUnsafeMutableBufferPointer { inRPtr in
        outLeft.withUnsafeMutableBufferPointer { outLPtr in
        outRight.withUnsafeMutableBufferPointer { outRPtr in
            processor.process(
                phase: phase,
                left: (source: (inLPtr.baseAddress!, 1, inLPtr.count), destination: (outLPtr.baseAddress!, 1, outLPtr.count)),
                right: (source: (inRPtr.baseAddress!, 1, inRPtr.count), destination: (outRPtr.baseAddress!, 1, outRPtr.count)),
                ildGains: ildGains
            )
        }}}}
        return (outLeft, outRight)
    }

    func testImpulseArrivesDelayedOnFarEar() {
        // pan = sin(pi/2) = 1: left is the far ear.
        let processor = BinauralProcessor(sampleRate: sampleRate)
        let maxDelay = sampleRate * BinauralEffect.maxITDMilliseconds / 1000 // ~33.6 samples
        var impulse = [Float32](repeating: 0, count: 200)
        impulse[0] = 1
        let (left, _) = run(processor, phase: .pi / 2, inputLeft: impulse, inputRight: impulse)

        // Exact position: energy comparisons would pass for any delay >= 3.
        let expectedIndex = Int(maxDelay.rounded())
        XCTAssertEqual(left[expectedIndex - 1], 0, accuracy: 1e-6, "nothing before the ITD")
        XCTAssertGreaterThan(left[expectedIndex], 0.4 * BinauralEffect.depthGain(depth: cos(.pi / 2)), "impulse arrives exactly at round(maxDelay)")
    }

    func testHeadShadowNearEarConvergesFasterThanFarEar() {
        // pan = 1: right is near, left far. Compare each ear n samples past its
        // own ITD so only filter speed matters.
        let processor = BinauralProcessor(sampleRate: sampleRate)
        let maxDelay = sampleRate * BinauralEffect.maxITDMilliseconds / 1000
        let itd = Int(maxDelay.rounded())
        let constantInput = [Float32](repeating: 1, count: 50)
        let (left, right) = run(processor, phase: .pi / 2, inputLeft: constantInput, inputRight: constantInput)

        let n = 2
        let sideGain = BinauralEffect.depthGain(depth: cos(.pi / 2))
        XCTAssertGreaterThan(right[n], left[itd + n], "near ear should converge toward the input faster than the far ear")
        XCTAssertGreaterThan(right[n], 0.99 * sideGain, "near ear (alpha ~0.927) is nearly converged after 3 samples")
        XCTAssertLessThan(left[itd + n], 0.85 * sideGain, "far ear (alpha ~0.408) is still well below the input after 3 samples")
    }

    func testNoDiscontinuityAcrossBufferBoundaries() {
        let a = BinauralProcessor(sampleRate: sampleRate)
        let b = BinauralProcessor(sampleRate: sampleRate)
        let fullInput = (0..<32).map { Float32($0) / 32 }

        let (oneCallLeft, oneCallRight) = run(a, phase: 1.0, inputLeft: fullInput, inputRight: fullInput)

        let firstHalf = Array(fullInput[0..<16])
        let secondHalf = Array(fullInput[16..<32])
        let (firstLeft, firstRight) = run(b, phase: 1.0, inputLeft: firstHalf, inputRight: firstHalf)
        let (secondLeft, secondRight) = run(b, phase: 1.0, inputLeft: secondHalf, inputRight: secondHalf)
        let splitLeft = firstLeft + secondLeft
        let splitRight = firstRight + secondRight

        for i in 0..<32 {
            XCTAssertEqual(oneCallLeft[i], splitLeft[i], accuracy: 0.0001, "sample \(i) left")
            XCTAssertEqual(oneCallRight[i], splitRight[i], accuracy: 0.0001, "sample \(i) right")
        }
    }

    func testCenterPanIsNearNoOp() {
        // phase = 0 -> pan = 0, depth = 1: no ITD, cutoffs fully open, no dip.
        let processor = BinauralProcessor(sampleRate: sampleRate)
        let input = [Float32](repeating: 0.5, count: 50)
        let (left, right) = run(processor, phase: 0, inputLeft: input, inputRight: input, ildGains: (1, 1))

        // Filters still smooth the input, so check convergence, not equality.
        XCTAssertEqual(left[49], 0.5, accuracy: 0.01)
        XCTAssertEqual(right[49], 0.5, accuracy: 0.01)
    }
}
