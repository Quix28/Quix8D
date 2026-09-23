import AppKit
import CoreAudio
import SwiftUI

func startStopButtonState(isRunning: Bool, isStarting: Bool, osSupported: Bool) -> (title: String, enabled: Bool) {
    guard osSupported else { return ("Start", false) }
    if isStarting { return ("Starting…", false) }
    return (isRunning ? "Stop" : "Start", true)
}

// start() runs off main: it can block on a TCC prompt. After the 10 s timeout
// the switch stays disabled so a second start() can't race the pending one.
final class MenuBarController: ObservableObject {
    // Rotations per second at the knob's ends.
    static let maxSpeed = 0.5
    // Snap-to-zero zone so stop is easy to hit.
    private static let stopZone = 0.03
    static let boostGain: Float = 6

    let osSupported = PermissionsGate.isOSVersionSupported(ProcessInfo.processInfo.operatingSystemVersion)

    enum Page { case main, mix, effects }
    @Published var page: Page = .main {
        didSet { updateAnalyzerFeed() }
    }
    /// The panel's view outlives the popover; its timers check this.
    @Published private(set) var isPanelVisible = false {
        didSet { updateAnalyzerFeed() }
    }

    // Playing now, plus custom-volume apps so paused ones can be turned back up.
    @Published private(set) var audioApps: [AudioApp] = []
    @Published private(set) var appVolumes: [String: Float] = [:]

    @Published var eq = EQSettings() {
        didSet { eqChanged() }
    }
    @Published var isEQOn = true {
        didSet { eqChanged() }
    }
    @Published private(set) var eqPresets = EQPresetStore.load()

    /// App whose EQ the graph edits; nil is the master EQ.
    @Published var eqTarget: String?
    // Flat app EQs are dropped, so this only holds apps with a real EQ.
    @Published private(set) var appEQs: [String: EQSettings] = [:]

    var selectedEQ: EQSettings {
        get { eqTarget.map { appEQs[$0] ?? EQSettings() } ?? eq }
        set {
            guard let target = eqTarget else { eq = newValue; return }
            appEQs[target] = newValue.isFlat ? nil : newValue
            pipeline.setAppEQs(appEQs)
            syncPipeline()
        }
    }

    var eqTargets: [AudioApp] { appTargets(with: Set(appEQs.keys), selected: eqTarget) }

    /// Apps playing, plus ones with their own settings or currently selected.
    private func appTargets(with configured: Set<String>, selected: String?) -> [AudioApp] {
        let extra = configured.union(selected.map { [$0] } ?? []).filter { id in !audioApps.contains { $0.id == id } }
        let idle = extra.map { knownApps[$0] ?? AudioApp(id: $0) }
        return (audioApps + idle).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func saveEQPreset(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        eqPresets = EQPresetStore.upserting(EQPreset(name: trimmed, settings: selectedEQ), into: eqPresets)
        EQPresetStore.save(eqPresets)
    }

    func loadEQPreset(_ preset: EQPreset) {
        selectedEQ = preset.settings
    }

    func deleteEQPreset(_ preset: EQPreset) {
        eqPresets.removeAll { $0 == preset }
        EQPresetStore.save(eqPresets)
    }

    @Published var isAnalyzerOn = false {
        didSet {
            updateAnalyzerFeed()
            syncPipeline()
        }
    }

    // The RTA lives on the Mix page; don't copy samples nobody will see.
    private func updateAnalyzerFeed() {
        pipeline.isAnalyzerOn = isAnalyzerOn && isPanelVisible && page == .mix
    }
    private let analyzer = SpectrumAnalyzer()

    // dBFS per bin; nil when not capturing.
    func spectrum() -> (db: [Float], binHz: Double)? {
        guard isRunning, isAnalyzerOn else { return nil }
        let snapshot = pipeline.analyzerSnapshot()
        return (analyzer.update(with: snapshot.samples), snapshot.sampleRate / Double(SpectrumAnalyzer.size))
    }
    private var knownApps: [String: AudioApp] = [:]

    @Published private(set) var isRunning = false
    @Published private(set) var isStarting = false
    @Published private(set) var volume: Float = 0
    @Published private(set) var isVolumeAdjustable = false
    @Published private(set) var devices: [OutputDevices.Device] = []
    @Published private(set) var currentDevice: AudioDeviceID?

    @Published var is8DOn = false {
        didSet { syncPipeline() }
    }
    @Published var effectsOn = true {
        didSet { syncPipeline() }
    }
    @Published var isBoosted = false {
        didSet {
            pipeline.boost = isBoosted ? Self.boostGain : 1
            syncPipeline()
        }
    }
    @Published private(set) var appPositions = SpatialMap.load()

    var placedApps: [AudioApp] {
        appPositions.keys.map { knownApps[$0] ?? AudioApp(id: $0) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func position(for app: AudioApp) -> AppPosition? { appPositions[app.id] }

    /// nil removes. Pass `commit: false` while dragging: sound follows, no save/refresh.
    func setPosition(_ position: AppPosition?, for app: AudioApp, commit: Bool = true) {
        knownApps[app.id] = app
        appPositions[app.id] = position
        syncPipeline()
        guard commit else { return }
        SpatialMap.save(appPositions)
        refreshAudioApps()
    }

    @Published var effects = EffectsSettings() {
        didSet { syncPipeline() }
    }

    /// App whose effects the Effects page edits; nil is the master chain.
    @Published var effectsTarget: String?
    // Default settings are dropped, so this only holds apps with changes.
    @Published private(set) var appEffects: [String: EffectsSettings] = [:]

    var selectedEffects: EffectsSettings {
        get { effectsTarget.map { appEffects[$0] ?? EffectsSettings() } ?? effects }
        set {
            guard let target = effectsTarget else { effects = newValue; return }
            appEffects[target] = newValue == EffectsSettings() ? nil : newValue
            pipeline.setAppEffects(appEffects)
            syncPipeline()
        }
    }

    var effectsTargets: [AudioApp] { appTargets(with: Set(appEffects.keys), selected: effectsTarget) }

    @Published var pan: Double = 0 {
        didSet {
            pipeline.pan = Float(abs(pan) < Self.stopZone ? 0 : pan)
            syncPipeline()
        }
    }
    @Published var speed: Double {
        didSet { pipeline.speed = abs(speed) < Self.stopZone ? 0 : speed }
    }

    private let pipeline = AudioPipeline()
    private let systemVolume = SystemVolume()
    private let outputDevices = OutputDevices()
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    // Popover re-anchors on resize; with an auto-hiding menu bar the real
    // button is off screen by then, flinging the popover top-left.
    private let popoverAnchor: NSWindow = {
        let window = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: true)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.ignoresMouseEvents = true
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        return window
    }()
    private var popoverClosedAt: Date?
    private var pendingTimeout: DispatchWorkItem?

    init() {
        speed = pipeline.speed

        systemVolume.onChange = { [weak self] volume in
            guard let self else { return }
            self.volume = volume
            self.isVolumeAdjustable = self.systemVolume.isAdjustable
        }
        volume = systemVolume.volume ?? 0
        isVolumeAdjustable = systemVolume.isAdjustable

        outputDevices.onChange = { [weak self] in self?.refreshDevices() }
        devices = outputDevices.all
        currentDevice = outputDevices.current

        let hosting = NSHostingController(rootView: ControlPanelView(controller: self))
        hosting.sizingOptions = .preferredContentSize
        popover.contentViewController = hosting
        popover.behavior = .transient
        NotificationCenter.default.addObserver(forName: NSPopover.didCloseNotification, object: popover, queue: .main) { [weak self] _ in
            self?.popoverAnchor.orderOut(nil)
            self?.isPanelVisible = false
            self?.popoverClosedAt = Date()
        }

        if let icon = NSImage(named: "MenuBarIcon") {
            icon.isTemplate = true
            statusItem.button?.image = icon
        } else {
            statusItem.button?.title = "Quix8D"
        }
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        // Saved positions should sound placed at launch.
        if !appPositions.isEmpty { syncPipeline() }
    }

    @objc private func togglePopover() {
        // Transient popover already closed on this mouse-down; keep it closed.
        if let closedAt = popoverClosedAt, Date().timeIntervalSince(closedAt) < 0.3 { return }
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        guard let button = statusItem.button, let buttonWindow = button.window,
              let anchorView = popoverAnchor.contentView
        else { return }
        popoverAnchor.setFrame(buttonWindow.convertToScreen(button.convert(button.bounds, to: nil)), display: false)
        popoverAnchor.orderFront(nil)
        isPanelVisible = true
        popover.show(relativeTo: anchorView.bounds, of: anchorView, preferredEdge: .minY)
        NSApp.activate()
    }

    func setVolume(_ newValue: Float) {
        volume = newValue
        systemVolume.setVolume(newValue)
    }

    func refreshAudioApps() {
        let playing = AudioApps.current().map(\.app)
        playing.forEach { knownApps[$0.id] = $0 }
        let adjustedIdle = knownApps.values.filter { app in
            !playing.contains(app) && ((appVolumes[app.id] ?? 1) != 1 || appPositions[app.id] != nil || appEQs[app.id] != nil || appEffects[app.id] != nil)
        }
        let apps = (playing + adjustedIdle).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if apps != audioApps { audioApps = apps }
    }

    func volume(for app: AudioApp) -> Float {
        appVolumes[app.id] ?? 1
    }

    func setVolume(_ volume: Float, for app: AudioApp) {
        appVolumes[app.id] = volume
        pipeline.setAppVolumes(appVolumes)
        syncPipeline()
    }

    private func eqChanged() {
        pipeline.setEQ(eq, enabled: isEQOn)
        syncPipeline()
    }

    func selectDevice(_ device: AudioDeviceID) {
        outputDevices.select(device) // refreshDevices() follows via the listener
    }

    private func refreshDevices() {
        devices = outputDevices.all
        let newDevice = outputDevices.current
        guard newDevice != currentDevice else { return }
        currentDevice = newDevice
        // Running aggregate still targets the old device.
        guard isRunning else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                try self?.pipeline.restart()
            } catch {
                DispatchQueue.main.async { self?.handleStartResult(.failure(error)) }
            }
        }
    }

    private func syncPipeline() {
        pipeline.isBypassed = !(is8DOn && effectsOn)
        pipeline.setEffects(effects, enabled: effectsOn)
        pipeline.setAppPositions(appPositions, enabled: effectsOn)
        let hasCustomAppVolume = appVolumes.values.contains { $0 != 1 }
        let hasEQ = isEQOn && (!eq.isFlat || !appEQs.isEmpty)
        if is8DOn || isBoosted || hasCustomAppVolume || hasEQ || isAnalyzerOn || pipeline.pan != 0
            || (effectsOn && (effects.anyOn || appEffects.values.contains(where: \.anyOn) || !appPositions.isEmpty)) {
            start()
        } else if isRunning {
            pipeline.stop()
            isRunning = false
        }
    }

    private func start() {
        guard !isRunning, !isStarting, osSupported else { return }
        isStarting = true

        let speed = pipeline.speed
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                try self?.pipeline.start(speed: speed)
                DispatchQueue.main.async { self?.handleStartResult(.success(())) }
            } catch {
                DispatchQueue.main.async { self?.handleStartResult(.failure(error)) }
            }
        }

        let timeout = DispatchWorkItem { [weak self] in self?.handleStartTimeout() }
        pendingTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: timeout)
    }

    private func handleStartResult(_ result: Result<Void, Swift.Error>) {
        pendingTimeout?.cancel()
        pendingTimeout = nil
        isStarting = false
        switch result {
        case .success:
            isRunning = true
            syncPipeline() // switched off while starting?
        case .failure(let error):
            isRunning = false
            is8DOn = false
            isBoosted = false
            showAlert("Couldn't start Quix8D: \(error)")
        }
    }

    private func handleStartTimeout() {
        showAlert("Still waiting for the system audio-capture permission prompt. Grant it in System Settings > Privacy & Security > Audio Recording, or quit and relaunch by double-clicking the app in Finder — the prompt doesn't route to a Terminal- or IDE-launched process.")
    }

    @Published private(set) var isCheckingForUpdates = false

    func checkForUpdates() {
        isCheckingForUpdates = true
        Task { @MainActor in
            defer { isCheckingForUpdates = false }
            do {
                let release = try await Updater.latestRelease()
                let current = Updater.currentVersion
                guard Updater.isNewer(release.version, than: current) else {
                    showAlert("You're up to date (version \(current)).")
                    return
                }
                guard confirm("Quix8D \(release.version) is available. You have \(current).", action: "Install and Restart") else { return }
                showStatus("0%")
                try await Updater.install(release) { [weak self] fraction in
                    self?.showStatus(fraction < 1 ? "\(Int(fraction * 100))%" : "Installing…")
                }
                Updater.relaunch()
                quit()
            } catch {
                showStatus(nil)
                showAlert("Update failed: \(error.localizedDescription)")
            }
        }
    }

    /// Text next to the menu bar icon; nil clears it.
    private func showStatus(_ text: String?) {
        guard let button = statusItem.button, button.image != nil else { return }
        button.title = text.map { " \($0)" } ?? ""
        button.imagePosition = text == nil ? .imageOnly : .imageLeading
    }

    private func confirm(_ message: String, action: String) -> Bool {
        popover.performClose(nil)
        let alert = NSAlert()
        alert.messageText = "Quix8D"
        alert.informativeText = message
        alert.addButton(withTitle: action)
        alert.addButton(withTitle: "Later")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func showAlert(_ message: String) {
        popover.performClose(nil)
        let alert = NSAlert()
        alert.messageText = "Quix8D"
        alert.informativeText = message
        alert.runModal()
    }

    func quit() {
        if isRunning {
            pipeline.stop()
        }
        NSApplication.shared.terminate(nil)
    }
}
