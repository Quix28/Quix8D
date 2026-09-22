import CoreAudio
import XCTest
@testable import Quix8D

/// Real-time cost of the render path, as % of one core. Opt-in:
/// `BENCH=1 swift test -c release -Xswiftc -enable-testing --filter PipelineBenchmark`
final class PipelineBenchmark: XCTestCase {
    private let sampleRate = 48_000.0
    private let frames = 512
    private let seconds = 10.0

    private struct Scenario {
        let name: String
        let taps: Int
        let configure: (AudioPipeline, [String]) -> Void
    }

    func testRealtimeCost() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["BENCH"] == "1", "set BENCH=1")
        var everything = EffectsSettings()
        everything.reverb.isOn = true
        everything.delay.isOn = true
        everything.compressor.isOn = true
        everything.widener.isOn = true
        everything.bassEnhancer.isOn = true
        everything.chorus.isOn = true
        var eq = EQSettings()
        for index in eq.bands.indices { eq.bands[index].gainDb = index.isMultiple(of: 2) ? 3 : -3 }
        eq.highPass.isOn = true
        eq.lowPass.isOn = true

        let placed: (AudioPipeline, [String], Int) -> Void = { p, ids, count in
            p.setAppPositions(Dictionary(uniqueKeysWithValues: ids.prefix(count).enumerated().map {
                ($1, AppPosition(azimuth: Double($0) * 22.5, distance: 2)) }), enabled: true)
        }
        let breakdown = [
            Scenario(name: "8D + EQ only", taps: 8) { p, _ in p.setEQ(eq, enabled: true) },
            Scenario(name: "8D + 6x boost only", taps: 8) { p, _ in p.boost = 6 },
            Scenario(name: "8D + pan only", taps: 8) { p, _ in p.pan = 0.3 },
            Scenario(name: "8D + RTA feed only", taps: 8) { p, _ in p.isAnalyzerOn = true },
            Scenario(name: "8D + faders only", taps: 8) { p, ids in
                p.setAppVolumes(Dictionary(uniqueKeysWithValues: ids.map { ($0, Float(0.7)) })) },
            Scenario(name: "8D + 1 placed", taps: 8) { p, ids in placed(p, ids, 1) },
            Scenario(name: "8D + 16 placed of 16", taps: 16) { p, ids in placed(p, ids, 16) },
        ] + ["reverb", "delay", "compressor", "widener", "bass", "chorus"].map { name in
            Scenario(name: "8D + \(name) only", taps: 8) { p, _ in
                var one = EffectsSettings()
                switch name {
                case "reverb": one.reverb.isOn = true
                case "delay": one.delay.isOn = true
                case "compressor": one.compressor.isOn = true
                case "widener": one.widener.isOn = true
                case "bass": one.bassEnhancer.isOn = true
                default: one.chorus.isOn = true
                }
                p.setEffects(one, enabled: true)
            }
        }
        let scenarios = [
            Scenario(name: "passthrough, 1 app", taps: 1) { p, _ in p.isBypassed = true },
            Scenario(name: "8D (HRTF bed), 1 app", taps: 1) { _, _ in },
            Scenario(name: "8D, 8 apps", taps: 8) { _, _ in },
            Scenario(name: "8D + 6 placed of 8 apps", taps: 8) { p, ids in
                p.setAppPositions(Dictionary(uniqueKeysWithValues: ids.prefix(6).enumerated().map {
                    ($1, AppPosition(azimuth: Double($0) * 60, distance: 2)) }), enabled: true)
            },
            Scenario(name: "  + all 6 effects", taps: 8) { p, ids in
                p.setAppPositions(Dictionary(uniqueKeysWithValues: ids.prefix(6).enumerated().map {
                    ($1, AppPosition(azimuth: Double($0) * 60, distance: 2)) }), enabled: true)
                p.setEffects(everything, enabled: true)
            },
            Scenario(name: "  + EQ, pan, 6x, RTA, faders (full)", taps: 8) { p, ids in
                p.setAppPositions(Dictionary(uniqueKeysWithValues: ids.prefix(6).enumerated().map {
                    ($1, AppPosition(azimuth: Double($0) * 60, distance: 2)) }), enabled: true)
                p.setEffects(everything, enabled: true)
                p.setEQ(eq, enabled: true)
                p.pan = 0.3
                p.boost = 6
                p.isAnalyzerOn = true
                p.setAppVolumes(Dictionary(uniqueKeysWithValues: ids.map { ($0, Float(0.7)) }))
            },
        ] + (ProcessInfo.processInfo.environment["BREAKDOWN"] == "1" ? breakdown : [])

        var report = "\nREALTIME COST (% of one core, 48 kHz, 512-frame callbacks)\n"
        for scenario in scenarios {
            let percent = run(scenario)
            report += "  " + scenario.name.padding(toLength: 40, withPad: " ", startingAt: 0) + String(format: "%6.2f%%\n", percent)
        }
        print(report)
    }

    private func run(_ scenario: Scenario) -> Double {
        let pipeline = AudioPipeline()
        let ids = (0..<scenario.taps).map { "/Applications/Bench \($0).app" }
        pipeline.speed = 0.25
        scenario.configure(pipeline, ids)
        pipeline.prepare(sampleRate: sampleRate, tapAppIDs: ids)

        let input = AudioBufferList.allocate(maximumBuffers: 2 * scenario.taps)
        let output = AudioBufferList.allocate(maximumBuffers: 2)
        var storage: [UnsafeMutablePointer<Float32>] = []
        defer {
            storage.forEach { $0.deallocate() }
            free(input.unsafeMutablePointer)
            free(output.unsafeMutablePointer)
        }
        func attach(_ list: UnsafeMutableAudioBufferListPointer, _ index: Int, noise: Bool) {
            let buffer = UnsafeMutablePointer<Float32>.allocate(capacity: frames)
            var seed = UInt32(index + 1)
            for frame in 0..<frames {
                seed = seed &* 1_664_525 &+ 1_013_904_223
                buffer[frame] = noise ? Float32(seed >> 8) / Float32(1 << 24) - 0.5 : 0
            }
            storage.append(buffer)
            list[index] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(frames * 4), mData: buffer)
        }
        for index in 0..<2 * scenario.taps { attach(input, index, noise: true) }
        for index in 0..<2 { attach(output, index, noise: false) }

        let callbacks = Int(seconds * sampleRate) / frames
        for _ in 0..<20 { pipeline.render(input: input.unsafePointer, output: output.unsafeMutablePointer) }
        let start = clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)
        for _ in 0..<callbacks {
            pipeline.render(input: input.unsafePointer, output: output.unsafeMutablePointer)
        }
        let cpuSeconds = Double(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) - start) / 1e9
        return 100 * cpuSeconds / (Double(callbacks * frames) / sampleRate)
    }
}
