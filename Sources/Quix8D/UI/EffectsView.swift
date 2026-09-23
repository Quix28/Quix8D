import SwiftUI

struct EffectsPage: View {
    @Binding var effects: EffectsSettings
    var isEnabled: Bool

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 3)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 10) {
            card("Reverb", isOn: $effects.reverb.isOn, reset: { effects.reverb = .init(isOn: effects.reverb.isOn) }) {
                SmallKnob("Mix", $effects.reverb.mix, 0...1, percent: true)
                SmallKnob("Size", $effects.reverb.size, 0...1, percent: true)
                SmallKnob("Tone", $effects.reverb.damping, 0...1) { "\(Int(((1 - $0) * 100).rounded()))%" }
            }
            card("Compressor", isOn: $effects.compressor.isOn, reset: { effects.compressor = .init(isOn: effects.compressor.isOn) }) {
                SmallKnob("Thresh", $effects.compressor.threshold, -40...0) { String(format: "%.0f dB", $0) }
                SmallKnob("Ratio", $effects.compressor.ratio, 1...20) { String(format: "%.1f:1", $0) }
                SmallKnob("Makeup", $effects.compressor.makeup, 0...18) { String(format: "+%.0f dB", $0) }
            }
            card("Delay", isOn: $effects.delay.isOn, reset: { effects.delay = .init(isOn: effects.delay.isOn) }) {
                SmallKnob("Time", $effects.delay.time, 0.02...1.5) { "\(Int(($0 * 1_000).rounded())) ms" }
                SmallKnob("Feedback", $effects.delay.feedback, 0...0.9, percent: true)
                SmallKnob("Mix", $effects.delay.mix, 0...1, percent: true)
            }
            card("Widener", isOn: $effects.widener.isOn, reset: { effects.widener = .init(isOn: effects.widener.isOn) }) {
                SmallKnob("Width", $effects.widener.width, 0...2, percent: true, reset: 1)
            }
            card("Bass", isOn: $effects.bassEnhancer.isOn, reset: { effects.bassEnhancer = .init(isOn: effects.bassEnhancer.isOn) }) {
                SmallKnob("Amount", $effects.bassEnhancer.amount, 0...1, percent: true)
                SmallKnob("Freq", $effects.bassEnhancer.frequency, 60...250) { "\(Int($0.rounded())) Hz" }
            }
            card("Chorus", isOn: $effects.chorus.isOn, reset: { effects.chorus = .init(isOn: effects.chorus.isOn) }) {
                SmallKnob("Rate", $effects.chorus.rate, 0.1...5) { String(format: "%.1f Hz", $0) }
                SmallKnob("Depth", $effects.chorus.depth, 0...1, percent: true)
                SmallKnob("Mix", $effects.chorus.mix, 0...1, percent: true)
            }
        }
        .opacity(isEnabled ? 1 : 0.5)
    }

    private func card<Knobs: View>(
        _ title: String, isOn: Binding<Bool>, reset: @escaping () -> Void, @ViewBuilder knobs: () -> Knobs
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
