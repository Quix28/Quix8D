import CoreAudio
import XCTest
@testable import Quix8D

final class MenuBarStateTests: XCTestCase {
    func testUnsupportedOSDisablesRegardlessOfOtherState() {
        let state = startStopButtonState(isRunning: true, isStarting: true, osSupported: false)
        XCTAssertEqual(state.title, "Start")
        XCTAssertFalse(state.enabled)
    }

    func testStartingIsDisabled() {
        let state = startStopButtonState(isRunning: false, isStarting: true, osSupported: true)
        XCTAssertEqual(state.title, "Starting…")
        XCTAssertFalse(state.enabled)
    }

    func testIdleShowsStart() {
        let state = startStopButtonState(isRunning: false, isStarting: false, osSupported: true)
        XCTAssertEqual(state.title, "Start")
        XCTAssertTrue(state.enabled)
    }

    func testRunningShowsStop() {
        let state = startStopButtonState(isRunning: true, isStarting: false, osSupported: true)
        XCTAssertEqual(state.title, "Stop")
        XCTAssertTrue(state.enabled)
    }
}

/// Counts lifecycle calls; "starting" only prepares for offline rendering.
final class CountingPipeline: AudioPipeline {
    var starts = 0, stops = 0, restarts = 0
    override func start(speed: Double) throws {
        starts += 1
        prepare(sampleRate: 48_000, tapAppIDs: ["tone"])
    }
    override func stop() { stops += 1 }
    override func restart() throws { restarts += 1 }
}

extension MenuBarController {
    func startAndWait() {
        start()
        let deadline = Date() + 5
        while !isRunning, Date() < deadline { RunLoop.main.run(until: Date() + 0.01) }
    }
}

final class AlwaysOnCaptureTests: XCTestCase {
    private let frames = 480 // 10 cycles of 1 kHz at 48 kHz

    /// Output RMS per side in dBFS once filters settle; the one tap plays 1 kHz on its left channel only.
    private func levels(_ pipeline: AudioPipeline) -> (left: Double, right: Double) {
        let input = AudioBufferList.allocate(maximumBuffers: 2)
        let output = AudioBufferList.allocate(maximumBuffers: 2)
        let buffers = (0..<4).map { _ in UnsafeMutablePointer<Float32>.allocate(capacity: frames) }
        defer {
            buffers.forEach { $0.deallocate() }
            free(input.unsafeMutablePointer)
            free(output.unsafeMutablePointer)
        }
        for frame in 0..<frames {
            buffers[0][frame] = 0.25 * Float32(sin(2 * Double.pi * 1_000 * Double(frame) / 48_000))
        }
        for index in 1..<4 { buffers[index].initialize(repeating: 0, count: frames) }
        for index in 0..<2 {
            input[index] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(frames * 4), mData: buffers[index])
            output[index] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(frames * 4), mData: buffers[2 + index])
        }
        for _ in 0..<50 { pipeline.render(input: input.unsafePointer, output: output.unsafeMutablePointer) }
        func level(_ buffer: UnsafeMutablePointer<Float32>) -> Double {
            10 * log10((0..<frames).map { Double(buffer[$0] * buffer[$0]) }.reduce(0, +) / Double(frames) + 1e-20)
        }
        return (level(buffers[2]), level(buffers[3]))
    }

    func testFeatureSwitchesChangeRenderingWithoutStoppingCapture() {
        let pipeline = CountingPipeline()
        let controller = MenuBarController(pipeline: pipeline)
        let app = AudioApp(id: "tone")
        controller.startAndWait()
        XCTAssertTrue(controller.isRunning)

        let dry = levels(pipeline)
        XCTAssertEqual(dry.left, -15, accuracy: 0.5)
        XCTAssertLessThan(dry.right, -100)

        controller.is8DOn = true
        XCTAssertGreaterThan(levels(pipeline).right, -60, "8D moves sound to the right ear")
        controller.effectsOn = false
        XCTAssertLessThan(levels(pipeline).right, -100, "Effects off bypasses 8D")
        controller.effectsOn = true
        controller.is8DOn = false
        XCTAssertLessThan(levels(pipeline).right, -100)

        controller.isBoosted = true
        XCTAssertGreaterThan(levels(pipeline).left, dry.left + 5)
        controller.isBoosted = false

        controller.pan = 1
        XCTAssertLessThan(levels(pipeline).left, -100)
        controller.pan = 0

        controller.setVolume(0.5, for: app)
        XCTAssertEqual(levels(pipeline).left - dry.left, -6, accuracy: 0.5)
        controller.setVolume(1, for: app)

        var cut = EQSettings()
        cut.bands[0].frequency = 1_000
        cut.bands[0].gainDb = -12
        cut.bands[0].q = 1
        controller.eq = cut
        XCTAssertEqual(levels(pipeline).left - dry.left, -12, accuracy: 0.5)
        controller.isEQOn = false
        XCTAssertEqual(levels(pipeline).left, dry.left, accuracy: 0.1)
        controller.isEQOn = true
        controller.eq = EQSettings()

        controller.effects.widener.isOn = true
        controller.effects.widener.width = 0
        XCTAssertGreaterThan(levels(pipeline).right, -30, "Mono widener copies left into right")
        controller.effects = EffectsSettings()

        controller.setPosition(AppPosition(azimuth: 90), for: app, commit: false)
        XCTAssertGreaterThan(levels(pipeline).right, -60, "Placed app plays from the right")
        controller.setPosition(nil, for: app, commit: false)
        XCTAssertLessThan(levels(pipeline).right, -100)

        controller.isAnalyzerOn = true
        controller.isAnalyzerOn = false

        XCTAssertEqual(levels(pipeline).left, dry.left, accuracy: 0.1)
        XCTAssertEqual(pipeline.starts, 1)
        XCTAssertEqual(pipeline.stops, 0)
        XCTAssertEqual(pipeline.restarts, 0)
    }
}
