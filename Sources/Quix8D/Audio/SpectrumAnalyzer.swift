import Accelerate

/// dBFS per bin (0 dBFS = full-scale sine). Main thread only.
final class SpectrumAnalyzer {
    static let size = 4096

    private let fft = vDSP.FFT(log2n: vDSP_Length(log2(Double(size))), radix: .radix2, ofType: DSPSplitComplex.self)!
    private let window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: size, isHalfWindow: false)
    private static let fallPerUpdate: Float = 1.5
    private(set) var smoothedDb = [Float](repeating: -120, count: size / 2)

    @discardableResult
    func update(with samples: [Float]) -> [Float] {
        let fresh = Self.magnitudesDb(samples, fft: fft, window: window)
        for bin in 0..<smoothedDb.count {
            smoothedDb[bin] = max(fresh[bin], smoothedDb[bin] - Self.fallPerUpdate)
        }
        return smoothedDb
    }

    static func magnitudesDb(_ samples: [Float], fft: vDSP.FFT<DSPSplitComplex>, window: [Float]) -> [Float] {
        let half = size / 2
        let windowed = vDSP.multiply(samples, window)
        var real = [Float](repeating: 0, count: half)
        var imaginary = [Float](repeating: 0, count: half)
        var squared = [Float](repeating: 0, count: half)
        real.withUnsafeMutableBufferPointer { realPointer in
            imaginary.withUnsafeMutableBufferPointer { imaginaryPointer in
                var split = DSPSplitComplex(realp: realPointer.baseAddress!, imagp: imaginaryPointer.baseAddress!)
                windowed.withUnsafeBufferPointer { input in
                    input.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                    }
                }
                fft.forward(input: split, output: &split)
                vDSP.squareMagnitudes(split, result: &squared)
            }
        }
        // vDSP scales by 2 and Hann halves a sine: full scale = (size / 2)^2.
        let reference = Float(half * half)
        return squared.map { 10 * log10(max($0 / reference, 1e-12)) }
    }
}
