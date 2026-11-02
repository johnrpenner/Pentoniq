// Oscillator.swift
// Milestone 3, part 1 of 3: the VCO core.
//
// One oscillator = one phase accumulator that can produce five waveforms:
//
//     sine, +sawtooth (rising ramp), -sawtooth (falling ramp),
//     square / pulse (variable width), noise
//
// The saw and pulse are band-limited with PolyBLEP: the naive waveform is
// corrected for a couple of samples around each step so the harmonics that
// would fold back past Nyquist (aliasing) are largely suppressed. (Measured in
// a prototype: about 24 dB less aliasing than a naive saw at 11 kHz.)
// PolyBLEP is Tale's published technique; the code here is written from the
// technique, not copied from any implementation.
//
// The pulse is made DC-free and scaled so its peak is exactly +/-1 at every
// pulse width. That matters because the tube stage follows the oscillator: DC
// at its input would shift the tube's bias, and PWM would then also modulate
// the bias.
//
// No dependency on AudioToolbox (also usable from the unit-test target).
// Nothing allocates; safe on the audio thread.

import Foundation

enum VCOWaveform: Int, CaseIterable {
    case sine = 0
    case sawUp
    case sawDown
    case square
    case noise

    var displayName: String {
        switch self {
        case .sine: return "Sine"
        case .sawUp: return "+Saw"
        case .sawDown: return "-Saw"
        case .square: return "Square"
        case .noise: return "Noise"
        }
    }
}

/// PolyBLEP residual for a unit step at t = 0 (and t = 1). `t` is the phase in
/// 0..<1 and `dt` the phase increment per sample.
@inline(__always)
private func polyBLEP(_ t: Double, _ dt: Double) -> Double {
    if t < dt {
        let x = t / dt
        return x + x - x * x - 1.0
    } else if t > 1.0 - dt {
        let x = (t - 1.0) / dt
        return x * x + x + x + 1.0
    }
    return 0.0
}

struct VCOOscillator {

    private(set) var phase: Double = 0
    private(set) var phaseIncrement: Double = 0
    private var noiseState: UInt32

    /// `seed` must differ between oscillators so voices do not share noise.
    init(seed: UInt32 = 0x1234_5678) {
        noiseState = seed == 0 ? 1 : seed
    }

    mutating func reset() {
        phase = 0
    }

    mutating func setFrequency(_ hertz: Double, sampleRate: Double) {
        // Capped well below Nyquist: PolyBLEP is only valid for dt < 0.5.
        phaseIncrement = min(max(hertz / sampleRate, 0.0), 0.45)
    }

    /// White noise, uniform in -1...+1 (xorshift32: fast, no allocation).
    @inline(__always)
    mutating func nextNoise() -> Float {
        noiseState ^= noiseState << 13
        noiseState ^= noiseState >> 17
        noiseState ^= noiseState << 5
        return Float(noiseState) * (1.0 / 2_147_483_648.0) - 1.0
    }

    /// Next sample. `pulseWidth` is the fraction of the cycle spent high
    /// (0.5 = square); it only affects `.square`.
    @inline(__always)
    mutating func next(_ waveform: VCOWaveform, pulseWidth: Double = 0.5) -> Float {
        let t = phase
        let dt = phaseIncrement
        var value: Double

        switch waveform {
        case .sine:
            value = sin(2.0 * Double.pi * t)

        case .sawUp:
            value = 2.0 * t - 1.0 - polyBLEP(t, dt)

        case .sawDown:
            value = -(2.0 * t - 1.0 - polyBLEP(t, dt))

        case .square:
            let w = min(max(pulseWidth, 0.02), 0.98)
            var edges = t < w ? 1.0 : -1.0
            edges += polyBLEP(t, dt)                 // rising edge at t = 0
            var shifted = t + 1.0 - w
            if shifted >= 1.0 { shifted -= 1.0 }
            edges -= polyBLEP(shifted, dt)           // falling edge at t = w
            // Remove the DC offset (2w - 1) and rescale to a +/-1 peak.
            value = (edges - (2.0 * w - 1.0)) / (2.0 * max(w, 1.0 - w))

        case .noise:
            value = Double(nextNoise())
        }

        phase += dt
        if phase >= 1.0 { phase -= 1.0 }
        return Float(value)
    }
}
