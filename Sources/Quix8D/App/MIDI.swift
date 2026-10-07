import CoreMIDI
import Foundation

/// What a binding listens for: one CC or note number on one channel, from any device.
struct MIDITrigger: Hashable, Codable {
    enum Kind: String, Codable { case controlChange, note }
    var kind: Kind
    var channel: UInt8 // 0...15
    var number: UInt8

    var label: String {
        (kind == .note ? "Note \(number)" : "CC \(number)") + (channel == 0 ? "" : " ch\(channel + 1)")
    }
}

/// A CC (value 0...127) or note-on (value = velocity).
struct MIDIMessage: Equatable {
    var trigger: MIDITrigger
    var value: UInt8

    /// Calls `body` for each CC and note-on in MIDI 1.0 UMP words. Note-offs
    /// (including note-on at velocity 0) and all other messages are skipped.
    static func parse<Words: RandomAccessCollection>(_ words: Words, _ body: (MIDIMessage) -> Void)
    where Words.Element == UInt32, Words.Index == Int {
        var index = words.startIndex
        while index < words.endIndex {
            let word = words[index]
            let type = Int(word >> 28)
            index += wordCounts[type]
            guard type == 0x2 else { continue } // MIDI 1.0 channel voice
            let status = UInt8(truncatingIfNeeded: word >> 16) & 0xF0
            let channel = UInt8(truncatingIfNeeded: word >> 16) & 0x0F
            let number = UInt8(truncatingIfNeeded: word >> 8) & 0x7F
            let value = UInt8(truncatingIfNeeded: word) & 0x7F
            switch status {
            case 0xB0: body(MIDIMessage(trigger: MIDITrigger(kind: .controlChange, channel: channel, number: number), value: value))
            case 0x90 where value > 0: body(MIDIMessage(trigger: MIDITrigger(kind: .note, channel: channel, number: number), value: value))
            default: break
            }
        }
    }

    /// UMP length in words, by message type (the top nibble).
    private static let wordCounts = [1, 1, 1, 2, 2, 4, 1, 1, 2, 2, 2, 3, 3, 4, 4, 4]
}

enum EffectSwitch: String, Codable, CaseIterable {
    case reverb, compressor, delay, widener, bass, chorus

    var isOn: WritableKeyPath<EffectsSettings, Bool> {
        switch self {
        case .reverb: \.reverb.isOn
        case .compressor: \.compressor.isOn
        case .delay: \.delay.isOn
        case .widener: \.widener.isOn
        case .bass: \.bassEnhancer.isOn
        case .chorus: \.chorus.isOn
        }
    }
}

/// A panel control MIDI can drive. Continuous ones follow CC values; the rest
/// toggle on note-on or a button CC press (value >= 64).
enum MIDIControl: Hashable, Codable {
    case rotation, pan, volume, appVolume(String)
    case boost // CC: >= 64 is 6x. Note-on toggles.
    case eightD, effects, eq, analyzer, effect(EffectSwitch)

    var isContinuous: Bool {
        switch self {
        case .rotation, .pan, .volume, .appVolume: true
        default: false
        }
    }

    var name: String {
        switch self {
        case .rotation: "Rotation"
        case .pan: "Pan"
        case .volume: "Volume"
        case .appVolume(let id): AudioApp(id: id).name
        case .boost: "Boost"
        case .eightD: "8D Audio"
        case .effects: "Effects"
        case .eq: "EQ"
        case .analyzer: "RTA"
        case .effect(let effect): effect.rawValue.capitalized
        }
    }
}

struct MIDIBinding: Codable, Equatable {
    var trigger: MIDITrigger
    var control: MIDIControl
}

enum MIDIBindings {
    static let storeKey = "midiBindings"

    /// General MIDI's volume and pan CCs on channel 1; used until the user saves a mapping.
    static let builtIn = [
        MIDIBinding(trigger: MIDITrigger(kind: .controlChange, channel: 0, number: 7), control: .volume),
        MIDIBinding(trigger: MIDITrigger(kind: .controlChange, channel: 0, number: 10), control: .pan),
    ]

    static func load(from defaults: UserDefaults = .standard) -> [MIDIBinding] {
        guard let data = defaults.data(forKey: storeKey) else { return builtIn }
        return (try? JSONDecoder().decode([MIDIBinding].self, from: data)) ?? builtIn
    }

    static func save(_ bindings: [MIDIBinding], to defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(bindings) {
            defaults.set(data, forKey: storeKey)
        }
    }
}

/// Listens to every MIDI source, including ones plugged in later.
/// `onMessage` runs on the main queue.
final class MIDIInput {
    private var client = MIDIClientRef()
    private var port = MIDIPortRef()
    private var sources: [MIDIEndpointRef] = []

    /// Call on the main thread: setup-change notifications arrive on this run loop.
    init(onMessage: @escaping (MIDIMessage) -> Void) {
        MIDIClientCreateWithBlock("Quix8D" as CFString, &client) { [weak self] notification in
            if notification.pointee.messageID == .msgSetupChanged { self?.connectSources() }
        }
        // CoreMIDI's thread: parse here, touch app state only on main.
        MIDIInputPortCreateWithProtocol(client, "Quix8D Input" as CFString, ._1_0, &port) { list, _ in
            for packet in list.unsafeSequence() {
                MIDIMessage.parse(packet.words()) { message in
                    DispatchQueue.main.async { onMessage(message) }
                }
            }
        }
        connectSources()
    }

    deinit {
        MIDIClientDispose(client)
    }

    private func connectSources() {
        sources.forEach { MIDIPortDisconnectSource(port, $0) }
        sources = (0..<MIDIGetNumberOfSources()).map(MIDIGetSource)
        sources.forEach { MIDIPortConnectSource(port, $0, nil) }
    }
}
