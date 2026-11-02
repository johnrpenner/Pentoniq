// Envelope.swift
// Milestone 5, part 1 of 3: the envelope generator used for BOTH the CS-80 style
// filter ("brilliance") envelope and the plain amplifier ADSR.
//
// One generator, four resting/target levels, three speeds:
//
//     key down ---> ATTACK (initial level -> attack level, then)
//                   DECAY  (attack level -> sustain level, and it stays there)
//     key up   ---> RELEASE (current level -> release level, then idle)
//
//   Amplifier ADSR:   initial 0, attack level 1, sustain = Sustain fader, release level 0.
//   VCF envelope (CS-80): the levels are OFFSETS from the cutoff fader ("Brilliance"):
//                     initial = IL, attack level = AL, sustain = 0 (the cutoff itself: the
//                     CS-80 has no filter sustain fader), release level = IL. IL is usually
//                     below the cutoff (negative) and AL above it (positive), so a note
//                     rises from IL past the cutoff to AL, settles back to the cutoff,
//                     and on release drops to IL.
//
// The segments are analogue-style exponentials (an RC charging toward a target),
// which is what gives envelopes their natural, slightly "bowed" feel:
//   - Attack aims at a target 30% beyond the attack level, so it arrives with a
//     little speed instead of creeping in; the Attack time is the time to ARRIVE.
//   - Decay time is the time to get within 1% of the sustain level.
//   - Release time is the time to fall 60 dB toward the release level.
// A retriggered or stolen voice starts its attack from wherever the level is now,
// so there is no click.
//
// No dependency on AudioToolbox (also usable from the unit-test target).
// Nothing allocates; safe on the audio thread.

import Foundation

/// Everything an envelope needs, as plain numbers. The engine builds one per
/// envelope once per render block and hands it to every voice.
struct EnvelopeSettings {
    var initialLevel: Float = 0
    var attackLevel: Float = 1
    var sustainLevel: Float = 1
    var releaseLevel: Float = 0
    var attackCoefficient: Float = 0.01      // per-sample one-pole coefficients
    var decayCoefficient: Float = 0.001
    var releaseCoefficient: Float = 0.001

    /// How far past the attack level the attack aims (fraction of its span).
    static let overshoot: Float = 0.3

    /// Time faders (0...1) to seconds: exponential, 1 ms (0) to 10 s (1).
    static func seconds(forFader x: Float) -> Double {
        0.001 * pow(10.0, 4.0 * Double(min(max(x, 0), 1)))
    }

    init() {}

    init(initialLevel: Float, attackLevel: Float, sustainLevel: Float, releaseLevel: Float,
         attackFader: Float, decayFader: Float, releaseFader: Float, sampleRate: Double) {
        self.initialLevel = initialLevel
        self.attackLevel = attackLevel
        self.sustainLevel = sustainLevel
        self.releaseLevel = releaseLevel

        let o = Double(EnvelopeSettings.overshoot)
        let attackSeconds = EnvelopeSettings.seconds(forFader: attackFader)
        let decaySeconds = EnvelopeSettings.seconds(forFader: decayFader)
        let releaseSeconds = EnvelopeSettings.seconds(forFader: releaseFader)
        attackCoefficient = Float(1.0 - exp(-log((1.0 + o) / o) / (attackSeconds * sampleRate)))
        decayCoefficient = Float(1.0 - exp(-log(100.0) / (decaySeconds * sampleRate)))
        releaseCoefficient = Float(1.0 - exp(-log(1000.0) / (releaseSeconds * sampleRate)))
    }
}

enum EnvelopeStage {
    case idle
    case attack
    case decay      // also the sustain: the level just stays at the sustain level
    case release
}

struct Envelope {

    private(set) var level: Float = 0
    private(set) var stage: EnvelopeStage = .idle
    private var attackTarget: Float = 1
    private var rising = true

    var isActive: Bool { stage != .idle }

    mutating func reset() {
        level = 0
        stage = .idle
    }

    /// Key down. `fresh` = the voice was silent, so start from the initial
    /// level; otherwise carry on from the current level.
    mutating func gateOn(_ s: EnvelopeSettings, fresh: Bool) {
        if fresh { level = s.initialLevel }
        let span = s.attackLevel - level
        if abs(span) < 0.000_001 {
            stage = .decay
        } else {
            rising = span > 0
            attackTarget = s.attackLevel + EnvelopeSettings.overshoot * span
            stage = .attack
        }
    }

    /// Key up.
    mutating func gateOff() {
        if stage != .idle { stage = .release }
    }

    /// One sample. Returns the new level.
    @inline(__always)
    mutating func process(_ s: EnvelopeSettings) -> Float {
        switch stage {
        case .idle:
            break
        case .attack:
            level += (attackTarget - level) * s.attackCoefficient
            if (rising && level >= s.attackLevel) || (!rising && level <= s.attackLevel) {
                level = s.attackLevel
                stage = .decay
            }
        case .decay:
            level += (s.sustainLevel - level) * s.decayCoefficient
        case .release:
            level += (s.releaseLevel - level) * s.releaseCoefficient
            if abs(level - s.releaseLevel) < 0.0001 {
                level = s.releaseLevel
                stage = .idle
            }
        }
        return level
    }
}
