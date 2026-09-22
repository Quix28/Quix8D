import XCTest
@testable import Quix8D

final class EffectsTests: XCTestCase {
    private let sampleRate = 48_000.0

    private func run(_ settings: EffectsSettings, left: [Float], right: [Float]) -> (left: [Float], right: [Float]) {
        let processor = EffectsProcessor(sampleRate: sampleRate)
        var l = left
        var r = right
        l.withUnsafeMutableBufferPointer { lp in
            r.withUnsafeMutableBufferPointer { rp in
                var offset = 0
                while offset < lp.count {
                    let count = min(512, lp.count - offset)
                    processor.process(left: (lp.baseAddress! + offset, 1, count), right: (rp.baseAddress! + offset, 1, count), settings: settings)
                    offset += count
                }
            }
        }
        return (l, r)
    }

    func testDelayEchoesAtTheSetTime() {
        var settings = EffectsSettings()
        settings.delay = .init(isOn: true, time: 0.1, feedback: 0, mix: 1)
        var impulse = [Float](repeating: 0, count: 12_000)
        impulse[0] = 1
        let out = run(settings, left: impulse, right: impulse).left
        let echo = out.indices.dropFirst(10).max { abs(out[$0]) < abs(out[$1]) }!
        XCTAssertEqual(echo, 4_800, "100 ms at 48 kHz")
        XCTAssertEqual(out[echo], 1, accuracy: 0.01)
    }

    func testReverbTailDecaysEvenAtMaxSize() {
        var settings = EffectsSettings()
        settings.reverb = .init(isOn: true, mix: 1, size: 1, damping: 0)
        var impulse = [Float](repeating: 0, count: 48_000 * 6)
        impulse[0] = 1
        let out = run(settings, left: impulse, right: impulse).left
        func energy(_ range: Range<Int>) -> Float { out[range].reduce(0) { $0 + $1 * $1 } }
        let early = energy(4_800..<48_000)
        let late = energy(48_000 * 5..<48_000 * 6)
        XCTAssertGreaterThan(early, 0, "there is a tail")
        XCTAssertLessThan(late, early / 10, "and it dies away")
        XCTAssertTrue(out.allSatisfy(\.isFinite))
    }

    func testWidenerUnityIsTransparentAndZeroIsMono() {
        var settings = EffectsSettings()
        settings.widener = .init(isOn: true, width: 1)
        let same = run(settings, left: [0.5, -0.2], right: [0.1, 0.3])
        XCTAssertEqual(same.left[0], 0.5, accuracy: 1e-6)
        XCTAssertEqual(same.right[1], 0.3, accuracy: 1e-6)

        settings.widener.width = 0
        let mono = run(settings, left: [0.5], right: [0.1])
        XCTAssertEqual(mono.left[0], mono.right[0], accuracy: 1e-6)
        XCTAssertEqual(mono.left[0], 0.3, accuracy: 1e-6)
    }

    func testCompressorGainComputer() {
        XCTAssertEqual(EffectsProcessor.compressorGainDb(levelDb: -30, threshold: -20, ratio: 4), 0)
        XCTAssertEqual(EffectsProcessor.compressorGainDb(levelDb: -8, threshold: -20, ratio: 4), -9, accuracy: 1e-5,
                       "12 dB over at 4:1 comes out 3 dB over")
    }

    func testEveryEffectOnStaysFiniteOnLoudInput() {
        var settings = EffectsSettings()
        settings.reverb.isOn = true
        settings.delay = .init(isOn: true, time: 0.05, feedback: 0.9, mix: 1)
        settings.compressor.isOn = true
        settings.widener.isOn = true
        settings.bassEnhancer.isOn = true
        settings.chorus.isOn = true
        let loud = (0..<48_000).map { Float(sin(Double($0) * 0.05)) }
        let out = run(settings, left: loud, right: loud)
        XCTAssertTrue(out.left.allSatisfy(\.isFinite) && out.right.allSatisfy(\.isFinite))
    }
}
