// PentoniqView.swift  (milestone 5, revision 2)
//
// Panel layout follows the way the Yamaha CS-80 groups a channel's controls:
// dark faceplate, light legends, framed sections, vertical faders with scale
// ticks, lamp push-buttons for selectors. Sections run left to right:
//
//     TUBE  |  VCO  |  VCF  |  ENVELOPE  |  MASTER
//
// TUBE, VCO, MASTER and the low-pass half of the VCF are live. The VCF's HPF
// faders are still drawn dimmed: they show where the CS-80's high-pass half
// will go and are not connected to anything yet.
// Every fader row sits on the same baseline across sections, like the panel.
//
// To add a module later: add a PanelSection to `body`, drop VerticalFaders and
// ButtonBanks into it, and add the parameters to PentoniqParameters.

import SwiftUI
import Combine
import Foundation
import AudioToolbox

// MARK: - Panel look

enum Panel {
    static let face = Color(red: 0.0 / 255, green: 10.0 / 255, blue: 25.0 / 255)
    static let section = Color(red: 0.0 / 255, green: 20.0 / 255, blue: 50.0 / 255)
    static let legend = Color(red: 0.91, green: 0.88, blue: 0.80)
    static let legendDim = Color(red: 0.91, green: 0.88, blue: 0.80).opacity(0.45)
    static let line = Color(red: 0.91, green: 0.88, blue: 0.80).opacity(0.55)
    static let glow = Color(red: 1.0, green: 0.62, blue: 0.24)
    static let green = Color(red: 0.30, green: 0.95, blue: 0.40)
    static let yellow = Color(red: 1.0, green: 0.85, blue: 0.20)
    static let red = Color(red: 1.0, green: 0.20, blue: 0.18)
    // Graph colours. Voice I is orange (`glow`); Voice II (milestone 6) is violet.
    // A high-pass curve is red for Voice I and blue for Voice II.
    static let violet = Color(red: 0.66, green: 0.46, blue: 1.0)
    static let blue = Color(red: 0.30, green: 0.58, blue: 1.0)
    static let capLight = Color(white: 0.90)
    static let capDark = Color(white: 0.50)
}

private let panelSectionHeight: CGFloat = 396
private let faderHeight: CGFloat = 170
/// Height of every graph (TUBE curve, VCO waveform, VCF response, MASTER scope).
private let graphHeight: CGFloat = 120
/// Height of the Voice II row and the MIX section: no graphs there (the graphs above show both voices).
private let compactSectionHeight: CGFloat = 284
private let thirdRowHeight: CGFloat = 150
private let thirdRowFaderHeight: CGFloat = 88
private let thirdRowTitledFaderHeight: CGFloat = 66
private let keyboardRowHeight: CGFloat = 150   // equal to thirdRowHeight

/// Envelope time fader (0...1) as ms or s.
private func timeReadout(_ value: AUValue) -> String {
    let seconds = EnvelopeSettings.seconds(forFader: value)
    return seconds < 1 ? String(format: "%.0f ms", seconds * 1000) : String(format: "%.2f s", seconds)
}

private func levelReadout(_ value: AUValue) -> String {
    String(format: "%.2f", Double(value))
}

/// VCF envelope offsets (fader units) as octaves: the cutoff fader spans 1000:1, so 1.0 = 9.97 octaves.
private func octaveReadout(_ value: AUValue) -> String {
    String(format: "%+.1f oct", Double(value) * 9.9658)
}

/// Cutoff fader (0...1) as Hz / kHz, for the LPF and MIX CUTOFF readouts.
private func hertzReadout(_ value: AUValue) -> String {
    let hertz = LadderCoefficients.cutoffHertz(forFader: value)
    return hertz >= 1000 ? String(format: "%.1f kHz", hertz / 1000) : String(format: "%.0f Hz", hertz)
}

private func defaultValue(_ id: ParamID) -> AUValue {
    PentoniqParameters.specs.first { $0.id == id }?.defaultValue ?? 0
}

// MARK: - Parameter bridge

/// Bridges one AUParameter to SwiftUI: reflects host automation into the UI
/// and sends UI edits to the audio unit.
final class ObservedParameter: ObservableObject {
    let parameter: AUParameter
    @Published var value: AUValue
    private var token: AUParameterObserverToken?

    init(_ parameter: AUParameter) {
        self.parameter = parameter
        self.value = parameter.value
        token = parameter.token(byAddingParameterObserver: { [weak self] _, newValue in
            DispatchQueue.main.async { self?.value = newValue }
        })
    }

    /// Re-reads the value. With `read` it comes straight from the audio unit's storage, which is how
    /// changes made by MIDI (and the MIDI-driven WHEEL) reach the screen.
    func refreshFromParameter(using read: ((Int) -> Float)? = nil) {
        let current = read?(Int(parameter.address)) ?? parameter.value
        if current != value { value = current }
    }

    /// Called by the UI. Passing our own token as originator stops the
    /// change from echoing back into this object.
    func set(_ newValue: AUValue) {
        value = newValue
        parameter.setValue(newValue, originator: token)
    }

    deinit {
        if let token { parameter.removeParameterObserver(token) }
    }
}

/// All 23 controls of one voice (Tube, VCO, VCF, Envelope). Voice I and Voice II are two
/// instances. It re-publishes any parameter change, so graphs that show both voices redraw.
final class VoiceModel: ObservableObject {
    // Tube
    let tubeEnabled: ObservedParameter
    let tubeType: ObservedParameter
    let drive: ObservedParameter
    let bias: ObservedParameter
    let output: ObservedParameter
    let oversampling: ObservedParameter
    // VCO
    let waveform: ObservedParameter
    let speed: ObservedParameter
    let pwm: ObservedParameter
    let pulseWidth: ObservedParameter
    let noise: ObservedParameter
    let sync: ObservedParameter
    // VCF
    let cutoff: ObservedParameter
    let resonance: ObservedParameter
    // Amplifier ADSR
    let ampAttack: ObservedParameter
    let ampDecay: ObservedParameter
    let ampSustain: ObservedParameter
    let ampRelease: ObservedParameter
    // VCF envelope
    let vcfInitialLevel: ObservedParameter
    let vcfAttackLevel: ObservedParameter
    let vcfAttack: ObservedParameter
    let vcfDecay: ObservedParameter
    let vcfRelease: ObservedParameter

    private var subscriptions: [AnyCancellable] = []

    /// Every control of this voice, for the view's refresh poll.
    let all: [ObservedParameter]

    /// `ids` are this voice's parameter addresses, in the order of `PentoniqParameters.voiceIIPairs`
    /// (Voice I passes the `base` column, Voice II the `v2` column).
    init(tree: AUParameterTree, ids: [ParamID]) {
        let lookup = Dictionary(uniqueKeysWithValues: zip(PentoniqParameters.voiceIIPairs.map { $0.base }, ids))
        // The tree is ours, so every address always exists.
        func make(_ base: ParamID) -> ObservedParameter {
            ObservedParameter(tree.parameter(withAddress: lookup[base]!.rawValue)!)
        }
        tubeEnabled = make(.tubeEnabled)
        tubeType = make(.tubeType)
        drive = make(.drive)
        bias = make(.bias)
        output = make(.output)
        oversampling = make(.oversampling)
        waveform = make(.waveform)
        speed = make(.speed)
        pwm = make(.pwm)
        pulseWidth = make(.pulseWidth)
        noise = make(.noise)
        sync = make(.sync)
        cutoff = make(.lpfCutoff)
        resonance = make(.lpfResonance)
        ampAttack = make(.ampAttack)
        ampDecay = make(.ampDecay)
        ampSustain = make(.ampSustain)
        ampRelease = make(.ampRelease)
        vcfInitialLevel = make(.vcfInitialLevel)
        vcfAttackLevel = make(.vcfAttackLevel)
        vcfAttack = make(.vcfAttack)
        vcfDecay = make(.vcfDecay)
        vcfRelease = make(.vcfRelease)

        all = [tubeEnabled, tubeType, drive, bias, output, oversampling,
               waveform, speed, pwm, pulseWidth, noise, sync,
               cutoff, resonance, ampAttack, ampDecay, ampSustain, ampRelease,
               vcfInitialLevel, vcfAttackLevel, vcfAttack, vcfDecay, vcfRelease]
        subscriptions = all.map { parameter in
            parameter.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        }
    }
}

final class PentoniqViewModel: ObservableObject {
    // Global
    let master: ObservedParameter
    let mix: ObservedParameter
    let mixResonance: ObservedParameter
    let brilliance: ObservedParameter
    // The two complete voices
    let voice1: VoiceModel
    let voice2: VoiceModel
    let presets: PresetController
    
    let detune: ObservedParameter
    let wheelEnable: ObservedParameter
    let wheelValue: ObservedParameter
    let arpEnable: ObservedParameter
    let delayEnable: ObservedParameter
    
    let subWaveform: ObservedParameter
    let subSync: ObservedParameter
    let subSpeed: ObservedParameter
    let subVCO: ObservedParameter
    let subVCF: ObservedParameter
    let subVCA: ObservedParameter
    let subPan: ObservedParameter
    
    let arpSpeed: ObservedParameter
    let arpMode: ObservedParameter
    let arpOctave: ObservedParameter
    let arpRepeat: ObservedParameter
    let arpHold: ObservedParameter
    let arpSync: ObservedParameter
    
    let delaySpeed: ObservedParameter
    let delayDepth: ObservedParameter
    let delayMix: ObservedParameter
    let delaySync: ObservedParameter
    let delayChorus: ObservedParameter
    
    let learn: LearnController
    let vfd = VFDDisplayModel()
    let leslie: ObservedParameter
    
    private let readParameter: ((Int) -> Float)?
    
    init(tree: AUParameterTree, link: MIDILearnLink) {
        func make(_ id: ParamID) -> ObservedParameter {
            ObservedParameter(tree.parameter(withAddress: id.rawValue)!)
        }
        master = make(.masterVolume)
        mix = make(.mix)
        mixResonance = make(.mixResonance)
        brilliance = make(.brilliance)
        
        detune = make(.detune)
        wheelEnable = make(.wheelEnable)
        wheelValue = make(.wheelValue)
        arpEnable = make(.arpEnable)
        delayEnable = make(.delayEnable)
        
        subWaveform = make(.subWaveform)
        subSync = make(.subSync)
        subSpeed = make(.subSpeed)
        subVCO = make(.subVCO)
        subVCF = make(.subVCF)
        subVCA = make(.subVCA)
        subPan = make(.subPan)
        leslie = make(.leslie)
        
        arpSpeed = make(.arpSpeed)
        arpMode = make(.arpMode)
        arpOctave = make(.arpOctave)
        arpRepeat = make(.arpRepeat)
        arpHold = make(.arpHold)
        arpSync = make(.arpSync)
        
        delaySpeed = make(.delaySpeed)
        delayDepth = make(.delayDepth)
        delayMix = make(.delayMix)
        delaySync = make(.delaySync)
        delayChorus = make(.delayChorus)
        
        let v1 = VoiceModel(tree: tree, ids: PentoniqParameters.voiceIIPairs.map { $0.base })
        let v2 = VoiceModel(tree: tree, ids: PentoniqParameters.voiceIIPairs.map { $0.v2 })
        voice1 = v1
        voice2 = v2
        presets = PresetController(voice1: v1, voice2: v2)
        
        // Milestone 8: new instances start at the user's default oversampling (UserDefaults, 4x unless changed).
        // A project that is reloaded restores its own saved value afterwards.
        let oversampling = AUValue(PentoniqDefaults.defaultOversampling)
        tree.parameter(withAddress: ParamID.oversampling.rawValue)?.value = oversampling
        tree.parameter(withAddress: ParamID.v2Oversampling.rawValue)?.value = oversampling
        learn = LearnController(link: link)
        readParameter = link.readParameter
    }
    
    /// Makes every slider and button show the audio unit's current value. Called ~15 times a second.
    /// This is what moves the controls when the host loads a preset or a saved setting, and when a MIDI
    /// controller moves a learned slider.
    func refreshAll() {
        let read = readParameter
        let globals = [master, mix, mixResonance, brilliance, detune, wheelEnable, wheelValue,
                       arpEnable, delayEnable, subWaveform, subSync, subSpeed,
                       subVCO, subVCF, subVCA, subPan, leslie,
                       arpSpeed, arpMode, arpOctave, arpRepeat, arpHold, arpSync,
                       delaySpeed, delayDepth, delayMix, delaySync, delayChorus]
        for parameter in globals { parameter.refreshFromParameter(using: read) }
        for parameter in voice1.all { parameter.refreshFromParameter(using: read) }
        for parameter in voice2.all { parameter.refreshFromParameter(using: read) }
    }
}

// MARK: - Legend text

struct Legend: View {
    let text: String
    var dim = false

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .bold))
            .tracking(1.2)
            .foregroundStyle(dim ? Panel.legendDim : Panel.legend)
            .lineLimit(1)
            .fixedSize()
    }
}

// MARK: - Fader

/// The drawn fader: groove, scale ticks and cap. Drag to set, double-click to
/// reset. Knows nothing about parameters, so it also serves the dimmed ghosts.
struct FaderTrack: View {
    let normalized: Double
    let height: CGFloat
    let onChange: (Double) -> Void
    let onReset: () -> Void

    static let capHeight: CGFloat = 26
    static let width: CGFloat = 48

    var body: some View {
        let cap = FaderTrack.capHeight
        let travel = height - cap
        ZStack(alignment: .top) {
            Canvas { context, size in
                for i in 0...10 {
                    let y = cap / 2 + travel * CGFloat(i) / 10
                    let length: CGFloat = (i % 5 == 0) ? 9 : 5
                    var path = Path()
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: length, y: y))
                    context.stroke(path, with: .color(Panel.legendDim), lineWidth: 1)
                }
            }
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.black)
                .overlay(RoundedRectangle(cornerRadius: 2)
                    .stroke(Panel.legendDim.opacity(0.6), lineWidth: 0.5))
                .frame(width: 6, height: travel + 6)
                .padding(.top, cap / 2 - 3)
            RoundedRectangle(cornerRadius: 3)
                .fill(LinearGradient(colors: [Panel.capLight, Panel.capDark],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(Rectangle().fill(Color.black.opacity(0.75)).frame(height: 2))
                .frame(width: 32, height: cap)
                .shadow(color: .black.opacity(0.7), radius: 2, x: 0, y: 2)
                .offset(y: travel * CGFloat(1 - min(max(normalized, 0), 1)))
        }
        .frame(width: FaderTrack.width, height: height)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
            let n = 1 - Double((drag.location.y - cap / 2) / travel)
            onChange(min(max(n, 0), 1))
        })
        .simultaneousGesture(TapGesture(count: 2).onEnded { onReset() })
    }
}

/// A live fader bound to one parameter, with a readout above and a legend below.
struct VerticalFader: View {
    let label: String
    @ObservedObject var parameter: ObservedParameter
    let defaultValue: AUValue
    let readout: (AUValue) -> String
    var height: CGFloat = 170

    @EnvironmentObject private var learn: LearnController

    var body: some View {
        let low = Double(parameter.parameter.minValue)
        let high = Double(parameter.parameter.maxValue)
        let tag = learn.isActive ? learn.ccLabel(for: parameter) : nil
        let glowing = learn.isGlowing(parameter)
        VStack(spacing: 6) {
            Text(tag ?? readout(parameter.value))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(tag != nil ? Panel.yellow : Panel.glow)
                .frame(height: 12)
            FaderTrack(normalized: (Double(parameter.value) - low) / (high - low),
                       height: height,
                       onChange: { parameter.set(AUValue(low + $0 * (high - low))) },
                       onReset: { parameter.set(defaultValue) })
            Legend(text: label)
        }
        .frame(width: 56)
        .background {
            if glowing {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Panel.yellow)
                    .blur(radius: 9)
                    .opacity(0.55)
            }
        }
        .overlay {
            if learn.isActive {
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Panel.yellow.opacity(glowing ? 1 : 0.35), lineWidth: glowing ? 1.5 : 1)
            }
        }
        .overlay {
            if learn.isActive {
                // Catches the click in learn mode, so the slider is selected instead of moved.
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { learn.select(parameter) }
            }
        }
    }
}

/// A dimmed, non-interactive fader marking where a future control will sit.
struct GhostFader: View {
    let label: String
    var position: Double = 0.5
    var height: CGFloat? = nil          // nil = full fader height

    var body: some View {
        VStack(spacing: 6) {
            Text("--")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Panel.legendDim)
                .frame(height: 12)
            FaderTrack(normalized: position, height: height ?? faderHeight,
                       onChange: { _ in }, onReset: {})
                .allowsHitTesting(false)
            Legend(text: label, dim: true)
        }
        .frame(width: 56)
        .opacity(0.5)
    }
}

/// Dims a proxy control and makes it non-interactive.
private extension View {
    func ghosted() -> some View { opacity(0.5).allowsHitTesting(false) }
}

/// A compact lamp button (18 pt high) for the crowded third row. Proxy only.
struct MiniLamp: View {
    let title: String
    var width: CGFloat = 52
    var isOn = false
    var dot = true

    var body: some View {
        HStack(spacing: 4) {
            if dot {
                Circle()
                    .fill(isOn ? Panel.glow : Color.black)
                    .overlay(Circle().stroke(Panel.legendDim, lineWidth: 0.5))
                    .frame(width: 6, height: 6)
            }
            Text(title)
                .font(.system(size: 8, weight: .bold))
                .tracking(0.5)
                .foregroundStyle(isOn ? Panel.legend : Panel.legendDim)
                .lineLimit(1)
            if dot { Spacer(minLength: 0) }
        }
        .padding(.horizontal, 5)
        .frame(width: width, height: 18)
        .background(RoundedRectangle(cornerRadius: 3).fill(Color.black.opacity(0.35)))
        .overlay(RoundedRectangle(cornerRadius: 3).stroke(Panel.line.opacity(0.4), lineWidth: 1))
    }
}

/// One expanding, fading ring. Give it a new .id to fire it again.
struct PulseRing: View {
    @State private var go = false

    var body: some View {
        Circle()
            .stroke(Panel.blue, lineWidth: 2)
            .scaleEffect(go ? 1.8 : 1)
            .opacity(go ? 0 : 0.9)
            .allowsHitTesting(false)
            .onAppear { withAnimation(.easeOut(duration: 0.45)) { go = true } }
    }
}

/// A blue push button for the ENABLE / WHEEL switches. Lit = on. Bound to a boolean parameter.
struct BlueSwitch: View {
    let title: String
    @ObservedObject var parameter: ObservedParameter

    var body: some View {
        Button { parameter.set(parameter.value >= 0.5 ? 0 : 1) } label: { Text(title) }
            .buttonStyle(PadStyle(colour: Panel.blue, lit: parameter.value >= 0.5, width: 62))
    }
}

/// The WHEEL knob: 48 pt, dark blue and black, white indicator from 7 o'clock (0) through 12 o'clock (0.5)
/// to 5 o'clock (1.0).
///  - Not enabled: the user drags it up and down (double-click = back to 1.0, fully on).
///  - Enabled: it follows the MIDI MOD wheel and a ring pulses each time the value changes. Dragging is ignored.
struct WheelKnob: View {
    @ObservedObject var wheel: ObservedParameter
    @EnvironmentObject private var learn: LearnController
    let enabled: Bool
    
    static let diameter: CGFloat = 48
    
    @State private var dragStart: Double? = nil
    @State private var pulses: [KnobPulse] = []
    
    private var shown: Double { min(max(Double(wheel.value), 0), 1) }
    /// Clockwise from 12 o'clock: 7 o'clock is 210 degrees, and the sweep is 300 degrees.
    private var angle: Double { (210 + 300 * shown) * Double.pi / 180 }
    
    var body: some View {
        let d = WheelKnob.diameter
        let r = d / 2 - 8
        ZStack {
            Circle()
                .fill(RadialGradient(colors: [Color(red: 0.12, green: 0.26, blue: 0.62),
                                              Color(red: 0.03, green: 0.07, blue: 0.22),
                                              Color.black],
                                     center: UnitPoint(x: 0.35, y: 0.30),
                                     startRadius: 2, endRadius: d * 0.75))
                .overlay(Circle().stroke(Panel.blue.opacity(enabled ? 0.95 : 0.55), lineWidth: 1))
                .shadow(color: .black.opacity(0.7), radius: 2, x: 0, y: 2)
            Circle()
                .fill(Color.white)
                .frame(width: 7, height: 7)
                .shadow(color: Color.white.opacity(0.7), radius: 2)
                .offset(x: CGFloat(sin(angle)) * r, y: -CGFloat(cos(angle)) * r)
        }
        .frame(width: d, height: d)
        .background(PulseLayerView(pulses: pulses, knobDiameter: d))   // rings sit behind the knob
        .overlay {
            if learn.isGlowing(wheel) {
                Circle().stroke(Panel.yellow, lineWidth: 2).shadow(color: Panel.yellow, radius: 7)
            } else if learn.isActive {
                Circle().stroke(Panel.yellow.opacity(0.35), lineWidth: 1)
            }
        }
        .overlay {
            if learn.isActive {
                Circle().fill(Color.clear).contentShape(Circle())
                    .onTapGesture { learn.select(wheel) }
            }
        }
        .contentShape(Circle())
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { drag in
                guard !enabled else { return }
                if dragStart == nil { dragStart = Double(wheel.value) }
                let start = dragStart ?? Double(wheel.value)
                wheel.set(AUValue(min(max(start - Double(drag.translation.height) / 120, 0), 1)))
            }
            .onEnded { _ in dragStart = nil })
        .simultaneousGesture(TapGesture(count: 2).onEnded { if !enabled { wheel.set(1) } })
        .onChange(of: wheel.value) { _ in
            if enabled { firePulse() }
        }
        .help(enabled ? "Following the MIDI MOD wheel." : "Drag to set. Double-click for fully on.")
    }
    
    private func firePulse() {
        let pulse = KnobPulse()
        pulses.append(pulse)
        if pulses.count > PentoniqPulse.maxActive {
            pulses.removeFirst(pulses.count - PentoniqPulse.maxActive)
        }
        let id = pulse.id
        DispatchQueue.main.asyncAfter(deadline: .now() + PentoniqPulse.lifetime) {
            pulses.removeAll { $0.id == id }
        }
    }
    
    // find: eee this is where one more } goes if its missing!!
}

/// The WHEEL section: knob with the blue WHEEL button under it, then DETUNE and PAN. No title,
/// so the faders get the full height. DETUNE is live (Voice II +/- 12 semitones from Voice I,
/// independent of the wheel). PAN is still a proxy.
struct WheelSection: View {
    @ObservedObject var wheelEnable: ObservedParameter
    @ObservedObject var wheelValue: ObservedParameter
    let detune: ObservedParameter
    let pan: ObservedParameter

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(spacing: 0) {
                Text(String(format: "%.1f%%", Double(wheelValue.value) * 100))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Panel.glow)
                    .frame(height: 12)
                Spacer(minLength: 4)
                WheelKnob(wheel: wheelValue, enabled: wheelEnable.value >= 0.5)
                Spacer(minLength: 4)
                BlueSwitch(title: "WHEEL", parameter: wheelEnable)
                    .help("On: the Sub-Osc sends follow the MIDI MOD wheel. Off: you set the wheel by hand.")
            }
            VerticalFader(label: "DETUNE", parameter: detune,
                          defaultValue: defaultValue(.detune),
                          readout: { String(format: "%+.2f st", Double($0)) },
                          height: thirdRowFaderHeight)
                .help("Detunes Voice II from Voice I by up to 12 semitones either way. Double-click to reset.")
            VerticalFader(label: "PAN", parameter: pan,
                          defaultValue: defaultValue(.leslie),
                          readout: { LeslieSimulation.readout(amount: $0) },
                          height: thirdRowFaderHeight)
                .help("Leslie speaker: sets the rotor speed (horn 0.7 to 7 Hz) and the room depth together. Bottom = off.")
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// A clickable MiniLamp.
struct MiniLampButton: View {
    let title: String
    var width: CGFloat = 58
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) { MiniLamp(title: title, width: width, isOn: isOn) }
            .buttonStyle(.plain)
    }
}

/// The live SUB-OSC section: waveform, SYNC, then SPEED and the four sends.
/// 432 HZ stays a ghost here (it is not a sub-oscillator control; it only sits here for space).
struct SubOscSection: View {
    @ObservedObject var waveform: ObservedParameter
    @ObservedObject var sync: ObservedParameter
    @ObservedObject var speed: ObservedParameter
    let vco: ObservedParameter
    let vcf: ObservedParameter
    let vca: ObservedParameter
    let pan: ObservedParameter
    
    var body: some View {
        let syncOn = sync.value >= 0.5
        let selected = Int(waveform.value.rounded())
        let names = ["SINE", "TRI", "SAW", "SQUARE"]
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 0) {
                Legend(text: "SUB-OSC")
                    .frame(height: 12)
                Spacer(minLength: 4)
                HStack(alignment: .bottom, spacing: 4) {
                    VStack(spacing: 3) {
                        ForEach(0..<4, id: \.self) { i in
                            MiniLampButton(title: names[i], isOn: selected == i) { waveform.set(AUValue(i)) }
                        }
                    }
                    VStack(spacing: 3) {
                        MiniLampButton(title: "S+H", isOn: selected == 4) { waveform.set(4) }
                        MiniLampButton(title: "SYNC", isOn: syncOn) { sync.set(syncOn ? 0 : 1) }
                            .help("Tempo sync: the SPEED fader steps through note values, from 32 bars to 1/64.")
                        MiniLamp(title: "432 HZ", width: 58).ghosted()
                    }
                }
            }
            HStack(alignment: .top, spacing: 4) {
                VerticalFader(label: "SPEED", parameter: speed,
                              defaultValue: defaultValue(.subSpeed),
                              readout: { SubOscRate.readout(speed: $0, sync: syncOn) },
                              height: thirdRowFaderHeight)
                    .help("Bottom = OFF. Free: 0.1 to 120 Hz. With SYNC: note values locked to the host tempo.")
                VerticalFader(label: "VCO", parameter: vco,
                              defaultValue: defaultValue(.subVCO),
                              readout: { String(format: "%.2f st", Double($0) * Double(SubOscDepth.vibratoSemitones)) },
                              height: thirdRowFaderHeight)
                    .help("Vibrato: up to +/-2 semitones of pitch, on both voices.")
                VerticalFader(label: "VCF", parameter: vcf,
                              defaultValue: defaultValue(.subVCF),
                              readout: { String(format: "%.1f oct", Double($0) * Double(SubOscDepth.wobbleOctaves)) },
                              height: thirdRowFaderHeight)
                    .help("Filter wobble: up to +/-3 octaves of cutoff.")
                VerticalFader(label: "VCA", parameter: vca,
                              defaultValue: defaultValue(.subVCA),
                              readout: { String(format: "%.0f%%", Double($0) * 100) },
                              height: thirdRowFaderHeight)
                    .help("Tremolo: up to 100%.")
                VerticalFader(label: "PAN", parameter: pan,
                              defaultValue: defaultValue(.subPan),
                              readout: { String(format: "±%.0f%%", Double($0) * 50) },
                              height: thirdRowFaderHeight)
                    .help("Swings Leslie PAN slider by up to ±50% of its travel around where you set it. Scaled by the WHEEL.")
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}


/// The ARPEGGIATOR section. Columns, left to right: SPEED | MODE | OCT | REP | SYNC, HOLD, ENABLE.
/// OCT and REP list 4 at the top and 1 at the bottom. SYNC and HOLD are the same size as ENABLE.
struct ArpSection: View {
    @ObservedObject var speed: ObservedParameter
    @ObservedObject var mode: ObservedParameter
    @ObservedObject var octave: ObservedParameter
    @ObservedObject var repeats: ObservedParameter
    @ObservedObject var sync: ObservedParameter
    let hold: ObservedParameter
    let enable: ObservedParameter

    private func lamp(_ title: String, width: CGFloat, dot: Bool, on: Bool,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) { MiniLamp(title: title, width: width, isOn: on, dot: dot) }
            .buttonStyle(.plain)
    }

    private func column<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Legend(text: title, dim: true)
                .frame(height: 12)
            Spacer(minLength: 4)
            VStack(spacing: 3) { content() }
        }
    }

    var body: some View {
        let syncOn = sync.value >= 0.5
        let selectedMode = Int(mode.value.rounded())
        let selectedOctave = Int(octave.value.rounded())
        let selectedRepeat = Int(repeats.value.rounded())
        HStack(alignment: .top, spacing: 8) {
            VerticalFader(label: "SPEED", parameter: speed,
                          defaultValue: defaultValue(.arpSpeed),
                          readout: { ArpRate.readout(speed: $0, sync: syncOn) },
                          height: thirdRowTitledFaderHeight)
                .help("Steps a second, or with SYNC the note value, locked to the host tempo.")

            column("MODE") {
                ForEach(0..<4, id: \.self) { i in
                    lamp(["UP", "DOWN", "UP-DOWN", "RAND"][i], width: 64, dot: true, on: selectedMode == i) {
                        mode.set(AUValue(i))
                    }
                }
            }

            column("OCT") {
                ForEach([4, 3, 2, 1], id: \.self) { n in
                    lamp("\(n)", width: 28, dot: false, on: selectedOctave == n - 1) { octave.set(AUValue(n - 1)) }
                }
            }
            .help("How many octaves the pattern climbs through.")

            column("REP") {
                ForEach([4, 3, 2, 1], id: \.self) { n in
                    lamp("\(n)", width: 28, dot: false, on: selectedRepeat == n - 1) { repeats.set(AUValue(n - 1)) }
                }
            }
            .help("How many times each note is played before moving on.")

            VStack(spacing: 4) {
                BlueSwitch(title: "SYNC", parameter: sync)
                    .help("Lock the speed to the host tempo (127 BPM when there is none).")
                BlueSwitch(title: "HOLD", parameter: hold)
                    .help("Keep playing after the keys are released. A new chord replaces the held one.")
                BlueSwitch(title: "ENABLE", parameter: enable)
                    .help("On: the keys you play are arpeggiated.")
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}


/// The DELAY section. Columns, left to right: SPEED | DEPTH | MIX | SYNC, CHORUS, DELAY.
/// DELAY and CHORUS share the three faders: SPEED is the delay time (or the chorus rate when only
/// CHORUS is on), DEPTH is feedback (or chorus sweep), MIX is the effect level.
struct DelaySection: View {
    @ObservedObject var speed: ObservedParameter
    @ObservedObject var depth: ObservedParameter
    @ObservedObject var mix: ObservedParameter
    @ObservedObject var sync: ObservedParameter
    @ObservedObject var chorus: ObservedParameter
    @ObservedObject var enable: ObservedParameter

    var body: some View {
        let syncOn = sync.value >= 0.5
        let chorusOn = chorus.value >= 0.5
        let delayOn = enable.value >= 0.5
        HStack(alignment: .top, spacing: 8) {
            HStack(alignment: .top, spacing: 4) {
                VerticalFader(label: "SPEED", parameter: speed,
                              defaultValue: defaultValue(.delaySpeed),
                              readout: { DelayRate.readout(speed: $0, sync: syncOn,
                                                           delayOn: delayOn, chorusOn: chorusOn) },
                              height: thirdRowTitledFaderHeight)
                    .help("Delay time: 50 ms to 1 s, or with SYNC note values locked to the host tempo. With only CHORUS on, the chorus rate.")
                VerticalFader(label: "DEPTH", parameter: depth,
                              defaultValue: defaultValue(.delayDepth),
                              readout: { String(format: "%.0f%%", Double($0) * 100) },
                              height: thirdRowTitledFaderHeight)
                    .help("Delay: feedback (how many echoes). Chorus: how far the pitch sweeps.")
                VerticalFader(label: "MIX", parameter: mix,
                              defaultValue: defaultValue(.delayMix),
                              readout: { String(format: "%.0f%%", Double($0) * 100) },
                              height: thirdRowTitledFaderHeight)
                    .help("How much of the echoes and the chorus is added to the dry sound.")
            }
            VStack(spacing: 4) {
                BlueSwitch(title: "SYNC", parameter: sync)
                    .help("Lock the delay time to the host tempo (127 BPM when there is none).")
                BlueSwitch(title: "CHORUS", parameter: chorus)
                    .help("Chorus on or off. It shares SPEED, DEPTH and MIX with the delay.")
                BlueSwitch(title: "DELAY", parameter: enable)
                    .help("Ping-pong delay on or off. Echoes already sounding ring out.")
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}


// MARK: - Lamp buttons

struct LampButton: View {
    let title: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Circle()
                    .fill(isOn ? Panel.glow : Color.black)
                    .overlay(Circle().stroke(Panel.legendDim, lineWidth: 0.5))
                    .shadow(color: isOn ? Panel.glow.opacity(0.9) : Color.clear, radius: 3)
                    .frame(width: 8, height: 8)
                Text(title)
                    .font(.system(size: 10, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(isOn ? Panel.legend : Panel.legendDim)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(width: 84, height: 24)
            .background(RoundedRectangle(cornerRadius: 3)
                .fill(Color.black.opacity(isOn ? 0.55 : 0.35)))
            .overlay(RoundedRectangle(cornerRadius: 3)
                .stroke(Panel.line.opacity(isOn ? 0.9 : 0.4), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }
}

/// A column of lamp buttons where exactly one is lit (an indexed parameter).
struct ButtonBank: View {
    @ObservedObject var parameter: ObservedParameter
    let labels: [String]

    var body: some View {
        VStack(spacing: 4) {
            ForEach(0..<labels.count, id: \.self) { index in
                LampButton(title: labels[index],
                           isOn: Int(parameter.value.rounded()) == index) {
                    parameter.set(AUValue(index))
                }
            }
        }
    }
}

/// A single lamp button that toggles a boolean parameter.
struct SwitchLamp: View {
    let title: String
    @ObservedObject var parameter: ObservedParameter

    var body: some View {
        LampButton(title: title, isOn: parameter.value >= 0.5) {
            parameter.set(parameter.value >= 0.5 ? 0 : 1)
        }
    }
}

// MARK: - MIDI lamp

/// A small green lamp that flashes when the audio unit receives MIDI. It polls a
/// counter the audio thread bumps for every MIDI event (about 30 times a second)
/// and stays lit for a moment after the counter changes.
struct MIDIIndicator: View {
    let activity: () -> UInt32

    @State private var lastCount: UInt32
    @State private var litUntil = Date.distantPast
    @State private var lit = false
    private let timer = Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()

    init(activity: @escaping () -> UInt32) {
        self.activity = activity
        _lastCount = State(initialValue: activity())
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(lit ? Panel.green : Color.black)
                .overlay(Circle().stroke(Panel.legendDim, lineWidth: 0.5))
                .shadow(color: lit ? Panel.green.opacity(0.9) : Color.clear, radius: 4)
                .frame(width: 10, height: 10)
            Text("MIDI   ")
                .font(.system(size: 11, weight: .bold))
                .tracking(1.4)
                .foregroundStyle(Panel.legend)
        }
        .onReceive(timer) { _ in
            let count = activity()
            if count != lastCount {
                lastCount = count
                litUntil = Date().addingTimeInterval(0.15)
            }
            let shouldLight = Date() < litUntil
            if shouldLight != lit { lit = shouldLight }
        }
    }
}

// MARK: - Filter response graph

/// One low-pass curve to draw: cutoff and resonance faders (0...1) and a colour.
struct FilterCurve {
    let cutoff: Float
    let resonance: Float
    let colour: Color
}

/// Frequency (20 Hz to 20 kHz, log) against gain (dB) of the low-pass ladder. Drawn from the
/// same maths as the filter: H = G^4 / (1 + k G^4), with G a one-pole at the cutoff
/// (bilinear-warped) and k = kMax x resonance. Curves are drawn semi-transparent, so
/// overlapping Voice I (orange) and Voice II (violet) curves both stay visible.
/// The high-pass curves will be red (Voice I) and blue (Voice II).
struct FilterResponseView: View {
    let curves: [FilterCurve]

    private static let dbTop = 30.0
    private static let dbBottom = -48.0
    private static let sampleRate = 48_000.0   // only matters close to Nyquist

    var body: some View {
        Canvas { context, size in
            let top = FilterResponseView.dbTop
            let bottom = FilterResponseView.dbBottom
            func yFor(_ db: Double) -> CGFloat { size.height * CGFloat((top - db) / (top - bottom)) }
            func xFor(_ hz: Double) -> CGFloat { size.width * CGFloat(log10(hz / 20.0) / 3.0) }

            // Grid: decades and 20 dB steps; 0 dB is brighter.
            var grid = Path()
            for hz in [100.0, 1000.0, 10000.0] {
                grid.move(to: CGPoint(x: xFor(hz), y: 0))
                grid.addLine(to: CGPoint(x: xFor(hz), y: size.height))
            }
            for db in [20.0, -20.0, -40.0] {
                grid.move(to: CGPoint(x: 0, y: yFor(db)))
                grid.addLine(to: CGPoint(x: size.width, y: yFor(db)))
            }
            context.stroke(grid, with: .color(Panel.legendDim.opacity(0.25)), lineWidth: 0.5)
            var zero = Path()
            zero.move(to: CGPoint(x: 0, y: yFor(0)))
            zero.addLine(to: CGPoint(x: size.width, y: yFor(0)))
            context.stroke(zero, with: .color(Panel.legendDim.opacity(0.6)), lineWidth: 1)

            let fs = FilterResponseView.sampleRate
            func mul(_ a: (Double, Double), _ b: (Double, Double)) -> (Double, Double) {
                (a.0 * b.0 - a.1 * b.1, a.0 * b.1 + a.1 * b.0)
            }
            let steps = max(Int(size.width), 2)

            for curve in curves {
                let cutoffHz = min(max(LadderCoefficients.cutoffHertz(forFader: curve.cutoff), 5.0), 0.45 * fs)
                let k = Double(LadderCoefficients.kMax) * Double(min(max(curve.resonance, 0), 1))
                let warpedCutoff = tan(Double.pi * cutoffHz / fs)
                var line = Path()
                var area = Path()
                for i in 0...steps {
                    let hz = 20.0 * pow(1000.0, Double(i) / Double(steps))
                    let omega = tan(Double.pi * min(hz, 0.499 * fs) / fs) / warpedCutoff
                    let d = 1.0 + omega * omega
                    let g = (1.0 / d, -omega / d)                  // 1 / (1 + j omega)
                    let g2 = mul(g, g)
                    let g4 = mul(g2, g2)
                    let den = (1.0 + k * g4.0, k * g4.1)
                    let denMag2 = max(den.0 * den.0 + den.1 * den.1, 1e-12)
                    let mag = sqrt((g4.0 * g4.0 + g4.1 * g4.1) / denMag2)
                    let db = min(max(20.0 * log10(max(mag, 1e-6)), bottom), top)
                    let point = CGPoint(x: CGFloat(i) / CGFloat(steps) * size.width, y: yFor(db))
                    if i == 0 {
                        line.move(to: point)
                        area.move(to: CGPoint(x: point.x, y: size.height))
                        area.addLine(to: point)
                    } else {
                        line.addLine(to: point)
                        area.addLine(to: point)
                    }
                }
                area.addLine(to: CGPoint(x: size.width, y: size.height))
                area.closeSubpath()
                context.fill(area, with: .color(curve.colour.opacity(0.10)))
                context.stroke(line, with: .color(curve.colour.opacity(0.85)), lineWidth: 2)
            }

            // Tiny scale labels
            let label = { (text: String) in Text(text).font(.system(size: 8, design: .monospaced)).foregroundStyle(Panel.legendDim) }
            context.draw(label("0 dB"), at: CGPoint(x: 3, y: yFor(0) - 1), anchor: .bottomLeading)
            for (hz, text) in [(100.0, "100"), (1000.0, "1k"), (10000.0, "10k")] {
                context.draw(label(text), at: CGPoint(x: xFor(hz) + 2, y: size.height - 1), anchor: .bottomLeading)
            }
        }
        .background(Color.black.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .overlay(RoundedRectangle(cornerRadius: 3).stroke(Panel.line.opacity(0.4), lineWidth: 1))
    }
}

/// The VCF graph: both voices' low-pass curves (Voice I orange, Voice II violet).
struct VCFResponseGraph: View {
    @ObservedObject var one: VoiceModel
    @ObservedObject var two: VoiceModel
    @ObservedObject var brilliance: ObservedParameter
    @ObservedObject var resonanceOffset: ObservedParameter

    /// The curve a voice really has: its own faders plus the global BRILLIANCE and RESONANCE offsets.
    private func curve(_ v: VoiceModel, _ colour: Color) -> FilterCurve {
        let cutoff = min(max(v.cutoff.value + (brilliance.value - 0.5), 0), 1)
        let resonance = min(v.resonance.value + resonanceOffset.value, 1)
        return FilterCurve(cutoff: cutoff, resonance: resonance, colour: colour)
    }

    var body: some View {
        FilterResponseView(curves: [curve(one, Panel.glow), curve(two, Panel.violet)])
    }
}

// MARK: - Envelope graphs

/// One envelope to draw: its four levels, the three time faders (0...1) and a colour.
struct EnvelopeShape {
    let initial: Double
    let attack: Double
    let sustain: Double
    let release: Double
    let attackFader: Double
    let decayFader: Double
    let releaseFader: Double
    let colour: Color
}

/// Shape of envelopes, drawn from the same segments the envelope generator uses:
/// attack (an exponential that arrives at the attack level), decay (exponential to the
/// sustain level, to within 1%), a fixed-width sustain hold, then release (exponential,
/// 60 dB). Each stage's width follows its fader (the faders are logarithmic in time), so the
/// picture shows relative speeds, not literal seconds. Voice I (orange) is the first shape: its
/// stage edges are the grey dividers and the A D S R letters. Voice II (violet) is drawn
/// semi-transparent on its own stage widths, with small violet ticks at its stage edges.
struct EnvelopeGraph: View {
    let title: String
    let shapes: [EnvelopeShape]
    let low: Double
    let high: Double
    var referenceLine: Double? = nil        // dashed line (VCF: the cutoff, at 0)
    var referenceLabel: String? = nil

    private static func edges(_ shape: EnvelopeShape, width: CGFloat, margin: CGFloat) -> [CGFloat] {
        let weights = [0.12 + shape.attackFader, 0.12 + shape.decayFader, 0.7, 0.12 + shape.releaseFader]
        let total = weights.reduce(0, +)
        var edges: [CGFloat] = [margin]
        for w in weights { edges.append(edges.last! + (width - 2 * margin) * CGFloat(w / total)) }
        return edges
    }

    var body: some View {
        Canvas { context, size in
            let top: CGFloat = 12
            let bottom = size.height - 14
            func yFor(_ v: Double) -> CGFloat {
                top + (bottom - top) * CGFloat((high - v) / (high - low))
            }
            let margin: CGFloat = 6

            // Reference line
            if let ref = referenceLine {
                var dash = Path()
                dash.move(to: CGPoint(x: 0, y: yFor(ref)))
                dash.addLine(to: CGPoint(x: size.width, y: yFor(ref)))
                context.stroke(dash, with: .color(Panel.legendDim.opacity(0.6)),
                               style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            }

            // Stage dividers (first shape)
            if let first = shapes.first {
                let e = EnvelopeGraph.edges(first, width: size.width, margin: margin)
                var dividers = Path()
                for x in e.dropFirst().dropLast() {
                    dividers.move(to: CGPoint(x: x, y: top))
                    dividers.addLine(to: CGPoint(x: x, y: bottom))
                }
                context.stroke(dividers, with: .color(Panel.legendDim.opacity(0.25)), lineWidth: 0.5)
                let tinyLetter = { (text: String) in
                    Text(text).font(.system(size: 8, weight: .bold, design: .monospaced)).foregroundStyle(Panel.legendDim)
                }
                for (i, letter) in ["A", "D", "S", "R"].enumerated() {
                    context.draw(tinyLetter(letter), at: CGPoint(x: (e[i] + e[i + 1]) / 2, y: size.height - 2),
                                 anchor: .bottom)
                }
            }

            // Curves
            let o = Double(EnvelopeSettings.overshoot)
            let arrive = o / (1 + o)
            let steps = 48
            for (n, shape) in shapes.enumerated() {
                let e = EnvelopeGraph.edges(shape, width: size.width, margin: margin)
                var line = Path()
                var area = Path()
                var started = false
                func add(_ x: CGFloat, _ v: Double) {
                    let p = CGPoint(x: x, y: yFor(v))
                    if !started {
                        line.move(to: p)
                        area.move(to: CGPoint(x: x, y: bottom))
                        area.addLine(to: p)
                        started = true
                    } else {
                        line.addLine(to: p)
                        area.addLine(to: p)
                    }
                }
                // Attack
                let attackTarget = shape.attack + o * (shape.attack - shape.initial)
                for i in 0...steps {
                    let u = Double(i) / Double(steps)
                    let v = (shape.attack == shape.initial)
                        ? shape.attack
                        : attackTarget - (attackTarget - shape.initial) * pow(arrive, u)
                    add(e[0] + (e[1] - e[0]) * CGFloat(u), v)
                }
                // Decay
                for i in 1...steps {
                    let u = Double(i) / Double(steps)
                    add(e[1] + (e[2] - e[1]) * CGFloat(u),
                        shape.sustain + (shape.attack - shape.sustain) * exp(-log(100.0) * u))
                }
                // Sustain hold
                add(e[3], shape.sustain)
                // Release
                for i in 1...steps {
                    let u = Double(i) / Double(steps)
                    add(e[3] + (e[4] - e[3]) * CGFloat(u),
                        shape.release + (shape.sustain - shape.release) * exp(-log(1000.0) * u))
                }
                area.addLine(to: CGPoint(x: e[4], y: bottom))
                area.closeSubpath()
                context.fill(area, with: .color(shape.colour.opacity(0.10)))
                context.stroke(line, with: .color(shape.colour.opacity(0.85)), lineWidth: 2)

                // Ticks at this voice's own stage edges (not for the first shape: it has dividers)
                if n > 0 {
                    var ticks = Path()
                    for x in e.dropFirst().dropLast() {
                        ticks.move(to: CGPoint(x: x, y: bottom - 5))
                        ticks.addLine(to: CGPoint(x: x, y: bottom))
                    }
                    context.stroke(ticks, with: .color(shape.colour.opacity(0.85)), lineWidth: 1.5)
                }
            }

            // Labels
            let tiny = { (text: String) in
                Text(text).font(.system(size: 8, weight: .bold, design: .monospaced)).foregroundStyle(Panel.legendDim)
            }
            context.draw(tiny(title), at: CGPoint(x: 6, y: 2), anchor: .topLeading)
            if let label = referenceLabel {
                context.draw(tiny(label), at: CGPoint(x: size.width - 4, y: yFor(referenceLine ?? 0) - 1), anchor: .bottomTrailing)
            }
        }
        .background(Color.black.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .overlay(RoundedRectangle(cornerRadius: 3).stroke(Panel.line.opacity(0.4), lineWidth: 1))
    }
}

/// VCF envelopes: levels are offsets from the cutoff (dashed line); there is no sustain fader,
/// the sustain is the cutoff itself. Release returns to IL.
struct VCFEnvelopeGraph: View {
    @ObservedObject var one: VoiceModel
    @ObservedObject var two: VoiceModel

    private func shape(_ v: VoiceModel, _ colour: Color) -> EnvelopeShape {
        EnvelopeShape(initial: Double(v.vcfInitialLevel.value), attack: Double(v.vcfAttackLevel.value),
                      sustain: 0, release: Double(v.vcfInitialLevel.value),
                      attackFader: Double(v.vcfAttack.value), decayFader: Double(v.vcfDecay.value),
                      releaseFader: Double(v.vcfRelease.value), colour: colour)
    }

    var body: some View {
        EnvelopeGraph(title: "VCF ENVELOPE",
                      shapes: [shape(one, Panel.glow), shape(two, Panel.violet)],
                      low: -1.05, high: 1.05, referenceLine: 0, referenceLabel: "CUTOFF")
    }
}

/// VCA envelopes: a plain ADSR from silence to the attack peak (1.0), settling at S.
struct VCAEnvelopeGraph: View {
    @ObservedObject var one: VoiceModel
    @ObservedObject var two: VoiceModel

    private func shape(_ v: VoiceModel, _ colour: Color) -> EnvelopeShape {
        EnvelopeShape(initial: 0, attack: 1, sustain: Double(v.ampSustain.value), release: 0,
                      attackFader: Double(v.ampAttack.value), decayFader: Double(v.ampDecay.value),
                      releaseFader: Double(v.ampRelease.value), colour: colour)
    }

    var body: some View {
        EnvelopeGraph(title: "VCA ENVELOPE",
                      shapes: [shape(one, Panel.glow), shape(two, Panel.violet)],
                      low: -0.05, high: 1.05)
    }
}

// MARK: - VU meter

/// Vertical 10-segment LED meter for the master output (0 dB = full scale, 1.0). Six green
/// (-20, -15, -10, -6, -4, -2 dB), three yellow (0, +1, +2 dB) and one red (+6 dB).
/// It follows the output peak with an instant attack and a release of about 0.3 s.
struct VUMeter: View {
    let tap: ScopeTap
    @State private var levelDB: Float = -100
    private let timer = Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()

    private static let thresholds: [Float] = [-20, -15, -10, -6, -4, -2, 0, 1, 2, 6]
    private static let labels = ["-20", "-15", "-10", "-6", "-4", "-2", "0", "+1", "+2", "+6"]
    private static let ledHeight: CGFloat = 12

    private static func colour(_ index: Int) -> Color {
        index < 6 ? Panel.green : (index < 9 ? Panel.yellow : Panel.red)
    }

    var body: some View {
        let gap = (faderHeight - 10 * VUMeter.ledHeight) / 9
        HStack(spacing: 4) {
            VStack(alignment: .trailing, spacing: gap) {
                ForEach((0..<10).reversed(), id: \.self) { i in
                    Text(VUMeter.labels[i])
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundStyle(Panel.legendDim)
                        .frame(height: VUMeter.ledHeight)
                }
            }
            VStack(spacing: gap) {
                ForEach((0..<10).reversed(), id: \.self) { i in
                    let lit = levelDB >= VUMeter.thresholds[i]
                    let colour = VUMeter.colour(i)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(lit ? colour : colour.opacity(0.16))
                        .overlay(RoundedRectangle(cornerRadius: 2).stroke(Color.black.opacity(0.6), lineWidth: 0.5))
                        .shadow(color: lit ? colour.opacity(0.8) : Color.clear, radius: 3)
                        .frame(width: 16, height: VUMeter.ledHeight)
                }
            }
        }
        .frame(height: faderHeight)
        .onReceive(timer) { _ in
            let level = tap.level
            let db: Float = level > 1e-6 ? 20 * log10(level) : -100
            if db != levelDB { levelDB = db }
        }
    }
}

// MARK: - Mini oscilloscope

/// Very dark green rounded rectangle with a bright green beam. Exactly
/// `ScopeLayout.points` samples are drawn, one per point of width.
struct ScopeView: View {
    let tap: ScopeTap
    @State private var samples = [Float](repeating: 0, count: ScopeLayout.points)
    @State private var lastFrame: UInt32 = 0
    private let timer = Timer.publish(every: 1.0 / 60.0, on: .main, in: .common).autoconnect()

    private static let screen = Color(red: 0.0, green: 0.05, blue: 0.02)
    private static let beam = Color(red: 0.25, green: 1.0, blue: 0.35)

    var body: some View {
        Canvas { ctx, size in
            let mid = size.height / 2
            // faint centre line
            var axis = Path()
            axis.move(to: CGPoint(x: 0, y: mid))
            axis.addLine(to: CGPoint(x: size.width, y: mid))
            ctx.stroke(axis, with: .color(ScopeView.beam.opacity(0.12)), lineWidth: 0.5)

            let n = samples.count
            guard n > 1 else { return }
            let amp = size.height * 0.45
            var path = Path()
            for i in 0..<n {
                let x = CGFloat(i) * size.width / CGFloat(n - 1)
                let y = mid - CGFloat(max(-1, min(1, samples[i]))) * amp
                if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
            }
            ctx.stroke(path, with: .color(ScopeView.beam.opacity(0.25)), lineWidth: 3)   // glow
            ctx.stroke(path, with: .color(ScopeView.beam), lineWidth: 1.1)               // beam
        }
        .frame(width: ScopeLayout.width, height: ScopeLayout.height)
        .background(RoundedRectangle(cornerRadius: 8).fill(ScopeView.screen))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Panel.legendDim, lineWidth: 0.5))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .onReceive(timer) { _ in
            let frame = tap.frameCount
            if frame != lastFrame {
                lastFrame = frame
                tap.read(into: &samples)
            }
        }
    }
}

// MARK: - Section frame

struct PanelSection<Content: View>: View {
    private let title: String
    private let width: CGFloat
    private let height: CGFloat
    private let dimmed: Bool
    private let content: Content

    init(title: String, width: CGFloat, height: CGFloat = 396, dimmed: Bool = false,
         @ViewBuilder content: () -> Content) {
        self.title = title
        self.width = width
        self.height = height
        self.dimmed = dimmed
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 10) {
            if !title.isEmpty {
                HStack(spacing: 8) {
                    Rectangle().fill(Panel.line).frame(height: 1)
                    Legend(text: title, dim: dimmed)
                    Rectangle().fill(Panel.line).frame(height: 1)
                }
            }
            content
                .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .padding(12)
        .frame(width: width, height: height)
        .background(RoundedRectangle(cornerRadius: 4).fill(Panel.section))
        .overlay(RoundedRectangle(cornerRadius: 4)
            .stroke(Panel.line.opacity(dimmed ? 0.25 : 0.5), lineWidth: 1))
    }
}

// MARK: - Transfer curve

/// What the tube stage does to a -1...+1 input, at each voice's Tube Type, Gain and Bias.
/// Dashed line is unity. Voice I orange, Voice II violet (both semi-transparent).
struct TransferCurveView: View {
    @ObservedObject var one: VoiceModel
    @ObservedObject var two: VoiceModel

    var body: some View {
        Canvas { context, size in
            var axes = Path()
            axes.move(to: CGPoint(x: 0, y: size.height / 2))
            axes.addLine(to: CGPoint(x: size.width, y: size.height / 2))
            axes.move(to: CGPoint(x: size.width / 2, y: 0))
            axes.addLine(to: CGPoint(x: size.width / 2, y: size.height))
            context.stroke(axes, with: .color(Panel.legendDim), lineWidth: 1)

            var unity = Path()
            unity.move(to: CGPoint(x: 0, y: size.height * 0.75))
            unity.addLine(to: CGPoint(x: size.width, y: size.height * 0.25))
            context.stroke(unity, with: .color(Panel.legendDim.opacity(0.6)),
                           style: StrokeStyle(lineWidth: 1, dash: [4, 4]))

            for (voice, colour) in [(one, Panel.glow), (two, Panel.violet)] {
                let index = min(max(Int(voice.tubeType.value.rounded()), 0), TubeType.allCases.count - 1)
                let type = TubeType(rawValue: index) ?? .twelveAX7
                let curve = TubeBank.shared.curve(index)
                let point = TubeOperatingPoint(curve: curve, tube: type, bias: voice.bias.value)
                let driveGain = Float(type.parameters.inputScaleVolts)
                    * Float(pow(10.0, Double(voice.drive.value) / 20.0))

                var path = Path()
                let steps = 240
                for i in 0...steps {
                    let x = Float(i) / Float(steps) * 2 - 1
                    let y = point.output(curve: curve, input: x, driveGain: driveGain)
                    let clamped = max(-2.0, min(2.0, y))
                    let px = CGFloat(i) / CGFloat(steps) * size.width
                    let py = size.height * (0.5 - CGFloat(clamped) / 4.0)
                    if i == 0 {
                        path.move(to: CGPoint(x: px, y: py))
                    } else {
                        path.addLine(to: CGPoint(x: px, y: py))
                    }
                }
                context.stroke(path, with: .color(colour.opacity(0.85)), lineWidth: 2)
            }
        }
        .background(Color.black.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .overlay(RoundedRectangle(cornerRadius: 3).stroke(Panel.line.opacity(0.4), lineWidth: 1))
    }
}

// MARK: - Waveform preview

/// One and a half cycles of each voice's selected waveform, drawn from the same shapes
/// the oscillator produces. PW is shown at its static setting (PWM is not drawn).
/// Voice I orange, Voice II violet (both semi-transparent).
struct WaveformPreview: View {
    @ObservedObject var one: VoiceModel
    @ObservedObject var two: VoiceModel

    var body: some View {
        Canvas { context, size in
            var centre = Path()
            centre.move(to: CGPoint(x: 0, y: size.height / 2))
            centre.addLine(to: CGPoint(x: size.width, y: size.height / 2))
            context.stroke(centre, with: .color(Panel.legendDim.opacity(0.6)), lineWidth: 1)

            for (n, (voice, colour)) in [(one, Panel.glow), (two, Panel.violet)].enumerated() {
                let shape = VCOWaveform(rawValue: Int(voice.waveform.value.rounded())) ?? .sawUp
                let width = min(max(Double(voice.pulseWidth.value), 0.05), 0.95)

                var path = Path()
                let steps = 300
                var random: UInt32 = n == 0 ? 12_345 : 54_321   // different noise for each voice
                for i in 0...steps {
                    let t = Double(i) / Double(steps) * 1.5
                    let p = t - floor(t)
                    var y: Double
                    switch shape {
                    case .sine:
                        y = sin(2.0 * Double.pi * p)
                    case .sawUp:
                        y = 2.0 * p - 1.0
                    case .sawDown:
                        y = 1.0 - 2.0 * p
                    case .square:
                        let edges = p < width ? 1.0 : -1.0
                        y = (edges - (2.0 * width - 1.0)) / (2.0 * max(width, 1.0 - width))
                    case .noise:
                        random ^= random << 13
                        random ^= random >> 17
                        random ^= random << 5
                        y = Double(random) / 2_147_483_648.0 - 1.0
                    }
                    let px = CGFloat(i) / CGFloat(steps) * size.width
                    let py = size.height * (0.5 - 0.42 * CGFloat(y))
                    if i == 0 {
                        path.move(to: CGPoint(x: px, y: py))
                    } else {
                        path.addLine(to: CGPoint(x: px, y: py))
                    }
                }
                context.stroke(path, with: .color(colour.opacity(0.85)), lineWidth: 2)
            }
        }
        .background(Color.black.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .overlay(RoundedRectangle(cornerRadius: 3).stroke(Panel.line.opacity(0.4), lineWidth: 1))
    }
}


// MARK: - Keyboard preview

/// What the keyboard needs from the audio unit. `.inactive` does nothing (used when there is no unit).
struct KeyboardLink {
    var noteOn: (UInt8, UInt8) -> Void = { _, _ in }     // (note, velocity)
    var noteOff: (UInt8) -> Void = { _ in }
    var isHeld: (UInt8) -> Bool = { _ in false }         // is a MIDI key (or the mouse) holding this note?

    static let inactive = KeyboardLink()
}

/// A piano key outline: white keys are a plain rounded rectangle; black keys have square top corners
/// and rounded bottom-left and bottom-right corners.
struct KeyShape: Shape {
    let black: Bool
    var whiteRadius: CGFloat = 6
    var blackRadius: CGFloat = 6

    func path(in rect: CGRect) -> Path {
        if !black {
            return Path(roundedRect: rect, cornerRadius: whiteRadius)
        }
        let r = min(blackRadius, rect.width / 2, rect.height / 2)
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY),
                    tangent2End: CGPoint(x: rect.minX, y: rect.maxY), radius: r)
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY),
                    tangent2End: CGPoint(x: rect.minX, y: rect.minY), radius: r)
        path.closeSubpath()
        return path
    }
}


/// Fixed C2...C6 on-screen keyboard. Dark aquatic bed; translucent blue when held.
/// Mouse down → note-on (vel 100); mouse up → note-off.
struct KeyboardPreview: View {
    let link: KeyboardLink

    private static let lowNote: UInt8 = 36   // C2
    private static let highNote: UInt8 = 84  // C6
    private static let mouseVelocity: UInt8 = 100

    private static let aquatic = Color(red: 0.02, green: 0.08, blue: 0.12)
    private static let whiteKey = Color(red: 0.82, green: 0.88, blue: 0.92)
    private static let whiteKeyEdge = Color(red: 0.55, green: 0.65, blue: 0.72)
    private static let blackKey = Color(red: 0.04, green: 0.06, blue: 0.10)
    private static let pressBlue = Color(red: 0.35, green: 0.75, blue: 1.0).opacity(0.35)

    @State private var heldMask: Set<UInt8> = []
    @State private var mouseDown: UInt8? = nil
    private let timer = Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()

    /// Pitch-class black-key map: C C# D D# E F F# G G# A A# B
    private static let isBlack: [Bool] = [
        false, true, false, true, false, false, true, false, true, false, true, false
    ]

    private var whiteNotes: [UInt8] {
        (Self.lowNote...Self.highNote).filter { !Self.isBlack[Int($0) % 12] }
    }

    private var blackNotes: [UInt8] {
        (Self.lowNote...Self.highNote).filter { Self.isBlack[Int($0) % 12] }
    }

    var body: some View {
        GeometryReader { geo in
            let whites = whiteNotes
            let whiteW = geo.size.width / CGFloat(whites.count)
            let whiteH = geo.size.height
            let blackW = whiteW * 0.58
            let blackH = whiteH * 0.58

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Self.aquatic)

                HStack(spacing: 0) {
                    ForEach(whites, id: \.self) { note in
                        keyView(note: note, width: whiteW, height: whiteH, black: false)
                    }
                }

                ForEach(blackNotes, id: \.self) { note in
                    let x = blackKeyX(note: note, whites: whites, whiteW: whiteW) - blackW / 2
                    keyView(note: note, width: blackW, height: blackH, black: true)
                        .offset(x: x, y: 0)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .overlay(RoundedRectangle(cornerRadius: 3).stroke(Panel.line.opacity(0.4), lineWidth: 1))
        .onReceive(timer) { _ in
            var next = Set<UInt8>()
            for n in Self.lowNote...Self.highNote where link.isHeld(n) {
                next.insert(n)
            }
            if next != heldMask { heldMask = next }
        }
        .onDisappear {
            if let n = mouseDown {
                link.noteOff(n)
                mouseDown = nil
            }
        }
    }

    /// `width` x `height` is the key's whole cell. A white key leaves 1 pt on the right and 2 pt at the
    /// bottom as its gap, inside the cell, so the cells line up exactly with the black keys.
    private func keyView(note: UInt8, width: CGFloat, height: CGFloat, black: Bool) -> some View {
        let pressed = heldMask.contains(note) || mouseDown == note
        let shape = KeyShape(black: black)
        return shape
            .fill(black ? Self.blackKey : Self.whiteKey)
            .overlay {
                if pressed {
                    shape.fill(Self.pressBlue)
                }
            }
            .overlay(
                shape.stroke(black ? Color.black.opacity(0.8) : Self.whiteKeyEdge, lineWidth: 0.5)
            )
            .padding(.trailing, black ? 0 : 1)
            .padding(.bottom, black ? 0 : 2)
            .frame(width: width, height: height, alignment: .topLeading)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if mouseDown != note {
                            if let prev = mouseDown { link.noteOff(prev) }
                            mouseDown = note
                            link.noteOn(note, Self.mouseVelocity)
                        }
                    }
                    .onEnded { _ in
                        if mouseDown == note {
                            link.noteOff(note)
                            mouseDown = nil
                        }
                    }
            )
    }

    /// Centre X of the black key (gap after the white keys strictly below this note).
    private func blackKeyX(note: UInt8, whites: [UInt8], whiteW: CGFloat) -> CGFloat {
        let whitesBelow = whites.filter { $0 < note }.count
        return CGFloat(whitesBelow) * whiteW
    }
}


// MARK: - Main view

struct PentoniqView: View {
    /// The size the panel is DESIGNED at: two voice rows (Voice I above Voice II) under the header.
    /// AudioUnitViewController uses it for the initial window size, and `body` scales the whole
    /// panel uniformly to fit whatever size the host window actually is, so nothing is clipped.
    //static let windowSize = CGSize(width: 1816, height: 938)
    static let windowSize = CGSize(width: 1816, height: 1100)   // 938 + 12 + 150

    /// The size the window STARTS at (80% of the design size, so it fits smaller screens).
    //static let initialSize = CGSize(width: 1453, height: 750)
    static let initialSize = CGSize(width: 1453, height: 880)   // ~80% of design

    @StateObject private var model: PentoniqViewModel

    private let midiActivity: () -> UInt32
    private let scope: ScopeTap?
    private let keyboard: KeyboardLink
    
    // Keeps the sliders in step with the audio unit (host presets, settings and automation).
    private let refreshTimer = Timer.publish(every: 1.0 / 15.0, on: .main, in: .common).autoconnect()
    
    private let learnTimer = Timer.publish(every: 1.0 / 30.0, on: .main, in: .common).autoconnect()

    /// `midiActivity` returns a counter that changes whenever MIDI arrives (drives the MIDI lamp).
    init(parameterTree: AUParameterTree,
         midiActivity: @escaping () -> UInt32 = { 0 },
         scope: ScopeTap? = nil,
         midiLearn: MIDILearnLink = MIDILearnLink(),
         keyboard: KeyboardLink = .inactive) {
        _model = StateObject(wrappedValue: PentoniqViewModel(tree: parameterTree, link: midiLearn))
        self.midiActivity = midiActivity
        self.scope = scope
        self.keyboard = keyboard
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("PENTONIQ")
                    .font(.system(size: 17, weight: .heavy))
                    .tracking(5)
                    .foregroundStyle(Panel.legend)
                Text("Tube Synth")
                    .font(.system(size: 13, weight: .regular))
                    .tracking(2)
                    .foregroundStyle(Panel.legendDim)
            }
            Spacer()
            Legend(text: "v0.7 (MILESTONE 11) • VOICE I + II, SUB-OSC, CS-80 ENVELOPES", dim: true)
                .padding(.trailing, 16)
            MIDIIndicator(activity: midiActivity)
            MIDILearnButton(learn: model.learn)
                .padding(.trailing, 16)
        }
    }
    
    /// Temporary diagnostic: shows the size the view is given. Set to true to see it.
    static let showSizeReadout = false

    /// Scale-to-fit: the panel is laid out at its design size, then scaled
    /// uniformly (and centred) to fit the window it is given.
    var body: some View {
        GeometryReader { geometry in
            let design = PentoniqView.windowSize
            let fit = min(geometry.size.width / design.width,
                          geometry.size.height / design.height)
            let scale = min(max(fit, 0.25), 4.0)
            panel
                .frame(width: design.width, height: design.height, alignment: .topLeading)
                .scaleEffect(scale)
                .frame(width: geometry.size.width, height: geometry.size.height)
                .overlay(alignment: .bottomTrailing) {
                    if PentoniqView.showSizeReadout {
                        Text("view \(Int(geometry.size.width)) x \(Int(geometry.size.height))  scale \(String(format: "%.2f", scale))")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Panel.legendDim)
                            .padding(4)
                    }
                }
        }
        .background(Panel.face)
        .environmentObject(model.learn)
        .onReceive(refreshTimer) { _ in model.refreshAll() }
        .onReceive(learnTimer) { _ in model.learn.poll() }
        .onDisappear { model.learn.cancel() }      // never leave the audio unit deaf to CCs
    }

    // MARK: Voice row (TUBE | VCO | VCF | ENVELOPE). Used for Voice I and again for Voice II.
    //
    // Controls belong to `v`. Only the Voice I row has graphs; they show BOTH voices
    // (Voice I orange, Voice II violet). The Voice II row is the same controls without graphs.

    @ViewBuilder
    private func voiceSections(_ v: VoiceModel, tag: String, showGraphs: Bool) -> some View {
        let one = model.voice1
        let two = model.voice2
        let sectionHeight: CGFloat = showGraphs ? 396 : compactSectionHeight

        // TUBE
        PanelSection(title: "TUBE " + tag, width: 316, height: sectionHeight) {
          if showGraphs {
            VStack(spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    TransferCurveView(one: one, two: two)
                        .frame(width: 180, height: 120)
                    VStack(alignment: .leading, spacing: 6) {
                        SwitchLamp(title: "TUBE ON", parameter: v.tubeEnabled)
                        Legend(text: "TYPE", dim: true)
                        ButtonBank(parameter: v.tubeType,
                                   labels: PentoniqParameters.tubeNames)
                    }
                }
                HStack(alignment: .top, spacing: 12) {
                    HStack(alignment: .top, spacing: 4) {
                        VerticalFader(label: "GAIN", parameter: v.drive,
                                      defaultValue: defaultValue(.drive),
                                      readout: { String(format: "%+.1f dB", Double($0)) })
                        VerticalFader(label: "BIAS", parameter: v.bias,
                                      defaultValue: defaultValue(.bias),
                                      readout: { String(format: "%+.2f", Double($0)) })
                        VerticalFader(label: "OUTPUT", parameter: v.output,
                                      defaultValue: defaultValue(.output),
                                      readout: { String(format: "%+.1f dB", Double($0)) })
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Legend(text: "OVERSAMPLE", dim: true)
                        ButtonBank(parameter: v.oversampling,
                                   labels: PentoniqParameters.oversamplingNames
                                    .map { $0.uppercased() })
                    }
                    .padding(.top, 14)
                }
            }
          } else {
            // Voice II has no graph: the type and oversample buttons sit beside the faders.
            HStack(alignment: .bottom, spacing: 12) {
                HStack(alignment: .top, spacing: 4) {
                    VerticalFader(label: "GAIN", parameter: v.drive,
                                  defaultValue: defaultValue(.drive),
                                  readout: { String(format: "%+.1f dB", Double($0)) })
                    VerticalFader(label: "BIAS", parameter: v.bias,
                                  defaultValue: defaultValue(.bias),
                                  readout: { String(format: "%+.2f", Double($0)) })
                    VerticalFader(label: "OUTPUT", parameter: v.output,
                                  defaultValue: defaultValue(.output),
                                  readout: { String(format: "%+.1f dB", Double($0)) })
                }
                VStack(alignment: .leading, spacing: 6) {
                    SwitchLamp(title: "TUBE ON", parameter: v.tubeEnabled)
                    Legend(text: "TYPE", dim: true)
                    ButtonBank(parameter: v.tubeType,
                               labels: PentoniqParameters.tubeNames)
                    Legend(text: "OVERSAMPLE", dim: true)
                    ButtonBank(parameter: v.oversampling,
                               labels: PentoniqParameters.oversamplingNames
                                .map { $0.uppercased() })
                }
            }
          }
        }

        // VCO
        PanelSection(title: "VCO " + tag, width: 360, height: sectionHeight) {
            VStack(spacing: 12) {
                if showGraphs {
                    WaveformPreview(one: one, two: two)
                        .frame(width: 332, height: graphHeight)
                }
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Legend(text: "WAVEFORM", dim: true)
                        ButtonBank(parameter: v.waveform,
                                   labels: PentoniqParameters.waveformNames
                                    .map { $0.uppercased() })
                        SwitchLamp(title: "SYNC", parameter: v.sync)
                            .padding(.top, 6)
                            .help("Reserved for MIDI sync. Not active yet.")
                    }
                    HStack(alignment: .top, spacing: 4) {
                        VerticalFader(label: "SPEED", parameter: v.speed,
                                      defaultValue: defaultValue(.speed),
                                      readout: { String(format: "%.2f Hz",
                                                        SynthSettings.lfoHertz(forSpeed: $0)) })
                        VerticalFader(label: "PWM", parameter: v.pwm,
                                      defaultValue: defaultValue(.pwm),
                                      readout: { String(format: "%.0f%%", Double($0) * 100) })
                        VerticalFader(label: "PW", parameter: v.pulseWidth,
                                      defaultValue: defaultValue(.pulseWidth),
                                      readout: { String(format: "%.0f%%", Double($0) * 100) })
                        VerticalFader(label: "NOISE", parameter: v.noise,
                                      defaultValue: defaultValue(.noise),
                                      readout: { String(format: "%.2f", Double($0)) })
                    }
                }
            }
        }

        // VCF: low-pass half is live, high-pass half is a placeholder
        PanelSection(title: "VCF " + tag, width: 276, height: sectionHeight) {
            VStack(spacing: 12) {
                if showGraphs {
                    VCFResponseGraph(one: one, two: two,
                                         brilliance: model.brilliance, resonanceOffset: model.mixResonance)
                        .frame(width: 252, height: graphHeight)
                }
                HStack(alignment: .top, spacing: 4) {
                    GhostFader(label: "HPF")
                    GhostFader(label: "RES H")
                    VerticalFader(label: "LPF", parameter: v.cutoff,
                                  defaultValue: defaultValue(.lpfCutoff),
                                  readout: hertzReadout)
                    VerticalFader(label: "RES L", parameter: v.resonance,
                                  defaultValue: defaultValue(.lpfResonance),
                                  readout: { String(format: "%.2f", Double($0)) })
                }
            }
        }

        // ENVELOPE (CS-80 style). VCF: IL, AL, AT, DT, RT. There is no sustain fader:
        // the sustain is the VCF cutoff itself. VCA: a plain ADSR.
        PanelSection(title: "ENVELOPE " + tag, width: 584, height: sectionHeight) {
            // .bottom: the divider is flexible in height, so top alignment pushed the faders up.
            HStack(alignment: .bottom, spacing: 12) {
                VStack(spacing: 12) {
                    if showGraphs {
                        VCFEnvelopeGraph(one: one, two: two)
                            .frame(width: 296, height: graphHeight)
                    }
                    HStack(alignment: .top, spacing: 4) {
                        VerticalFader(label: "IL", parameter: v.vcfInitialLevel,
                                      defaultValue: defaultValue(.vcfInitialLevel),
                                      readout: octaveReadout)
                        VerticalFader(label: "AL", parameter: v.vcfAttackLevel,
                                      defaultValue: defaultValue(.vcfAttackLevel),
                                      readout: octaveReadout)
                        VerticalFader(label: "AT", parameter: v.vcfAttack,
                                      defaultValue: defaultValue(.vcfAttack),
                                      readout: timeReadout)
                        VerticalFader(label: "DT", parameter: v.vcfDecay,
                                      defaultValue: defaultValue(.vcfDecay),
                                      readout: timeReadout)
                        VerticalFader(label: "RT", parameter: v.vcfRelease,
                                      defaultValue: defaultValue(.vcfRelease),
                                      readout: timeReadout)
                    }
                }
                Rectangle().fill(Panel.line.opacity(0.5)).frame(width: 1).padding(.vertical, 8)
                VStack(spacing: 12) {
                    if showGraphs {
                        VCAEnvelopeGraph(one: one, two: two)
                            .frame(width: 236, height: graphHeight)
                    }
                    HStack(alignment: .top, spacing: 4) {
                        VerticalFader(label: "A", parameter: v.ampAttack,
                                      defaultValue: defaultValue(.ampAttack),
                                      readout: timeReadout)
                        VerticalFader(label: "D", parameter: v.ampDecay,
                                      defaultValue: defaultValue(.ampDecay),
                                      readout: timeReadout)
                        VerticalFader(label: "S", parameter: v.ampSustain,
                                      defaultValue: defaultValue(.ampSustain),
                                      readout: levelReadout)
                        VerticalFader(label: "R", parameter: v.ampRelease,
                                      defaultValue: defaultValue(.ampRelease),
                                      readout: timeReadout)
                    }
                }
            }
        }
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            // VOICE I, then the global MASTER section
            HStack(alignment: .top, spacing: 10) {
                voiceSections(model.voice1, tag: "I", showGraphs: true)

                // MASTER (live)
                PanelSection(title: "MASTER", width: 200) {
                    VStack(spacing: 12) {
                        if let scope {
                            ScopeView(tap: scope)
                        }
                        HStack(alignment: .top, spacing: 12) {
                            if let scope {
                                VStack(spacing: 6) {
                                    Color.clear.frame(width: 1, height: 12)   // lines up with the fader readouts
                                    VUMeter(tap: scope)
                                    Legend(text: "dB", dim: true)
                                }
                            }
                            VerticalFader(label: "VOLUME", parameter: model.master,
                                          defaultValue: defaultValue(.masterVolume),
                                          readout: { String(format: "%.2f", Double($0)) })
                        }
                    }
                }
            }

            // VOICE II, then the global MIX section (Voice I + II fade and global resonant filter)
            HStack(alignment: .top, spacing: 10) {
                voiceSections(model.voice2, tag: "II", showGraphs: false)

                PanelSection(title: "MIX", width: 200, height: compactSectionHeight) {
                    VStack(spacing: 12) {
                        HStack(alignment: .top, spacing: 4) {
                            VerticalFader(label: "MIX", parameter: model.mix,
                                          defaultValue: defaultValue(.mix),
                                          readout: { String(format: "%.0f|%.0f", Double($0) * 100, (1 - Double($0)) * 100) })
                                .help("Fade between Voice II (bottom) and Voice I (top). Readout: Voice I % | Voice II %.")
                            VerticalFader(label: "RES", parameter: model.mixResonance,
                                          defaultValue: defaultValue(.mixResonance),
                                          readout: { String(format: "+%.2f", Double($0)) })
                                .help("Global RESONANCE: added to the resonance of every filter in both voices.")
                            VerticalFader(label: "BRILLIANCE", parameter: model.brilliance,
                                          defaultValue: defaultValue(.brilliance),
                                          readout: { String(format: "%+.1f oct", (Double($0) - 0.5) * 9.9658) })
                                .help("Global BRILLIANCE: shifts the cutoff of every filter in both voices. Centre = no shift.")
                        }
                    }
                }
            }

            // THIRD ROW: WHEEL | SUB-OSC | TONE SELECTOR | ARPEGGIATOR | DELAY
            // Nothing here is stored in the presets.
            HStack(alignment: .top, spacing: 10) {

                // i) WHEEL (live)
                PanelSection(title: "", width: 220, height: thirdRowHeight) {
                    WheelSection(wheelEnable: model.wheelEnable,
                                 wheelValue: model.wheelValue,
                                 detune: model.detune,
                                 pan: model.leslie)
                }

                // ii) SUB-OSC (live)
                PanelSection(title: "", width: 452, height: thirdRowHeight) {
                    SubOscSection(waveform: model.subWaveform, sync: model.subSync, speed: model.subSpeed,
                                  vco: model.subVCO, vcf: model.subVCF, vca: model.subVCA, pan: model.subPan)
                }

                // iii) TONE SELECTOR (live): the VFD display on top, the preset pads below.
                PanelSection(title: "TONE SELECTOR", width: 480, height: thirdRowHeight) {
                    VStack(alignment: .leading, spacing: 0) {
                        VFDDisplay(model: model.vfd)
                        PresetBlock(controller: model.presets)
                    }
                }

                // iv) ARPEGGIATOR (live)
                PanelSection(title: "ARPEGGIATOR", width: 300, height: thirdRowHeight) {
                    ArpSection(speed: model.arpSpeed, mode: model.arpMode, octave: model.arpOctave,
                               repeats: model.arpRepeat, sync: model.arpSync,
                               hold: model.arpHold, enable: model.arpEnable)
                }

                // v) DELAY + CHORUS (live)
                PanelSection(title: "DELAY", width: 270, height: thirdRowHeight) {
                    DelaySection(speed: model.delaySpeed, depth: model.delayDepth, mix: model.delayMix,
                                 sync: model.delaySync, chorus: model.delayChorus, enable: model.delayEnable)
                }
            }
            
            // FOURTH ROW: keyboard preview, C2 to C6 (MIDI 36...84, 49 keys)
            KeyboardPreview(link: keyboard)
                .frame(width: 1762, height: keyboardRowHeight)
            
        }
        .padding(16)
    }
}
