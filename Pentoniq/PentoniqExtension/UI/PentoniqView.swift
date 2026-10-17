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

private enum Panel {
    static let face = Color(red: 0.075, green: 0.068, blue: 0.062)
    static let section = Color(red: 0.115, green: 0.105, blue: 0.095)
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

        let all = [tubeEnabled, tubeType, drive, bias, output, oversampling,
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

    init(tree: AUParameterTree) {
        func make(_ id: ParamID) -> ObservedParameter {
            ObservedParameter(tree.parameter(withAddress: id.rawValue)!)
        }
        master = make(.masterVolume)
        mix = make(.mix)
        mixResonance = make(.mixResonance)
        brilliance = make(.brilliance)
        voice1 = VoiceModel(tree: tree, ids: PentoniqParameters.voiceIIPairs.map { $0.base })
        voice2 = VoiceModel(tree: tree, ids: PentoniqParameters.voiceIIPairs.map { $0.v2 })
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

    var body: some View {
        let low = Double(parameter.parameter.minValue)
        let high = Double(parameter.parameter.maxValue)
        VStack(spacing: 6) {
            Text(readout(parameter.value))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Panel.glow)
                .frame(height: 12)
            FaderTrack(normalized: (Double(parameter.value) - low) / (high - low),
                       height: height,
                       onChange: { parameter.set(AUValue(low + $0 * (high - low))) },
                       onReset: { parameter.set(defaultValue) })
            Legend(text: label)
        }
        .frame(width: 56)
    }
}

/// A dimmed, non-interactive fader marking where a future control will sit.
struct GhostFader: View {
    let label: String
    var position: Double = 0.5

    var body: some View {
        VStack(spacing: 6) {
            Text("--")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Panel.legendDim)
                .frame(height: 12)
            FaderTrack(normalized: position, height: faderHeight,
                       onChange: { _ in }, onReset: {})
                .allowsHitTesting(false)
            Legend(text: label, dim: true)
        }
        .frame(width: 56)
        .opacity(0.5)
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
        HStack(spacing: 5) {
            Circle()
                .fill(lit ? Panel.green : Color.black)
                .overlay(Circle().stroke(Panel.legendDim, lineWidth: 0.5))
                .shadow(color: lit ? Panel.green.opacity(0.9) : Color.clear, radius: 3)
                .frame(width: 8, height: 8)
            Legend(text: "MIDI")
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
            HStack(spacing: 8) {
                Rectangle().fill(Panel.line).frame(height: 1)
                Legend(text: title, dim: dimmed)
                Rectangle().fill(Panel.line).frame(height: 1)
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

// MARK: - Main view

struct PentoniqView: View {
    /// The size the panel is DESIGNED at: two voice rows (Voice I above Voice II) under the header.
    /// AudioUnitViewController uses it for the initial window size, and `body` scales the whole
    /// panel uniformly to fit whatever size the host window actually is, so nothing is clipped.
    static let windowSize = CGSize(width: 1816, height: 776)

    /// The size the window STARTS at (80% of the design size, so it fits smaller screens).
    static let initialSize = CGSize(width: 1453, height: 621)

    @StateObject private var model: PentoniqViewModel

    private let midiActivity: () -> UInt32
    private let scope: ScopeTap?

    /// `midiActivity` returns a counter that changes whenever MIDI arrives (drives the MIDI lamp).
    init(parameterTree: AUParameterTree, midiActivity: @escaping () -> UInt32 = { 0 },
         scope: ScopeTap? = nil) {
        _model = StateObject(wrappedValue: PentoniqViewModel(tree: parameterTree))
        self.midiActivity = midiActivity
        self.scope = scope
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
            MIDIIndicator(activity: midiActivity)
                .padding(.trailing, 14)
            Legend(text: "MILESTONE 6  -  VOICE I + VOICE II, MIX, CS-80 ENVELOPES, 8 VOICES EACH", dim: true)
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
        }
        .padding(16)
    }
}
