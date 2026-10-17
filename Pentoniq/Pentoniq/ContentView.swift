//
//  ContentView.swift
//  Pentoniq
//
//  Created by John Penner on 2026-10-15.
//
//  Host app container. The synth panel gets the whole window: the AU view fills the
//  space and scales itself to fit (see PentoniqView). The title line, the validation
//  banner and the "MIDI Input: Enabled" line are commented out below so they use no
//  room. They are kept in case they are needed again.

import AudioToolbox
import Combine
import SwiftUI

struct ContentView: View {
    @ObservedObject var hostModel: AudioUnitHostModel
    @State private var isSheetPresented = false   // used by ValidationView in the crash branch

    var body: some View {
        VStack(spacing: 0) {
            if hostModel.audioUnitCrashed {
                // Only ever shown if the audio unit crashes, so it is worth the room.
                VStack {
                    HStack(spacing: 2) {
                        Text("(\(hostModel.viewModel.title))")
                            .textSelection(.enabled)
                        Text("crashed!")
                    }
                    ValidationView(hostModel: hostModel, isSheetPresented: $isSheetPresented)
                }
                .padding(20)
            } else if let viewController = hostModel.viewModel.viewController {
                /* Title and validation banner, commented out to save room:
                Text("\(hostModel.viewModel.title)")
                    .textSelection(.enabled)
                    .bold()
                ValidationView(hostModel: hostModel, isSheetPresented: $isSheetPresented)
                */
                // The AU view takes all the space it is offered and scales its panel to fit.
                AUViewControllerUI(viewController: viewController)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text(hostModel.viewModel.message)
                    .frame(minWidth: 400, minHeight: 200)
            }

            if hostModel.viewModel.showAudioControls {
                Text("Audio Playback")
                Button {
                    hostModel.isPlaying ? hostModel.stopPlaying() : hostModel.startPlaying()

                } label: {
                    Text(hostModel.isPlaying ? "Stop" : "Play")
                }
            }

            /* "MIDI Input: Enabled", commented out to save room:
            if hostModel.viewModel.showMIDIContols {
                Text("MIDI Input: Enabled")
            }
            */
        }
        .frame(minWidth: 680, idealWidth: 1500, maxWidth: .infinity,
               minHeight: 200, idealHeight: 700, maxHeight: .infinity)
    }
}

/* The #Preview macro needs macOS 14, so it is commented out for the macOS 13.5 target.
#Preview {
    ContentView(hostModel: AudioUnitHostModel())
}
*/
