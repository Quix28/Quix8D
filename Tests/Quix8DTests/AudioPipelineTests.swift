import XCTest
import Darwin
@testable import Quix8D

final class AudioPipelineTests: XCTestCase {
    /// Guards the os_unfair_lock around speed/isBypassed.
    func testConcurrentReadWriteDoesNotCrash() {
        let pipeline = AudioPipeline()
        let stop = ManagedAtomicBool(false)
        let group = DispatchGroup()

        for _ in 0..<4 {
            group.enter()
            DispatchQueue.global().async {
                var speed = 0.5
                while !stop.value {
                    pipeline.speed = speed
                    pipeline.isBypassed.toggle()
                    speed = speed == 0.5 ? -0.5 : 0.5
                }
                group.leave()
            }
        }
        for _ in 0..<4 {
            group.enter()
            DispatchQueue.global().async {
                while !stop.value {
                    _ = pipeline.speed
                    _ = pipeline.isBypassed
                }
                group.leave()
            }
        }

        Thread.sleep(forTimeInterval: 0.15)
        stop.value = true
        XCTAssertEqual(group.wait(timeout: .now() + 2), .success)
    }
}

/// Avoids pulling in swift-atomics for one flag.
private final class ManagedAtomicBool {
    private var lock = os_unfair_lock()
    private var raw: Bool
    init(_ value: Bool) { raw = value }
    var value: Bool {
        get { os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }; return raw }
        set { os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }; raw = newValue }
    }
}

final class OutputGainTests: XCTestCase {
    func testBalanceLeavesCentreAloneAndFadesTheOtherSide() {
        XCTAssertTrue(AudioPipeline.balanceGains(pan: 0) == (1, 1))
        XCTAssertTrue(AudioPipeline.balanceGains(pan: -1) == (1, 0))
        XCTAssertTrue(AudioPipeline.balanceGains(pan: 0.5) == (0.5, 1))
    }
}

final class SpareTapTests: XCTestCase {
    /// Apps without settings stay in the spare tap; others get rebuilt into their own.
    func testOnlyAppsWithSettingsNeedTheirOwnTap() {
        let pipeline = AudioPipeline()
        XCTAssertFalse(pipeline.hasAppSettings("app"))

        pipeline.setAppVolumes(["app": 1])
        XCTAssertFalse(pipeline.hasAppSettings("app"), "a fader at 0 dB")
        pipeline.setAppVolumes(["app": 0.5])
        XCTAssertTrue(pipeline.hasAppSettings("app"))
        XCTAssertFalse(pipeline.hasAppSettings("other"))
        pipeline.setAppVolumes([:])

        var cut = EQSettings()
        cut.bands[0].gainDb = -6
        pipeline.setAppEQs(["app": EQSettings()])
        XCTAssertFalse(pipeline.hasAppSettings("app"), "a flat EQ")
        pipeline.setAppEQs(["app": cut])
        XCTAssertTrue(pipeline.hasAppSettings("app"))
        pipeline.setAppEQs([:])

        var effects = EffectsSettings()
        effects.reverb.mix = 0.9
        pipeline.setAppEffects(["app": effects])
        XCTAssertFalse(pipeline.hasAppSettings("app"), "effects all switched off")
        effects.reverb.isOn = true
        pipeline.setAppEffects(["app": effects])
        XCTAssertTrue(pipeline.hasAppSettings("app"))
        pipeline.setAppEffects([:])

        pipeline.setAppPositions(["app": AppPosition(azimuth: 90)], enabled: true)
        XCTAssertTrue(pipeline.hasAppSettings("app"))
    }

    /// The spare tap needs this process's object to exclude it; without one it isn't built.
    func testFindsOwnProcessObject() {
        XCTAssertNotNil(ProcessTapCapture.processObject(for: ProcessInfo.processInfo.processIdentifier))
        XCTAssertNil(ProcessTapCapture.processObject(for: -1))
    }
}
