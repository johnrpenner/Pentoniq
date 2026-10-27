// Arpeggiator.swift  (milestone 15)
// Add to the EXTENSION target only. No dependency on AudioToolbox.
//
// When ENABLE is on, the keys you play (from MIDI or the on-screen keyboard) no longer sound directly.
// They go into this arpeggiator, which plays them one after another:
//
//   MODE    UP, DOWN, UP-DOWN (the end notes are not played twice) or RAND (never the same note twice
//           in a row, when there is a choice).
//   OCT     1...4: the pattern is the held notes, then the same notes an octave up, and so on.
//   REP     1...4: each note of the pattern is played this many times before moving on.
//   SPEED   free: 1 to 32 steps a second. With SYNC: note values (1/2 down to 1/32, with dotted and
//           triplet values) locked to the host tempo (127 BPM when the host gives none).
//   HOLD    the notes keep playing after the keys are released. Playing a new chord (after all keys were
//           up) replaces them. Turning HOLD off with no key down stops the pattern.
//
// Each step plays the note at the velocity it was struck with, then releases it after 60% of the step.
// The first step starts the moment the first key goes down. Nothing allocates after init; safe on
// the audio thread.

import Foundation

enum ArpMode: Int, CaseIterable {
    case up = 0
    case down
    case upDown
    case random
}

enum ArpRate {
    /// Note values, slowest to fastest. `beats` = length of one step in quarter notes.
    static let divisions: [(name: String, beats: Double)] = [
        ("1/2", 2), ("1/4.", 1.5), ("1/4", 1), ("1/8.", 0.75), ("1/4T", 2.0 / 3.0), ("1/8", 0.5),
        ("1/16.", 0.375), ("1/8T", 1.0 / 3.0), ("1/16", 0.25), ("1/16T", 1.0 / 6.0), ("1/32", 0.125)
    ]

    static func divisionIndex(forSpeed speed: Float) -> Int {
        let x = min(max(speed, 0), 1)
        return min(Int(x * Float(divisions.count)), divisions.count - 1)
    }

    /// Free mode: 1 step a second (bottom) to 32 a second (top), exponential.
    static func freeHertz(forSpeed speed: Float) -> Double {
        pow(32.0, Double(min(max(speed, 0), 1)))
    }

    /// Length of one step in samples.
    static func samplesPerStep(speed: Float, sync: Bool, bpm: Double, sampleRate: Double) -> Double {
        let seconds = sync
            ? divisions[divisionIndex(forSpeed: speed)].beats * 60.0 / bpm
            : 1.0 / freeHertz(forSpeed: speed)
        return max(seconds * sampleRate, 0.005 * sampleRate)
    }

    /// Text for the SPEED fader readout.
    static func readout(speed: Float, sync: Bool) -> String {
        if sync { return divisions[divisionIndex(forSpeed: speed)].name }
        let hz = freeHertz(forSpeed: speed)
        return hz < 10 ? String(format: "%.1f/s", hz) : String(format: "%.0f/s", hz)
    }
}

/// What one sample of the arpeggiator asks the engines to do. -1 = nothing. A note off comes before a note on.
struct ArpStepEvent {
    var off = -1
    var on = -1
    var velocity: UInt8 = 100
}

final class Arpeggiator {

    /// Fraction of a step the note is held.
    static let gate = 0.6

    private let physical: UnsafeMutablePointer<UInt8>      // keys really down (128 flags)
    private let members: UnsafeMutablePointer<UInt8>       // keys in the pattern (differs from `physical` while holding)
    private let velocities: UnsafeMutablePointer<UInt8>    // the velocity each key was struck with
    private let sorted: UnsafeMutablePointer<UInt8>        // members, low to high
    private var sortedCount = 0
    private var physicalCount = 0
    private var dirty = false
    private var hold = false

    private var mode: ArpMode = .up
    private var octaves = 1
    private var repeats = 1
    private var samplesPerStep = 12_000.0

    private var running = false
    private var samplesToNext = 0.0
    private var samplesToOff = 0.0
    private var soundingNote = -1
    private var position = 0
    private var repeatCount = 0
    private var randomIndex = 0
    private var randomState: UInt32 = 0x1F2E_3D4C

    init() {
        physical = UnsafeMutablePointer<UInt8>.allocate(capacity: 128)
        members = UnsafeMutablePointer<UInt8>.allocate(capacity: 128)
        velocities = UnsafeMutablePointer<UInt8>.allocate(capacity: 128)
        sorted = UnsafeMutablePointer<UInt8>.allocate(capacity: 128)
        physical.initialize(repeating: 0, count: 128)
        members.initialize(repeating: 0, count: 128)
        velocities.initialize(repeating: 100, count: 128)
        sorted.initialize(repeating: 0, count: 128)
    }

    deinit {
        physical.deallocate()
        members.deallocate()
        velocities.deallocate()
        sorted.deallocate()
    }

    // MARK: Setup and settings (once per block)

    func configure(mode: ArpMode, octaves: Int, repeats: Int, hold newHold: Bool, samplesPerStep: Double) {
        self.mode = mode
        self.octaves = min(max(octaves, 1), 4)
        self.repeats = min(max(repeats, 1), 4)
        self.samplesPerStep = samplesPerStep
        if hold && !newHold && physicalCount == 0 {       // HOLD off with no key down: the pattern stops
            clearMembers()
        }
        hold = newHold
    }

    func reset() {
        for i in 0..<128 {
            physical[i] = 0
            members[i] = 0
        }
        physicalCount = 0
        sortedCount = 0
        dirty = false
        running = false
        soundingNote = -1
        position = 0
        repeatCount = 0
    }

    private func clearMembers() {
        for i in 0..<128 { members[i] = 0 }
        dirty = true
    }

    // MARK: Keys

    func keyDown(note: UInt8, velocity: UInt8) {
        guard note < 128 else { return }
        let n = Int(note)
        if hold && physicalCount == 0 { clearMembers() }  // a new chord replaces the held one
        if physical[n] == 0 {
            physical[n] = 1
            physicalCount += 1
        }
        members[n] = 1
        velocities[n] = velocity
        dirty = true
    }

    func keyUp(note: UInt8) {
        guard note < 128 else { return }
        let n = Int(note)
        if physical[n] != 0 {
            physical[n] = 0
            physicalCount -= 1
        }
        if !hold {
            members[n] = 0
            dirty = true
        }
    }

    /// All notes off / all sound off.
    func releaseAll() {
        for i in 0..<128 { physical[i] = 0 }
        physicalCount = 0
        clearMembers()
        soundingNote = -1
    }

    func isPhysicallyDown(_ note: Int) -> Bool { note >= 0 && note < 128 && physical[note] != 0 }
    func velocity(of note: Int) -> UInt8 { note >= 0 && note < 128 ? velocities[note] : 100 }

    // MARK: Switching on and off

    /// ENABLE went on: the keys now down become the pattern.
    func begin() {
        for i in 0..<128 { members[i] = physical[i] }
        dirty = true
        running = false
        soundingNote = -1
    }

    /// ENABLE went off: returns the note that was sounding (to release), or -1.
    func end() -> Int {
        let note = soundingNote
        soundingNote = -1
        running = false
        return note
    }

    // MARK: Audio thread

    private func rebuild() {
        sortedCount = 0
        for i in 0..<128 where members[i] != 0 {
            sorted[sortedCount] = UInt8(i)
            sortedCount += 1
        }
        dirty = false
    }

    @inline(__always)
    private func nextRandom(_ bound: Int) -> Int {
        randomState ^= randomState << 13
        randomState ^= randomState >> 17
        randomState ^= randomState << 5
        return Int(randomState % UInt32(max(bound, 1)))
    }

    /// Picks a new random pattern index, never the same one twice in a row when there is a choice.
    private func pickRandom(_ pool: Int) {
        if pool <= 1 {
            randomIndex = 0
            return
        }
        var r = nextRandom(pool - 1)
        if r >= randomIndex % pool { r += 1 }
        randomIndex = r
    }

    /// One sample. Call it for every sample while the arpeggiator is enabled.
    @inline(__always)
    func step() -> ArpStepEvent {
        var event = ArpStepEvent()
        if dirty { rebuild() }

        // Release the sounding note when its gate is over.
        if soundingNote >= 0 {
            samplesToOff -= 1
            if samplesToOff <= 0 {
                event.off = soundingNote
                soundingNote = -1
            }
        }

        if sortedCount == 0 {                     // nothing to play: wait for the first key
            running = false
            return event
        }
        if !running {                             // the first key starts the pattern at once
            running = true
            samplesToNext = 0
            position = 0
            repeatCount = 0
            pickRandom(sortedCount * octaves)
        }

        samplesToNext -= 1
        if samplesToNext <= 0 {
            samplesToNext += samplesPerStep
            if soundingNote >= 0 { event.off = soundingNote }   // safety: never leave a note hanging

            let count = sortedCount
            let pool = count * octaves
            let index: Int
            switch mode {
            case .up:
                index = position % pool
            case .down:
                index = pool - 1 - (position % pool)
            case .upDown:
                let cycle = max(1, 2 * pool - 2)
                let p = position % cycle
                index = p < pool ? p : 2 * pool - 2 - p
            case .random:
                index = randomIndex % pool
            }
            let source = Int(sorted[index % count])
            let note = min(source + 12 * (index / count), 127)
            event.on = note
            event.velocity = velocities[source]
            soundingNote = note
            samplesToOff = samplesPerStep * Arpeggiator.gate

            // On to the next step, after `repeats` plays of this one.
            repeatCount += 1
            if repeatCount >= repeats {
                repeatCount = 0
                position = (position + 1) & 0xFFFFF
                pickRandom(pool)
            }
        }
        return event
    }
}
