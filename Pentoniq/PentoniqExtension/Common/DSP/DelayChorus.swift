// DelayChorus.swift  (milestone 16: CS-80 style DELAY + CHORUS)
// Add to the EXTENSION target only. No dependency on AudioToolbox.
//
// Sits after the Leslie and before the master volume:
//
//   Leslie (L, R) -> CHORUS (two short modulated delays, opposite LFO phases) -> DELAY (ping-pong) -> master
//
// The SPEED, DEPTH and MIX faders are shared by both effects:
//
//   DELAY   SPEED = delay time: free 50 ms to 1 s (exponential), or with SYNC note values locked to the
//                   host tempo (127 BPM when the host gives none).
//           DEPTH = feedback (0 = a single echo, top = long ping-pong trail, never runaway).
//           MIX   = echo level, added to the dry signal.
//   CHORUS  SPEED = LFO rate, 0.2 Hz to 6 Hz (SYNC is ignored).
//           DEPTH = how far the delay swings (about 11 to 19 ms at the top).
//           MIX   = chorus level, added to the dry signal.
//
// DELAY and CHORUS are independent switches; either, both or neither can be on.
// Turning DELAY off stops feeding the echoes but lets the tail ring out. Turning CHORUS off fades it
// in about 5 ms.
//
// The echo is a true ping-pong: the input (summed to mono) goes into the LEFT line, and the two lines
// feed each other, so echoes alternate left, right, left... The feedback path is darkened (about 4.5 kHz)
// so repeats get softer and duller, like a tape or analogue delay.
//
// Nothing allocates after configure(sampleRate:); safe on the audio thread.

import Foundation

enum DelayRate {

    /// Note values for SYNC, slowest to fastest. `beats` = length in quarter notes.
    static let divisions: [(name: String, beats: Double)] = [
        ("1/2", 2), ("1/4.", 1.5), ("1/4", 1), ("1/8.", 0.75), ("1/4T", 2.0 / 3.0), ("1/8", 0.5),
        ("1/16.", 0.375), ("1/8T", 1.0 / 3.0), ("1/16", 0.25)
    ]

    static func divisionIndex(forSpeed speed: Float) -> Int {
        let x = min(max(speed, 0), 1)
        return min(Int(x * Float(divisions.count)), divisions.count - 1)
    }

    /// Free mode: 50 ms (bottom) to 1 s (top), exponential.
    static func freeSeconds(forSpeed speed: Float) -> Double {
        0.05 * pow(20.0, Double(min(max(speed, 0), 1)))
    }

    /// Delay time in seconds.
    static func seconds(speed: Float, sync: Bool, bpm: Double) -> Double {
        sync ? divisions[divisionIndex(forSpeed: speed)].beats * 60.0 / bpm
             : freeSeconds(forSpeed: speed)
    }

    /// Chorus LFO rate: 0.2 Hz (bottom) to 6 Hz (top), exponential.
    static func chorusHertz(forSpeed speed: Float) -> Double {
        0.2 * pow(30.0, Double(min(max(speed, 0), 1)))
    }

    /// Text for the SPEED fader readout. Chorus alone shows its rate; otherwise the delay time.
    static func readout(speed: Float, sync: Bool, delayOn: Bool, chorusOn: Bool) -> String {
        if chorusOn && !delayOn { return String(format: "%.1f Hz", chorusHertz(forSpeed: speed)) }
        if sync { return divisions[divisionIndex(forSpeed: speed)].name }
        let seconds = freeSeconds(forSpeed: speed)
        return seconds < 1 ? String(format: "%.0f ms", seconds * 1000) : String(format: "%.2f s", seconds)
    }
}

final class DelayChorusEffect {

    // MARK: Character (change these to taste)

    static let maxDelaySeconds = 3.9            // the longest delay the buffers can hold (slow synced tempos)
    static let feedbackMaximum: Float = 0.8     // feedback at DEPTH = 1
    static let dampingHertz = 4_500.0           // feedback darkening
    static let glideSeconds = 0.08              // delay-time changes glide (tape-like pitch bend)
    static let chorusCentreSeconds = 0.015
    static let chorusSwingSeconds = 0.004       // swing at DEPTH = 1

    // MARK: State

    private var delayLeft: UnsafeMutablePointer<Float>
    private var delayRight: UnsafeMutablePointer<Float>
    private var chorusLeft: UnsafeMutablePointer<Float>
    private var chorusRight: UnsafeMutablePointer<Float>
    private var delayMask = 0
    private var chorusMask = 0
    private var delayIndex = 0
    private var chorusIndex = 0

    private var sampleRate = 44_100.0
    private var inverseRate = 1.0 / 44_100.0
    private var smoothing: Float = 0.01
    private var glide: Float = 0.001
    private var damping: Float = 0.5
    private var chorusCentre: Float = 660
    private var chorusSwing: Float = 176

    // Targets, set once per block
    private var delayOn = false
    private var chorusOn = false
    private var targetDelaySamples: Float = 10_000
    private var targetFeedback: Float = 0
    private var targetDepth: Float = 0
    private var targetMix: Float = 0
    private var chorusIncrement = 0.0

    // Smoothed values
    private var delaySamplesNow: Float = 10_000
    private var feedbackNow: Float = 0
    private var depthNow: Float = 0
    private var mixNow: Float = 0
    private var delayGate: Float = 0
    private var chorusGate: Float = 0
    private var chorusPhase = 0.0
    private var dampLeft: Float = 0
    private var dampRight: Float = 0
    private var primed = false

    init() {
        delayLeft = UnsafeMutablePointer<Float>.allocate(capacity: 1)
        delayRight = UnsafeMutablePointer<Float>.allocate(capacity: 1)
        chorusLeft = UnsafeMutablePointer<Float>.allocate(capacity: 1)
        chorusRight = UnsafeMutablePointer<Float>.allocate(capacity: 1)
        delayLeft.initialize(to: 0)
        delayRight.initialize(to: 0)
        chorusLeft.initialize(to: 0)
        chorusRight.initialize(to: 0)
        configure(sampleRate: 44_100)
    }

    deinit {
        delayLeft.deallocate()
        delayRight.deallocate()
        chorusLeft.deallocate()
        chorusRight.deallocate()
    }

    // MARK: Setup (not real-time)

    func configure(sampleRate rate: Double) {
        sampleRate = rate
        inverseRate = 1.0 / rate
        smoothing = Float(1.0 - exp(-1.0 / (0.005 * rate)))
        glide = Float(1.0 - exp(-1.0 / (DelayChorusEffect.glideSeconds * rate)))
        damping = Float(1.0 - exp(-2.0 * Double.pi * DelayChorusEffect.dampingHertz / rate))
        chorusCentre = Float(DelayChorusEffect.chorusCentreSeconds * rate)
        chorusSwing = Float(DelayChorusEffect.chorusSwingSeconds * rate)

        var delaySize = 1024
        while delaySize < Int(DelayChorusEffect.maxDelaySeconds * rate) + 16 { delaySize *= 2 }
        var chorusSize = 1024
        while chorusSize < Int(0.05 * rate) + 16 { chorusSize *= 2 }

        delayLeft.deallocate()
        delayRight.deallocate()
        chorusLeft.deallocate()
        chorusRight.deallocate()
        delayLeft = UnsafeMutablePointer<Float>.allocate(capacity: delaySize)
        delayRight = UnsafeMutablePointer<Float>.allocate(capacity: delaySize)
        chorusLeft = UnsafeMutablePointer<Float>.allocate(capacity: chorusSize)
        chorusRight = UnsafeMutablePointer<Float>.allocate(capacity: chorusSize)
        delayMask = delaySize - 1
        chorusMask = chorusSize - 1
        reset()
    }

    func reset() {
        for i in 0...delayMask {
            delayLeft[i] = 0
            delayRight[i] = 0
        }
        for i in 0...chorusMask {
            chorusLeft[i] = 0
            chorusRight[i] = 0
        }
        delayIndex = 0
        chorusIndex = 0
        dampLeft = 0
        dampRight = 0
        chorusPhase = 0
        primed = false
    }

    /// Once per render block, from the parameters.
    func setControls(delayOn: Bool, chorusOn: Bool, speed: Float, depth: Float, mix: Float,
                     sync: Bool, bpm: Double) {
        self.delayOn = delayOn
        self.chorusOn = chorusOn
        let s = min(max(speed, 0), 1)
        let d = min(max(depth, 0), 1)
        let seconds = DelayRate.seconds(speed: s, sync: sync, bpm: bpm)
        let longest = DelayChorusEffect.maxDelaySeconds * sampleRate
        targetDelaySamples = Float(min(max(seconds * sampleRate, 64), longest))
        targetFeedback = DelayChorusEffect.feedbackMaximum * d
        targetDepth = d
        targetMix = min(max(mix, 0), 1)
        chorusIncrement = DelayRate.chorusHertz(forSpeed: s) * inverseRate

        if !primed {                     // first block: start at the targets, no ramp
            delaySamplesNow = targetDelaySamples
            feedbackNow = targetFeedback
            depthNow = targetDepth
            mixNow = targetMix
            delayGate = delayOn ? 1 : 0
            chorusGate = chorusOn ? 1 : 0
            primed = true
        }
    }

    // MARK: Audio thread

    /// A delay of `d` samples (at least 2) read from `ring` with cubic (Catmull-Rom) interpolation.
    /// Call it BEFORE writing this sample: `index` is where the next sample will go.
    @inline(__always)
    private func read(_ ring: UnsafeMutablePointer<Float>, mask: Int, index: Int, delay d: Float) -> Float {
        let whole = Int(d)
        let t = d - Float(whole)
        let base = index - whole
        let ym1 = ring[(base + 1) & mask]
        let y0 = ring[base & mask]
        let y1 = ring[(base - 1) & mask]
        let y2 = ring[(base - 2) & mask]
        let a = -0.5 * ym1 + 1.5 * y0 - 1.5 * y1 + 0.5 * y2
        let b = ym1 - 2.5 * y0 + 2 * y1 - 0.5 * y2
        let c = -0.5 * ym1 + 0.5 * y1
        return ((a * t + b) * t + c) * t + y0
    }

    /// One stereo sample in, one out.
    @inline(__always)
    func process(_ inLeft: Float, _ inRight: Float) -> (Float, Float) {
        delayGate += ((delayOn ? 1 : 0) - delayGate) * smoothing
        chorusGate += ((chorusOn ? 1 : 0) - chorusGate) * smoothing
        mixNow += (targetMix - mixNow) * smoothing
        feedbackNow += (targetFeedback - feedbackNow) * smoothing
        depthNow += (targetDepth - depthNow) * smoothing
        delaySamplesNow += (targetDelaySamples - delaySamplesNow) * glide

        // CHORUS: left and right sweep in opposite directions.
        chorusPhase += chorusIncrement
        if chorusPhase >= 1.0 { chorusPhase -= 1.0 }
        let sweep = Float(sin(2.0 * Double.pi * chorusPhase)) * chorusSwing * depthNow
        let chorusL = read(chorusLeft, mask: chorusMask, index: chorusIndex, delay: chorusCentre + sweep)
        let chorusR = read(chorusRight, mask: chorusMask, index: chorusIndex, delay: chorusCentre - sweep)
        chorusLeft[chorusIndex] = inLeft
        chorusRight[chorusIndex] = inRight
        chorusIndex = (chorusIndex + 1) & chorusMask
        let chorusLevel = mixNow * chorusGate
        let afterLeft = inLeft + chorusL * chorusLevel
        let afterRight = inRight + chorusR * chorusLevel

        // DELAY: ping-pong. Input (mono) into the left line; each line feeds the other.
        let d = max(delaySamplesNow, 2)
        let tapL = read(delayLeft, mask: delayMask, index: delayIndex, delay: d)
        let tapR = read(delayRight, mask: delayMask, index: delayIndex, delay: d)
        dampLeft += damping * (tapL - dampLeft)
        dampRight += damping * (tapR - dampRight)
        if abs(dampLeft) < 1e-15 { dampLeft = 0 }
        if abs(dampRight) < 1e-15 { dampRight = 0 }
        let send = 0.5 * (afterLeft + afterRight) * delayGate
        delayLeft[delayIndex] = send + feedbackNow * dampRight
        delayRight[delayIndex] = feedbackNow * dampLeft
        delayIndex = (delayIndex + 1) & delayMask

        return (afterLeft + tapL * mixNow, afterRight + tapR * mixNow)
    }
}
