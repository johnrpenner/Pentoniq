//
//  AudioUnitHostModel.swift
//  Pentoniq
//
//  Created by John Penner on 2026-10-15.
//

import SwiftUI
import Combine
import CoreMIDI
import AudioToolbox
import AVFAudio

@MainActor
class AudioUnitHostModel: ObservableObject {
    /// The playback engine used to play audio.
    private let playEngine = SimplePlayEngine()

    /// The model providing information about the current Audio Unit
    @Published var viewModel = AudioUnitViewModel()

    /// Mirrors the play engine so SwiftUI redraws when playback starts or stops.
    @Published private(set) var isPlaying = false
    private var engineObservation: AnyCancellable?
    
    @Published var audioUnitCrashed = false

    /// Audio Component Description
    let type: String
    let subType: String
    let manufacturer: String

    let wantsAudio: Bool
    let wantsMIDI: Bool
    let isFreeRunning: Bool

    let auValString: String
    
    private let instanceInvalidationNotifcation = Notification.Name(String(kAudioComponentInstanceInvalidationNotification))

    @Published var validationResult: AudioComponentValidationResult?
    @Published var currentValidationData: String?
    
    init(type: String = "aumu", subType: String = "TbSy", manufacturer: String = "iDoc") {
        self.type = type
        self.subType = subType
        self.manufacturer = manufacturer
        let wantsAudio = type.fourCharCode == kAudioUnitType_MusicEffect || type.fourCharCode == kAudioUnitType_Effect
        self.wantsAudio = wantsAudio

        let wantsMIDI = type.fourCharCode == kAudioUnitType_MIDIProcessor ||
        type.fourCharCode == kAudioUnitType_MusicDevice ||
        type.fourCharCode == kAudioUnitType_MusicEffect
        self.wantsMIDI = wantsMIDI

        let isFreeRunning = type.fourCharCode == kAudioUnitType_MIDIProcessor ||
        type.fourCharCode == kAudioUnitType_MusicDevice ||
        type.fourCharCode == kAudioUnitType_Generator
        self.isFreeRunning = isFreeRunning

        auValString = "\(type) \(subType) \(manufacturer)"

        engineObservation = playEngine.$isPlaying
            .receive(on: DispatchQueue.main)
            .sink { [weak self] playing in self?.isPlaying = playing }

        setupNotifications()
        loadAudioUnit()
    }

    private func loadAudioUnit() {
        Task {
            let viewController = await playEngine.initComponent(type: type, subType: subType, manufacturer: manufacturer)

            if let audioUnit = playEngine.avAudioUnit {
                Task { @MainActor in
                    let (validationResult, validationData) = await validateAU(audioUnit: audioUnit)
                    self.validationResult = validationResult
                    self.currentValidationData = validationData
                }
            }
                self.viewModel = AudioUnitViewModel(showAudioControls: self.wantsAudio,
                                                    showMIDIContols: self.wantsMIDI,
                                                    title: self.auValString,
                                                    message: "Successfully loaded (\(self.auValString))",
                                                    viewController: viewController)
                
                if self.isFreeRunning {
                    self.playEngine.startPlaying()
            }
        }
    }
    
    private func setupNotifications() {
        let notificationName = Notification.Name(instanceInvalidationNotifcation.rawValue)
        NotificationCenter.default.addObserver(forName: notificationName, object: nil, queue: nil) { [weak self] notification in
            guard let self = self else { return }
            if let _ = notification.object as? AUAudioUnit {
                Task { @MainActor in
                    self.audioUnitCrashed = true
                }
            }
        }
    }
    
    private func validateAU(audioUnit: AVAudioUnit) async -> (AudioComponentValidationResult, String) {
        await withCheckedContinuation { continuation in
            let validationParameters: [String: Any] = ["ForceValidation": true]

            AudioComponentValidateWithResults(audioUnit.auAudioUnit.component, validationParameters as CFDictionary) { @Sendable result, output in
                let formattedOutput: String

                if let validationDict = output as? [String: Any],
                   let rawOutput = validationDict["Output"] as? [String] {
                    formattedOutput = rawOutput.joined(separator: "\n")
                } else {
                    formattedOutput = "Validation probably crashed"
                }

                print(formattedOutput)
                
                continuation.resume(returning: (result, formattedOutput))
            }
        }
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self, name: instanceInvalidationNotifcation, object: nil)
    }

    func startPlaying() {
        playEngine.startPlaying()
    }

    func stopPlaying() {
        playEngine.stopPlaying()
    }
}
