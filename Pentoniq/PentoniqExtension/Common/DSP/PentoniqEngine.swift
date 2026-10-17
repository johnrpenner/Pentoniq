// PentoniqEngine.swift
// Milestone 5: the polyphonic engine with the CS-80 style envelopes.
//
//   per voice:  VCO (+ noise, own PWM LFO)  ->  TUBE stage  ->  VCF  ->  amplifier
//               VCF cutoff   = cutoff fader + filter envelope (own envelope per voice)
//               amplifier    = amp ADSR (own envelope per voice) x velocity
//   shared:     sum of the voices, master volume
//
// Eight voices, as on the CS-80, each with its own oscillator, its own PWM LFO
// (the CS-80 has a separate LFO per oscillator), its own tube stage (so chord
// notes do not intermodulate through a shared tube), its own filter and its
// own two envelopes.
//
// The filter coefficients are now per voice (the envelope moves each voice's
// cutoff separately). The tangent they need is refreshed every
// `TubeVoice.controlInterval` samples instead of every sample, which keeps eight
// voices affordable; the envelope itself still runs at full sample rate.
//
// No dependency on AudioToolbox, so the unit tests can drive it directly.
// Nothing here allocates after init, so it is safe on the audio thread.

import Foundation

// MARK: - Settings snapshot

/// Plain values the kernel reads from the parameter storage once per block.
struct SynthSettings {
    var waveform = 1                 // VCOWaveform raw value; 1 = +saw
    var pulseWidth: Float = 0.5      // fraction high, 0.05...0.95
    var pwmDepth: Float = 0          // 0...1
    var speed: Float = 0.35          // 0...1, see lfoHertz(forSpeed:)
    var noiseLevel: Float = 0        // 0...1, mixed in with any waveform
    var sync = false                 // RESERVED for MIDI sync: no effect yet
    var tubeOn = true
    var tubeIndex = 0
    var bias: Float = 0
    var driveDB: Float = 6
    var outputDB: Float = 0
    var oversampling = 2
    var master: Float = 0.5
    var cutoff: Float = 1            // 0...1, see LadderCoefficients.cutoffHertz(forFader:)
    var resonance: Float = 0         // 0...1

    // Milestone 6: the CS-80's global BRILLIANCE and RESONANCE act as offsets on every voice's filter.
    // Brilliance shifts the cutoff, in fader units (the cutoff fader spans about 10 octaves per 1.0).
    // Resonance is added to the voice's resonance (the total is limited to 1).
    var brillianceOffset: Float = 0
    var resonanceOffset: Float = 0

    // Milestone 5: amplifier ADSR. Time faders 0...1, see EnvelopeSettings.seconds(forFader:).
    // The defaults reproduce the milestone 4 fade (about 18 ms in, 0.35 s release).
    var ampAttack: Float = 0.314
    var ampDecay: Float = 0.6
    var ampSustain: Float = 1
    var ampRelease: Float = 0.635

    // Milestone 5: VCF envelope (CS-80 style). IL and AL are offsets from the cutoff
    // fader in fader units (-1...+1, about 10 octaves per 1.0). The sustain is the
    // cutoff itself. With IL = AL = 0 it does nothing, which is also the M4 sound.
    var vcfInitialLevel: Float = 0
    var vcfAttackLevel: Float = 0
    var vcfAttack: Float = 0.55
    var vcfDecay: Float = 0.65
    var vcfRelease: Float = 0.6

    /// PWM LFO rate: exponential from 0.1 Hz (speed 0) to 20 Hz (speed 1).
    static func lfoHertz(forSpeed speed: Float) -> Double {
        0.1 * pow(200.0, Double(min(max(speed, 0), 1)))
    }
}

// MARK: - One voice

final class TubeVoice {

    /// Samples between refreshes of this voice's filter coefficients (about 0.18 ms at 44.1 kHz).
    static let controlInterval = 8

    let tube: TubeStage
    private var oscillator: VCOOscillator
    private var filter = LadderFilter()
    private var coefficients = LadderCoefficients()
    private var coefficientCountdown = 0
    private var ampEnvelope = Envelope()
    private var filterEnvelope = Envelope()
    private var lfoPhase: Double              // this voice's own PWM LFO

    private(set) var note: UInt8 = 0
    private(set) var velocity: Float = 0
    private(set) var gate = false
    private(set) var order: UInt64 = 0     // allocation order, used for stealing

    /// `index` staggers the LFO start phase so the voices do not all sweep
    /// their pulse widths in lock-step.
    init(bank: TubeBank, seed: UInt32, index: Int) {
        tube = TubeStage(bank: bank)
        oscillator = VCOOscillator(seed: seed)
        lfoPhase = (Double(index) * 0.3819660112501051).truncatingRemainder(dividingBy: 1.0)
    }

    /// Current amplifier level (0 when silent).
    var level: Float { ampEnvelope.level }

    /// Sounding, or still in its release tail.
    var isActive: Bool { ampEnvelope.isActive }

    func setSampleRate(_ rate: Double) {
        tube.setSampleRate(rate)
    }

    func noteOn(note: UInt8, velocity: Float, order: UInt64, sampleRate: Double,
                amp: EnvelopeSettings, filterEnvelope filterSettings: EnvelopeSettings) {
        let wasActive = isActive
        self.note = note
        self.velocity = velocity
        self.order = order
        gate = true
        let hertz = 440.0 * exp2((Double(note) - 69.0) / 12.0)
        oscillator.setFrequency(hertz, sampleRate: sampleRate)
        if !wasActive {
            // Fresh voice: start from a known state. A stolen or retriggered
            // voice keeps its phase and envelope levels so there is no click.
            oscillator.reset()
            tube.reset()
            filter.reset()
            coefficientCountdown = 0
        }
        ampEnvelope.gateOn(amp, fresh: !wasActive)
        filterEnvelope.gateOn(filterSettings, fresh: !wasActive)
    }

    func noteOff() {
        gate = false
        ampEnvelope.gateOff()
        filterEnvelope.gateOff()
    }

    func kill() {
        gate = false
        ampEnvelope.reset()
        filterEnvelope.reset()
        tube.reset()
        filter.reset()
        coefficientCountdown = 0
    }

    @inline(__always)
    func process(waveform: VCOWaveform, pulseWidth: Double, pwmDepth: Double,
                 lfoIncrement: Double, noiseLevel: Float,
                 tubeOn: Bool, cutoff: Float, resonance: Float, sampleRate: Double,
                 amp: EnvelopeSettings, filterEnvelope filterSettings: EnvelopeSettings) -> Float {

        // Per-voice PWM LFO. Only the square wave uses it.
        lfoPhase += lfoIncrement
        if lfoPhase >= 1.0 { lfoPhase -= 1.0 }
        var width = pulseWidth
        if waveform == .square && pwmDepth > 0 {
            width += pwmDepth * 0.45 * sin(2.0 * Double.pi * lfoPhase)
        }
        width = min(max(width, 0.05), 0.95)

        var x = oscillator.next(waveform, pulseWidth: width)
        // The Noise fader mixes noise into the other waveforms; the Noise
        // waveform is already noise, so the fader is ignored there.
        if waveform != .noise && noiseLevel > 0 { x += noiseLevel * oscillator.nextNoise() }

        // The tube always runs while the voice sounds, so its filters stay warm
        // and switching it on mid-note does not click.
        let shaped = tube.process(x)
        let y = tubeOn ? shaped : x

        // VCF: after the tube, before the amplifier. The filter envelope adds to
        // the cutoff fader (in fader units, which are octaves on a log scale).
        let sweep = filterEnvelope.process(filterSettings)
        if coefficientCountdown <= 0 {
            let fader = min(max(cutoff + sweep, 0), 1)
            coefficients = LadderCoefficients(
                cutoffHertz: LadderCoefficients.cutoffHertz(forFader: fader),
                resonance: resonance, sampleRate: sampleRate)
            coefficientCountdown = TubeVoice.controlInterval
        }
        coefficientCountdown -= 1
        let filtered = filter.process(y, coefficients)

        // Amplifier.
        let amplitude = ampEnvelope.process(amp)
        return filtered * amplitude * velocity
    }
}

// MARK: - Engine

final class PentoniqEngine {

    static let voiceCount = 8

    private let bank: TubeBank
    private let voices: [TubeVoice]

    private var sampleRate = 44_100.0
    private var settings = SynthSettings()
    private var waveform: VCOWaveform = .sawUp
    private var configured = false

    // One-pole smoothing (about 5 ms) for the controls that would otherwise zipper.
    private var smoothing: Float = 0.01
    private var pulseWidth: Float = 0.5
    private var pwmDepth: Float = 0
    private var noiseLevel: Float = 0
    private var master: Float = 0.5
    private var cutoff: Float = 1
    private var resonance: Float = 0

    // Envelope settings, rebuilt once per block from the faders.
    private var ampEnvelope = EnvelopeSettings()
    private var filterEnvelope = EnvelopeSettings()

    // PWM LFO rate (phase increment per sample); each voice runs its own LFO.
    private var lfoIncrement = 0.0

    private var orderCounter: UInt64 = 0

    init() {
        let bank = TubeBank()
        self.bank = bank
        voices = (0..<PentoniqEngine.voiceCount).map { index in
            TubeVoice(bank: bank, seed: 0x9E37_79B9 &* UInt32(index + 1), index: index)
        }
    }

    // MARK: Setup (not real-time)

    func setSampleRate(_ rate: Double) {
        sampleRate = rate
        smoothing = Float(1.0 - exp(-1.0 / (0.005 * rate)))
        for voice in voices { voice.setSampleRate(rate) }
        reset()
    }

    func reset() {
        for voice in voices { voice.kill() }
        configured = false
    }

    // MARK: Per block

    func configure(_ s: SynthSettings) {
        settings = s
        waveform = VCOWaveform(rawValue: s.waveform) ?? .sawUp
        lfoIncrement = SynthSettings.lfoHertz(forSpeed: s.speed) / sampleRate

        // Amplifier ADSR: 0 -> 1 -> sustain, release to 0.
        ampEnvelope = EnvelopeSettings(
            initialLevel: 0, attackLevel: 1, sustainLevel: s.ampSustain, releaseLevel: 0,
            attackFader: s.ampAttack, decayFader: s.ampDecay, releaseFader: s.ampRelease,
            sampleRate: sampleRate)
        // VCF envelope, CS-80 style: offsets from the cutoff fader. IL -> AL, decay to 0
        // (the cutoff itself: there is no sustain fader), release back down to IL.
        filterEnvelope = EnvelopeSettings(
            initialLevel: s.vcfInitialLevel, attackLevel: s.vcfAttackLevel,
            sustainLevel: 0, releaseLevel: s.vcfInitialLevel,
            attackFader: s.vcfAttack, decayFader: s.vcfDecay, releaseFader: s.vcfRelease,
            sampleRate: sampleRate)

        for voice in voices {
            voice.tube.configure(tubeIndex: s.tubeIndex, bias: s.bias, driveDB: s.driveDB,
                                 outputDB: s.outputDB, oversampling: s.oversampling)
        }
        if !configured {              // first call: start at the targets, no ramp
            pulseWidth = s.pulseWidth
            pwmDepth = s.pwmDepth
            noiseLevel = s.noiseLevel
            master = s.master
            cutoff = s.cutoff + s.brillianceOffset
            resonance = min(s.resonance + s.resonanceOffset, 1)
            configured = true
        }
    }

    // MARK: Notes

    func noteOn(note: UInt8, velocity: UInt8) {
        orderCounter &+= 1
        let voice = allocate(note: note)
        voice.noteOn(note: note, velocity: Float(velocity) / 127.0,
                     order: orderCounter, sampleRate: sampleRate,
                     amp: ampEnvelope, filterEnvelope: filterEnvelope)
    }

    func noteOff(note: UInt8) {
        for voice in voices where voice.gate && voice.note == note {
            voice.noteOff()
        }
    }

    func allNotesOff() {
        for voice in voices { voice.noteOff() }
    }

    /// Voices that are sounding or fading out.
    var activeVoiceCount: Int {
        voices.reduce(0) { $0 + ($1.isActive ? 1 : 0) }
    }

    /// True while a key for `note` is held down on some voice.
    func isHeld(note: UInt8) -> Bool {
        voices.contains { $0.gate && $0.note == note }
    }

    /// CS-80 style allocation: re-use the voice already playing this note,
    /// else a free voice, else steal (a fading voice first, then the oldest).
    private func allocate(note: UInt8) -> TubeVoice {
        for voice in voices where voice.isActive && voice.note == note {
            return voice
        }
        for voice in voices where !voice.isActive {
            return voice
        }
        var victim: TubeVoice? = nil
        for voice in voices where !voice.gate {
            if let current = victim {
                if voice.order < current.order { victim = voice }
            } else {
                victim = voice
            }
        }
        if let fading = victim { return fading }
        var oldest = voices[0]
        for voice in voices where voice.order < oldest.order { oldest = voice }
        return oldest
    }

    // MARK: Per sample (audio thread)

    func process() -> Float {
        pulseWidth += (settings.pulseWidth - pulseWidth) * smoothing
        pwmDepth += (settings.pwmDepth - pwmDepth) * smoothing
        noiseLevel += (settings.noiseLevel - noiseLevel) * smoothing
        master += (settings.master - master) * smoothing
        // The global offsets ride on top of the voice's own faders (the voice clamps the final value).
        cutoff += (settings.cutoff + settings.brillianceOffset - cutoff) * smoothing
        resonance += (min(settings.resonance + settings.resonanceOffset, 1) - resonance) * smoothing

        var mix: Float = 0
        for voice in voices where voice.isActive {
            mix += voice.process(waveform: waveform,
                                 pulseWidth: Double(pulseWidth), pwmDepth: Double(pwmDepth),
                                 lfoIncrement: lfoIncrement, noiseLevel: noiseLevel,
                                 tubeOn: settings.tubeOn,
                                 cutoff: cutoff, resonance: resonance, sampleRate: sampleRate,
                                 amp: ampEnvelope, filterEnvelope: filterEnvelope)
        }
        return mix * master * 0.5
    }
}
