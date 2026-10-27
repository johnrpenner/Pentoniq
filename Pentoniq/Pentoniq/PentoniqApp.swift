//
//  PentoniqApp.swift
//  Pentoniq
//
//  Created by John Penner on 2026-10-15.
//

import SwiftUI

@main
struct PentoniqApp: App {
    @StateObject private var hostModel = AudioUnitHostModel()

    var body: some Scene {
        WindowGroup {
            ContentView(hostModel: hostModel)
        }
        // Starts large enough for a 1080p display; the window can be resized freely
        // and the synth panel scales to fit it.
        .defaultSize(width: 1500, height: 900)
        .windowResizability(.contentMinSize)   // window may grow without limit (macOS 13+)
    }
}
