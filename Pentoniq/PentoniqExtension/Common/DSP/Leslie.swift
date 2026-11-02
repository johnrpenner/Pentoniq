// Leslie.swift  (milestone 18: stereo Leslie speaker simulation, the PAN slider)
// Add to the EXTENSION target only. No dependency on AudioToolbox.
//
// A rotating-speaker cabinet, in the spirit of Isao Tomita's record-player rig. It runs on the mixed
// Voice I + II signal as a mono-in, stereo-out effect.
//
//   input -> crossover (800 Hz) -> HORN (highs)  -> rotating, two microphones (left and right)
//                               -> DRUM (lows)   -> rotating, two microphones
//         -> the two microphones' sums -> small room (early reflections) -> left, right
//
// Each rotor, as it turns, gives each microphone three things:
//   - an AMPLITUDE swell: loudest when it points at the microphone, quietest when it points away,
//   - a DOPPLER shift: it is a little closer to the microphone while it points at it, so a short, moving
//     delay (the pitch bends up as it swings toward the microphone and down as it swings away),
//   - a different PHASE at the left and right microphones (they sit 60 degrees either side), which is
//     what makes the sound move across the stereo field.
//
// One control, `amount` (0...1, the PAN slider), sets both the rotor SPEED and the DEPTH:
//   speed  horn 0.7 Hz (bottom) to 7 Hz (top), exponential; the drum turns at 85% of the horn's speed.
//   depth  0 at the bottom (no effect at all) rising to full at the top, together with the room (0 to 25%).
// The rotors have inertia, like a platter: they glide to a new speed (the horn in about half a second,
// the drum in about a second and a half) instead of jumping. Depth and room follow the control at once.
//
// With amount = 0 the output is the input, delayed by about 1 ms, in both channels.
//
// Nothing allocates after configure(); safe on the audio thread.

import Foundation

final class LeslieSimulation {

    // MARK: Character (change these to taste)

    static let slowHornHertz = 0.7
    static let fastHornHertz = 7.0
    static let drumRatio = 0.85                  // drum speed as a fraction of the horn's
    static let crossoverHertz = 800.0
    static let hornLagSeconds = 0.5              // time constant of the horn's speed-up and slow-down
    static let drumLagSeconds = 1.5              // the heavier drum is slower
    static let hornAmplitudeDepth: Float = 0.75  // how far the horn dips when it points away (at full depth)
    static let drumAmplitudeDepth: Float = 0.30
    static let hornSwingSeconds = 0.0005         // Doppler delay swing at full depth
    static let drumSwingSeconds = 0.0003
    static let baseDelaySeconds = 0.001          // resting delay of both rotors
    static let roomWetMaximum: Float = 0.25      // room level at full amount

    /// Horn speed for a PAN slider position.
    static func hornHertz(forAmount amount: Float) -> Double {
        slowHornHertz * pow(fastHornHertz / slowHornHertz, Double(min(max(amount, 0), 1)))
    }

    /// Text for the PAN fader readout.
    static func readout(amount: Float) -> String {
        amount < 0.005 ? "OFF" : String(format: "%.1f Hz", hornHertz(forAmount: amount))
    }

    // MARK: State

    private static let ringSize = 2048           // plenty: the longest delay is about 300 samples at 192 kHz
    private let ringMask = LeslieSimulation.ringSize - 1
    private let hornRing: UnsafeMutablePointer<Float>
    private let drumRing: UnsafeMutablePointer<Float>
    private var writeIndex = 0

    // Room: one ring per channel, sized for the sample rate in configure().
    private var roomLeft: UnsafeMutablePointer<Float>
    private var roomRight: UnsafeMutablePointer<Float>
    private var roomMask = 0
    private var roomIndex = 0
    private var roomTapsFromRight = (0, 0, 0)
    private var roomTapsFromLeft = (0, 0, 0)
    private var roomCoefficient: Float = 0.5
    private var roomFilterLeft: Float = 0
    private var roomFilterRight: Float = 0

    private var inverseRate = 1.0 / 44_100.0
    private var crossover: Float = 0.1
    private var lowpass1: Float = 0
    private var lowpass2: Float = 0
    private var baseDelay: Float = 44
    private var hornSwing: Float = 22
    private var drumSwing: Float = 13
    private var hornLag = 0.0001
    private var drumLag = 0.00005

    private var hornPhase = 0.0
    private var drumPhase = 0.25
    private var hornHertzNow = 0.7
    private var drumHertzNow = 0.6
    private var primed = false

    // Microphones at -60 and +60 degrees.
    private let micCos: Float = 0.5
    private let micSin: Float = 0.8660254

    init() {
        hornRing = UnsafeMutablePointer<Float>.allocate(capacity: LeslieSimulation.ringSize)
        drumRing = UnsafeMutablePointer<Float>.allocate(capacity: LeslieSimulation.ringSize)
        hornRing.initialize(repeating: 0, count: LeslieSimulation.ringSize)
        drumRing.initialize(repeating: 0, count: LeslieSimulation.ringSize)
        roomLeft = UnsafeMutablePointer<Float>.allocate(capacity: 1)
        roomRight = UnsafeMutablePointer<Float>.allocate(capacity: 1)
        roomLeft.initialize(to: 0)
        roomRight.initialize(to: 0)
        configure(sampleRate: 44_100)
    }

    deinit {
        hornRing.deallocate()
        drumRing.deallocate()
        roomLeft.deallocate()
        roomRight.deallocate()
    }

    // MARK: Setup (not real-time)

    func configure(sampleRate: Double) {
        let twoPi = 2.0 * Double.pi
        inverseRate = 1.0 / sampleRate
        crossover = Float(1.0 - exp(-twoPi * LeslieSimulation.crossoverHertz / sampleRate))
        baseDelay = Float((LeslieSimulation.baseDelaySeconds * sampleRate).rounded())   // whole samples
        hornSwing = Float(LeslieSimulation.hornSwingSeconds * sampleRate)
        drumSwing = Float(LeslieSimulation.drumSwingSeconds * sampleRate)
        hornLag = 1.0 - exp(-1.0 / (LeslieSimulation.hornLagSeconds * sampleRate))
        drumLag = 1.0 - exp(-1.0 / (LeslieSimulation.drumLagSeconds * sampleRate))
        roomCoefficient = Float(1.0 - exp(-twoPi * 5_000.0 / sampleRate))

        func samples(_ milliseconds: Double) -> Int { max(1, Int((milliseconds * 0.001 * sampleRate).rounded())) }
        roomTapsFromRight = (samples(7.3), samples(13.1), samples(19.7))
        roomTapsFromLeft = (samples(9.1), samples(15.3), samples(23.9))

        var size = 1024
        while size < Int(0.03 * sampleRate) + 8 { size *= 2 }
        roomLeft.deallocate()
        roomRight.deallocate()
        roomLeft = UnsafeMutablePointer<Float>.allocate(capacity: size)
        roomRight = UnsafeMutablePointer<Float>.allocate(capacity: size)
        roomMask = size - 1
        reset()
    }

    func reset() {
        for i in 0..<LeslieSimulation.ringSize {
            hornRing[i] = 0
            drumRing[i] = 0
        }
        for i in 0...roomMask {
            roomLeft[i] = 0
            roomRight[i] = 0
        }
        writeIndex = 0
        roomIndex = 0
        lowpass1 = 0
        lowpass2 = 0
        roomFilterLeft = 0
        roomFilterRight = 0
        hornPhase = 0
        drumPhase = 0.25
        primed = false
    }

    // MARK: Audio thread

    /// A delay of `d` samples (at least 2) read from `ring` with cubic interpolation.
    @inline(__always)
    private func read(_ ring: UnsafeMutablePointer<Float>, delay d: Float) -> Float {
        let whole = Int(d)
        let u = 1 - (d - Float(whole))
        let base = writeIndex - 1 - whole
        let ym1 = ring[(base - 2) & ringMask]
        let y0 = ring[(base - 1) & ringMask]
        let y1 = ring[base & ringMask]
        let y2 = ring[(base + 1) & ringMask]
        let a = 1.5 * (y0 - y1) + 0.5 * (y2 - ym1)
        let b = ym1 - 2.5 * y0 + 2 * y1 - 0.5 * y2
        let c = 0.5 * (y1 - ym1)
        return ((a * u + b) * u + c) * u + y0
    }

    /// One sample in, left and right out. `amount` is the PAN slider position, 0...1.
    @inline(__always)
    func process(_ x: Float, amount: Float) -> (Float, Float) {
        let a = min(max(amount, 0), 1)
        let twoPi = 2.0 * Double.pi

        // Rotor speeds glide toward their targets (a platter's inertia).
        let hornTarget = LeslieSimulation.hornHertz(forAmount: a)
        let drumTarget = hornTarget * LeslieSimulation.drumRatio
        if !primed {
            hornHertzNow = hornTarget
            drumHertzNow = drumTarget
            primed = true
        }
        hornHertzNow += (hornTarget - hornHertzNow) * hornLag
        drumHertzNow += (drumTarget - drumHertzNow) * drumLag
        hornPhase += hornHertzNow * inverseRate
        if hornPhase >= 1.0 { hornPhase -= 1.0 }
        drumPhase += drumHertzNow * inverseRate
        if drumPhase >= 1.0 { drumPhase -= 1.0 }

        // Split into highs (horn) and lows (drum); the two add back to the input exactly.
        lowpass1 += crossover * (x - lowpass1)
        lowpass2 += crossover * (lowpass1 - lowpass2)
        hornRing[writeIndex] = x - lowpass2
        drumRing[writeIndex] = lowpass2
        writeIndex = (writeIndex + 1) & ringMask

        // Rotor angles. cos(angle - microphone) for the right (+60) and left (-60) microphones.
        let hornAngle = Float(twoPi * hornPhase)
        let drumAngle = Float(twoPi * drumPhase)
        let hornCos = cos(hornAngle), hornSin = sin(hornAngle)
        let drumCos = cos(drumAngle), drumSin = sin(drumAngle)
        let hornRight = hornCos * micCos + hornSin * micSin
        let hornLeft = hornCos * micCos - hornSin * micSin
        let drumRight = drumCos * micCos + drumSin * micSin
        let drumLeft = drumCos * micCos - drumSin * micSin

        // Depth follows the control at once. At 0 every gain is 1 and every delay is the resting one.
        let depth = a
        let hornAM = LeslieSimulation.hornAmplitudeDepth * depth * 0.5
        let drumAM = LeslieSimulation.drumAmplitudeDepth * depth * 0.5
        let hornDoppler = hornSwing * depth
        let drumDoppler = drumSwing * depth

        let rotorLeft = read(hornRing, delay: baseDelay - hornDoppler * hornLeft) * (1 - hornAM * (1 - hornLeft))
            + read(drumRing, delay: baseDelay - drumDoppler * drumLeft) * (1 - drumAM * (1 - drumLeft))
        let rotorRight = read(hornRing, delay: baseDelay - hornDoppler * hornRight) * (1 - hornAM * (1 - hornRight))
            + read(drumRing, delay: baseDelay - drumDoppler * drumRight) * (1 - drumAM * (1 - drumRight))

        // Small room: three early reflections per side, fed from the opposite channel for width, softened.
        roomLeft[roomIndex] = rotorLeft
        roomRight[roomIndex] = rotorRight
        let fromRight = 0.45 * roomRight[(roomIndex - roomTapsFromRight.0) & roomMask]
            + 0.30 * roomRight[(roomIndex - roomTapsFromRight.1) & roomMask]
            + 0.20 * roomRight[(roomIndex - roomTapsFromRight.2) & roomMask]
        let fromLeft = 0.45 * roomLeft[(roomIndex - roomTapsFromLeft.0) & roomMask]
            + 0.30 * roomLeft[(roomIndex - roomTapsFromLeft.1) & roomMask]
            + 0.20 * roomLeft[(roomIndex - roomTapsFromLeft.2) & roomMask]
        roomIndex = (roomIndex + 1) & roomMask
        roomFilterLeft += roomCoefficient * (fromRight - roomFilterLeft)
        roomFilterRight += roomCoefficient * (fromLeft - roomFilterRight)

        let wet = LeslieSimulation.roomWetMaximum * a
        return (rotorLeft + roomFilterLeft * wet, rotorRight + roomFilterRight * wet)
    }
}
