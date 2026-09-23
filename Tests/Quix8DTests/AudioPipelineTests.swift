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
