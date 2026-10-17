// PentoniqAudioUnit.swift
// The AUAudioUnit subclass: owns the bus layout, the parameter tree and the
// render block. All DSP lives in PentoniqKernel.

import AudioToolbox
import AVFoundation

public final class PentoniqAudioUnit: AUAudioUnit {

    private let kernel: PentoniqKernel
    private let outputBus: AUAudioUnitBus
    private var outputBusArray: AUAudioUnitBusArray!
    private let kernelRenderBlock: AUInternalRenderBlock

    public override init(componentDescription: AudioComponentDescription,
                         options: AudioComponentInstantiationOptions = []) throws {

        let kernel = PentoniqKernel()

        guard let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2) else {
            throw NSError(domain: NSOSStatusErrorDomain,
                          code: Int(kAudioUnitErr_FormatNotSupported))
        }
        let bus = try AUAudioUnitBus(format: format)
        bus.supportedChannelCounts = [2]

        self.kernel = kernel
        self.outputBus = bus

        // The block captures only the kernel (never self) so the audio thread
        // does no property lookups on the AU object.
        self.kernelRenderBlock = { _, timestamp, frameCount, _, outputData, realtimeEventListHead, _ in
            kernel.render(frameCount: Int(frameCount),
                          sampleTimeBase: Int64(timestamp.pointee.mSampleTime),
                          output: outputData,
                          events: realtimeEventListHead)
            return noErr
        }

        try super.init(componentDescription: componentDescription, options: options)

        outputBusArray = AUAudioUnitBusArray(audioUnit: self,
                                             busType: .output,
                                             busses: [bus])

        let tree = PentoniqParameters.makeParameterTree()
        tree.implementorValueObserver = { [kernel] parameter, value in
            kernel.setParameter(address: parameter.address, value: value)
        }
        tree.implementorValueProvider = { [kernel] parameter in
            kernel.parameter(address: parameter.address)
        }
        parameterTree = tree
    }

    /// Counts every MIDI event received (bumped on the audio thread). The UI polls it for the MIDI lamp.
    public var midiActivityCount: UInt32 { kernel.midiActivity }

    /// Oscilloscope tap, read by the UI.
    var scopeTap: ScopeTap { kernel.scope }

    // MARK: - AUAudioUnit overrides

    public override var outputBusses: AUAudioUnitBusArray { outputBusArray }

    public override var internalRenderBlock: AUInternalRenderBlock { kernelRenderBlock }

    /// No inputs, stereo output.
    public override var channelCapabilities: [NSNumber]? { [0, 2] }

    public override func allocateRenderResources() throws {
        try super.allocateRenderResources()
        kernel.setSampleRate(outputBus.format.sampleRate)
    }

    public override func deallocateRenderResources() {
        kernel.reset()
        super.deallocateRenderResources()
    }
}
