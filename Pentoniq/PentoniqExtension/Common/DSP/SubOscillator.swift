// SubOscillator.swift  (milestone 11: the CS-80 style sub-oscillator)
// Add to the EXTENSION target. No dependency on AudioToolbox.
//
// ONE shared low-frequency modulator for every voice of both Voice I and Voice II. The kernel runs it
// once per sample and feeds four sends:
//     VCO  vibrato          up to +/-2 semitones
//     VCF  filter wobble    up to +/-3 octaves
//     VCA  tremolo          up to 100%
//     PAN  opposed panning  Voice I and Voice II swing in opposite directions
// Each send is multiplied by the WHEEL value (0...1) before it is used.
//
// Speed fader: bottom = OFF (no modulation at all). Free mode: 0.1 Hz to 20 Hz, exponential.
// Sync mode: the fader steps through note values from 32 bars (slowest) to 1/64 (fastest),
// locked to the host tempo (127 BPM when the host gives none).
//
// Nothing allocates; safe on the audio thread.

import Foundation

enum SubOscWaveform: Int, CaseIterable {
    case sine = 0
    case triangle
    case saw
    case square
    case sampleAndHold

    var displayName: String {
        switch self {
        case .sine: return "Sine"
        case .triangle: return "Triangle"
        case .saw: return "Saw"
        case .square: return "Square"
        case .sampleAndHold: return "S+H"
        }
    }
}

/// Full-scale depth of each send (send fader = 1, wheel = 1).
enum SubOscDepth {
    static let vibratoSemitones: Float = 2
    static let wobbleOctaves: Float = 3
    /// The cutoff fader spans about 9.97 octaves per 1.0.
    static let faderUnitsPerOctave: Float = 1 / 9.9658
}

enum SubOscRate {
    /// Speed fader below this is OFF.
    static let offBelow: Float = 0.01
    static let defaultBPM = 127.0

    /// Note values, slowest to fastest. `beats` = length of one LFO cycle in quarter notes.
    static let divisions: [(name: String, beats: Double)] = [
        ("32 BARS", 128), ("16 BARS", 64), ("8 BARS", 32), ("4 BARS", 16), ("2 BARS", 8), ("1 BAR", 4),
        ("1/2.", 3), ("1/2", 2), ("1/4.", 1.5), ("1/2T", 4.0 / 3.0), ("1/4", 1),
        ("1/8.", 0.75), ("1/4T", 2.0 / 3.0), ("1/8", 0.5), ("1/16.", 0.375), ("1/8T", 1.0 / 3.0),
        ("1/16", 0.25), ("1/32.", 0.1875), ("1/16T", 1.0 / 6.0), ("1/32", 0.125),
        ("1/32T", 1.0 / 12.0), ("1/64", 0.0625)
    ]

    static func isOff(_ speed: Float) -> Bool { speed < offBelow }

    /// Free mode: 0.1 Hz (bottom) to 120 Hz (top, twice the 60 Hz mains frequency).
    /// About 6 Hz, a standard vibrato, at 0.58.
    static func freeHertz(forSpeed speed: Float) -> Double {
        0.1 * pow(1200.0, Double(min(max(speed, 0), 1)))
    }

    static func divisionIndex(forSpeed speed: Float) -> Int {
        let x = (min(max(speed, offBelow), 1) - offBelow) / (1 - offBelow)
        return min(Int(x * Float(divisions.count)), divisions.count - 1)
    }

    /// LFO frequency in hertz; 0 means off.
    static func hertz(speed: Float, sync: Bool, bpm: Double) -> Double {
        if isOff(speed) { return 0 }
        if sync { return (bpm / 60.0) / divisions[divisionIndex(forSpeed: speed)].beats }
        return freeHertz(forSpeed: speed)
    }

    /// Text for the SPEED fader readout.
    static func readout(speed: Float, sync: Bool) -> String {
        if isOff(speed) { return "OFF" }
        if sync { return divisions[divisionIndex(forSpeed: speed)].name }
        let hz = freeHertz(forSpeed: speed)
        if hz < 10 { return String(format: "%.2f Hz", hz) }
        return hz < 100 ? String(format: "%.1f Hz", hz) : String(format: "%.0f Hz", hz)
    }
}

struct SubOscillator {

    private var phase = 0.0
    private var increment = 0.0          // 0 = off
    private var held: Float = 0.6        // current sample-and-hold value
    private var noiseState: UInt32 = 0x2545_F491
    private var smoothed: Float = 0
    private var slew: Float = 0.1        // about 2 ms: takes the clicks off square, saw and S+H steps

    mutating func configure(sampleRate: Double) {
        slew = Float(1.0 - exp(-1.0 / (0.002 * sampleRate)))
        reset()
    }

    mutating func reset() {
        phase = 0
        smoothed = 0
    }

    /// `hertz` = 0 turns the modulator off.
    mutating func setRate(hertz: Double, sampleRate: Double) {
        increment = hertz > 0 ? min(hertz / sampleRate, 0.25) : 0
        // Edge smoothing: 2 ms at slow rates, shortened at fast ones so a 120 Hz wave keeps its shape.
        let seconds = hertz > 0 ? min(0.002, 0.08 / hertz) : 0.002
        slew = Float(1.0 - exp(-1.0 / (seconds * sampleRate)))
    }

    @inline(__always)
    private mutating func randomValue() -> Float {
        noiseState ^= noiseState << 13
        noiseState ^= noiseState >> 17
        noiseState ^= noiseState << 5
        return Float(noiseState) * (1.0 / 2_147_483_648.0) - 1.0
    }

    /// One sample, -1...+1. Every shape starts at 0 (S+H starts at its held value).
    @inline(__always)
    mutating func next(waveform: SubOscWaveform) -> Float {
        var target: Float = 0
        if increment > 0 {
            let p = phase
            switch waveform {
            case .sine:
                target = Float(sin(2.0 * Double.pi * p))
            case .triangle:
                target = Float(1.0 - 4.0 * abs((p + 0.25).truncatingRemainder(dividingBy: 1.0) - 0.5))
            case .saw:
                target = Float(2.0 * (p + 0.5).truncatingRemainder(dividingBy: 1.0) - 1.0)
            case .square:
                target = p < 0.5 ? 1 : -1
            case .sampleAndHold:
                target = held
            }
            phase += increment
            if phase >= 1.0 {
                phase -= 1.0
                held = randomValue()
            }
        }
        smoothed += (target - smoothed) * slew
        if target == 0 && abs(smoothed) < 1e-7 { smoothed = 0 }
        return smoothed
    }
}
