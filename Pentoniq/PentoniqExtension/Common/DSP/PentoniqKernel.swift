// PentoniqKernel.swift  (milestone 6: replaces the milestone 5 version)
// Real-time glue between the Audio Unit and the synth engine. Pure Swift.
//
// All sound generation lives in PentoniqEngine (8 voices: VCO -> tube -> VCF -> amp, with envelopes). This
// file only reads parameters, turns AU render events (MIDI, parameter changes)
// into engine calls, and writes the engine's output into the host's buffers.
//
// Real-time rules for everything called from render(): no allocation,
// no locks, no Swift arrays/strings/closures created, no Objective-C calls.

import AudioToolbox
import Foundation

final class PentoniqKernel {

    // Parameter storage: raw memory so the UI thread can write and the audio
    // thread can read without locks or ARC traffic. Single-Float reads/writes
    // are atomic on Apple CPUs, so this benign race is the usual AU approach.
    private let params: UnsafeMutablePointer<Float>
    // Counts every MIDI event received (bumped on the audio thread, read by the UI's
    // MIDI lamp). A single UInt32 read/write is the same benign race as the parameters.
    private let midiCounter: UnsafeMutablePointer<UInt32>
    // Milestone 6: two complete synths. Voice I and Voice II both play every MIDI note;
    // the MIX control fades between them, then the global filter and master volume follow.
    private let engine1 = PentoniqEngine()
    private let engine2 = PentoniqEngine()
    // Parameter index maps: base parameter -> where that voice reads it. Voice I reads itself,
    // Voice II reads its twin. Raw memory, like the parameters.
    private let voice1Map: UnsafeMutablePointer<Int>
    private let voice2Map: UnsafeMutablePointer<Int>
    private var sampleRate = 44_100.0
    private var smoothing: Float = 0.01
    private var mixSmoothed: Float = 0
    private var masterSmoothed: Float = 0.5
    private var started = false
    /// Feeds the MASTER section oscilloscope.
    let scope = ScopeTap()

    init() {
        let count = ParamID.allCases.count
        let storage = UnsafeMutablePointer<Float>.allocate(capacity: count)
        storage.initialize(repeating: 0, count: count)
        for spec in PentoniqParameters.specs {
            storage[spec.id.index] = spec.defaultValue
        }
        params = storage
        let map1 = UnsafeMutablePointer<Int>.allocate(capacity: count)
        let map2 = UnsafeMutablePointer<Int>.allocate(capacity: count)
        for i in 0..<count { map1[i] = i; map2[i] = i }
        for pair in PentoniqParameters.voiceIIPairs { map2[pair.base.index] = pair.v2.index }
        voice1Map = map1
        voice2Map = map2
        let counter = UnsafeMutablePointer<UInt32>.allocate(capacity: 1)
        counter.initialize(to: 0)
        midiCounter = counter
    }

    deinit {
        params.deallocate()
        voice1Map.deallocate()
        voice2Map.deallocate()
        midiCounter.deallocate()
    }

    /// Number of MIDI events received so far (wraps). For the UI's MIDI lamp.
    var midiActivity: UInt32 { midiCounter.pointee }

    // MARK: - Setup (not real-time; called from allocateRenderResources)

    func setSampleRate(_ newRate: Double) {
        sampleRate = newRate
        smoothing = Float(1.0 - exp(-1.0 / (0.005 * newRate)))
        engine1.setSampleRate(newRate)
        engine2.setSampleRate(newRate)
        started = false
        scope.configure(sampleRate: newRate)
    }

    func reset() {
        engine1.reset()
        engine2.reset()
        started = false
    }

    // MARK: - Parameters (any thread)

    func setParameter(address: AUParameterAddress, value: AUValue) {
        guard address < UInt64(ParamID.allCases.count) else { return }
        params[Int(address)] = value
    }

    func parameter(address: AUParameterAddress) -> AUValue {
        guard address < UInt64(ParamID.allCases.count) else { return 0 }
        return params[Int(address)]
    }

    /// One voice's settings. `map` says where each of its parameters lives (Voice I or Voice II).
    /// Master volume is applied after the mix, so each voice runs at master = 1.
    private func settings(map: UnsafeMutablePointer<Int>) -> SynthSettings {
        func p(_ id: ParamID) -> Float { params[map[id.index]] }
        var s = SynthSettings()
        // Global BRILLIANCE and RESONANCE: the same offsets go to both voices (they are not mapped).
        s.brillianceOffset = params[ParamID.brilliance.index] - 0.5
        s.resonanceOffset = params[ParamID.mixResonance.index]
        s.waveform = Int(p(.waveform).rounded())
        s.pulseWidth = p(.pulseWidth)
        s.pwmDepth = p(.pwm)
        s.speed = p(.speed)
        s.noiseLevel = p(.noise)
        s.sync = p(.sync) >= 0.5
        s.tubeOn = p(.tubeEnabled) >= 0.5
        s.tubeIndex = Int(p(.tubeType).rounded())
        s.bias = p(.bias)
        s.driveDB = p(.drive)
        s.outputDB = p(.output)
        s.oversampling = Int(p(.oversampling).rounded())
        s.master = 1
        s.cutoff = p(.lpfCutoff)
        s.resonance = p(.lpfResonance)
        s.ampAttack = p(.ampAttack)
        s.ampDecay = p(.ampDecay)
        s.ampSustain = p(.ampSustain)
        s.ampRelease = p(.ampRelease)
        s.vcfInitialLevel = p(.vcfInitialLevel)
        s.vcfAttackLevel = p(.vcfAttackLevel)
        s.vcfAttack = p(.vcfAttack)
        s.vcfDecay = p(.vcfDecay)
        s.vcfRelease = p(.vcfRelease)
        return s
    }

    // MARK: - Render (audio thread)

    func render(frameCount: Int,
                sampleTimeBase: Int64,
                output: UnsafeMutablePointer<AudioBufferList>,
                events: UnsafePointer<AURenderEvent>?) {

        let buffers = UnsafeMutableAudioBufferListPointer(output)
        let byteCount = UInt32(frameCount * MemoryLayout<Float>.size)

        var left: UnsafeMutablePointer<Float>? = nil
        var right: UnsafeMutablePointer<Float>? = nil
        if buffers.count > 0 {
            buffers[0].mDataByteSize = byteCount
            left = buffers[0].mData?.assumingMemoryBound(to: Float.self)
        }
        if buffers.count > 1 {
            buffers[1].mDataByteSize = byteCount
            right = buffers[1].mData?.assumingMemoryBound(to: Float.self)
        }

        // Settings are read once per block.
        engine1.configure(settings(map: voice1Map))
        engine2.configure(settings(map: voice2Map))
        let mixTarget = params[ParamID.mix.index]
        let masterTarget = params[ParamID.masterVolume.index]
        if !started {                     // first block: start at the targets, no ramp
            mixSmoothed = mixTarget
            masterSmoothed = masterTarget
            started = true
        }

        var nextEvent = events

        for frame in 0..<frameCount {

            // Apply every event that is due at (or before) this frame.
            while let e = nextEvent,
                  e.pointee.head.eventSampleTime - sampleTimeBase <= Int64(frame) {
                handle(event: e)
                nextEvent = UnsafePointer(e.pointee.head.next)
            }

            // One-pole smoothing (about 5 ms) so the faders do not zipper.
            mixSmoothed += (mixTarget - mixSmoothed) * smoothing
            masterSmoothed += (masterTarget - masterSmoothed) * smoothing

            // Equal-power fade: MIX at the top (1) is Voice I only, at the bottom (0) Voice II only.
            let angle = mixSmoothed * (Float.pi / 2)
            let mixed = sin(angle) * engine1.process() + cos(angle) * engine2.process()

            // BRILLIANCE and RESONANCE are applied inside each voice's filter (see PentoniqEngine),
            // so nothing more happens here except the master volume.
            let sample = mixed * masterSmoothed
            scope.push(sample)
            left?[frame] = sample
            right?[frame] = sample
        }

        // Anything left over (shouldn't happen) is applied so state stays right.
        while let e = nextEvent {
            handle(event: e)
            nextEvent = UnsafePointer(e.pointee.head.next)
        }
    }

    // MARK: - Events

    private func handle(event e: UnsafePointer<AURenderEvent>) {
        switch e.pointee.head.eventType {
        case .MIDI:
            midiCounter.pointee &+= 1
            let m = e.pointee.MIDI
            handleMIDI(status: m.data.0, data1: m.data.1, data2: m.data.2)
        case .parameter, .parameterRamp:
            // Ramps are applied as an immediate jump for now; the engine's own
            // smoothing hides the step.
            let p = e.pointee.parameter
            setParameter(address: p.parameterAddress, value: p.value)
        default:
            break
        }
    }

    private func handleMIDI(status: UInt8, data1: UInt8, data2: UInt8) {
        switch status & 0xF0 {
        case 0x90 where data2 > 0:                    // note on
            engine1.noteOn(note: data1, velocity: data2)
            engine2.noteOn(note: data1, velocity: data2)
        case 0x80, 0x90:                              // note off (or on, velocity 0)
            engine1.noteOff(note: data1)
            engine2.noteOff(note: data1)
        case 0xB0 where data1 == 123 || data1 == 120: // all notes / all sound off
            engine1.allNotesOff()
            engine2.allNotesOff()
        default:
            break
        }
    }
}
