import SwiftUI

struct ControlPanelView: View {
    @ObservedObject var controller: MenuBarController

    private let appRefresh = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 20) {
            header
            switch controller.page {
            case .main: mainPage
            case .mix: MixPage(controller: controller)
            case .effects:
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Effects for").font(.headline)
                        AppTargetMenu(targets: controller.effectsTargets, selection: $controller.effectsTarget)
                    }
                    EffectsPage(effects: $controller.selectedEffects, isEnabled: controller.effectsOn)
                }
            }
        }
        .padding(16)
        .frame(width: controller.page == .main ? 320 : 520)
        .onAppear { controller.refreshAudioApps() }
        .onChange(of: controller.page) { _, _ in controller.refreshAudioApps() }
        .onReceive(appRefresh) { _ in
            if controller.isPanelVisible, controller.page != .effects { controller.refreshAudioApps() }
        }
    }

    @ViewBuilder private var mainPage: some View {
        HStack(alignment: .top, spacing: 30) {
            VStack(spacing: 10) {
                Knob(
                    title: "Volume",
                    value: Binding(get: { Double(controller.volume) }, set: { controller.setVolume(Float($0)) }),
                    range: 0...1,
                    valueText: "\(Int((controller.volume * 100).rounded()))%"
                )
                .disabled(!controller.isVolumeAdjustable)
                boostButton
            }

            VStack(spacing: 10) {
                Knob(
                    title: "Rotation",
                    value: $controller.speed,
                    range: -MenuBarController.maxSpeed...MenuBarController.maxSpeed,
                    isBipolar: true,
                    valueText: rotationText,
                    resetValue: 0
                )
                audioSwitch
            }

            Knob(
                title: "Pan",
                value: $controller.pan,
                range: -1...1,
                isBipolar: true,
                valueText: panText,
                resetValue: 0
            )
        }
        Divider()
        AppFaders(controller: controller)
        Divider()
        deviceMenu
    }

    private var header: some View {
        HStack(spacing: 10) {
            Picker("Page", selection: $controller.page) {
                Text("Main").tag(MenuBarController.Page.main)
                Text("Mix").tag(MenuBarController.Page.mix)
                Text("Effects").tag(MenuBarController.Page.effects)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Spacer()
            Toggle("Effects", isOn: $controller.effectsOn)
                .toggleStyle(PillSwitchStyle(onColor: .green))
            Button { controller.checkForUpdates() } label: {
                if controller.isCheckingForUpdates {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.down.circle").font(.system(size: 15, weight: .semibold))
                }
            }
            .buttonStyle(.borderless)
            .disabled(controller.isCheckingForUpdates)
            .accessibilityLabel("Check for updates")
            Button(action: controller.quit) {
                Image(systemName: "power").font(.system(size: 15, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .keyboardShortcut("q")
            .accessibilityLabel("Quit")
        }
    }

    private var audioSwitch: some View {
        let state = startStopButtonState(
            isRunning: controller.isRunning, isStarting: controller.isStarting, osSupported: controller.osSupported)
        return Toggle("8D Audio", isOn: $controller.is8DOn)
        .toggleStyle(PillSwitchStyle(onColor: .accentColor, width: 52, height: 28))
        .disabled(!state.enabled)
        .overlay(alignment: .trailing) {
            if controller.isStarting {
                ProgressView().controlSize(.small).offset(x: 28)
            }
        }
    }

    private var boostButton: some View {
        let boosted = controller.isBoosted
        return Button { controller.isBoosted.toggle() } label: {
            Text(boosted ? "6×" : "1×")
                .font(.caption.weight(.bold).monospacedDigit())
                .frame(width: 40, height: 20)
                .foregroundStyle(boosted ? Color.white : Color.primary)
                .background(Capsule().fill(boosted ? Color.orange : Color.secondary.opacity(0.2)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Volume boost")
        .accessibilityValue(boosted ? "6 times" : "1 times")
    }

    private var deviceMenu: some View {
        let currentName = controller.devices.first { $0.id == controller.currentDevice }?.name ?? "No output device"
        return Menu {
            ForEach(controller.devices) { device in
                Button {
                    controller.selectDevice(device.id)
                } label: {
                    if device.id == controller.currentDevice {
                        Label(device.name, systemImage: "checkmark")
                    } else {
                        Text(device.name)
                    }
                }
            }
        } label: {
            Label(currentName, systemImage: "speaker.wave.2.fill")
        }
        .menuStyle(.borderlessButton)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel("Output device: \(currentName)")
    }

    private var panText: String {
        let percent = Int((abs(controller.pan) * 100).rounded())
        guard percent >= 3 else { return "Centre" }
        return controller.pan < 0 ? "L \(percent)" : "R \(percent)"
    }

    private var rotationText: String {
        let speed = controller.speed
        guard speed != 0 else { return "Stopped" }
        return String(format: "%@ %.1f s/turn", speed > 0 ? "↻" : "↺", 1 / abs(speed))
    }
}

/// "Master" or one app; nil selection is Master.
private struct AppTargetMenu: View {
    let targets: [AudioApp]
    @Binding var selection: String?

    var body: some View {
        Menu(targets.first { $0.id == selection }?.name ?? "Master") {
            Button("Master") { selection = nil }
            if !targets.isEmpty {
                Divider()
            }
            ForEach(targets) { app in
                Button(app.name) { selection = app.id }
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}

private struct MixPage: View {
    @ObservedObject var controller: MenuBarController
    @State private var presetName: String?
    @FocusState private var isNamingFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SpatialMapView(controller: controller)
            Divider()
            HStack {
                Text("EQ").font(.headline)
                AppTargetMenu(targets: controller.eqTargets, selection: $controller.eqTarget)
                presetsMenu
                Spacer()
                Toggle("RTA", isOn: $controller.isAnalyzerOn)
                    .toggleStyle(.button)
                Button("Flat") { controller.selectedEQ = EQSettings() }
                    .disabled(controller.selectedEQ.isFlat)
                Toggle("EQ", isOn: $controller.isEQOn)
                    .toggleStyle(PillSwitchStyle(onColor: .green))
            }
            if presetName != nil {
                saveRow
            }
            EQGraph(
                eq: $controller.selectedEQ,
                isOn: controller.isEQOn,
                spectrum: controller.spectrum,
                isAnalyzing: controller.isAnalyzerOn && controller.isRunning && controller.isPanelVisible
            )
                .frame(height: 200)
        }
    }
}

extension MixPage {
    private var presetsMenu: some View {
        Menu("Presets") {
            ForEach(controller.eqPresets) { preset in
                Button(preset.name) { controller.loadEQPreset(preset) }
            }
            if !controller.eqPresets.isEmpty {
                Divider()
            }
            Button("Save Current…") {
                presetName = ""
                isNamingFocused = true
            }
            if !controller.eqPresets.isEmpty {
                Menu("Delete") {
                    ForEach(controller.eqPresets) { preset in
                        Button(preset.name) { controller.deleteEQPreset(preset) }
                    }
                }
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private var saveRow: some View {
        HStack {
            TextField("Preset name", text: Binding(get: { presetName ?? "" }, set: { presetName = $0 }))
                .textFieldStyle(.roundedBorder)
                .focused($isNamingFocused)
                .onSubmit(save)
            Button("Cancel") { presetName = nil }
                .keyboardShortcut(.cancelAction)
            Button("Save", action: save)
                .keyboardShortcut(.defaultAction)
                .disabled((presetName ?? "").trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private func save() {
        guard let name = presetName, !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        controller.saveEQPreset(named: name)
        presetName = nil
    }
}

private struct AppFaders: View {
    @ObservedObject var controller: MenuBarController

    static let columnWidth: CGFloat = 44
    static let columnSpacing: CGFloat = 2

    var body: some View {
        if controller.audioApps.isEmpty {
            Text("No apps are playing sound.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 40)
        } else {
            ScrollView(.horizontal) {
                HStack(spacing: Self.columnSpacing) {
                    ForEach(controller.audioApps) { app in
                        column(for: app)
                    }
                }
            }
            .scrollIndicators(.automatic)
        }
    }

    private func column(for app: AudioApp) -> some View {
        let volume = controller.volume(for: app)
        let percent = "\(Int((volume * 100).rounded()))%"
        return VStack(spacing: 6) {
            Text(percent)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            VerticalFader(value: Binding(
                get: { controller.volume(for: app) },
                set: { controller.setVolume($0, for: app) }
            ))
            .frame(height: 110)
            Image(nsImage: app.icon)
                .resizable()
                .frame(width: 22, height: 22)
            Text(app.name)
                .font(.caption2)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(width: Self.columnWidth)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(app.name) volume")
        .accessibilityValue(percent)
        .accessibilityAdjustableAction { direction in
            let step: Float = direction == .increment ? 0.05 : -0.05
            controller.setVolume(min(max(volume + step, 0), 1), for: app)
        }
    }
}

struct VerticalFader: View {
    @Binding var value: Float

    static func value(atY y: CGFloat, height: CGFloat) -> Float {
        guard height > 0 else { return 0 }
        return Float(min(max(1 - y / height, 0), 1))
    }

    var body: some View {
        GeometryReader { geometry in
            let height = geometry.size.height
            let thumbY = height * CGFloat(1 - value)
            ZStack(alignment: .bottom) {
                Capsule()
                    .fill(Color.secondary.opacity(0.25))
                    .frame(width: 6)
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: 6, height: height - thumbY)
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color(white: 0.88))
                    .overlay(Rectangle().fill(Color.black.opacity(0.45)).frame(height: 1.5))
                    .shadow(color: .black.opacity(0.35), radius: 1.5, y: 1)
                    .frame(width: 26, height: 12)
                    .position(x: geometry.size.width / 2, y: min(max(thumbY, 6), height - 6))
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in value = Self.value(atY: drag.location.y, height: height) }
            )
            .simultaneousGesture(TapGesture(count: 2).onEnded { value = 1 })
        }
    }
}

// Native .switch tint is unreliable on macOS.
struct PillSwitchStyle: ToggleStyle {
    var onColor: Color
    var width: CGFloat = 40
    var height: CGFloat = 22

    func makeBody(configuration: Configuration) -> some View {
        PillSwitch(configuration: configuration, onColor: onColor, width: width, height: height)
    }
}

private struct PillSwitch: View {
    let configuration: ToggleStyleConfiguration
    let onColor: Color
    let width: CGFloat
    let height: CGFloat
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button { configuration.isOn.toggle() } label: {
            Capsule()
                .fill(configuration.isOn ? onColor : Color.secondary.opacity(0.3))
                .frame(width: width, height: height)
                .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                    Circle()
                        .fill(.white)
                        .shadow(color: .black.opacity(0.3), radius: 1, y: 0.5)
                        .padding(2)
                }
                .animation(.easeInOut(duration: 0.15), value: configuration.isOn)
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.4)
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
        }
    }
}

struct Knob: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    /// Arc grows from 12 o'clock both ways.
    var isBipolar = false
    let valueText: String
    var resetValue: Double?
    var diameter: CGFloat = 76

    private var scale: CGFloat { diameter / 76 }

    @State private var dragStartValue: Double?
    @Environment(\.isEnabled) private var isEnabled

    static let sweep = 0.75 // 270°
    static let dragPointsForFullRange = 200.0

    static func value(from start: Double, verticalTranslation: Double, in range: ClosedRange<Double>) -> Double {
        let span = range.upperBound - range.lowerBound
        let proposed = start - verticalTranslation / dragPointsForFullRange * span
        return min(max(proposed, range.lowerBound), range.upperBound)
    }

    private var fraction: Double {
        (value - range.lowerBound) / (range.upperBound - range.lowerBound)
    }

    var body: some View {
        VStack(spacing: 6) {
            dial
                .frame(width: diameter, height: diameter)
                .contentShape(Circle())
                .gesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { drag in
                            let start = dragStartValue ?? value
                            dragStartValue = start
                            value = Self.value(from: start, verticalTranslation: drag.translation.height, in: range)
                        }
                        .onEnded { _ in dragStartValue = nil }
                )
                .onTapGesture(count: 2) {
                    if let resetValue { value = resetValue }
                }
            Text(title).font(.caption).foregroundStyle(.secondary)
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(valueText).font(.caption.monospacedDigit())
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .opacity(isEnabled ? 1 : 0.4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(valueText)
        .accessibilityAdjustableAction { direction in
            let step = (range.upperBound - range.lowerBound) / 20
            let delta = direction == .increment ? step : -step
            value = min(max(value + delta, range.lowerBound), range.upperBound)
        }
    }

    private var dial: some View {
        let arcStart = isBipolar ? min(Self.sweep / 2, Self.sweep * fraction) : 0
        let arcEnd = isBipolar ? max(Self.sweep / 2, Self.sweep * fraction) : Self.sweep * fraction
        return ZStack {
            Circle()
                .trim(from: 0, to: Self.sweep)
                .stroke(Color.secondary.opacity(0.25), style: StrokeStyle(lineWidth: 5 * scale, lineCap: .round))
                .rotationEffect(.degrees(135))
            Circle()
                .trim(from: arcStart, to: arcEnd)
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 5 * scale, lineCap: .round))
                .rotationEffect(.degrees(135))
            Circle()
                .fill(Color(nsColor: .controlColor))
                .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                .padding(11 * scale)
            Capsule()
                .fill(Color.primary)
                .frame(width: max(2, 3 * scale), height: 12 * scale)
                .offset(y: -18 * scale)
                .rotationEffect(.degrees(-135 + 270 * fraction))
        }
    }
}
