// PentoniqMIDILearn.swift  (milestone 9: MIDI Learn)
// Add to the EXTENSION target only.
//
// How it works:
//   1. Press MIDI LEARN (header). It lights like the M buttons and every learnable slider gets a
//      faint yellow outline (sliders that already have a CC show it, e.g. "CC 74", instead of their value).
//   2. Click a slider (or the WHEEL knob). It glows yellow and the audio unit starts listening.
//      While listening, incoming CCs do NOT move anything.
//   3. Move a knob on your keyboard. The first CC that arrives is assigned to that slider, the slider
//      flashes, and learn mode ends.
//   Option-click a slider in learn mode to clear its assignment. Pressing MIDI LEARN again cancels.
//
// One CC drives one slider, and one slider has one CC: assigning replaces any earlier link.
// The map lives in UserDefaults (the user's preferences), NOT in the Logic project, and the audio
// unit loads it itself, so it works even when the plug-in window has never been opened.
// A new instance (or a re-allocated one) picks up changes made in another instance.
//
// Only Control Change messages can be learned. (Pitch bend is a different MIDI message.)

import SwiftUI
import Combine
import AppKit
import AudioToolbox

// MARK: - Storage (UserDefaults, not per project)

enum MIDIMapStore {
    static let key = "pentoniq.midiMap.v1"

    /// CC number -> parameter identifier.
    static func load() -> [Int: String] {
        let raw = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
        var map: [Int: String] = [:]
        for (text, identifier) in raw {
            if let cc = Int(text) { map[cc] = identifier }
        }
        return map
    }

    static func save(_ map: [Int: String]) {
        var raw: [String: String] = [:]
        for (cc, identifier) in map { raw[String(cc)] = identifier }
        UserDefaults.standard.set(raw, forKey: key)
    }
}

// MARK: - Link between the view and the kernel

/// The few kernel calls the learn UI needs. The audio unit builds one (see `midiLearnLink`).
struct MIDILearnLink {
    /// (CC number, parameter index). Parameter index -1 clears the CC.
    var setMapping: (Int, Int) -> Void = { _, _ in }
    /// While true the kernel records CCs but acts on none of them.
    var setListening: (Bool) -> Void = { _ in }
    /// How many CCs have arrived so far (wraps) and the number of the latest one.
    var lastCC: () -> (count: UInt32, cc: Int) = { (0, 0) }
    /// Reads a parameter straight from the audio unit's own storage (parameter index -> value).
    /// The UI poll uses it, so changes made by MIDI show up on screen.
    var readParameter: ((Int) -> Float)? = nil
}

// MARK: - Controller

final class LearnController: ObservableObject {

    enum Phase { case off, pickControl, listening }

    @Published private(set) var phase: Phase = .off
    /// CC number -> parameter identifier, as stored.
    @Published private(set) var assignments: [Int: String] = MIDIMapStore.load()
    @Published private(set) var targetID: String? = nil
    @Published private(set) var flashID: String? = nil

    private let link: MIDILearnLink
    private var target: ObservedParameter?
    private var baseline: UInt32 = 0

    init(link: MIDILearnLink) {
        self.link = link
    }

    deinit {
        link.setListening(false)
    }

    var isActive: Bool { phase != .off }

    var prompt: String {
        switch phase {
        case .off: return ""
        case .pickControl: return "CLICK A SLIDER"
        case .listening: return "MOVE A MIDI KNOB"
        }
    }

    /// The MIDI LEARN button: starts, or cancels.
    func toggle() {
        if phase == .off {
            assignments = MIDIMapStore.load()
            phase = .pickControl
        } else {
            cancel()
        }
    }

    func cancel() {
        link.setListening(false)
        target = nil
        targetID = nil
        phase = .off
    }

    /// A learnable control was clicked while learn mode is on.
    func select(_ parameter: ObservedParameter) {
        guard phase != .off else { return }
        if NSEvent.modifierFlags.contains(.option) {
            clear(parameter)
            return
        }
        target = parameter
        targetID = parameter.parameter.identifier
        baseline = link.lastCC().count
        link.setListening(true)
        phase = .listening
    }

    /// Called about 30 times a second by the view: has a CC arrived?
    func poll() {
        guard phase == .listening, let parameter = target else { return }
        let latest = link.lastCC()
        guard latest.count != baseline else { return }
        assign(cc: latest.cc, to: parameter)
    }

    // MARK: Looking things up (for drawing)

    func isGlowing(_ parameter: ObservedParameter) -> Bool {
        let identifier = parameter.parameter.identifier
        return (phase == .listening && targetID == identifier) || flashID == identifier
    }

    func ccLabel(for parameter: ObservedParameter) -> String? {
        let identifier = parameter.parameter.identifier
        guard let entry = assignments.first(where: { $0.value == identifier }) else { return nil }
        return "CC \(entry.key)"
    }

    // MARK: Changing the map

    private func assign(cc: Int, to parameter: ObservedParameter) {
        let identifier = parameter.parameter.identifier
        var map = MIDIMapStore.load()
        for (existingCC, existingID) in map where existingID == identifier {
            map[existingCC] = nil
            link.setMapping(existingCC, -1)
        }
        map[cc] = identifier                       // replaces whatever this CC used to drive
        MIDIMapStore.save(map)
        link.setMapping(cc, Int(parameter.parameter.address))
        assignments = map

        link.setListening(false)
        target = nil
        targetID = nil
        phase = .off
        flash(identifier)
    }

    private func clear(_ parameter: ObservedParameter) {
        let identifier = parameter.parameter.identifier
        var map = MIDIMapStore.load()
        for (existingCC, existingID) in map where existingID == identifier {
            map[existingCC] = nil
            link.setMapping(existingCC, -1)
        }
        MIDIMapStore.save(map)
        assignments = map
        flash(identifier)
    }

    private func flash(_ identifier: String) {
        flashID = identifier
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            if self?.flashID == identifier { self?.flashID = nil }
        }
    }
}

// MARK: - Header button

/// "MIDI 🔗": red text in a thin red rectangle that lights up like the M buttons when learn is on.
/// A short yellow prompt appears beside it while learn mode is active.
struct MIDILearnButton: View {
    @ObservedObject var learn: LearnController

    var body: some View {
        HStack(spacing: 8) {
            if learn.isActive {
                Text(learn.prompt)
                    .font(.system(size: 9, weight: .bold))
                    .tracking(1.0)
                    .foregroundStyle(Panel.yellow)
            }
            Button { learn.toggle() } label: { Text("MIDI 🔗") }
                .buttonStyle(PadStyle(colour: Panel.red, lit: learn.isActive, width: 68,
                                      restFill: 0, restText: Panel.red, padHeight: 22))
                .help("MIDI Learn: click a slider, then move a knob on your keyboard. Option-click a slider to clear it.")
        }
    }
}
