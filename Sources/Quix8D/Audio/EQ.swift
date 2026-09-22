import Foundation

struct EQBand: Equatable, Codable {
    var frequency: Double
    var gainDb: Double
    var q: Double
}

struct EQFilter: Equatable, Codable {
    var frequency: Double
    var isOn: Bool
}

struct EQSettings: Equatable, Codable {
    var bands = EQ.defaultBands
    var highPass = EQFilter(frequency: 80, isOn: false)
    var lowPass = EQFilter(frequency: 16_000, isOn: false)

    static let stageCount = EQ.defaultBands.count + 2

    var isFlat: Bool { EQ.isFlat(bands) && !highPass.isOn && !lowPass.isOn }

    func stages(sampleRate: Double) -> [(coefficients: BinauralEffect.Biquad, isActive: Bool)] {
        bands.map { (EQ.coefficients($0, sampleRate: sampleRate), EQ.isActive($0)) } + [
            (EQ.passCoefficients(highPass: true, frequency: highPass.frequency, sampleRate: sampleRate), highPass.isOn),
            (EQ.passCoefficients(highPass: false, frequency: lowPass.frequency, sampleRate: sampleRate), lowPass.isOn),
        ]
    }
}

struct EQPreset: Codable, Equatable, Identifiable {
    var name: String
    var settings: EQSettings
    var id: String { name }
}

enum EQPresetStore {
    static let key = "eqPresets"

    static func load(from defaults: UserDefaults = .standard) -> [EQPreset] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([EQPreset].self, from: data)) ?? []
    }

    static func save(_ presets: [EQPreset], to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(presets) {
            defaults.set(data, forKey: key)
        }
    }

    static func upserting(_ preset: EQPreset, into presets: [EQPreset]) -> [EQPreset] {
        (presets.filter { $0.name.caseInsensitiveCompare(preset.name) != .orderedSame } + [preset])
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

enum EQ {
    static let frequencyRange = 20.0...20_000.0
    static let gainRange = -18.0...18.0
    static let qRange = 0.3...12.0

    static let defaultBands: [EQBand] = [32, 80, 200, 500, 1_200, 3_000, 7_000, 14_000]
        .map { EQBand(frequency: $0, gainDb: 0, q: 1) }

    /// Near 0 dB a band is an identity filter, so it is skipped.
    static func isActive(_ band: EQBand) -> Bool { abs(band.gainDb) >= 0.05 }
    static func isFlat(_ bands: [EQBand]) -> Bool { !bands.contains(where: isActive) }

    static func position(ofFrequency frequency: Double) -> Double {
        log(frequency / frequencyRange.lowerBound) / log(frequencyRange.upperBound / frequencyRange.lowerBound)
    }

    static func frequency(atPosition position: Double) -> Double {
        frequencyRange.lowerBound * pow(frequencyRange.upperBound / frequencyRange.lowerBound, min(max(position, 0), 1))
    }

    static func coefficients(_ band: EQBand, sampleRate: Double) -> BinauralEffect.Biquad {
        // Stay under Nyquist so a 44.1k device can't get an unstable filter.
        let frequency = min(band.frequency, sampleRate * 0.45)
        return BinauralEffect.peakingCoefficients(centerHz: frequency, gainDb: band.gainDb, q: band.q, sampleRate: sampleRate)
    }

    /// RBJ cookbook Butterworth, Q = 1/√2.
    static func passCoefficients(highPass: Bool, frequency: Double, sampleRate: Double) -> BinauralEffect.Biquad {
        let w0 = 2 * Double.pi * min(frequency, sampleRate * 0.45) / sampleRate
        let alpha = sin(w0) / (2 * 0.5.squareRoot())
        let cosW0 = cos(w0)
        let a0 = 1 + alpha
        let edge = highPass ? (1 + cosW0) : (1 - cosW0)
        return BinauralEffect.Biquad(
            b0: Float32(edge / 2 / a0), b1: Float32((highPass ? -edge : edge) / a0), b2: Float32(edge / 2 / a0),
            a1: Float32(-2 * cosW0 / a0), a2: Float32((1 - alpha) / a0))
    }

    static func responseDb(of coefficients: [BinauralEffect.Biquad], at frequency: Double, sampleRate: Double) -> Double {
        coefficients.reduce(0) { $0 + magnitudeDb($1, hz: frequency, sampleRate: sampleRate) }
    }

    static func magnitudeDb(_ c: BinauralEffect.Biquad, hz: Double, sampleRate: Double) -> Double {
        let w = 2 * Double.pi * hz / sampleRate
        func magnitude(_ k0: Double, _ k1: Double, _ k2: Double) -> Double {
            let re = k0 + k1 * cos(w) + k2 * cos(2 * w)
            let im = -(k1 * sin(w) + k2 * sin(2 * w))
            return (re * re + im * im).squareRoot()
        }
        let numerator = magnitude(Double(c.b0), Double(c.b1), Double(c.b2))
        let denominator = magnitude(1, Double(c.a1), Double(c.a2))
        return 20 * log10(numerator / denominator)
    }
}
