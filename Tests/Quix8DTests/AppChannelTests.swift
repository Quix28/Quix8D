import CoreAudio
import XCTest
@testable import Quix8D

final class AppChannelTests: XCTestCase {
    private let frames = 480 // 10 cycles of 1 kHz at 48 kHz, so the buffer loops seamlessly

    private var cut: EQSettings {
        var eq = EQSettings()
        eq.bands[0].frequency = 1_000
        eq.bands[0].gainDb = -12
        eq.bands[0].q = 1
        return eq
    }

    private func outputLevel(configure: (AudioPipeline) -> Void) -> Double {
        outputLevels(configure: configure).left
    }

    /// Output RMS per side in dBFS once filters settle. Tap 0 ("tone") plays a
    /// 1 kHz tone, on its left channel only if `leftOnly`; tap 1 ("silent") is silent.
    private func outputLevels(leftOnly: Bool = false, configure: (AudioPipeline) -> Void) -> (left: Double, right: Double) {
        let pipeline = AudioPipeline()
        pipeline.isBypassed = true
        configure(pipeline)
        pipeline.prepare(sampleRate: 48_000, tapAppIDs: ["tone", "silent"])

        let input = AudioBufferList.allocate(maximumBuffers: 4)
        let output = AudioBufferList.allocate(maximumBuffers: 2)
        var storage: [UnsafeMutablePointer<Float32>] = []
        defer {
            storage.forEach { $0.deallocate() }
            free(input.unsafeMutablePointer)
            free(output.unsafeMutablePointer)
        }
        func attach(_ list: UnsafeMutableAudioBufferListPointer, _ index: Int, tone: Bool) {
            let buffer = UnsafeMutablePointer<Float32>.allocate(capacity: frames)
            for frame in 0..<frames {
                buffer[frame] = tone ? 0.25 * Float32(sin(2 * Double.pi * 1_000 * Double(frame) / 48_000)) : 0
            }
            storage.append(buffer)
            list[index] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(frames * 4), mData: buffer)
        }
        for index in 0..<4 { attach(input, index, tone: leftOnly ? index == 0 : index < 2) }
        for index in 0..<2 { attach(output, index, tone: false) }

        for _ in 0..<50 { pipeline.render(input: input.unsafePointer, output: output.unsafeMutablePointer) }
        func level(_ buffer: UnsafeMutablePointer<Float32>) -> Double {
            10 * log10((0..<frames).map { Double(buffer[$0] * buffer[$0]) }.reduce(0, +) / Double(frames) + 1e-20)
        }
        return (level(storage[4]), level(storage[5]))
    }

    private var mono: EffectsSettings {
        var effects = EffectsSettings()
        effects.widener.isOn = true
        effects.widener.width = 0
        return effects
    }

    func testAppEffectsProcessOnlyTheirOwnApp() {
        let dry = outputLevels(leftOnly: true) { _ in }
        let toneMono = outputLevels(leftOnly: true) { $0.setAppEffects(["tone": self.mono]) }
        let otherMono = outputLevels(leftOnly: true) { $0.setAppEffects(["silent": self.mono]) }
        XCTAssertLessThan(dry.right, -100)
        XCTAssertGreaterThan(toneMono.right, -30)
        XCTAssertEqual(toneMono.left, toneMono.right, accuracy: 0.1)
        XCTAssertLessThan(otherMono.right, -100)
    }

    func testEffectsSwitchBypassesAppEffects() {
        let bypassed = outputLevels(leftOnly: true) { pipeline in
            pipeline.setAppEffects(["tone": self.mono])
            pipeline.setEffects(EffectsSettings(), enabled: false)
        }
        XCTAssertLessThan(bypassed.right, -100)
    }

    func testAppEQShapesOnlyItsOwnApp() {
        let dry = outputLevel { _ in }
        let toneCut = outputLevel { $0.setAppEQs(["tone": self.cut]) }
        let otherCut = outputLevel { $0.setAppEQs(["silent": self.cut]) }
        XCTAssertEqual(toneCut - dry, -12, accuracy: 0.5)
        XCTAssertEqual(otherCut, dry, accuracy: 0.01)
    }

    func testEQSwitchBypassesAppEQs() {
        let dry = outputLevel { _ in }
        let bypassed = outputLevel { pipeline in
            pipeline.setAppEQs(["tone": self.cut])
            pipeline.setEQ(EQSettings(), enabled: false)
        }
        XCTAssertEqual(bypassed, dry, accuracy: 0.01)
    }
}
