import SwiftUI

struct EffectsPage: View {
    @Binding var effects: EffectsSettings
    var isEnabled: Bool
    @State private var shown: EffectSwitch?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)

    var body: some View {
        VStack(spacing: 10) {
            grid
            if let shown {
                EffectGraph(effect: shown, effects: effects)
                    .frame(height: 120)
            }
        }
    }

    private var grid: some View {
        LazyVGrid(columns: columns, spacing: 10) {
            card("Reverb", .reverb, isOn: $effects.reverb.isOn, reset: { effects.reverb = .init(isOn: effects.reverb.isOn) }) {
                SmallKnob("Mix", $effects.reverb.mix, 0...1, percent: true)
                SmallKnob("Size", $effects.reverb.size, 0...1, percent: true)
                SmallKnob("Tone", $effects.reverb.damping, 0...1) { "\(Int(((1 - $0) * 100).rounded()))%" }
            }
            card("Compressor", .compressor, isOn: $effects.compressor.isOn, reset: { effects.compressor = .init(isOn: effects.compressor.isOn) }) {
                SmallKnob("Thresh", $effects.compressor.threshold, -40...0) { String(format: "%.0f dB", $0) }
                SmallKnob("Ratio", $effects.compressor.ratio, 1...20) { String(format: "%.1f:1", $0) }
                SmallKnob("Makeup", $effects.compressor.makeup, 0...18) { String(format: "+%.0f dB", $0) }
            }
            card("Delay", .delay, isOn: $effects.delay.isOn, reset: { effects.delay = .init(isOn: effects.delay.isOn) }) {
                SmallKnob("Time", $effects.delay.time, 0.02...1.5) { "\(Int(($0 * 1_000).rounded())) ms" }
                SmallKnob("Feedback", $effects.delay.feedback, 0...0.9, percent: true)
                SmallKnob("Mix", $effects.delay.mix, 0...1, percent: true)
            }
            card("Widener", .widener, isOn: $effects.widener.isOn, reset: { effects.widener = .init(isOn: effects.widener.isOn) }) {
                SmallKnob("Width", $effects.widener.width, 0...2, percent: true, reset: 1)
            }
            card("Bass", .bass, isOn: $effects.bassEnhancer.isOn, reset: { effects.bassEnhancer = .init(isOn: effects.bassEnhancer.isOn) }) {
                SmallKnob("Amount", $effects.bassEnhancer.amount, 0...1, percent: true)
                SmallKnob("Freq", $effects.bassEnhancer.frequency, 60...250) { "\(Int($0.rounded())) Hz" }
            }
            card("Chorus", .chorus, isOn: $effects.chorus.isOn, reset: { effects.chorus = .init(isOn: effects.chorus.isOn) }) {
                SmallKnob("Rate", $effects.chorus.rate, 0.1...5) { String(format: "%.1f Hz", $0) }
                SmallKnob("Depth", $effects.chorus.depth, 0...1, percent: true)
                SmallKnob("Mix", $effects.chorus.mix, 0...1, percent: true)
            }
        }
        .opacity(isEnabled ? 1 : 0.5)
    }

    private func card<Knobs: View>(
        _ title: String, _ midi: EffectSwitch, isOn: Binding<Bool>, reset: @escaping () -> Void, @ViewBuilder knobs: () -> Knobs
    ) -> some View {
        VStack(spacing: 8) {
            HStack {
                Text(title).font(.subheadline.weight(.semibold))
                Spacer()
                Button(action: reset) {
                    Image(systemName: "arrow.counterclockwise").font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Reset \(title)")
                Toggle(title, isOn: isOn)
                    .toggleStyle(PillSwitchStyle(onColor: .green, width: 30, height: 17))
                    .midiLearnable(.effect(midi))
            }
            HStack(alignment: .top, spacing: 4) {
                knobs()
            }
            .frame(maxWidth: .infinity)
            .opacity(isOn.wrappedValue ? 1 : 0.45)
        }
        .padding(8)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.1)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor, lineWidth: 1.5).opacity(shown == midi ? 1 : 0))
        .contentShape(Rectangle())
        // Select only: a knob double-click (reset) would toggle it off again.
        .onTapGesture { shown = midi }
    }
}

private struct SmallKnob: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let format: (Double) -> String
    let reset: Double?

    init(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>,
         percent: Bool = false, reset: Double? = nil, format: ((Double) -> String)? = nil) {
        self.title = title
        _value = value
        self.range = range
        self.reset = reset
        self.format = format ?? (percent ? { "\(Int(($0 * 100).rounded()))%" } : { String(format: "%.2f", $0) })
    }

    var body: some View {
        Knob(title: title, value: $value, range: range, valueText: format(value), resetValue: reset, diameter: 40)
            .font(.caption2)
            .frame(minWidth: 44)
    }
}

/// What the selected effect does with its current settings.
struct EffectGraph: View {
    let effect: EffectSwitch
    let effects: EffectsSettings

    private static let curveColor = Color(red: 0.8, green: 0.95, blue: 0.2)
    private static let gridColor = Color.white.opacity(0.12)

    var body: some View {
        Canvas { context, size in
            let plot = CGRect(x: 8, y: 20, width: size.width - 16, height: size.height - 30)
            let color = effects[keyPath: effect.isOn] ? Self.curveColor : .gray
            switch effect {
            case .reverb: Self.drawReverb(effects.reverb, color: color, in: &context, plot: plot)
            case .compressor: Self.drawCompressor(effects.compressor, color: color, in: &context, plot: plot)
            case .delay: Self.drawDelay(effects.delay, color: color, in: &context, plot: plot)
            case .widener: Self.drawWidener(effects.widener, color: color, in: &context, plot: plot)
            case .bass: Self.drawBass(effects.bassEnhancer, color: color, in: &context, plot: plot)
            case .chorus: Self.drawChorus(effects.chorus, color: color, in: &context, plot: plot)
            }
        }
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.35)))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private static let captions: [EffectSwitch: String] = [
        .reverb: "Impulse response",
        .compressor: "Input level → output level",
        .delay: "Echoes of a click",
        .widener: "Stereo width",
        .bass: "Bass band (outline) and the harmonics it adds",
        .chorus: "Delay sweep, left and right",
    ]

    private static func label(_ text: String, at point: CGPoint, anchor: UnitPoint = .center, color: Color = .secondary, in context: inout GraphicsContext) {
        context.draw(Text(verbatim: text).font(.system(size: 9)).foregroundStyle(color), at: point, anchor: anchor)
    }

    private static func line(from start: CGPoint, to end: CGPoint, color: Color = gridColor, dashed: Bool = false, in context: inout GraphicsContext) {
        context.stroke(Path { $0.move(to: start); $0.addLine(to: end) }, with: .color(color),
                       style: StrokeStyle(lineWidth: 1, dash: dashed ? [3, 3] : []))
    }

    private static func timeGrid(seconds: Double, step: Double, in context: inout GraphicsContext, plot: CGRect) {
        for time in stride(from: step, to: seconds, by: step) {
            let x = plot.minX + CGFloat(time / seconds) * plot.width
            line(from: CGPoint(x: x, y: plot.minY), to: CGPoint(x: x, y: plot.maxY), in: &context)
            label(time < 1 ? "\(Int(time * 1_000)) ms" : String(format: "%g s", time), at: CGPoint(x: x + 2, y: plot.minY), anchor: .topLeading, in: &context)
        }
    }

    private static func caption(_ effect: EffectSwitch, in context: inout GraphicsContext) {
        label(captions[effect] ?? "", at: CGPoint(x: 8, y: 4), anchor: .topLeading, in: &context)
    }

    // Runs the real reverb on a click, so the picture is what you hear.
    static func reverbEnvelope(_ reverb: EffectsSettings.Reverb, seconds: Double, columns: Int) -> [Float] {
        let sampleRate = 12_000.0
        var settings = EffectsSettings()
        settings.reverb = reverb
        settings.reverb.isOn = true
        var left = [Float](repeating: 0, count: Int(sampleRate * seconds))
        left[0] = 1
        var right = left
        let processor = EffectsProcessor(sampleRate: sampleRate)
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                processor.process(left: (l.baseAddress!, 1, l.count), right: (r.baseAddress!, 1, r.count), settings: settings)
            }
        }
        let bucket = left.count / columns
        return (0..<columns).map { column in
            left[column * bucket..<(column + 1) * bucket].reduce(0) { max($0, abs($1)) }
        }
    }

    private static func drawReverb(_ reverb: EffectsSettings.Reverb, color: Color, in context: inout GraphicsContext, plot: CGRect) {
        caption(.reverb, in: &context)
        let seconds = 4.0
        let floorDb = -72.0
        timeGrid(seconds: seconds, step: 1, in: &context, plot: plot)
        let envelope = reverbEnvelope(reverb, seconds: seconds, columns: max(Int(plot.width / 2), 1))
        var path = Path()
        path.move(to: CGPoint(x: plot.minX, y: plot.maxY))
        for (index, peak) in envelope.enumerated() {
            let db = max(20 * log10(Double(peak) + 1e-9), floorDb)
            path.addLine(to: CGPoint(x: plot.minX + CGFloat(index) * 2, y: plot.maxY - CGFloat(1 - db / floorDb) * plot.height))
        }
        path.addLine(to: CGPoint(x: plot.minX + CGFloat(envelope.count) * 2, y: plot.maxY))
        context.fill(path, with: .color(color.opacity(0.35)))
        context.stroke(path, with: .color(color), lineWidth: 1)
    }

    private static func drawCompressor(_ compressor: EffectsSettings.Compressor, color: Color, in context: inout GraphicsContext, plot: CGRect) {
        caption(.compressor, in: &context)
        let input = -60.0...0.0
        let output = -60.0...18.0
        func point(_ inDb: Double, _ outDb: Double) -> CGPoint {
            CGPoint(x: plot.minX + CGFloat((inDb - input.lowerBound) / (input.upperBound - input.lowerBound)) * plot.width,
                    y: plot.maxY - CGFloat((min(outDb, output.upperBound) - output.lowerBound) / (output.upperBound - output.lowerBound)) * plot.height)
        }
        for db in stride(from: -48.0, through: 12.0, by: 12.0) {
            line(from: point(input.lowerBound, db), to: point(input.upperBound, db), color: db == 0 ? Color.white.opacity(0.3) : gridColor, in: &context)
            label(db > 0 ? "+\(Int(db))" : "\(Int(db))", at: point(input.lowerBound, db), anchor: .bottomLeading, in: &context)
        }
        line(from: point(-60, -60), to: point(0, 0), color: .gray, dashed: true, in: &context)
        let threshold = point(compressor.threshold, output.lowerBound)
        line(from: threshold, to: CGPoint(x: threshold.x, y: plot.minY), color: color.opacity(0.6), dashed: true, in: &context)
        label("Threshold", at: CGPoint(x: threshold.x + 2, y: plot.maxY), anchor: .bottomLeading, in: &context)
        let ratio = max(compressor.ratio, 1)
        var curve = Path()
        for step in 0...60 {
            let inDb = input.lowerBound + Double(step)
            let gain = Double(EffectsProcessor.compressorGainDb(levelDb: Float(inDb), threshold: Float(compressor.threshold), ratio: Float(ratio)))
            let p = point(inDb, inDb + gain + compressor.makeup)
            step == 0 ? curve.move(to: p) : curve.addLine(to: p)
        }
        context.stroke(curve, with: .color(color), lineWidth: 2)
    }

    private static func drawDelay(_ delay: EffectsSettings.Delay, color: Color, in context: inout GraphicsContext, plot: CGRect) {
        caption(.delay, in: &context)
        let seconds = 3.0
        timeGrid(seconds: seconds, step: 0.5, in: &context, plot: plot)
        func stem(at time: Double, level: Double, color: Color) {
            let x = plot.minX + CGFloat(time / seconds) * plot.width
            context.stroke(Path { $0.move(to: CGPoint(x: x, y: plot.maxY)); $0.addLine(to: CGPoint(x: x, y: plot.maxY - CGFloat(level) * plot.height)) },
                           with: .color(color), lineWidth: 2)
        }
        stem(at: 0, level: 1, color: .gray)
        var level = delay.mix
        var time = delay.time
        while time <= seconds, level > 0.002 {
            stem(at: time, level: level, color: color)
            level *= delay.feedback
            time += delay.time
        }
    }

    private static func drawWidener(_ widener: EffectsSettings.Widener, color: Color, in context: inout GraphicsContext, plot: CGRect) {
        caption(.widener, in: &context)
        let center = CGPoint(x: plot.midX, y: plot.maxY)
        let radius = min(plot.height, plot.width / 2)
        // Up is centre; unchanged stereo spans ±45°, double width ±90°.
        func wedge(halfAngle: Double) -> Path {
            Path { path in
                path.move(to: center)
                for step in 0...40 {
                    let angle = (-halfAngle + 2 * halfAngle * Double(step) / 40) * .pi / 180
                    path.addLine(to: CGPoint(x: center.x + radius * CGFloat(sin(angle)), y: center.y - radius * CGFloat(cos(angle))))
                }
                path.closeSubpath()
            }
        }
        context.stroke(wedge(halfAngle: 45), with: .color(.gray), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        label("L", at: CGPoint(x: center.x - radius * 0.75, y: center.y - radius * 0.75), anchor: .bottomTrailing, in: &context)
        label("R", at: CGPoint(x: center.x + radius * 0.75, y: center.y - radius * 0.75), anchor: .bottomLeading, in: &context)
        let shape = wedge(halfAngle: 45 * widener.width)
        context.fill(shape, with: .color(color.opacity(0.35)))
        context.stroke(shape, with: .color(color), lineWidth: 1.5)
    }

    private static func drawBass(_ bass: EffectsSettings.BassEnhancer, color: Color, in context: inout GraphicsContext, plot: CGRect) {
        caption(.bass, in: &context)
        let range = 20.0...2_000.0
        func x(_ frequency: Double) -> CGFloat {
            plot.minX + CGFloat(log(frequency / range.lowerBound) / log(range.upperBound / range.lowerBound)) * plot.width
        }
        for frequency in [50.0, 100, 200, 500, 1_000] {
            line(from: CGPoint(x: x(frequency), y: plot.minY), to: CGPoint(x: x(frequency), y: plot.maxY), in: &context)
            label(frequency >= 1_000 ? "1k" : "\(Int(frequency))", at: CGPoint(x: x(frequency) + 2, y: plot.minY), anchor: .topLeading, in: &context)
        }
        let sampleRate = 48_000.0
        let lowPass = EQ.passCoefficients(highPass: false, frequency: bass.frequency, sampleRate: sampleRate)
        // Music has little below ~30 Hz, so the band is drawn from there.
        let musicFloor = EQ.passCoefficients(highPass: true, frequency: 30, sampleRate: sampleRate)
        // Saturation is odd-symmetric, so it adds odd harmonics at about 1/n level.
        func band(shift: Double, level: Double) -> Path {
            Path { path in
                path.move(to: CGPoint(x: x(range.lowerBound), y: plot.maxY))
                for step in 0...Int(plot.width / 2) {
                    let frequency = range.lowerBound * pow(range.upperBound / range.lowerBound, Double(step) / Double(Int(plot.width / 2)))
                    let gain = pow(10, EQ.responseDb(of: [lowPass, musicFloor], at: frequency / shift, sampleRate: sampleRate) / 20)
                    path.addLine(to: CGPoint(x: x(frequency), y: plot.maxY - CGFloat(gain * level) * plot.height))
                }
                path.addLine(to: CGPoint(x: x(range.upperBound), y: plot.maxY))
            }
        }
        context.stroke(band(shift: 1, level: 0.9), with: .color(.gray), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        for harmonic in [3.0, 5.0, 7.0] {
            let shape = band(shift: harmonic, level: 0.9 * bass.amount * 3 / harmonic)
            context.fill(shape, with: .color(color.opacity(0.3)))
            context.stroke(shape, with: .color(color), lineWidth: 1)
        }
    }

    private static func drawChorus(_ chorus: EffectsSettings.Chorus, color: Color, in context: inout GraphicsContext, plot: CGRect) {
        caption(.chorus, in: &context)
        let seconds = 2.0
        let delayRange = 14.0...26.0 // ms; the chorus sweeps 20 ± 5 ms
        timeGrid(seconds: seconds, step: 0.5, in: &context, plot: plot)
        func sweep(_ wave: (Double) -> Double) -> Path {
            Path { path in
                for step in 0...Int(plot.width / 2) {
                    let time = seconds * Double(step) / Double(Int(plot.width / 2))
                    let delayMs = 20 + 5 * chorus.depth * wave(2 * .pi * chorus.rate * time)
                    let point = CGPoint(x: plot.minX + CGFloat(time / seconds) * plot.width,
                                        y: plot.maxY - CGFloat((delayMs - delayRange.lowerBound) / (delayRange.upperBound - delayRange.lowerBound)) * plot.height)
                    step == 0 ? path.move(to: point) : path.addLine(to: point)
                }
            }
        }
        context.stroke(sweep(sin), with: .color(color), lineWidth: 2)
        context.stroke(sweep(cos), with: .color(.cyan.opacity(0.8)), lineWidth: 2)
        label("L", at: CGPoint(x: plot.maxX - 20, y: 4), anchor: .topLeading, color: color, in: &context)
        label("R", at: CGPoint(x: plot.maxX - 8, y: 4), anchor: .topLeading, color: .cyan, in: &context)
    }
}
