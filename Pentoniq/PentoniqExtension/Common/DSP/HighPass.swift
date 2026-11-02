// HighPass.swift  (milestone 12: the VCF's high-pass half)
// Add to the EXTENSION target only. No dependency on AudioToolbox.
//
// A four-pole (24 dB per octave) resonant HIGH-pass ladder, the mirror image of the low-pass in
// Filter.swift: the same zero-delay-feedback (trapezoidal) construction, the same feedback law
// (k = 0...4.2, self-oscillation near k = 4), the same tanh on the summed input (x0.5 before, x2 after).
//
//   * gain at the cutoff with no resonance: -12 dB (four poles, -3 dB each)
//   * the resonance peak sits on the cutoff; at the top of RES H the filter rings at the cutoff frequency
//   * as with the low-pass, turning Resonance up thins the PASSBAND (here the top end) by about 1/(1+k)
//
// Placement in the voice: VCO -> tube -> HPF -> LPF -> amplitude. The high-pass has no envelope, and the
// global BRILLIANCE, RESONANCE and Sub-Osc wobble do not touch it.
//
// Nothing allocates; safe on the audio thread.

import Foundation

/// Coefficients for one high-pass setting. Cheap to build (one tangent).
struct HighPassCoefficients {
    var g: Float = 0          // one-pole gain g = t / (1 + t)
    var h: Float = 1          // 1 - g (the high-pass stage gain)
    var h2: Float = 1
    var h3: Float = 1
    var h4: Float = 1
    var k: Float = 0          // feedback amount, 0...kMax
    var invD: Float = 1       // 1 / (1 + k * h^4)

    init() {}

    init(cutoffHertz: Double, resonance: Float, sampleRate: Double) {
        // Stay well below Nyquist: the tangent blows up there.
        let hertz = min(max(cutoffHertz, 5.0), 0.45 * sampleRate)
        let t = tan(Double.pi * hertz / sampleRate)
        g = Float(t / (1.0 + t))
        h = 1 - g
        h2 = h * h
        h3 = h2 * h
        h4 = h2 * h2
        k = LadderCoefficients.kMax * min(max(resonance, 0), 1)
        invD = 1 / (1 + k * h4)
    }
}

struct HighPassFilter {

    private var s0: Float = 0     // trapezoidal integrator states, one per pole
    private var s1: Float = 0
    private var s2: Float = 0
    private var s3: Float = 0

    mutating func reset() {
        s0 = 0; s1 = 0; s2 = 0; s3 = 0
    }

    @inline(__always)
    mutating func process(_ x: Float, _ c: HighPassCoefficients) -> Float {
        // Part of the output that does not depend on the current input: lets the feedback be
        // solved exactly instead of through a delay.
        let memory = c.h4 * s0 + c.h3 * s1 + c.h2 * s2 + c.h * s3
        let u = tanh((0.5 * x + c.k * memory) * c.invD)

        // Four trapezoidal one-pole high-passes in series: hp = h * (in - s), s += 2 * g * (in - s).
        var d = u - s0
        let y0 = c.h * d
        s0 += 2 * c.g * d

        d = y0 - s1
        let y1 = c.h * d
        s1 += 2 * c.g * d

        d = y1 - s2
        let y2 = c.h * d
        s2 += 2 * c.g * d

        d = y2 - s3
        let y3 = c.h * d
        s3 += 2 * c.g * d

        return 2.0 * y3
    }
}
