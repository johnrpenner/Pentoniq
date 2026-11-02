// ScopeTap.swift
// Feeds the mini oscilloscope in the MASTER section. Pure Swift, no AudioToolbox.
//
// The audio thread calls push() once per output sample. It waits for a rising
// zero crossing (a trigger, so periodic tones hold still), then stores ONE sample
// every `decimation` samples until it has exactly `points` values, and publishes
// that frame. It never computes more points than the scope is wide, and
// does no allocation, locking or ARC work. The UI thread calls read() about 60
// times a second.

import Foundation

/// Geometry shared by the DSP tap and the view. One stored sample = one point of width.
enum ScopeLayout {
    /// Scope width in view points. The tap stores exactly this many samples per frame.
    static let width: CGFloat = 176
    /// Same height as the TUBE and VCO graphs (and the new VCF graph), so all four line up.
    static let height: CGFloat = 120
    static var points: Int { Int(width) }
    /// Time shown across the scope.
    static let windowSeconds: Double = 0.020
}

final class ScopeTap {

    let points = ScopeLayout.points

    private let front: UnsafeMutablePointer<Float>   // last complete frame (read by the UI)
    private let back: UnsafeMutablePointer<Float>    // frame being captured (audio thread only)
    private let frameCounter: UnsafeMutablePointer<UInt32>
    private let levelStorage: UnsafeMutablePointer<Float>   // meter level (linear peak, with release)

    // Audio-thread state
    private var decimation = 6
    private var timeoutSamples = 2_400      // free-run if no trigger arrives (silence, DC)
    private var capturing = false
    private var decimCount = 0
    private var writeIndex = 0
    private var waitCount = 0
    private var previous: Float = 0
    private var meterPeak: Float = 0
    private var meterDecay: Float = 0.9999   // per sample; set in configure()

    init() {
        let n = ScopeLayout.points
        front = UnsafeMutablePointer<Float>.allocate(capacity: n)
        back = UnsafeMutablePointer<Float>.allocate(capacity: n)
        frameCounter = UnsafeMutablePointer<UInt32>.allocate(capacity: 1)
        front.initialize(repeating: 0, count: n)
        back.initialize(repeating: 0, count: n)
        frameCounter.initialize(to: 0)
        levelStorage = UnsafeMutablePointer<Float>.allocate(capacity: 1)
        levelStorage.initialize(to: 0)
        configure(sampleRate: 44_100)
    }

    deinit {
        front.deallocate()
        back.deallocate()
        frameCounter.deallocate()
        levelStorage.deallocate()
    }

    /// Not real-time: called when the sample rate is known.
    func configure(sampleRate: Double) {
        decimation = max(1, Int((sampleRate * ScopeLayout.windowSeconds / Double(points)).rounded()))
        timeoutSamples = Int(sampleRate * 0.05)
        // Meter release: level falls by 1/e in about 0.3 s (VU-like).
        meterDecay = Float(exp(-1.0 / (0.3 * sampleRate)))
        capturing = false
        decimCount = 0
        writeIndex = 0
        waitCount = 0
    }

    // MARK: Audio thread

    @inline(__always)
    func push(_ x: Float) {
        // Level meter: instant attack on peaks, slow release.
        let a = abs(x)
        meterPeak = a > meterPeak ? a : meterPeak * meterDecay
        if meterPeak < 1e-9 { meterPeak = 0 }
        levelStorage.pointee = meterPeak

        if !capturing {
            waitCount += 1
            let triggered = previous < 0 && x >= 0
            previous = x
            guard triggered || waitCount > timeoutSamples else { return }
            capturing = true
            decimCount = 0
            writeIndex = 0
            waitCount = 0
        }

        if decimCount == 0 {
            back[writeIndex] = x
            writeIndex += 1
            if writeIndex >= points {
                front.update(from: back, count: points)
                frameCounter.pointee &+= 1
                capturing = false
                return
            }
        }
        decimCount += 1
        if decimCount >= decimation { decimCount = 0 }
    }

    // MARK: UI thread

    /// Number of frames published so far (wraps). Cheap check before reading.
    var frameCount: UInt32 { frameCounter.pointee }

    /// Current meter level, linear (1.0 = full scale = 0 dB).
    var level: Float { levelStorage.pointee }

    /// Copies the latest frame into `out` (which must hold `points` values).
    func read(into out: inout [Float]) {
        if out.count != points { out = [Float](repeating: 0, count: points) }
        out.withUnsafeMutableBufferPointer { buf in
            if let base = buf.baseAddress { base.update(from: front, count: points) }
        }
    }
}
