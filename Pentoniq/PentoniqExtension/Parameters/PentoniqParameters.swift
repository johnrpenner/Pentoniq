// PentoniqParameters.swift  (milestone 6: replaces the milestone 5 version)
// Shared by the audio unit, the DSP kernel and the SwiftUI view.
//
// The first seven parameters keep their original order, so projects saved with
// milestone 2 still load. New parameters are only ever appended.

import AudioToolbox

/// Parameter addresses. The raw value doubles as the index into the
/// kernel's parameter storage, so keep them contiguous starting at 0.
enum ParamID: AUParameterAddress, CaseIterable {
    case masterVolume = 0
    case tubeEnabled
    case tubeType
    case drive
    case bias
    case output
    case oversampling
    // Milestone 3: VCO
    case waveform
    case speed
    case pwm
    case pulseWidth
    case noise
    case sync
    // Milestone 4: VCF
    case lpfCutoff
    case lpfResonance
    // Milestone 5: amplifier ADSR
    case ampAttack
    case ampDecay
    case ampSustain
    case ampRelease
    // Milestone 5: VCF envelope (CS-80 style)
    case vcfInitialLevel
    case vcfAttackLevel
    case vcfAttack
    case vcfDecay
    case vcfRelease
    // Milestone 6: Voice II = a full copy of the Voice I controls above (same order as `voiceIIPairs`).
    case v2TubeEnabled
    case v2TubeType
    case v2Drive
    case v2Bias
    case v2Output
    case v2Oversampling
    case v2Waveform
    case v2Speed
    case v2Pwm
    case v2PulseWidth
    case v2Noise
    case v2Sync
    case v2LpfCutoff
    case v2LpfResonance
    case v2AmpAttack
    case v2AmpDecay
    case v2AmpSustain
    case v2AmpRelease
    case v2VcfInitialLevel
    case v2VcfAttackLevel
    case v2VcfAttack
    case v2VcfDecay
    case v2VcfRelease
    // Milestone 6: global Voice I + II MIX section
    case mix                // 1 (top) = Voice I only ... 0 (bottom) = Voice II only
    case mixResonance       // global RESONANCE: added to every voice's resonance
    case brilliance         // global BRILLIANCE: shifts every voice's cutoff (0.5 = no shift)

    var index: Int { Int(rawValue) }
}

struct ParameterSpec {
    let id: ParamID
    let identifier: String
    let name: String
    let min: AUValue
    let max: AUValue
    let defaultValue: AUValue
    let unit: AudioUnitParameterUnit
    var valueStrings: [String]? = nil
}

enum PentoniqParameters {

    static let tubeNames = ["12AX7", "12AT7", "12AU7"]
    static let oversamplingNames = ["Off", "2x", "4x"]
    static let waveformNames = ["Sine", "+Saw", "-Saw", "Square", "Noise"]

    /// Voice I parameter -> its Voice II twin. This table is the one place the pairing lives.
    static let voiceIIPairs: [(base: ParamID, v2: ParamID)] = [
        (.tubeEnabled, .v2TubeEnabled), (.tubeType, .v2TubeType), (.drive, .v2Drive),
        (.bias, .v2Bias), (.output, .v2Output), (.oversampling, .v2Oversampling),
        (.waveform, .v2Waveform), (.speed, .v2Speed), (.pwm, .v2Pwm),
        (.pulseWidth, .v2PulseWidth), (.noise, .v2Noise), (.sync, .v2Sync),
        (.lpfCutoff, .v2LpfCutoff), (.lpfResonance, .v2LpfResonance),
        (.ampAttack, .v2AmpAttack), (.ampDecay, .v2AmpDecay), (.ampSustain, .v2AmpSustain),
        (.ampRelease, .v2AmpRelease),
        (.vcfInitialLevel, .v2VcfInitialLevel), (.vcfAttackLevel, .v2VcfAttackLevel),
        (.vcfAttack, .v2VcfAttack), (.vcfDecay, .v2VcfDecay), (.vcfRelease, .v2VcfRelease)
    ]

    /// Every Voice II spec is the Voice I spec with a new address, identifier and name.
    private static let voiceIISpecs: [ParameterSpec] = voiceIIPairs.map { pair in
        let b = voiceISpecs.first { $0.id == pair.base }!
        return ParameterSpec(id: pair.v2, identifier: "v2_" + b.identifier, name: "Voice II " + b.name,
                             min: b.min, max: b.max, defaultValue: b.defaultValue, unit: b.unit,
                             valueStrings: b.valueStrings)
    }

    private static let mixSpecs: [ParameterSpec] = [
        // 1 (top of the fader) = Voice I only, 0 (bottom) = Voice II only.
        ParameterSpec(id: .mix, identifier: "mix", name: "Mix (Voice II to Voice I)",
                      min: 0, max: 1, defaultValue: 1, unit: .generic),
        ParameterSpec(id: .mixResonance, identifier: "mixResonance", name: "Resonance",
                      min: 0, max: 1, defaultValue: 0, unit: .generic),
        // Bipolar: 0.5 = no shift; the full fader moves every voice's cutoff by SynthSettings-style
        // +/- 0.5 fader units (about +/- 5 octaves).
        ParameterSpec(id: .brilliance, identifier: "brilliance", name: "Brilliance",
                      min: 0, max: 1, defaultValue: 0.5, unit: .generic)
    ]

    static let specs: [ParameterSpec] = voiceISpecs + voiceIISpecs + mixSpecs

    private static let voiceISpecs: [ParameterSpec] = [
        ParameterSpec(id: .masterVolume, identifier: "masterVolume", name: "Master Volume",
                      min: 0, max: 1, defaultValue: 0.5, unit: .linearGain),
        ParameterSpec(id: .tubeEnabled, identifier: "tubeEnabled", name: "Tube",
                      min: 0, max: 1, defaultValue: 1, unit: .boolean),
        ParameterSpec(id: .tubeType, identifier: "tubeType", name: "Tube Type",
                      min: 0, max: 2, defaultValue: 0, unit: .indexed,
                      valueStrings: tubeNames),
        ParameterSpec(id: .drive, identifier: "drive", name: "Gain",
                      min: -12, max: 36, defaultValue: 6, unit: .decibels),
        ParameterSpec(id: .bias, identifier: "bias", name: "Bias",
                      min: -1, max: 1, defaultValue: 0, unit: .generic),
        ParameterSpec(id: .output, identifier: "output", name: "Output",
                      min: -24, max: 12, defaultValue: 0, unit: .decibels),
        ParameterSpec(id: .oversampling, identifier: "oversampling", name: "Oversampling",
                      min: 0, max: 2, defaultValue: 2, unit: .indexed,
                      valueStrings: oversamplingNames),
        // VCO
        ParameterSpec(id: .waveform, identifier: "waveform", name: "Waveform",
                      min: 0, max: 4, defaultValue: 1, unit: .indexed,
                      valueStrings: waveformNames),
        ParameterSpec(id: .speed, identifier: "speed", name: "PWM Speed",
                      min: 0, max: 1, defaultValue: 0.35, unit: .generic),
        ParameterSpec(id: .pwm, identifier: "pwm", name: "PWM Depth",
                      min: 0, max: 1, defaultValue: 0, unit: .generic),
        ParameterSpec(id: .pulseWidth, identifier: "pulseWidth", name: "Pulse Width",
                      min: 0.05, max: 0.95, defaultValue: 0.5, unit: .generic),
        ParameterSpec(id: .noise, identifier: "noise", name: "Noise",
                      min: 0, max: 1, defaultValue: 0, unit: .generic),
        ParameterSpec(id: .sync, identifier: "sync", name: "Sync",
                      min: 0, max: 1, defaultValue: 0, unit: .boolean),
        // VCF
        ParameterSpec(id: .lpfCutoff, identifier: "lpfCutoff", name: "LPF Cutoff",
                      min: 0, max: 1, defaultValue: 1, unit: .generic),
        ParameterSpec(id: .lpfResonance, identifier: "lpfResonance", name: "LPF Resonance",
                      min: 0, max: 1, defaultValue: 0, unit: .generic),
        // Amplifier ADSR. Time faders map 1 ms ... 10 s (exponential), see
        // EnvelopeSettings.seconds(forFader:). Defaults reproduce the M4 fade.
        ParameterSpec(id: .ampAttack, identifier: "ampAttack", name: "Amp Attack",
                      min: 0, max: 1, defaultValue: 0.314, unit: .generic),
        ParameterSpec(id: .ampDecay, identifier: "ampDecay", name: "Amp Decay",
                      min: 0, max: 1, defaultValue: 0.6, unit: .generic),
        ParameterSpec(id: .ampSustain, identifier: "ampSustain", name: "Amp Sustain",
                      min: 0, max: 1, defaultValue: 1, unit: .generic),
        ParameterSpec(id: .ampRelease, identifier: "ampRelease", name: "Amp Release",
                      min: 0, max: 1, defaultValue: 0.635, unit: .generic),
        // VCF envelope (CS-80): IL / AL are OFFSETS from the cutoff fader, in fader units
        // (-1...+1, about 10 octaves per 1.0). 0 = no effect. The sustain is the cutoff.
        ParameterSpec(id: .vcfInitialLevel, identifier: "vcfInitialLevel", name: "VCF Initial Level",
                      min: -1, max: 1, defaultValue: 0, unit: .generic),
        ParameterSpec(id: .vcfAttackLevel, identifier: "vcfAttackLevel", name: "VCF Attack Level",
                      min: -1, max: 1, defaultValue: 0, unit: .generic),
        ParameterSpec(id: .vcfAttack, identifier: "vcfAttack", name: "VCF Attack",
                      min: 0, max: 1, defaultValue: 0.55, unit: .generic),
        ParameterSpec(id: .vcfDecay, identifier: "vcfDecay", name: "VCF Decay",
                      min: 0, max: 1, defaultValue: 0.65, unit: .generic),
        ParameterSpec(id: .vcfRelease, identifier: "vcfRelease", name: "VCF Release",
                      min: 0, max: 1, defaultValue: 0.6, unit: .generic)
    ]

    static func makeParameterTree() -> AUParameterTree {
        let parameters: [AUParameter] = specs.map { spec in
            let p = AUParameterTree.createParameter(
                withIdentifier: spec.identifier,
                name: spec.name,
                address: spec.id.rawValue,
                min: spec.min,
                max: spec.max,
                unit: spec.unit,
                unitName: nil,
                flags: [.flag_IsReadable, .flag_IsWritable],
                valueStrings: spec.valueStrings,
                dependentParameters: nil)
            p.value = spec.defaultValue
            return p
        }
        return AUParameterTree.createTree(withChildren: parameters)
    }
}
