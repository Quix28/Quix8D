import XCTest
@testable import Quix8D

final class MIDIParsingTests: XCTestCase {
    private func parse(_ words: [UInt32]) -> [MIDIMessage] {
        var messages: [MIDIMessage] = []
        MIDIMessage.parse(words) { messages.append($0) }
        return messages
    }

    func testParsesControlChangeAndNoteOn() {
        XCTAssertEqual(parse([0x20B0_0764, 0x2091_3C64]), [
            MIDIMessage(trigger: MIDITrigger(kind: .controlChange, channel: 0, number: 7), value: 100),
            MIDIMessage(trigger: MIDITrigger(kind: .note, channel: 1, number: 60), value: 100),
        ])
    }

    func testSkipsNoteOffsAndOtherMessages() {
        XCTAssertEqual(parse([
            0x2090_3C00, // note-on, velocity 0
            0x2080_3C40, // note-off
            0x20E0_0040, // pitch bend
            0x10F8_0000, // clock
            0x3016_7E7F, 0x20B0_0764, // two-word SysEx whose data looks like a CC
        ]), [])
    }
}

final class MIDIControlTests: XCTestCase {
    private var store: UserDefaults!
    private var suiteName = ""

    override func setUp() {
        suiteName = "Quix8DTests.MIDI.\(UUID())"
        store = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        store.removePersistentDomain(forName: suiteName)
    }

    private func cc(_ number: UInt8, _ value: UInt8, channel: UInt8 = 0) -> MIDIMessage {
        MIDIMessage(trigger: MIDITrigger(kind: .controlChange, channel: channel, number: number), value: value)
    }

    private func note(_ number: UInt8) -> MIDIMessage {
        MIDIMessage(trigger: MIDITrigger(kind: .note, channel: 0, number: number), value: 100)
    }

    /// Running, so the 8D switch is enabled, and with a fake pipeline: nothing touches real audio.
    private func makeController() -> MenuBarController {
        let controller = MenuBarController(pipeline: CountingPipeline(), midiDefaults: store)
        controller.startAndWait()
        return controller
    }

    private func learn(_ control: MIDIControl, _ message: MIDIMessage, on controller: MenuBarController) {
        controller.midiLearnTarget = control
        controller.handleMIDI(message)
    }

    func testCCValuesSetContinuousControls() {
        let controller = makeController()
        controller.handleMIDI(cc(10, 0))
        XCTAssertEqual(controller.pan, -1, "built-in CC 10 is pan")
        controller.handleMIDI(cc(10, 127))
        XCTAssertEqual(controller.pan, 1)

        learn(.rotation, cc(20, 0), on: controller)
        XCTAssertNil(controller.midiLearnTarget)
        controller.handleMIDI(cc(20, 127))
        XCTAssertEqual(controller.speed, MenuBarController.maxSpeed, accuracy: 1e-9)
        controller.handleMIDI(cc(20, 0))
        XCTAssertEqual(controller.speed, -MenuBarController.maxSpeed, accuracy: 1e-9)

        let app = AudioApp(id: "tone")
        learn(.appVolume(app.id), cc(21, 0), on: controller)
        controller.handleMIDI(cc(21, 127))
        XCTAssertEqual(controller.volume(for: app), 1)
        controller.handleMIDI(cc(21, 64))
        XCTAssertEqual(controller.volume(for: app), FaderTaper.gain(atPosition: 64 / 127), accuracy: 1e-6)
        controller.handleMIDI(cc(21, 0))
        XCTAssertEqual(controller.volume(for: app), 0)

        learn(.boost, cc(22, 0), on: controller)
        controller.handleMIDI(cc(22, 100))
        XCTAssertTrue(controller.isBoosted)
        controller.handleMIDI(cc(22, 10))
        XCTAssertFalse(controller.isBoosted)

        controller.handleMIDI(cc(20, 64, channel: 1))
        XCTAssertEqual(controller.speed, -MenuBarController.maxSpeed, accuracy: 1e-9, "other channel is unbound")
    }

    func testNoteOnAndButtonPressToggle() {
        let controller = makeController()
        learn(.eightD, note(60), on: controller)
        XCTAssertFalse(controller.is8DOn, "learning doesn't also toggle")
        controller.handleMIDI(note(60))
        XCTAssertTrue(controller.is8DOn)
        controller.handleMIDI(note(60))
        XCTAssertFalse(controller.is8DOn)

        learn(.effect(.reverb), cc(30, 127), on: controller)
        controller.handleMIDI(cc(30, 127))
        XCTAssertTrue(controller.effects.reverb.isOn)
        controller.handleMIDI(cc(30, 0))
        XCTAssertTrue(controller.effects.reverb.isOn, "button release does nothing")
        controller.handleMIDI(cc(30, 127))
        XCTAssertFalse(controller.effects.reverb.isOn)

        learn(.eq, note(61), on: controller)
        controller.handleMIDI(note(61))
        XCTAssertFalse(controller.isEQOn)
    }

    func testLearnRejectsKeysForKnobsAndReplacesOldBindings() {
        let controller = makeController()
        learn(.rotation, note(60), on: controller)
        XCTAssertEqual(controller.midiLearnTarget, .rotation, "still waiting for a CC")
        controller.handleMIDI(cc(20, 0))
        controller.handleMIDI(cc(10, 0)) // pan's built-in CC
        learn(.rotation, cc(10, 0), on: controller)
        XCTAssertEqual(controller.midiTrigger(for: .rotation), cc(10, 0).trigger)
        XCTAssertNil(controller.midiTrigger(for: .pan), "the CC moved from pan to rotation")
        XCTAssertEqual(controller.midiBindings.filter { $0.control == .rotation }.count, 1)
    }

    func testBindingsSurviveRelaunchAndClear() {
        XCTAssertEqual(MIDIBindings.load(from: store), MIDIBindings.builtIn, "fresh install gets the built-ins")

        let controller = makeController()
        learn(.effect(.chorus), note(62), on: controller)
        learn(.appVolume("/Applications/Spotify.app"), cc(21, 0), on: controller)
        let relaunched = MenuBarController(pipeline: CountingPipeline(), midiDefaults: store)
        XCTAssertEqual(relaunched.midiBindings, controller.midiBindings)
        XCTAssertEqual(relaunched.midiTrigger(for: .effect(.chorus)), note(62).trigger)

        relaunched.clearMIDIBindings()
        XCTAssertEqual(MIDIBindings.load(from: store), [], "cleared stays cleared")
    }
}
