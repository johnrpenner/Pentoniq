// Filter.swift
// Milestone 4, part 1 of 3: the VCF core, a four-pole resonant low-pass
// "ladder" in the Moog style (24 dB per octave, resonance by feedback).
//
// Built as a zero-delay-feedback (trapezoidal) ladder, written from the
// published technique (Zavalishin, "The Art of VA Filter Design"), not copied
// from any implementation. Why not the classic Huovilainen form with a one
// sample feedback delay: that delay detunes the resonance and weakens it as the
// cutoff rises (in the prototype the peak all but vanished above about 2 kHz).
// With the feedback solved exactly, the cutoff is where you set it and the
// resonance behaves the same at every frequency:
//
//   * gain at the cutoff with no resonance: -12 dB (four poles, -3 dB each)
//   * resonance peak sits on the cutoff; self-oscillation starts near the top
//     of the Resonance control and rings at the cutoff frequency
//
// Saturation: a tanh sits on the summed input of the ladder, so a hot signal
// or a ringing resonance is squashed instead of running away. The input is
// scaled down (x0.5) before and up (x2) after, so ordinary levels pass through
// almost linearly and the open filter stays close to transparent.
//
// Classic Moog behaviour is kept on purpose: turning Resonance up thins the
// low end of the passband.
//
// Placement in the voice: VCO -> tube -> VCF -> amplitude.
//
// No dependency on AudioToolbox (also usable from the unit-test target).
// Nothing allocates; safe on the audio thread.

import Foundation

/// Coefficients for one filter setting. Cheap to build (one tangent), so the
/// engine rebuilds it every sample while the controls are moving.
struct LadderCoefficients {
    var g: Float = 1          // one-pole gain G = g / (1 + g)
    var g2: Float = 1
    var g3: Float = 1
    var oneMinusG: Float = 0
    var k: Float = 0          // feedback amount, 0...kMax
    var invD: Float = 1       // 1 / (1 + k * G^4)

    /// Feedback at Resonance = 1. A four-pole ladder self-oscillates at k = 4;
    /// the margin above it keeps the top of the control ringing.
    static let kMax: Float = 4.2

    /// Cutoff control (0...1) to hertz: 20 Hz to 20 kHz, exponential.
    static func cutoffHertz(forFader x: Float) -> Double {
        20.0 * pow(1000.0, Double(min(max(x, 0), 1)))
    }

    init() {}

    init(cutoffHertz: Double, resonance: Float, sampleRate: Double) {
        // Stay well below Nyquist: the tangent blows up there.
        let hertz = min(max(cutoffHertz, 5.0), 0.45 * sampleRate)
        let t = tan(Double.pi * hertz / sampleRate)
        let big = t / (1.0 + t)
        g = Float(big)
        g2 = g * g
        g3 = g2 * g
        oneMinusG = 1 - g
        k = LadderCoefficients.kMax * min(max(resonance, 0), 1)
        invD = 1 / (1 + k * g2 * g2)
    }
}

struct LadderFilter {

    private var s0: Float = 0     // trapezoidal integrator states, one per pole
    private var s1: Float = 0
    private var s2: Float = 0
    private var s3: Float = 0

    mutating func reset() {
        s0 = 0; s1 = 0; s2 = 0; s3 = 0
    }

    @inline(__always)
    mutating func process(_ x: Float, _ c: LadderCoefficients) -> Float {
        // Part of the output that does not depend on the current input: lets
        // the feedback be solved exactly instead of through a delay.
        let memory = c.g3 * c.oneMinusG * s0 + c.g2 * c.oneMinusG * s1
            + c.g * c.oneMinusG * s2 + c.oneMinusG * s3
        let u = tanh((0.5 * x - c.k * memory) * c.invD)

        // Four trapezoidal one-poles in series.
        var v = (u - s0) * c.g
        let y0 = v + s0
        s0 = y0 + v

        v = (y0 - s1) * c.g
        let y1 = v + s1
        s1 = y1 + v

        v = (y1 - s2) * c.g
        let y2 = v + s2
        s2 = y2 + v

        v = (y2 - s3) * c.g
        let y3 = v + s3
        s3 = y3 + v

        return 2.0 * y3
    }
}
