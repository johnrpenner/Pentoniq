// PentoniqPresets.swift  (v0.7, milestone 8: Voice I + II presets, CS-80 style Tone Selector)
// Add this file to the EXTENSION target only.
//
// What is here:
//   PentoniqDefaults    UserDefaults settings: default oversampling, 432 Hz tuning flag (stored only,
//                       used from milestone 10), default bank name (not used yet).
//   PresetStore         the 24 preset slots (12 for Voice I, 12 for Voice II) in UserDefaults.
//   PresetController    M (store), slot (recall) and RAND logic, plus which pad is lit.
//   PresetBlock         the two rows of pads that go in the third row of the panel.
//
// A preset holds the 22 per-voice controls of ONE voice: everything in
// PentoniqParameters.voiceIIPairs except Oversampling. It never holds the global MIX / RES /
// BRILLIANCE / MASTER controls or anything from the third row. Slots are saved by parameter
// identifier (the Voice I identifier, for both voices), so adding parameters later does not
// break saved slots, and a slot made on Voice I is the same format as one made on Voice II.

import SwiftUI
import Combine
import AudioToolbox

// MARK: - UserDefaults settings

enum PentoniqDefaults {
    static let presetsKey = "pentoniq.presets.v1"
    static let oversamplingKey = "pentoniq.defaultOversampling"
    static let tuning432Key = "pentoniq.tuning432"
    static let bankKey = "pentoniq.defaultBank"

    /// Oversampling index for new instances: 0 = Off, 1 = 2x, 2 = 4x (the default).
    static var defaultOversampling: Int {
        get {
            guard let value = UserDefaults.standard.object(forKey: oversamplingKey) as? Int else { return 2 }
            return min(max(value, 0), 2)
        }
        set { UserDefaults.standard.set(min(max(newValue, 0), 2), forKey: oversamplingKey) }
    }

    /// 432 Hz tuning. Stored now; it has no effect until milestone 10.
    static var tuning432: Bool {
        get { UserDefaults.standard.bool(forKey: tuning432Key) }
        set { UserDefaults.standard.set(newValue, forKey: tuning432Key) }
    }

    /// Name of the default preset bank. Stored now; nothing reads it yet.
    static var defaultBank: String {
        get { UserDefaults.standard.string(forKey: bankKey) ?? "Factory" }
        set { UserDefaults.standard.set(newValue, forKey: bankKey) }
    }
}

// MARK: - Slot storage

/// voice: 0 = Voice I, 1 = Voice II. slot: 1...12. Each call reads UserDefaults afresh, so several
/// plug-in instances stay in step (the last save wins).
enum PresetStore {
    static func key(voice: Int, slot: Int) -> String {
        (voice == 0 ? "I" : "II") + "-" + String(slot)
    }

    private static func bank() -> [String: [String: Double]] {
        UserDefaults.standard.dictionary(forKey: PentoniqDefaults.presetsKey) as? [String: [String: Double]] ?? [:]
    }

    /// nil = empty slot.
    static func load(voice: Int, slot: Int) -> [String: Double]? {
        bank()[key(voice: voice, slot: slot)]
    }

    static func save(_ values: [String: Double], voice: Int, slot: Int) {
        var all = bank()
        all[key(voice: voice, slot: slot)] = values
        UserDefaults.standard.set(all, forKey: PentoniqDefaults.presetsKey)
    }
}

// MARK: - Controller

final class PresetController: ObservableObject {

    /// The lit pad (1...12) for [Voice I, Voice II], or nil. Clears when the sound stops matching.
    @Published private(set) var lit: [Int?] = [nil, nil]
    /// M is armed (waiting for a pad to store into) for [Voice I, Voice II].
    @Published private(set) var armed: [Bool] = [false, false]

    private struct Entry {
        let base: ParamID
        let identifier: String
        let spec: ParameterSpec
        let param: ObservedParameter
    }

    private let entries: [[Entry]]
    /// What the controls should read while a pad is lit, in `entries` order.
    private var expected: [[Double]] = [[], []]
    private var subscriptions: [AnyCancellable] = []

    init(voice1: VoiceModel, voice2: VoiceModel) {
        entries = [PresetController.makeEntries(voice1), PresetController.makeEntries(voice2)]
        for (index, voice) in [voice1, voice2].enumerated() {
            // objectWillChange fires BEFORE the value changes, so look again on the next main-queue turn.
            voice.objectWillChange
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.checkStillMatches(index) }
                .store(in: &subscriptions)
        }
    }

    /// VoiceModel.all is in the order of PentoniqParameters.voiceIIPairs. Oversampling is left out.
    private static func makeEntries(_ voice: VoiceModel) -> [Entry] {
        var result: [Entry] = []
        for (pair, param) in zip(PentoniqParameters.voiceIIPairs, voice.all) where pair.base != .oversampling {
            guard let spec = PentoniqParameters.specs.first(where: { $0.id == pair.base }) else { continue }
            result.append(Entry(base: pair.base, identifier: spec.identifier, spec: spec, param: param))
        }
        return result
    }

    // MARK: Buttons

    /// A numbered pad: stores if M is armed, otherwise recalls.
    func pressSlot(voice: Int, slot: Int) {
        if armed[voice] { store(voice: voice, slot: slot) } else { recall(voice: voice, slot: slot) }
    }

    /// M: arms, and a second press disarms. No timeout.
    func toggleArmed(voice: Int) {
        armed[voice].toggle()
    }

    private func store(voice: Int, slot: Int) {
        var values: [String: Double] = [:]
        var snapshot: [Double] = []
        for e in entries[voice] {
            let v = Double(e.param.value)
            values[e.identifier] = v
            snapshot.append(v)
        }
        PresetStore.save(values, voice: voice, slot: slot)
        expected[voice] = snapshot
        lit[voice] = slot
        armed[voice] = false
    }

    /// An empty slot (or a control missing from an older slot) loads the factory default.
    private func recall(voice: Int, slot: Int) {
        let saved = PresetStore.load(voice: voice, slot: slot)
        var snapshot: [Double] = []
        for e in entries[voice] {
            let raw = saved?[e.identifier] ?? Double(e.spec.defaultValue)
            let v = min(max(raw, Double(e.spec.min)), Double(e.spec.max))
            e.param.set(AUValue(v))
            snapshot.append(v)
        }
        expected[voice] = snapshot
        lit[voice] = slot
    }

    // MARK: RAND (VCO, VCF and envelopes only; never TUBE, MIX or MASTER)

    private static let randomRanges: [(id: ParamID, lo: Float, hi: Float, zero: Float)] = [
        // VCO (the waveform is handled separately: sine, +saw, -saw or square, never pure noise)
        (.speed,           0.00, 1.00, 0.0),
        (.pwm,             0.10, 0.80, 0.5),     // half the time no PWM
        (.pulseWidth,      0.15, 0.85, 0.0),
        (.noise,           0.02, 0.25, 0.75),    // mostly none
        // VCF: always audible, and short of wild self-oscillation
        (.lpfCutoff,       0.45, 1.00, 0.0),
        (.lpfResonance,    0.00, 0.65, 0.0),
        // Amplifier ADSR: never silent (sustain >= 0.3), attack well short of the 10 s maximum
        (.ampAttack,       0.00, 0.70, 0.0),
        (.ampDecay,        0.30, 0.90, 0.0),
        (.ampSustain,      0.30, 1.00, 0.0),
        (.ampRelease,      0.30, 0.80, 0.0),
        // VCF envelope
        (.vcfInitialLevel, -0.70, 0.10, 0.0),
        (.vcfAttackLevel,  -0.20, 0.60, 0.0),
        (.vcfAttack,       0.10, 0.80, 0.0),
        (.vcfDecay,        0.20, 0.90, 0.0),
        (.vcfRelease,      0.20, 0.80, 0.0)
    ]

    /// RAND I / RAND II: changes the sliders only (no slot is written) and un-lights the pad.
    func randomize(voice: Int) {
        for e in entries[voice] {
            if e.base == .waveform {
                e.param.set(AUValue(Int.random(in: 0...3)))
                continue
            }
            guard let r = PresetController.randomRanges.first(where: { $0.id == e.base }) else { continue }
            let value: Float = (r.zero > 0 && Float.random(in: 0...1) < r.zero) ? 0 : Float.random(in: r.lo...r.hi)
            e.param.set(value)
        }
        lit[voice] = nil
    }

    // MARK: Lit pad follows the sound

    private func checkStillMatches(_ voice: Int) {
        guard lit[voice] != nil, expected[voice].count == entries[voice].count else { return }
        for (i, e) in entries[voice].enumerated() where abs(Double(e.param.value) - expected[voice][i]) > 0.0005 {
            lit[voice] = nil
            return
        }
    }
}

// MARK: - Pad look

/// A glowing pad: dark tinted fill and a brighter outline at rest; when lit (or pressed) the inside
/// lightens and a blurred copy glows behind it.
struct PadStyle: ButtonStyle {
    let colour: Color
    let lit: Bool
    let width: CGFloat
    var restFill: Double = 0.20
    var restText: Color? = nil
    var padHeight: CGFloat = PadStyle.height

    static let height: CGFloat = 29

    func makeBody(configuration: Configuration) -> some View {
        let on = lit || configuration.isPressed
        ZStack {
            if on {
                RoundedRectangle(cornerRadius: 3)
                    .fill(colour)
                    .blur(radius: 7)
                    .opacity(0.85)
            }
            RoundedRectangle(cornerRadius: 3)
                .fill(colour.opacity(on ? 0.60 : restFill))
                .overlay(RoundedRectangle(cornerRadius: 3)
                    .stroke(colour.opacity(on ? 1.0 : 0.65), lineWidth: 1))
            configuration.label
                .font(.system(size: 12, weight: .bold))
                .tracking(0.7)
                .foregroundStyle(on ? Color.white : (restText ?? Panel.legend.opacity(0.8)))
        }
        .frame(width: width, height: padHeight)
    }
}

// MARK: - The two rows

struct PresetBlock: View {
    @ObservedObject var controller: PresetController

    private static let padWidth: CGFloat = 24     // 24 x 29 pt pads (20% larger than 20 x 24)
    private static let randWidth: CGFloat = 82
    private static let gap: CGFloat = 4

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            row(voice: 0, colour: Panel.glow, randTitle: "RAND I")
            row(voice: 1, colour: Panel.violet, randTitle: "RAND II")
        }
        .frame(maxHeight: .infinity, alignment: .bottom)
    }

    private func row(voice: Int, colour: Color, randTitle: String) -> some View {
        let name = voice == 0 ? "Voice I" : "Voice II"
        return HStack(spacing: PresetBlock.gap) {
            ForEach(1...12, id: \.self) { slot in
                Button { controller.pressSlot(voice: voice, slot: slot) } label: { Text("\(slot)") }
                    .buttonStyle(PadStyle(colour: colour,
                                          lit: controller.lit[voice] == slot,
                                          width: PresetBlock.padWidth))
                    .help("\(name) preset \(slot). Press M first to store the current sound here.")
            }
            Color.clear.frame(width: 6, height: 1)
            Button { controller.toggleArmed(voice: voice) } label: { Text("M") }
                .buttonStyle(PadStyle(colour: Panel.red, lit: controller.armed[voice],
                                      width: PresetBlock.padWidth))
                .help("MEMORY: press M, then a number, to store \(name). Press M again to cancel.")
            Button { controller.randomize(voice: voice) } label: { Text(randTitle) }
                .buttonStyle(PadStyle(colour: Panel.yellow, lit: false, width: PresetBlock.randWidth))
                .help("Randomise \(name)'s VCO, VCF and envelopes. Tube, MIX and MASTER are left alone.")
        }
    }
}
