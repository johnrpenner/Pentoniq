//
//  SimplePlayEngine.swift
//  Pentoniq
//
//  Created by John Penner on 2026-10-15.
//
//  Milestone 99: the fatalError calls are gone. If something cannot be set up (the sound file, Core MIDI,
//  the audio unit itself, the audio engine) the host app now carries on and shows a message instead of
//  crashing, which matters for App Store review. Everything else is unchanged.

import Foundation
import Combine
import CoreAudioKit
import AVFoundation
@preconcurrency import AVFAudio

#if os(iOS) || os(visionOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Wraps and Audio Unit extension and provides helper functions.
extension AVAudioUnit {

    var wantsAudioInput: Bool {
        let componentType = self.auAudioUnit.componentDescription.componentType
        return componentType == kAudioUnitType_MusicEffect || componentType == kAudioUnitType_Effect
    }
    
    static fileprivate func findComponent(type: String, subType: String, manufacturer: String) -> AVAudioUnitComponent? {
        // Make a component description matching any Audio Unit of the selected component type.
        let description = AudioComponentDescription(componentType: type.fourCharCode!,
                                                    componentSubType: subType.fourCharCode!,
                                                    componentManufacturer: manufacturer.fourCharCode!,
                                                    componentFlags: 0,
                                                    componentFlagsMask: 0)
        return AVAudioUnitComponentManager.shared().components(matching: description).first
    }
    
    fileprivate func loadAudioUnitViewController() async -> ViewController? {
        let viewController = await auAudioUnit.requestViewController()

        if #available(macOS 13.0, iOS 16.0, *) {
            if viewController == nil {
                let genericViewController = await AUGenericViewController()
                await MainActor.run {
                    genericViewController.auAudioUnit = self.auAudioUnit
                }
                return genericViewController
            }
        }

        return viewController
    }
}

/// Manages the interaction with the AudioToolbox and AVFoundation frameworks.
@MainActor
public class SimplePlayEngine: ObservableObject {
    
    @Published var avAudioUnit: AVAudioUnit?
    
    // Synchronizes starting/stopping the engine and scheduling file segments.
    private let stateChangeQueue = DispatchQueue(label: "com.example.apple-samplecode.StateChangeQueue")
    
    // Playback engine.
    private let engine = AVAudioEngine()
    
    // Engine's player node.
    private let player = AVAudioPlayerNode()
    
    // File to play (only used to test effects; Pentoniq is an instrument, so it may be nil).
    private var file: AVAudioFile?
    
    // Whether we are playing.
    @Published private(set) var isPlaying = false
    
    // This block will be called every render cycle and will receive MIDI events
    private let midiOutBlock: AUMIDIOutputEventBlock = { sampleTime, cable, length, data in return noErr }
    
    // This block can be used to send MIDI UMP events to the Audio Unit
    var scheduleMIDIEventListBlock: AUMIDIEventListBlock? = nil
    
    // MARK: Initialization
    
    public init() {
        engine.attach(player)
        
        // The sound file is only needed to try out effects. Without it the host still runs.
        if let fileURL = Bundle.main.url(forResource: "Synth", withExtension: "aif") {
            setPlayerFile(fileURL)
        } else {
            print("Pentoniq host: Synth.aif not found; effect testing is off.")
        }
        
        engine.prepare()
        setupMIDI()
    }
    
    private func setupMIDI() {
        let ready = MIDIManager.shared.setupPort(midiProtocol: MIDIProtocolID._2_0, receiveBlock: { [weak self] eventList, _ in
            if let scheduleMIDIEventListBlock = self?.scheduleMIDIEventListBlock {
                _ = scheduleMIDIEventListBlock(AUEventSampleTimeImmediate, 0, eventList)
            }
        })
        if !ready {
            print("Pentoniq host: Core MIDI could not be set up; MIDI input to the host is off.")
        }
    }
    
    func initComponent(type: String, subType: String, manufacturer: String) async -> ViewController? {
        // Reset the engine to remove any configured audio units.
        reset()
        
        guard let component = AVAudioUnit.findComponent(type: type, subType: subType, manufacturer: manufacturer) else {
            print("Pentoniq host: could not find the audio unit (\(type) \(subType) \(manufacturer)).")
            return nil
        }
        
        // Instantiate the audio unit.
        do {
            let audioUnit = try await AVAudioUnit.instantiate(
                with: component.audioComponentDescription, options: AudioComponentInstantiationOptions.loadOutOfProcess)
            
            self.avAudioUnit = audioUnit
            
            self.connect(avAudioUnit: audioUnit)
            
            return await audioUnit.loadAudioUnitViewController()
        } catch {
            print("Pentoniq host: could not instantiate the audio unit: \(error)")
            return nil
        }
    }
    
    private func setPlayerFile(_ fileURL: URL) {
        do {
            let file = try AVAudioFile(forReading: fileURL)
            self.file = file
            engine.connect(player, to: engine.mainMixerNode, format: file.processingFormat)
        } catch {
            print("Pentoniq host: could not open the sound file: \(error)")
        }
    }
    
    private func setSessionActive(_ active: Bool) {
#if os(iOS) || os(visionOS)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default)
            try session.setActive(active)
        } catch {
            print("Pentoniq host: could not set the audio session active (\(active)): \(error)")
        }
#endif
    }
    
    // MARK: Playback State
    
    public func startPlaying() {
        stateChangeQueue.sync {
            if !self.isPlaying { self.startPlayingInternal() }
        }
    }
    
    public func stopPlaying() {
        stateChangeQueue.sync {
            if self.isPlaying { self.stopPlayingInternal() }
        }
    }
    
    public func togglePlay() -> Bool {
        if isPlaying {
            stopPlaying()
        } else {
            startPlaying()
        }
        return isPlaying
    }
    
    private func startPlayingInternal() {
        guard let avAudioUnit = self.avAudioUnit else {
            return
        }
        
        // assumptions: we are protected by stateChangeQueue. we are not playing.
        setSessionActive(true)
        
        if avAudioUnit.wantsAudioInput {
            // Schedule buffers on the player.
            scheduleEffectLoop()
        }
        
        let hardwareFormat = engine.outputNode.outputFormat(forBus: 0)
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: hardwareFormat)
        
        // Start the engine.
        do {
            try engine.start()
        } catch {
            print("Pentoniq host: could not start the audio engine: \(error)")
            isPlaying = false
            setSessionActive(false)
            return
        }
        
        if avAudioUnit.wantsAudioInput {
            // Start the player.
            player.play()
        }
        
        isPlaying = true
    }
    
    private func stopPlayingInternal() {
        guard let avAudioUnit = self.avAudioUnit else {
            return
        }
        
        if avAudioUnit.wantsAudioInput {
            player.stop()
        }
        engine.stop()
        isPlaying = false
        setSessionActive(false)
    }
    
    private func scheduleEffectLoop() {
        // No sound file: nothing to loop (only effects need it).
        guard let file = file else { return }
        
        Task {
            await player.scheduleFile(file, at: nil)
            if self.isPlaying {
                self.scheduleEffectLoop()
            }
        }
    }
    
    private func resetAudioLoop() {
        guard let avAudioUnit = self.avAudioUnit else {
            return
        }
        
        if avAudioUnit.wantsAudioInput {
            // Connect player -> mixer.
            guard let format = file?.processingFormat else { return }
            engine.connect(player, to: engine.mainMixerNode, format: format)
        }
    }
    
    public func reset() {
        connect(avAudioUnit: nil)
    }
    
    public func connect(avAudioUnit: AVAudioUnit?, completion: @escaping (() -> Void) = {}) {
        guard let avAudioUnit = self.avAudioUnit else {
            return
        }
        
        // Break the audio unit -> mixer connection
        engine.disconnectNodeInput(engine.mainMixerNode)
        
        resetAudioLoop()
        
        // We're done with the unit; release all references.
        engine.detach(avAudioUnit)
        
        // Internal function to resume playing and call the completion handler.
        func rewiringComplete() {
            scheduleMIDIEventListBlock = auAudioUnit.scheduleMIDIEventListBlock
            if isPlaying {
                player.play()
            }
            completion()
        }
        
        let hardwareFormat = engine.outputNode.outputFormat(forBus: 0)
        
        // Connect the main mixer -> output node
        engine.connect(engine.mainMixerNode, to: engine.outputNode, format: hardwareFormat)
        
        // Pause the player before re-wiring it. It is not simple to keep it playing across an insertion or deletion.
        if isPlaying {
            player.pause()
        }
        
        let auAudioUnit = avAudioUnit.auAudioUnit
        
        if !auAudioUnit.midiOutputNames.isEmpty {
            auAudioUnit.midiOutputEventBlock = midiOutBlock
        }
        
        // Attach the AVAudioUnit the graph.
        engine.attach(avAudioUnit)
        
        if avAudioUnit.wantsAudioInput {
            // Disconnect the player -> mixer.
            engine.disconnectNodeInput(engine.mainMixerNode)
            
            // Connect the player -> effect -> mixer.
            if let format = file?.processingFormat {
                engine.connect(player, to: avAudioUnit, format: format)
                engine.connect(avAudioUnit, to: engine.mainMixerNode, format: format)
            }
        } else {
            let stereoFormat = AVAudioFormat(standardFormatWithSampleRate: hardwareFormat.sampleRate, channels: 2)
            engine.connect(avAudioUnit, to: engine.mainMixerNode, format: stereoFormat)
        }
        rewiringComplete()
    }
}
