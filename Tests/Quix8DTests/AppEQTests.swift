import CoreAudio
import XCTest
@testable import Quix8D

final class AppEQTests: XCTestCase {
    private let frames = 480 // 10 cycles of 1 kHz at 48 kHz, so the buffer loops seamlessly

    private var cut: EQSettings {
        var eq = EQSettings()
        eq.bands[0].frequency = 1_000
        eq.bands[0].gainDb = -12
        eq.bands[0].q = 1
        return eq
    }

    /// RMS of the output in dBFS once filters settle; tap 0 plays a 1 kHz tone, tap 1 is silent.
    private func outputLevel(configure: (AudioPipeline) -> Void) -> Double {
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
        for index in 0..<4 { attach(input, index, tone: index < 2) }
        for index in 0..<2 { attach(output, index, tone: false) }

        for _ in 0..<50 { pipeline.render(input: input.unsafePointer, output: output.unsafeMutablePointer) }
        let left = storage[4]
        let meanSquare = (0..<frames).map { Double(left[$0] * left[$0]) }.reduce(0, +) / Double(frames)
        return 10 * log10(meanSquare)
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
