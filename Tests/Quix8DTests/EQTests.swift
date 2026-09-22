import XCTest
@testable import Quix8D

final class EQTests: XCTestCase {
    func testFrequencyAxisRoundTripsAndSpansRange() {
        XCTAssertEqual(EQ.position(ofFrequency: 20), 0, accuracy: 1e-9)
        XCTAssertEqual(EQ.position(ofFrequency: 20_000), 1, accuracy: 1e-9)
        XCTAssertEqual(EQ.frequency(atPosition: EQ.position(ofFrequency: 1_000)), 1_000, accuracy: 1e-6)
    }

    func testSingleBandResponsePeaksAtItsGain() {
        var bands = EQ.defaultBands
        bands[4].gainDb = 6
        let coefficients = bands.map { EQ.coefficients($0, sampleRate: 48_000) }
        XCTAssertEqual(EQ.responseDb(of: coefficients, at: bands[4].frequency, sampleRate: 48_000), 6, accuracy: 0.1)
        XCTAssertEqual(EQ.responseDb(of: coefficients, at: 20, sampleRate: 48_000), 0, accuracy: 0.1)
    }

    func testDefaultBandsAreFlat() {
        XCTAssertTrue(EQ.isFlat(EQ.defaultBands))
    }

    func testHighAndLowPassAreThreeDbDownAtCutoff() {
        let highPass = EQ.passCoefficients(highPass: true, frequency: 100, sampleRate: 48_000)
        XCTAssertEqual(EQ.magnitudeDb(highPass, hz: 100, sampleRate: 48_000), -3, accuracy: 0.1)
        XCTAssertLessThan(EQ.magnitudeDb(highPass, hz: 25, sampleRate: 48_000), -20)
        XCTAssertEqual(EQ.magnitudeDb(highPass, hz: 5_000, sampleRate: 48_000), 0, accuracy: 0.1)

        let lowPass = EQ.passCoefficients(highPass: false, frequency: 5_000, sampleRate: 48_000)
        XCTAssertEqual(EQ.magnitudeDb(lowPass, hz: 5_000, sampleRate: 48_000), -3, accuracy: 0.2)
        XCTAssertEqual(EQ.magnitudeDb(lowPass, hz: 100, sampleRate: 48_000), 0, accuracy: 0.1)
    }

    func testFilterOnMakesSettingsNonFlat() {
        var settings = EQSettings()
        XCTAssertTrue(settings.isFlat)
        settings.highPass.isOn = true
        XCTAssertFalse(settings.isFlat)
    }

    func testAnalyzerFindsSineAtItsFrequencyAndLevel() {
        let sampleRate = 48_000.0
        let binHz = sampleRate / Double(SpectrumAnalyzer.size)
        let frequency = 100 * binHz // centered on a bin
        let samples = (0..<SpectrumAnalyzer.size).map { Float(0.5 * sin(2 * Double.pi * frequency * Double($0) / sampleRate)) }
        let db = SpectrumAnalyzer().update(with: samples)
        let peak = db.indices.max { db[$0] < db[$1] }!
        XCTAssertEqual(peak, 100)
        XCTAssertEqual(db[peak], -6, accuracy: 0.2, "a 0.5 sine is -6 dBFS")
    }

    func testAnalyzerSnapshotReturnsLatestSamplesOldestFirst() {
        let pipeline = AudioPipeline()
        let count = SpectrumAnalyzer.size + 100 // wraps the ring once
        var left = (0..<count).map { Float32($0) }
        var right = left
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                pipeline.feedAnalyzer(left: (l.baseAddress!, 1, count), right: (r.baseAddress!, 1, count))
            }
        }
        let samples = pipeline.analyzerSnapshot().samples
        XCTAssertEqual(samples.first, Float(100))
        XCTAssertEqual(samples.last, Float(count - 1))
        XCTAssertEqual(samples.count, SpectrumAnalyzer.size)
    }

    func testPresetsRoundTripAndSameNameReplaces() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "EQTests-\(UUID().uuidString)"))
        var boosted = EQSettings()
        boosted.bands[2].gainDb = 5
        boosted.lowPass = EQFilter(frequency: 9_000, isOn: true)

        var presets = EQPresetStore.upserting(EQPreset(name: "Warm", settings: boosted), into: [])
        presets = EQPresetStore.upserting(EQPreset(name: "Bright", settings: EQSettings()), into: presets)
        presets = EQPresetStore.upserting(EQPreset(name: "warm", settings: EQSettings()), into: presets)
        XCTAssertEqual(presets.map(\.name), ["Bright", "warm"], "same name (any case) replaces, sorted")

        EQPresetStore.save([EQPreset(name: "Warm", settings: boosted)], to: defaults)
        XCTAssertEqual(EQPresetStore.load(from: defaults), [EQPreset(name: "Warm", settings: boosted)])
    }

    func testStereoBiquadMatchesPerSampleFilter() {
        let c = BinauralEffect.peakingCoefficients(centerHz: 1_000, gainDb: 6, q: 2, sampleRate: 48_000)
        let input = (0..<300).map { Float32(sin(Double($0) * 0.37)) }
        var left = input, right = input.map { -$0 * 0.5 }
        var leftState = BiquadState(), rightState = BiquadState()
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                BiquadState.processStereo(left: (l.baseAddress!, 1), leftState: &leftState,
                                          right: (r.baseAddress!, 1), rightState: &rightState, frames: 300, c)
            }
        }
        var referenceLeft = BiquadState(), referenceRight = BiquadState()
        for index in input.indices {
            XCTAssertEqual(left[index], referenceLeft.process(input[index], c), accuracy: 1e-6)
            XCTAssertEqual(right[index], referenceRight.process(-input[index] * 0.5, c), accuracy: 1e-6)
        }
    }
}
