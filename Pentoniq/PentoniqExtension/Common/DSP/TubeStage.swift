// TubeStage.swift
// Milestone 2: vacuum tube emulation, part 3 of 3 (the stage you call).
//
//   input -> [x drive] -> triode stage (optionally oversampled 2x / 4x)
//         -> DC blocker -> [x output trim] -> output
//
// Use: create once, call setSampleRate(_:) from allocateRenderResources, call
// configure(...) once per render block, then process(_:) once per sample.
// Nothing here allocates after init.
//
// Side effects to be aware of:
//  - Changing tube type or bias jumps the operating point; the DC blocker
//    absorbs most of the click but it is not crossfaded.
//  - Oversampling adds latency of about 31 samples at the host rate (the
//    63-tap filter); the Off setting has none.
//
// No dependency on AudioToolbox (also usable from the unit-test target).

import Foundation

final class TubeStage {

    private let bank: TubeBank
    private let outer = HalfbandResampler(tapCount: 63)   // host rate <-> 2x
    private let inner = HalfbandResampler(tapCount: 15)   // 2x <-> 4x

    private var tubeType: TubeType = .twelveAX7
    private var curve: TubeCurve
    private var operatingPoint: TubeOperatingPoint

    private var currentTubeIndex = -1
    private var currentBias: Float = .nan
    private var oversampleFactor = 1
    private var configured = false

    // Smoothed controls
    private var drive: Float = 1          // grid volts per unit input
    private var driveTarget: Float = 1
    private var outputGain: Float = 1
    private var outputTarget: Float = 1
    private var smoothing: Float = 0.01

    // DC blocker (coupling capacitor, ~15 Hz)
    private var dcR: Float = 0.998
    private var dcX: Float = 0
    private var dcY: Float = 0

    init(bank: TubeBank) {
        self.bank = bank
        let initialCurve = bank.curve(0)
        curve = initialCurve
        operatingPoint = TubeOperatingPoint(curve: initialCurve, tube: .twelveAX7, bias: 0)
    }

    func setSampleRate(_ sampleRate: Double) {
        smoothing = Float(1.0 - exp(-1.0 / (0.005 * sampleRate)))
        dcR = Float(1.0 - 2.0 * Double.pi * 15.0 / sampleRate)
        reset()
    }

    func reset() {
        outer.reset()
        inner.reset()
        dcX = 0
        dcY = 0
        drive = driveTarget
        outputGain = outputTarget
    }

    /// Call once per render block. `oversampling`: 0 = off, 1 = 2x, 2 = 4x.
    func configure(tubeIndex: Int, bias: Float, driveDB: Float, outputDB: Float, oversampling: Int) {
        let index = min(max(tubeIndex, 0), TubeType.allCases.count - 1)
        let biasClamped = min(max(bias, -1), 1)

        if index != currentTubeIndex || biasClamped != currentBias {
            tubeType = TubeType(rawValue: index) ?? .twelveAX7
            curve = bank.curve(index)
            operatingPoint = TubeOperatingPoint(curve: curve, tube: tubeType, bias: biasClamped)
            currentTubeIndex = index
            currentBias = biasClamped
        }

        let driveDBClamped = min(max(driveDB, -24), 48)
        let outputDBClamped = min(max(outputDB, -48), 24)
        driveTarget = Float(tubeType.parameters.inputScaleVolts) * Float(pow(10.0, Double(driveDBClamped) / 20.0))
        outputTarget = Float(pow(10.0, Double(outputDBClamped) / 20.0))

        let factor = oversampling >= 2 ? 4 : (oversampling == 1 ? 2 : 1)
        if factor != oversampleFactor {
            oversampleFactor = factor
            outer.reset()
            inner.reset()
        }

        if !configured {          // first call: start at the target, no ramp
            drive = driveTarget
            outputGain = outputTarget
            configured = true
        }
    }

    @inline(__always)
    private func shape(_ x: Float) -> Float {
        operatingPoint.output(curve: curve, input: x, driveGain: drive)
    }

    @inline(__always)
    func process(_ x: Float) -> Float {
        drive += (driveTarget - drive) * smoothing
        outputGain += (outputTarget - outputGain) * smoothing

        let y: Float
        switch oversampleFactor {
        case 2:
            let (a0, a1) = outer.upsample(x)
            y = outer.downsample(shape(a0), shape(a1))
        case 4:
            let (a0, a1) = outer.upsample(x)
            let (b0, b1) = inner.upsample(a0)
            let (b2, b3) = inner.upsample(a1)
            let d0 = inner.downsample(shape(b0), shape(b1))
            let d1 = inner.downsample(shape(b2), shape(b3))
            y = outer.downsample(d0, d1)
        default:
            y = shape(x)
        }

        let blocked = y - dcX + dcR * dcY
        dcX = y
        dcY = blocked
        return blocked * outputGain
    }

    /// Static (memoryless) transfer for the current settings, for drawing the
    /// curve in the UI or for tests. Not used by the audio path.
    func staticTransfer(_ x: Float) -> Float {
        shape(x)
    }
}
