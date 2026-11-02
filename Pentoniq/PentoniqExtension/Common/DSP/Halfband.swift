// Halfband.swift
// Milestone 2: vacuum tube emulation, part 2 of 3 (2x resampler).
//
// A polyphase halfband FIR (windowed-sinc, Kaiser window) used to oversample
// around the tube nonlinearity, which would otherwise alias badly.
// One instance handles one 2x step in BOTH directions (separate state for up
// and down). Cascade two instances for 4x.
//
// Real-time safe: all memory is allocated in init, nothing allocates in
// upsample/downsample. Latency is (tapCount - 1) samples at the higher rate
// for the up+down pair.
//
// No dependency on AudioToolbox (also usable from the unit-test target).

import Foundation

final class HalfbandResampler {

    // Non-zero taps of the even and odd polyphase branches, compacted.
    private let evenCount: Int
    private let oddCount: Int
    private let evenCoefficients: UnsafeMutablePointer<Float>
    private let evenOffsets: UnsafeMutablePointer<Int>
    private let oddCoefficients: UnsafeMutablePointer<Float>
    private let oddOffsets: UnsafeMutablePointer<Int>

    // Ring-buffer histories (power-of-two length so wrapping is a mask).
    private let mask: Int
    private let historyLength: Int
    private let upHistory: UnsafeMutablePointer<Float>
    private let downHistoryA: UnsafeMutablePointer<Float>
    private let downHistoryB: UnsafeMutablePointer<Float>
    private var upPosition = 0
    private var downPositionA = 0
    private var downPositionB = 0

    /// `tapCount` must be odd; values of the form 4m+3 (15, 31, 63) give the
    /// most efficient structure (the odd branch collapses to one tap).
    init(tapCount: Int, kaiserBeta: Double = 8.0) {
        precondition(tapCount >= 3 && tapCount % 2 == 1)
        let centre = (tapCount - 1) / 2
        let i0Beta = HalfbandResampler.besselI0(kaiserBeta)

        var h = [Double](repeating: 0.0, count: tapCount)
        var sum = 0.0
        for n in 0..<tapCount {
            let d = n - centre
            var sinc = 1.0
            if d != 0 {
                if d % 2 == 0 {
                    sinc = 0.0   // exact zeros: this is what makes it a halfband
                } else {
                    let x = Double(d) / 2.0
                    sinc = sin(Double.pi * x) / (Double.pi * x)
                }
            }
            let r = Double(d) / Double(centre)
            let window = HalfbandResampler.besselI0(kaiserBeta * max(0.0, 1.0 - r * r).squareRoot()) / i0Beta
            h[n] = 0.5 * sinc * window
            sum += h[n]
        }
        for n in 0..<tapCount { h[n] /= sum }   // unity DC gain

        var evenC: [Float] = []
        var evenO: [Int] = []
        var oddC: [Float] = []
        var oddO: [Int] = []
        for i in 0..<((tapCount + 1) / 2) {
            let v = h[2 * i]
            if v != 0.0 { evenC.append(Float(v)); evenO.append(i) }
        }
        for i in 0..<((tapCount - 1) / 2) {
            let v = h[2 * i + 1]
            if v != 0.0 { oddC.append(Float(v)); oddO.append(i) }
        }

        let evenCoef = UnsafeMutablePointer<Float>.allocate(capacity: max(evenC.count, 1))
        let evenOff = UnsafeMutablePointer<Int>.allocate(capacity: max(evenC.count, 1))
        let oddCoef = UnsafeMutablePointer<Float>.allocate(capacity: max(oddC.count, 1))
        let oddOff = UnsafeMutablePointer<Int>.allocate(capacity: max(oddC.count, 1))
        for i in 0..<evenC.count { evenCoef[i] = evenC[i]; evenOff[i] = evenO[i] }
        for i in 0..<oddC.count { oddCoef[i] = oddC[i]; oddOff[i] = oddO[i] }

        var length = 1
        while length < (tapCount + 1) / 2 { length *= 2 }
        let upBuffer = UnsafeMutablePointer<Float>.allocate(capacity: length)
        let downBufferA = UnsafeMutablePointer<Float>.allocate(capacity: length)
        let downBufferB = UnsafeMutablePointer<Float>.allocate(capacity: length)
        upBuffer.initialize(repeating: 0, count: length)
        downBufferA.initialize(repeating: 0, count: length)
        downBufferB.initialize(repeating: 0, count: length)

        evenCount = evenC.count
        oddCount = oddC.count
        evenCoefficients = evenCoef
        evenOffsets = evenOff
        oddCoefficients = oddCoef
        oddOffsets = oddOff
        historyLength = length
        mask = length - 1
        upHistory = upBuffer
        downHistoryA = downBufferA
        downHistoryB = downBufferB
    }

    deinit {
        evenCoefficients.deallocate()
        evenOffsets.deallocate()
        oddCoefficients.deallocate()
        oddOffsets.deallocate()
        upHistory.deallocate()
        downHistoryA.deallocate()
        downHistoryB.deallocate()
    }

    func reset() {
        for i in 0..<historyLength {
            upHistory[i] = 0
            downHistoryA[i] = 0
            downHistoryB[i] = 0
        }
        upPosition = 0
        downPositionA = 0
        downPositionB = 0
    }

    /// One input sample in, two output samples (at twice the rate) out, in time order.
    @inline(__always)
    func upsample(_ x: Float) -> (Float, Float) {
        upPosition = (upPosition - 1) & mask
        upHistory[upPosition] = x
        var even: Float = 0
        for j in 0..<evenCount {
            even += evenCoefficients[j] * upHistory[(upPosition + evenOffsets[j]) & mask]
        }
        var odd: Float = 0
        for j in 0..<oddCount {
            odd += oddCoefficients[j] * upHistory[(upPosition + oddOffsets[j]) & mask]
        }
        return (2 * even, 2 * odd)   // x2 restores the gain lost to zero-stuffing
    }

    /// Two input samples (at the higher rate, in time order) in, one output sample out.
    @inline(__always)
    func downsample(_ a: Float, _ b: Float) -> Float {
        downPositionA = (downPositionA - 1) & mask
        downHistoryA[downPositionA] = a
        var y: Float = 0
        for j in 0..<evenCount {
            y += evenCoefficients[j] * downHistoryA[(downPositionA + evenOffsets[j]) & mask]
        }
        for j in 0..<oddCount {
            y += oddCoefficients[j] * downHistoryB[(downPositionB + oddOffsets[j]) & mask]
        }
        downPositionB = (downPositionB - 1) & mask
        downHistoryB[downPositionB] = b
        return y
    }

    private static func besselI0(_ x: Double) -> Double {
        var sum = 1.0
        var term = 1.0
        var k = 1.0
        while true {
            let q = x / (2.0 * k)
            term *= q * q
            sum += term
            k += 1.0
            if term < 1e-14 * sum { break }
        }
        return sum
    }
}
