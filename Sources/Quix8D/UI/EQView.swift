import AppKit
import SwiftUI

// Dot: drag freq/gain, scroll Q, double-click resets gain. HPF/LPF: drag cutoff, click toggles.
struct EQGraph: View {
    @Binding var eq: EQSettings
    var isOn: Bool
    // nil hides the RTA.
    var spectrum: () -> (db: [Float], binHz: Double)?
    var isAnalyzing: Bool

    @State private var selected = 0
    // Not @State: hover moves must not re-run this body at mouse rate.
    @State private var hover = HoverPoint()
    @State private var size: CGSize = .zero
    @State private var scrollMonitor: Any?

    static let bandColors: [Color] = [.red, .orange, .yellow, .green, .mint, .cyan, .blue, .purple]
    private static let displaySampleRate = 48_000.0
    private static let dotSize: CGFloat = 20
    private static let frequencyLabels: [Double] = [50, 100, 200, 500, 1_000, 2_000, 5_000, 10_000]
    // Music sits around -30…-70 dBFS per bin; a deeper floor keeps the lower
    // half always filled.
    static let analyzerRange: ClosedRange<Double> = -72...0

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Equatable layers: hover and RTA frames must not redraw the grid or curve.
                GridLayer(withLevelScale: isAnalyzing).equatable()
                if isAnalyzing {
                    SpectrumLayer(spectrum: spectrum, hover: hover)
                        .allowsHitTesting(false)
                }
                CurveLayer(eq: eq, isOn: isOn).equatable()
                ForEach(eq.bands.indices, id: \.self) { index in
                    dot(for: index, in: geometry.size)
                }
                passHandle(isHighPass: true, in: geometry.size)
                passHandle(isHighPass: false, in: geometry.size)
            }
            .coordinateSpace(name: "eqGraph")
            .onAppear { size = geometry.size }
            .onChange(of: geometry.size) { _, newSize in size = newSize }
        }
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.35)))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .onContinuousHover(coordinateSpace: .local) { phase in
            if case .active(let location) = phase { hover.location = location } else { hover.location = nil }
        }
        .onAppear(perform: installScrollMonitor)
        .onDisappear(perform: removeScrollMonitor)
    }

    fileprivate static func x(ofFrequency frequency: Double, width: CGFloat) -> CGFloat {
        CGFloat(EQ.position(ofFrequency: frequency)) * width
    }

    fileprivate static func y(ofGain gainDb: Double, height: CGFloat) -> CGFloat {
        let span = EQ.gainRange.upperBound - EQ.gainRange.lowerBound
        return CGFloat(1 - (gainDb - EQ.gainRange.lowerBound) / span) * height
    }

    private func gain(atY y: CGFloat, height: CGFloat) -> Double {
        let span = EQ.gainRange.upperBound - EQ.gainRange.lowerBound
        let raw = EQ.gainRange.lowerBound + (1 - Double(y / height)) * span
        return min(max(raw, EQ.gainRange.lowerBound), EQ.gainRange.upperBound)
    }

    fileprivate static func drawGrid(in context: inout GraphicsContext, size: CGSize, withLevelScale: Bool) {
        let line = Color.white.opacity(0.12)
        for frequency in Self.frequencyLabels {
            let px = Self.x(ofFrequency: frequency, width: size.width)
            context.stroke(Path { $0.move(to: CGPoint(x: px, y: 0)); $0.addLine(to: CGPoint(x: px, y: size.height)) }, with: .color(line))
            let label = frequency >= 1_000 ? "\(Int(frequency / 1_000))k" : "\(Int(frequency))"
            context.draw(Text(verbatim: label).font(.system(size: 9)).foregroundStyle(.secondary),
                         at: CGPoint(x: px, y: size.height - 7))
        }
        for gainDb in stride(from: -12.0, through: 12.0, by: 6.0) {
            let py = Self.y(ofGain: gainDb, height: size.height)
            let color = gainDb == 0 ? Color.white.opacity(0.3) : line
            context.stroke(Path { $0.move(to: CGPoint(x: 0, y: py)); $0.addLine(to: CGPoint(x: size.width, y: py)) }, with: .color(color))
            context.draw(Text(verbatim: gainDb > 0 ? "+\(Int(gainDb))" : "\(Int(gainDb))").font(.system(size: 9)).foregroundStyle(.secondary),
                         at: CGPoint(x: 10, y: py - 6))
        }
        guard withLevelScale else { return }
        for db in stride(from: -60.0, through: -12.0, by: 12.0) {
            context.draw(Text(verbatim: "\(Int(db))").font(.system(size: 8)).foregroundStyle(Color.cyan.opacity(0.7)),
                         at: CGPoint(x: size.width - 12, y: SpectrumNSView.y(ofLevel: db, height: size.height)))
        }
    }

    fileprivate static func drawCurve(_ eq: EQSettings, isOn: Bool, in context: inout GraphicsContext, size: CGSize) {
        let coefficients = eq.stages(sampleRate: Self.displaySampleRate).filter(\.isActive).map(\.coefficients)
        var path = Path()
        for step in 0...Int(size.width / 2) {
            let px = CGFloat(step) * 2
            let frequency = EQ.frequency(atPosition: Double(px / size.width))
            let gainDb = EQ.responseDb(of: coefficients, at: frequency, sampleRate: Self.displaySampleRate)
            let point = CGPoint(x: px, y: Self.y(ofGain: min(max(gainDb, EQ.gainRange.lowerBound - 6), EQ.gainRange.upperBound), height: size.height))
            step == 0 ? path.move(to: point) : path.addLine(to: point)
        }
        let color = isOn ? Color(red: 0.8, green: 0.95, blue: 0.2) : Color.gray
        context.stroke(path, with: .color(color), lineWidth: 2)
    }

    static func format(level db: Float) -> String {
        db <= Float(analyzerRange.lowerBound) ? "−∞ dB" : String(format: "%.0f dB", db)
    }

    private func dot(for index: Int, in size: CGSize) -> some View {
        let band = eq.bands[index]
        let position = CGPoint(x: Self.x(ofFrequency: band.frequency, width: size.width),
                               y: Self.y(ofGain: band.gainDb, height: size.height))
        let isSelected = index == selected
        return ZStack {
            Circle()
                .fill(Self.bandColors[index % Self.bandColors.count].opacity(isOn ? 1 : 0.4))
                .overlay(Circle().stroke(Color.white.opacity(isSelected ? 0.95 : 0.5), lineWidth: isSelected ? 2 : 1))
            Text("\(index + 1)")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.black)
        }
        .frame(width: Self.dotSize, height: Self.dotSize)
        .overlay(alignment: .bottom) {
            if isSelected {
                readout(for: band)
                    .fixedSize()
                    .offset(y: position.y < 50 ? 44 : -24)
            }
        }
        .position(position)
        .zIndex(isSelected ? 2 : 1)
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named("eqGraph"))
                .onChanged { drag in
                    selected = index
                    eq.bands[index].frequency = EQ.frequency(atPosition: Double(drag.location.x / size.width))
                    eq.bands[index].gainDb = gain(atY: drag.location.y, height: size.height)
                }
        )
        .simultaneousGesture(TapGesture(count: 2).onEnded { eq.bands[index].gainDb = 0 })
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("EQ band \(index + 1)")
        .accessibilityValue("\(Self.format(frequency: band.frequency)) hertz, \(String(format: "%.1f", band.gainDb)) dB, Q \(String(format: "%.2f", band.q))")
        .accessibilityAdjustableAction { direction in
            let step = direction == .increment ? 1.0 : -1.0
            eq.bands[index].gainDb = min(max(band.gainDb + step, EQ.gainRange.lowerBound), EQ.gainRange.upperBound)
        }
    }

    private func readout(for band: EQBand) -> some View {
        VStack(spacing: 0) {
            Text("Q \(String(format: "%.2f", band.q))")
            Text(Self.format(frequency: band.frequency))
            Text(String(format: "%+.1f dB", band.gainDb))
        }
        .font(.system(size: 9, weight: .semibold).monospacedDigit())
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 3).fill(Color.black.opacity(0.6)))
        .foregroundStyle(.white)
    }

    static func format(frequency: Double) -> String {
        frequency >= 1_000 ? String(format: "%.2fk", frequency / 1_000) : String(format: "%.0f", frequency)
    }

    private func passHandle(isHighPass: Bool, in size: CGSize) -> some View {
        let filter = isHighPass ? eq.highPass : eq.lowPass
        let position = CGPoint(x: min(max(Self.x(ofFrequency: filter.frequency, width: size.width), 16), size.width - 16),
                               y: size.height - 32)
        let setFilter: (EQFilter) -> Void = { newValue in
            if isHighPass { eq.highPass = newValue } else { eq.lowPass = newValue }
        }
        return VStack(spacing: 2) {
            Text(Self.format(frequency: filter.frequency))
                .font(.system(size: 9, weight: .semibold).monospacedDigit())
                .foregroundStyle(filter.isOn ? Color.white : Color.secondary)
            Text(isHighPass ? "HPF" : "LPF")
                .font(.system(size: 9, weight: .bold))
                .frame(width: 30, height: 18)
                .foregroundStyle(filter.isOn ? Color.black : Color.secondary)
                .background(RoundedRectangle(cornerRadius: 3).fill(filter.isOn ? Color.white.opacity(0.9) : Color.white.opacity(0.12)))
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.white.opacity(0.4)))
        }
        .position(position)
        .zIndex(1)
        .gesture(
            DragGesture(minimumDistance: 2, coordinateSpace: .named("eqGraph"))
                .onChanged { drag in
                    setFilter(EQFilter(frequency: EQ.frequency(atPosition: Double(drag.location.x / size.width)), isOn: true))
                }
        )
        .onTapGesture { setFilter(EQFilter(frequency: filter.frequency, isOn: !filter.isOn)) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isHighPass ? "High-pass filter" : "Low-pass filter")
        .accessibilityValue("\(filter.isOn ? "On" : "Off"), \(Self.format(frequency: filter.frequency)) hertz")
        .accessibilityAddTraits(.isButton)
    }

    // SwiftUI has no scroll-wheel gesture on macOS 14.
    private func installScrollMonitor() {
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard let hover = hover.location else { return event }
            let target = bandNearest(hover) ?? selected
            selected = target
            let factor = exp(Double(event.scrollingDeltaY) * (event.hasPreciseScrollingDeltas ? 0.01 : 0.1))
            eq.bands[target].q = min(max(eq.bands[target].q * factor, EQ.qRange.lowerBound), EQ.qRange.upperBound)
            return nil
        }
    }

    private func removeScrollMonitor() {
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        scrollMonitor = nil
    }

    private func bandNearest(_ point: CGPoint) -> Int? {
        let distances = eq.bands.indices.map { index -> (Int, CGFloat) in
            let dx = Self.x(ofFrequency: eq.bands[index].frequency, width: size.width) - point.x
            let dy = Self.y(ofGain: eq.bands[index].gainDb, height: size.height) - point.y
            return (index, (dx * dx + dy * dy).squareRoot())
        }
        guard let nearest = distances.min(by: { $0.1 < $1.1 }), nearest.1 < 40 else { return nil }
        return nearest.0
    }
}

private struct GridLayer: View, Equatable {
    var withLevelScale: Bool

    var body: some View {
        Canvas { context, size in EQGraph.drawGrid(in: &context, size: size, withLevelScale: withLevelScale) }
    }
}

private struct CurveLayer: View, Equatable {
    var eq: EQSettings
    var isOn: Bool

    var body: some View {
        Canvas { context, size in EQGraph.drawCurve(eq, isOn: isOn, in: &context, size: size) }
    }
}

final class HoverPoint {
    var location: CGPoint?
}

/// Draws the live spectrum in AppKit on its own 30 Hz timer, so RTA frames
/// never trigger a SwiftUI update (which re-lays-out the whole popover).
private struct SpectrumLayer: NSViewRepresentable {
    var spectrum: () -> (db: [Float], binHz: Double)?
    var hover: HoverPoint

    func makeNSView(context: Context) -> SpectrumNSView { SpectrumNSView() }

    func updateNSView(_ view: SpectrumNSView, context: Context) {
        view.spectrum = spectrum
        view.hover = hover
    }
}

final class SpectrumNSView: NSView {
    var spectrum: (() -> (db: [Float], binHz: Double)?)?
    var hover: HoverPoint?
    private var timer: Timer?
    private var latest: (db: [Float], binHz: Double)?

    override var isFlipped: Bool { true }

    static func y(ofLevel db: Double, height: CGFloat) -> CGFloat {
        let range = EQGraph.analyzerRange
        let clamped = min(max(db, range.lowerBound), range.upperBound)
        return CGFloat(1 - (clamped - range.lowerBound) / (range.upperBound - range.lowerBound)) * height
    }

    override func viewDidMoveToWindow() {
        timer?.invalidate()
        timer = nil
        guard window != nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            guard let self else { return }
            latest = spectrum?()
            needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let latest, bounds.width > 0 else { return }
        drawFill(latest)
        drawReadout(latest)
    }

    /// Per 2-pt column, the loudest bin.
    private func drawFill(_ spectrum: (db: [Float], binHz: Double)) {
        let size = bounds.size
        let path = CGMutablePath()
        path.move(to: CGPoint(x: 0, y: size.height))
        let columns = Int(size.width / 2)
        for column in 0...columns {
            let lowHz = EQ.frequency(atPosition: Double(column) / Double(columns + 1))
            let highHz = EQ.frequency(atPosition: Double(column + 1) / Double(columns + 1))
            let lowBin = max(1, Int(lowHz / spectrum.binHz))
            let highBin = min(spectrum.db.count - 1, max(lowBin, Int(highHz / spectrum.binHz)))
            var level: Float = -120
            if lowBin <= highBin {
                for bin in lowBin...highBin { level = max(level, spectrum.db[bin]) }
            }
            path.addLine(to: CGPoint(x: CGFloat(column) * 2, y: Self.y(ofLevel: Double(level), height: size.height)))
        }
        path.addLine(to: CGPoint(x: size.width, y: size.height))
        path.closeSubpath()

        guard let context = NSGraphicsContext.current?.cgContext,
              let gradient = CGGradient(colorsSpace: nil, colors: [
                NSColor.cyan.withAlphaComponent(0.55).cgColor, NSColor.cyan.withAlphaComponent(0.12).cgColor,
              ] as CFArray, locations: [0, 1])
        else { return }
        context.saveGState()
        context.addPath(path)
        context.clip()
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
        context.restoreGState()
    }

    private func drawReadout(_ spectrum: (db: [Float], binHz: Double)) {
        var peak = 1
        for bin in 1..<spectrum.db.count where spectrum.db[bin] > spectrum.db[peak] { peak = bin }
        var lines = ["Peak \(EQGraph.format(frequency: Double(peak) * spectrum.binHz)) Hz · \(EQGraph.format(level: spectrum.db[peak]))"]
        if let hoverX = hover?.location?.x {
            let hz = EQ.frequency(atPosition: Double(hoverX / bounds.width))
            let bin = min(max(1, Int(hz / spectrum.binHz)), spectrum.db.count - 1)
            lines.append("\(EQGraph.format(frequency: hz)) Hz · \(EQGraph.format(level: spectrum.db[bin]))")
        }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9, weight: .semibold),
            .foregroundColor: NSColor.cyan,
        ]
        var y: CGFloat = 4
        for line in lines {
            let text = NSAttributedString(string: line, attributes: attributes)
            text.draw(at: CGPoint(x: bounds.width - text.size().width - 4, y: y))
            y += text.size().height + 1
        }
    }
}
