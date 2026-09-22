import XCTest
@testable import Quix8D

final class HRTFRendererTests: XCTestCase {
    private let frames = 2048

    private func energies(azimuth: Float32, gainDb: Float32 = 0) throws -> (left: Float, right: Float) {
        let renderer = try XCTUnwrap(HRTFRenderer(sampleRate: 48_000), "AUSpatialMixer should be available")
        var seed: UInt32 = 1
        var input = (0..<frames).map { _ -> Float32 in
            seed = seed &* 1_664_525 &+ 1_013_904_223
            return Float32(seed >> 8) / Float32(1 << 24) - 0.5
        }
        var outLeft = [Float32](repeating: 0, count: frames)
        var outRight = [Float32](repeating: 0, count: frames)
        for _ in 0..<4 {
            input.withUnsafeMutableBufferPointer { inPtr in
            outLeft.withUnsafeMutableBufferPointer { lPtr in
            outRight.withUnsafeMutableBufferPointer { rPtr in
                let source = (inPtr.baseAddress!, 1, frames)
                renderer.process(
                    azimuthDegrees: azimuth,
                    gainDb: gainDb,
                    left: (source: source, destination: (lPtr.baseAddress!, 1, frames)),
                    right: (source: source, destination: (rPtr.baseAddress!, 1, frames)))
            }}}
        }
        return (outLeft.reduce(0) { $0 + $1 * $1 }, outRight.reduce(0) { $0 + $1 * $1 })
    }

    func testProducesSound() throws {
        let e = try energies(azimuth: 0)
        XCTAssertGreaterThan(e.left + e.right, 1)
    }

    func testGainDbAttenuates() throws {
        let full = try energies(azimuth: 180)
        let quiet = try energies(azimuth: 180, gainDb: -7)
        let ratioDb = 10 * log10((quiet.left + quiet.right) / (full.left + full.right))
        XCTAssertEqual(ratioDb, -7, accuracy: 1)
    }

    func testPositiveAzimuthIsOnTheRight() throws {
        let e = try energies(azimuth: 90)
        XCTAssertGreaterThan(e.right, 2 * e.left)
    }

    func testNegativeAzimuthIsOnTheLeft() throws {
        let e = try energies(azimuth: -90)
        XCTAssertGreaterThan(e.left, 2 * e.right)
    }

    private func slotEnergies(azimuth: Float32, distance: Float32) throws -> (left: Float, right: Float) {
        let renderer = try XCTUnwrap(HRTFRenderer(sampleRate: 48_000))
        var seed: UInt32 = 7
        var input = (0..<frames).map { _ -> Float32 in
            seed = seed &* 1_664_525 &+ 1_013_904_223
            return Float32(seed >> 8) / Float32(1 << 24) - 0.5
        }
        var outLeft = [Float32](repeating: 0, count: frames)
        var outRight = [Float32](repeating: 0, count: frames)
        for _ in 0..<4 {
            input.withUnsafeMutableBufferPointer { inPtr in
            outLeft.withUnsafeMutableBufferPointer { lPtr in
            outRight.withUnsafeMutableBufferPointer { rPtr in
                let source = (inPtr.baseAddress!, 1, frames)
                var slot = HRTFRenderer.Slot(azimuth: azimuth, distance: distance, left: source, right: source)
                renderer.process(bed: nil, slots: &slot, slotCount: 1,
                                 into: ((lPtr.baseAddress!, 1, frames), (rPtr.baseAddress!, 1, frames)), adding: false)
            }}}
        }
        return (outLeft.reduce(0) { $0 + $1 * $1 }, outRight.reduce(0) { $0 + $1 * $1 })
    }

    func testPlacedSlotIsHeardFromItsSide() throws {
        let right = try slotEnergies(azimuth: 90, distance: 1.5)
        XCTAssertGreaterThan(right.right, 2 * right.left)
        let left = try slotEnergies(azimuth: 270, distance: 1.5)
        XCTAssertGreaterThan(left.left, 2 * left.right)
    }

    func testFartherSlotIsQuieter() throws {
        let near = try slotEnergies(azimuth: 0, distance: 1)
        let far = try slotEnergies(azimuth: 0, distance: 5)
        XCTAssertLessThan(far.left + far.right, 0.7 * (near.left + near.right))
    }

    func testBedAndSlotTogetherStayFiniteAndAdd() throws {
        let renderer = try XCTUnwrap(HRTFRenderer(sampleRate: 48_000))
        var input = (0..<frames).map { Float32(sin(Double($0) * 0.03)) * 0.3 }
        var outLeft = [Float32](repeating: 0.25, count: frames)
        var outRight = [Float32](repeating: 0.25, count: frames)
        input.withUnsafeMutableBufferPointer { inPtr in
        outLeft.withUnsafeMutableBufferPointer { lPtr in
        outRight.withUnsafeMutableBufferPointer { rPtr in
            let source = (inPtr.baseAddress!, 1, frames)
            var slot = HRTFRenderer.Slot(azimuth: 137, distance: 2, left: source, right: source)
            renderer.process(bed: (0, 0, source, source), slots: &slot, slotCount: 1,
                             into: ((lPtr.baseAddress!, 1, frames), (rPtr.baseAddress!, 1, frames)), adding: true)
        }}}
        XCTAssertTrue(outLeft.allSatisfy(\.isFinite) && outRight.allSatisfy(\.isFinite))
        XCTAssertNotEqual(outLeft[frames / 2], 0.25, "rendered audio was added on top")
    }
}
