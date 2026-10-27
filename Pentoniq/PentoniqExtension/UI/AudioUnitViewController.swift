// AudioUnitViewController.swift
// Principal class of the extension: creates the audio unit and hosts the
// SwiftUI view. The host may load the view before or after the AU exists,
// so both paths call connectViewIfPossible().
//
// The class name must stay "AudioUnitViewController": the extension's
// Info.plist (NSExtensionPrincipalClass) refers to it by that name.

import CoreAudioKit
import AudioToolbox
import SwiftUI

public final class AudioUnitViewController: AUViewController, AUAudioUnitFactory {

    private var audioUnit: PentoniqAudioUnit? {
        didSet {
            DispatchQueue.main.async { [weak self] in
                self?.connectViewIfPossible()
            }
        }
    }

    private var hostingView: NSHostingView<PentoniqView>?

    public override func loadView() {
        let root = NSView(frame: NSRect(origin: .zero, size: PentoniqView.initialSize))
        root.autoresizingMask = [.width, .height]
        view = root
    }
    
    public override func viewDidLoad() {
        super.viewDidLoad()
        preferredContentSize = PentoniqView.initialSize
        connectViewIfPossible()
    }

    // AUAudioUnitFactory
    public func createAudioUnit(with componentDescription: AudioComponentDescription) throws -> AUAudioUnit {
        let unit = try PentoniqAudioUnit(componentDescription: componentDescription, options: [])
        audioUnit = unit
        return unit
    }
    
    private func connectViewIfPossible() {
        guard isViewLoaded,
              hostingView == nil,
              let unit = audioUnit,
              let tree = unit.parameterTree else { return }

        let hosting = NSHostingView(rootView: PentoniqView(
            parameterTree: tree,
            midiActivity: { [weak unit] in unit?.midiActivityCount ?? 0 },
            scope: unit.scopeTap,
            midiLearn: unit.midiLearnLink,
            keyboard: unit.keyboardLink))
        // Don't let the SwiftUI content dictate the size; the host's window does.
        if #available(macOS 13.0, *) { hosting.sizingOptions = [] }
        hosting.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: view.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        hostingView = hosting
    }
}
