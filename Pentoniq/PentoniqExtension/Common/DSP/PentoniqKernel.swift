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
    
    // Milestone 9: MIDI learn. All raw memory, like the parameters.
    private let ccTarget: UnsafeMutablePointer<Int32>        // CC number -> parameter index, or -1
    private let paramMin: UnsafeMutablePointer<Float>
    private let paramMax: UnsafeMutablePointer<Float>
    private let paramStepped: UnsafeMutablePointer<Bool>     // buttons and indexed controls
    private let learnState: UnsafeMutablePointer<UInt32>     // [0] listening flag, [1] CC count, [2] last CC
    
    // Milestone 11: one sub-oscillator shared by every voice of both engines.
    private var subOsc = SubOscillator()
    private var subVCOSmoothed: Float = 0
    private var subVCFSmoothed: Float = 0
    private var subVCASmoothed: Float = 0
    private var subPanSmoothed: Float = 0
    /// Set by the audio unit: lets the sub-oscillator read the host tempo.
    var musicalContext: AUHostMusicalContextBlock?
    
    // Milestone 18: the Leslie speaker simulation (replaces the opposed Voice I / II panning)
    private let leslie = LeslieSimulation()
    private var leslieSmoothed: Float = 0
    
    // Milestone 16: delay + chorus
    private let delayFX = DelayChorusEffect()
    
    // Milestone 15: arpeggiator. While `arpActive`, keys go to it instead of straight to the voices.
    private let arp = Arpeggiator()
    private var arpActive = false
    
    // Milestone 13: on-screen keyboard
    private static let uiQueueCapacity = 64
    private let heldNotes: UnsafeMutablePointer<UInt8>          // 128 flags, written by the audio thread
    private let uiQueue: UnsafeMutablePointer<UInt16>           // note << 8 | velocity (0 = note off)
    private let uiQueueCount: UnsafeMutablePointer<Int>
    private let uiQueueLock: UnsafeMutablePointer<os_unfair_lock>
    
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
        
        let ccMap = UnsafeMutablePointer<Int32>.allocate(capacity: 128)
        ccMap.initialize(repeating: -1, count: 128)
        let minima = UnsafeMutablePointer<Float>.allocate(capacity: count)
        let maxima = UnsafeMutablePointer<Float>.allocate(capacity: count)
        let stepped = UnsafeMutablePointer<Bool>.allocate(capacity: count)
        minima.initialize(repeating: 0, count: count)
        maxima.initialize(repeating: 1, count: count)
        stepped.initialize(repeating: false, count: count)
        for spec in PentoniqParameters.specs {
            minima[spec.id.index] = spec.min
            maxima[spec.id.index] = spec.max
            stepped[spec.id.index] = (spec.unit == .boolean || spec.unit == .indexed)
        }
        let learnStorage = UnsafeMutablePointer<UInt32>.allocate(capacity: 3)
        learnStorage.initialize(repeating: 0, count: 3)
        ccTarget = ccMap
        paramMin = minima
        paramMax = maxima
        paramStepped = stepped
        learnState = learnStorage
        
        let held = UnsafeMutablePointer<UInt8>.allocate(capacity: 128)
        held.initialize(repeating: 0, count: 128)
        let queue = UnsafeMutablePointer<UInt16>.allocate(capacity: PentoniqKernel.uiQueueCapacity)
        queue.initialize(repeating: 0, count: PentoniqKernel.uiQueueCapacity)
        let queueCount = UnsafeMutablePointer<Int>.allocate(capacity: 1)
        queueCount.initialize(to: 0)
        let lock = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
        lock.initialize(to: os_unfair_lock())
        heldNotes = held
        uiQueue = queue
        uiQueueCount = queueCount
        uiQueueLock = lock
        
        loadMIDIMap()
        
    }

    deinit {
        params.deallocate()
        voice1Map.deallocate()
        voice2Map.deallocate()
        midiCounter.deallocate()
        
        ccTarget.deallocate()
        paramMin.deallocate()
        paramMax.deallocate()
        paramStepped.deallocate()
        learnState.deallocate()
        
        heldNotes.deallocate()
        uiQueue.deallocate()
        uiQueueCount.deallocate()
        uiQueueLock.deallocate()
    }

    /// Number of MIDI events received so far (wraps). For the UI's MIDI lamp.
    var midiActivity: UInt32 { midiCounter.pointee }
    
    // MARK: - MIDI learn (not real-time, any thread)
    
    /// Links a CC to a parameter index; -1 clears the CC.
    func setMIDIMapping(cc: Int, parameterIndex: Int) {
        guard cc >= 0, cc < 128 else { return }
        ccTarget[cc] = Int32(parameterIndex)
    }

    /// While listening, CCs are recorded but do not move anything.
    func setMIDILearning(_ on: Bool) {
        learnState[0] = on ? 1 : 0
    }

    /// How many CCs have arrived (wraps) and the latest one's number.
    var lastMIDICC: (count: UInt32, cc: Int) {
        (learnState[1], Int(learnState[2]))
    }

    /// Reads the saved CC map (UserDefaults) into the audio thread's table.
    func loadMIDIMap() {
        for cc in 0..<128 { ccTarget[cc] = -1 }
        for (cc, identifier) in MIDIMapStore.load() {
            guard cc >= 0, cc < 128,
                  let spec = PentoniqParameters.specs.first(where: { $0.identifier == identifier })
            else { continue }
            ccTarget[cc] = Int32(spec.id.index)
        }
    }
    
    // MARK: - On-screen keyboard (milestone 13)

    /// UI thread: queue a note for the audio thread. velocity 0 = note off.
    func enqueueNote(note: UInt8, velocity: UInt8) {
        guard note < 128 else { return }
        os_unfair_lock_lock(uiQueueLock)
        if uiQueueCount.pointee < PentoniqKernel.uiQueueCapacity {
            uiQueue[uiQueueCount.pointee] = (UInt16(note) << 8) | UInt16(velocity)
            uiQueueCount.pointee += 1
        }
        os_unfair_lock_unlock(uiQueueLock)
    }

    /// Any thread: is this key down (from MIDI or the mouse)?
    func isNoteHeld(_ note: UInt8) -> Bool {
        note < 128 && heldNotes[Int(note)] != 0
    }

    /// Audio thread: start or stop the notes the mouse queued. Never waits for the UI.
    private func drainKeyboardQueue() {
        guard os_unfair_lock_trylock(uiQueueLock) else { return }
        let count = uiQueueCount.pointee
        for i in 0..<count {
            let entry = uiQueue[i]
            let note = UInt8(entry >> 8)
            let velocity = UInt8(entry & 0xFF)
            if velocity > 0 {
                handleMIDI(status: 0x90, data1: note, data2: velocity)
            } else {
                handleMIDI(status: 0x80, data1: note, data2: 0)
            }
        }
        uiQueueCount.pointee = 0
        os_unfair_lock_unlock(uiQueueLock)
    }
    
    // MARK: - Arpeggiator (milestone 15)

    /// ENABLE changed. Going on: whatever is sounding is released and the keys now down become the pattern.
    /// Going off: the pattern's note is released and the keys still down sound directly again.
    private func setArpActive(_ on: Bool) {
        guard on != arpActive else { return }
        arpActive = on
        if on {
            engine1.allNotesOff()
            engine2.allNotesOff()
            arp.begin()
        } else {
            let sounding = arp.end()
            if sounding >= 0 {
                engine1.noteOff(note: UInt8(sounding))
                engine2.noteOff(note: UInt8(sounding))
            }
            for i in 0..<128 {
                if heldNotes[i] == 2 { heldNotes[i] = 0 }          // 2 = lit by the arpeggiator
                if arp.isPhysicallyDown(i) {
                    engine1.noteOn(note: UInt8(i), velocity: arp.velocity(of: i))
                    engine2.noteOn(note: UInt8(i), velocity: arp.velocity(of: i))
                }
            }
        }
    }

    /// Plays one arpeggiator step's note off and note on. The on-screen keyboard lights the arpeggiated note.
    private func applyArp(_ event: ArpStepEvent) {
        if event.off >= 0 {
            engine1.noteOff(note: UInt8(event.off))
            engine2.noteOff(note: UInt8(event.off))
            if heldNotes[event.off] == 2 { heldNotes[event.off] = 0 }
        }
        if event.on >= 0 {
            engine1.noteOn(note: UInt8(event.on), velocity: event.velocity)
            engine2.noteOn(note: UInt8(event.on), velocity: event.velocity)
            if heldNotes[event.on] == 0 { heldNotes[event.on] = 2 }
        }
    }
    
    // MARK: - Setup (not real-time; called from allocateRenderResources)

    func setSampleRate(_ newRate: Double) {
        sampleRate = newRate
        smoothing = Float(1.0 - exp(-1.0 / (0.005 * newRate)))
        engine1.setSampleRate(newRate)
        engine2.setSampleRate(newRate)
        started = false
        scope.configure(sampleRate: newRate)
        subOsc.configure(sampleRate: newRate)
        leslie.configure(sampleRate: newRate)
        delayFX.configure(sampleRate: newRate)
    }

    func reset() {
        engine1.reset()
        engine2.reset()
        started = false
        subOsc.reset()
        for i in 0..<128 { heldNotes[i] = 0 }
        leslie.reset()
        delayFX.reset()
        arp.reset()
        arpActive = false
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
    private func settings(map: UnsafeMutablePointer<Int>, detune: Float) -> SynthSettings {
        func p(_ id: ParamID) -> Float { params[map[id.index]] }
        var s = SynthSettings()
        s.detuneSemitones = detune
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
        engine1.configure(settings(map: voice1Map, detune: 0))
        engine2.configure(settings(map: voice2Map, detune: params[ParamID.detune.index]))
        let mixTarget = params[ParamID.mix.index]
        let masterTarget = params[ParamID.masterVolume.index]

        // Host tempo, for the Sub-Osc, arpeggiator and delay SYNC (127 BPM when the host gives none).
        let subWaveform = SubOscWaveform(rawValue: Int(params[ParamID.subWaveform.index].rounded())) ?? .sine
        let subSync = params[ParamID.subSync.index] >= 0.5
        let arpSync = params[ParamID.arpSync.index] >= 0.5
        let delaySync = params[ParamID.delaySync.index] >= 0.5
        var bpm = SubOscRate.defaultBPM
        if subSync || arpSync || delaySync, let context = musicalContext {
            var tempo = 0.0
            if context(&tempo, nil, nil, nil, nil, nil), tempo > 1 { bpm = tempo }
        }

        // Sub-oscillator: rate and the four sends, each multiplied by the WHEEL value.
        subOsc.setRate(hertz: SubOscRate.hertz(speed: params[ParamID.subSpeed.index], sync: subSync, bpm: bpm),
                       sampleRate: sampleRate)
        let wheel = min(max(params[ParamID.wheelValue.index], 0), 1)
        let vcoTarget = params[ParamID.subVCO.index] * wheel
        let vcfTarget = params[ParamID.subVCF.index] * wheel
        let vcaTarget = params[ParamID.subVCA.index] * wheel
        let panTarget = params[ParamID.subPan.index] * wheel
        let leslieManual = params[ParamID.leslie.index]       // the PAN slider as the user set it

        // Delay + chorus settings, once per block.
        delayFX.setControls(delayOn: params[ParamID.delayEnable.index] >= 0.5,
                            chorusOn: params[ParamID.delayChorus.index] >= 0.5,
                            speed: params[ParamID.delaySpeed.index],
                            depth: params[ParamID.delayDepth.index],
                            mix: params[ParamID.delayMix.index],
                            sync: delaySync, bpm: bpm)

        // Arpeggiator settings. ENABLE changes take effect here, before this block's events.
        arp.configure(mode: ArpMode(rawValue: Int(params[ParamID.arpMode.index].rounded())) ?? .up,
                      octaves: Int(params[ParamID.arpOctave.index].rounded()) + 1,
                      repeats: Int(params[ParamID.arpRepeat.index].rounded()) + 1,
                      hold: params[ParamID.arpHold.index] >= 0.5,
                      samplesPerStep: ArpRate.samplesPerStep(speed: params[ParamID.arpSpeed.index],
                                                             sync: arpSync, bpm: bpm, sampleRate: sampleRate))
        setArpActive(params[ParamID.arpEnable.index] >= 0.5)

        drainKeyboardQueue()

        if !started {                     // first block: start at the targets, no ramp
            mixSmoothed = mixTarget
            masterSmoothed = masterTarget
            subVCOSmoothed = vcoTarget
            subVCFSmoothed = vcfTarget
            subVCASmoothed = vcaTarget
            subPanSmoothed = panTarget
            leslieSmoothed = leslieManual
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

            // The arpeggiator plays its next note when a step is due.
            if arpActive { applyArp(arp.step()) }

            // One-pole smoothing (about 5 ms) so the faders do not zipper.
            mixSmoothed += (mixTarget - mixSmoothed) * smoothing
            masterSmoothed += (masterTarget - masterSmoothed) * smoothing
            subVCOSmoothed += (vcoTarget - subVCOSmoothed) * smoothing
            subVCFSmoothed += (vcfTarget - subVCFSmoothed) * smoothing
            subVCASmoothed += (vcaTarget - subVCASmoothed) * smoothing
            subPanSmoothed += (panTarget - subPanSmoothed) * smoothing

            // The shared sub-oscillator, -1...+1 (0 when its speed is OFF).
            let lfo = subOsc.next(waveform: subWaveform)
            let vibrato = lfo * subVCOSmoothed * SubOscDepth.vibratoSemitones
            let wobble = lfo * subVCFSmoothed * SubOscDepth.wobbleOctaves * SubOscDepth.faderUnitsPerOctave
            // Tremolo swings the level between 1 and (1 - depth), so it never gets louder.
            let tremolo = 1 - subVCASmoothed * 0.5 * (1 - lfo)

            // PAN slider (Leslie): the manual value, plus the Sub-Osc PAN send swinging it by up to
            // +/-0.5 of its travel (the send is already scaled by the WHEEL).
            let leslieTarget = min(max(leslieManual + lfo * subPanSmoothed * 0.5, 0), 1)
            leslieSmoothed += (leslieTarget - leslieSmoothed) * smoothing

            // Equal-power fade: MIX at the top (1) is Voice I only, at the bottom (0) Voice II only.
            let angle = mixSmoothed * (Float.pi / 2)
            let voice1 = sin(angle) * engine1.process(vibrato: vibrato, cutoffMod: wobble)
            let voice2 = cos(angle) * engine2.process(vibrato: vibrato, cutoffMod: wobble)

            // The mixed voices go through the rotating speaker, which makes the stereo,
            // then the chorus and the ping-pong delay.
            let mono = (voice1 + voice2) * tremolo
            let (leslieLeft, leslieRight) = leslie.process(mono, amount: leslieSmoothed)
            let (fxLeft, fxRight) = delayFX.process(leslieLeft, leslieRight)
            let sampleLeft = fxLeft * masterSmoothed
            let sampleRight = fxRight * masterSmoothed
            scope.push(0.5 * (sampleLeft + sampleRight))
            left?[frame] = sampleLeft
            right?[frame] = sampleRight
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
            if data1 < 128 { heldNotes[Int(data1)] = 1 }
            arp.keyDown(note: data1, velocity: data2)
            if !arpActive {
                engine1.noteOn(note: data1, velocity: data2)
                engine2.noteOn(note: data1, velocity: data2)
            }
        case 0x80, 0x90:                              // note off (or on, velocity 0)
            if data1 < 128 { heldNotes[Int(data1)] = 0 }
            arp.keyUp(note: data1)
            if !arpActive {
                engine1.noteOff(note: data1)
                engine2.noteOff(note: data1)
            }
        case 0xB0 where data1 < 128:                  // control change
            // Record it for MIDI learn first. While learning, no CC acts on anything.
            learnState[2] = UInt32(data1)
            learnState[1] &+= 1
            if learnState[0] != 0 { return }

            if data1 == 123 || data1 == 120 {         // all notes / all sound off
                for i in 0..<128 { heldNotes[i] = 0 }
                arp.releaseAll()
                engine1.allNotesOff()
                engine2.allNotesOff()
            }
            if data1 == 1, params[ParamID.wheelEnable.index] >= 0.5 {   // MOD wheel drives the WHEEL
                params[ParamID.wheelValue.index] = Float(data2) / 127
            }
            // A learned CC moves its slider across the slider's whole range.
            let target = Int(ccTarget[Int(data1)])
            if target >= 0 {
                var value = paramMin[target] + Float(data2) / 127 * (paramMax[target] - paramMin[target])
                if paramStepped[target] { value = value.rounded() }
                params[target] = value
            }
        default:
            break
        }
    }
}
