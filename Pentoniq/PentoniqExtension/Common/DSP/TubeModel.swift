// TubeModel.swift
// Milestone 2: vacuum tube emulation, part 1 of 3 (model + lookup curves).
//
// Model: Norman Koren's phenomenological triode equations, solved for a
// common-cathode stage (supply voltage B+, plate load resistor, bypassed
// cathode so the grid sees a fixed DC bias). Because the stage has no memory
// in this form, plate voltage is a pure function of grid voltage, so the
// equations are solved ONCE (offline, in Double) into a lookup curve per tube.
// The real-time path only does a table interpolation.
//
// This file has no dependency on AudioToolbox so it can also be added to the
// unit-test target.
//
// NOTE: the Koren parameter sets below are the commonly published values for
// each tube, entered from memory of that literature. Treat them as a starting
// point and compare against the Koren / DAFx papers before relying on them.

import Foundation

// MARK: - Tube definitions

struct TubeParameters {
    let mu: Double            // amplification factor
    let ex: Double            // Koren exponent
    let kg1: Double           // current scaling
    let kp: Double            // knee shape
    let kvb: Double           // knee shape
    let supplyVolts: Double   // B+
    let loadOhms: Double      // plate load resistor
    let inputScaleVolts: Double // grid volts per 1.0 of audio at 0 dB drive
}

enum TubeType: Int, CaseIterable {
    case twelveAX7 = 0
    case twelveAT7 = 1
    case twelveAU7 = 2

    var displayName: String {
        switch self {
        case .twelveAX7: return "12AX7"
        case .twelveAT7: return "12AT7"
        case .twelveAU7: return "12AU7"
        }
    }

    var parameters: TubeParameters {
        switch self {
        case .twelveAX7:
            return TubeParameters(mu: 100.0, ex: 1.4, kg1: 1060.0, kp: 600.0, kvb: 300.0,
                                  supplyVolts: 250.0, loadOhms: 100_000.0, inputScaleVolts: 1.0)
        case .twelveAT7:
            return TubeParameters(mu: 60.0, ex: 1.35, kg1: 460.0, kp: 300.0, kvb: 300.0,
                                  supplyVolts: 250.0, loadOhms: 47_000.0, inputScaleVolts: 1.5)
        case .twelveAU7:
            return TubeParameters(mu: 21.5, ex: 1.3, kg1: 1180.0, kp: 84.0, kvb: 300.0,
                                  supplyVolts: 250.0, loadOhms: 47_000.0, inputScaleVolts: 4.0)
        }
    }
}

// MARK: - Koren equations (offline, Double precision)

enum KorenTriode {

    @inline(__always)
    private static func softplus(_ x: Double) -> Double {
        x > 30.0 ? x : log1p(exp(x))
    }

    /// Plate current in amperes.
    static func plateCurrent(_ t: TubeParameters, plateVolts vpk: Double, gridVolts vgk: Double) -> Double {
        if vpk <= 0.0 { return 0.0 }
        let s = (t.kvb + vpk * vpk).squareRoot()
        let e1 = vpk / t.kp * softplus(t.kp * (1.0 / t.mu + vgk / s))
        if e1 <= 0.0 { return 0.0 }
        return pow(e1, t.ex) / t.kg1
    }

    /// d(plate current)/d(plate voltage).
    static func plateCurrentSlope(_ t: TubeParameters, plateVolts vpk: Double, gridVolts vgk: Double) -> Double {
        if vpk <= 0.0 { return 0.0 }
        let s = (t.kvb + vpk * vpk).squareRoot()
        let arg = t.kp * (1.0 / t.mu + vgk / s)
        let sp = softplus(arg)
        let e1 = vpk / t.kp * sp
        if e1 <= 0.0 { return 0.0 }
        let sigmoid = 1.0 / (1.0 + exp(-arg))
        let dArg = -t.kp * vgk * vpk / (s * s * s)
        let dE1 = sp / t.kp + vpk / t.kp * sigmoid * dArg
        return t.ex * pow(e1, t.ex - 1.0) * dE1 / t.kg1
    }

    /// Solves the load line  (B+ - Vp)/Rp = Ip(Vp, Vg)  for the plate voltage.
    /// The root is always inside [0, B+] and unique (the left side falls and
    /// the right side rises with Vp), so a bracketed Newton iteration is safe.
    static func solvePlateVoltage(_ t: TubeParameters, gridVolts vgk: Double) -> Double {
        var lo = 0.0
        var hi = t.supplyVolts
        var vp = 0.5 * t.supplyVolts
        for _ in 0..<100 {
            let g = (t.supplyVolts - vp) / t.loadOhms - plateCurrent(t, plateVolts: vp, gridVolts: vgk)
            if g > 0.0 { lo = vp } else { hi = vp }
            let slope = -1.0 / t.loadOhms - plateCurrentSlope(t, plateVolts: vp, gridVolts: vgk)
            var next = vp - g / slope
            if !(next >= lo && next <= hi) { next = 0.5 * (lo + hi) }
            if abs(next - vp) < 1e-12 { vp = next; break }
            vp = next
        }
        return vp
    }

    /// Closed-form inverse: the (negative) grid bias that places the quiescent
    /// plate voltage at `quiescentPlate` for this load line.
    static func gridVoltage(forQuiescentPlate vq: Double, tube t: TubeParameters) -> Double {
        let ipq = (t.supplyVolts - vq) / t.loadOhms
        let e1 = pow(ipq * t.kg1, 1.0 / t.ex)
        let sp = e1 * t.kp / vq
        let arg = sp < 30.0 ? log(expm1(sp)) : sp
        return (arg / t.kp - 1.0 / t.mu) * (t.kvb + vq * vq).squareRoot()
    }
}

// MARK: - Real-time lookup curve

/// Plate voltage as a function of grid voltage, as a linearly interpolated
/// table. Plain value type (pointer + scalars): no reference counting, safe on
/// the audio thread.
struct TubeCurve {
    let table: UnsafePointer<Float>
    let count: Int
    let gridMin: Float
    let invStep: Float

    /// Grid conduction is approximated by smoothly limiting positive grid
    /// voltage to about +0.5 V (slope 1 at 0 V, so the join is smooth).
    @inline(__always)
    func plateVoltage(gridVoltage vgk: Float) -> Float {
        var v = vgk
        if v > 0 { v = 0.5 * tanh(2 * v) }
        let position = (v - gridMin) * invStep
        if !(position > 0) { return table[0] }
        let last = Float(count - 1)
        if position >= last { return table[count - 1] }
        let index = Int(position)
        let fraction = position - Float(index)
        let a = table[index]
        return a + fraction * (table[index + 1] - a)
    }
}

/// Owns the curve tables for every tube type. Built once (not real-time).
final class TubeBank {

    static let shared = TubeBank()
    static let tableSize = 4096

    private let storage: UnsafeMutablePointer<Float>
    private let curves: UnsafeMutablePointer<TubeCurve>
    private let curveCount: Int

    init() {
        let types = TubeType.allCases
        let count = types.count
        let size = TubeBank.tableSize
        let storage = UnsafeMutablePointer<Float>.allocate(capacity: count * size)
        let curves = UnsafeMutablePointer<TubeCurve>.allocate(capacity: count)

        for (index, type) in types.enumerated() {
            let p = type.parameters
            let gridMin = -(p.supplyVolts / p.mu) * 2.0 - 3.0   // well below cutoff
            let gridMax = 0.5
            let base = storage + index * size
            for i in 0..<size {
                let vg = gridMin + (gridMax - gridMin) * Double(i) / Double(size - 1)
                base[i] = Float(KorenTriode.solvePlateVoltage(p, gridVolts: vg))
            }
            (curves + index).initialize(to: TubeCurve(
                table: UnsafePointer(base),
                count: size,
                gridMin: Float(gridMin),
                invStep: Float(Double(size - 1) / (gridMax - gridMin))))
        }

        self.storage = storage
        self.curves = curves
        self.curveCount = count
    }

    deinit {
        curves.deinitialize(count: curveCount)
        curves.deallocate()
        storage.deallocate()
    }

    @inline(__always)
    func curve(_ index: Int) -> TubeCurve {
        curves[min(max(index, 0), curveCount - 1)]
    }
}

// MARK: - Operating point

/// Where on the load line the stage sits, plus the output normalisation.
/// `bias` runs from -1 (cold: near cutoff, strongly asymmetric, lower gain)
/// through 0 (neutral) to +1 (hot: drawn toward grid conduction).
///
/// Output is scaled so small signals pass at unity gain at NEUTRAL bias and
/// 0 dB drive; other bias settings change the gain realistically.
struct TubeOperatingPoint {
    let gridBias: Float        // quiescent grid-cathode voltage
    let plateQuiescent: Float  // plate voltage at that bias
    let outputNorm: Float

    static func quiescentPlateFraction(bias: Float) -> Double {
        min(max(0.75 - 0.22 * Double(bias), 0.45), 0.97)
    }

    init(curve: TubeCurve, tube: TubeType, bias: Float) {
        let p = tube.parameters
        let vg = Float(KorenTriode.gridVoltage(
            forQuiescentPlate: TubeOperatingPoint.quiescentPlateFraction(bias: bias) * p.supplyVolts,
            tube: p))
        gridBias = vg
        plateQuiescent = curve.plateVoltage(gridVoltage: vg)

        let vgRef = Float(KorenTriode.gridVoltage(
            forQuiescentPlate: TubeOperatingPoint.quiescentPlateFraction(bias: 0) * p.supplyVolts,
            tube: p))
        let d: Float = 0.001
        let slope = (curve.plateVoltage(gridVoltage: vgRef + d)
                     - curve.plateVoltage(gridVoltage: vgRef - d)) / (2 * d)
        outputNorm = 1 / (abs(slope) * Float(p.inputScaleVolts))
    }

    /// Memoryless stage transfer function. `driveGain` is grid volts per unit
    /// of input signal. Non-inverting (the plate inversion is undone).
    @inline(__always)
    func output(curve: TubeCurve, input x: Float, driveGain: Float) -> Float {
        (plateQuiescent - curve.plateVoltage(gridVoltage: gridBias + x * driveGain)) * outputNorm
    }
}
