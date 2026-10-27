// PentoniqVFD.swift  (milestone 17: VFD display)
// Add to the EXTENSION target only.
//
// A 32-character, fixed-width display in the style of a synthesizer's vacuum fluorescent display.
// It sits in the TONE SELECTOR section but is an independent element: it has its own model
// (`VFDDisplayModel`, owned by the view model) and knows nothing about presets.
//
// Showing a message:   model.vfd.show("SOME TEXT")           scrolls in from the right
//                      model.vfd.show("SOME TEXT", scroll: false)   appears at once
// Text is centred in the 32 slots (longer text is cut off). A scroll pushes the old message out to the
// left while the new one comes in from the right; the whole move takes `VFDDisplayModel.scrollSeconds`.
//
// Each of the 32 slots is drawn on its own, so later each one can become a 16 x 8 LED character
// without changing the model.

// PentoniqVFD.swift  (milestone 17: VFD display)
// Add to the EXTENSION target only.
//
// A 32-character, fixed-width display in the style of a synthesizer's vacuum fluorescent display.
// It sits in the TONE SELECTOR section but is an independent element: it has its own model
// (`VFDDisplayModel`, owned by the view model) and knows nothing about presets.
//
// Showing a message:   model.vfd.show("SOME TEXT")           scrolls in from the right
//                      model.vfd.show("SOME TEXT", scroll: false)   appears at once
// Text is centred in the 32 slots (longer text is cut off). A scroll pushes the old message out to the
// left while the new one comes in from the right; the whole move takes `VFDDisplayModel.scrollSeconds`.
//
// Clicking the display shows the credit line for `creditSeconds`, then scrolls back to the resting text.
//
// Each of the 32 slots is drawn on its own, so later each one can become a 16 x 8 LED character
// without changing the model.

import SwiftUI
import Combine

// MARK: - Model

final class VFDDisplayModel: ObservableObject {

    static let columns = 32

    /// How long a scrolling message takes to travel across the display, in seconds.
    static let scrollSeconds: Double = 0.7

    /// What the display says when the panel first appears.
    static let introText = "PENTONIQ"

    /// Shown when the display is clicked (exactly 32 characters).
    static let creditText = "Crafted with Love by John Penner"

    /// How long the credit stays on show once it has scrolled in, in seconds.
    static let creditSeconds: Double = 4.0

    /// The 32 characters on show right now.
    @Published private(set) var slots: [Character] = Array(repeating: " ", count: VFDDisplayModel.columns)

    private var scrollTask: Task<Void, Never>?
    private var revertTask: Task<Void, Never>?
    private var introduced = false

    /// The text the display goes back to after the credit. Later this can follow the patch name.
    private var restingText = VFDDisplayModel.introText

    /// Called when the display appears. Scrolls the intro text in, once per panel.
    func introduceIfNeeded() {
        guard !introduced else { return }
        introduced = true
        show(VFDDisplayModel.introText)
    }

    /// Called when the display is clicked: the credit scrolls in, stays for `creditSeconds`,
    /// then the resting text scrolls back in. Clicking again restarts the 4 seconds.
    func showCredit() {
        revertTask?.cancel()
        show(VFDDisplayModel.creditText)
        let wait = VFDDisplayModel.scrollSeconds + VFDDisplayModel.creditSeconds
        revertTask = Task { @MainActor [weak self] in
            try? await Task.sleep(until: .now + .seconds(wait), clock: .continuous)
            if Task.isCancelled { return }
            guard let self else { return }
            self.show(self.restingText)
            self.revertTask = nil
        }
    }

    /// `text` centred in the 32 slots, scrolling in from the right (or at once with `scroll: false`).
    /// Calling this mid-scroll starts the new scroll from whatever is on show.
    func show(_ text: String, scroll: Bool = true) {
        let target = VFDDisplayModel.centred(text)
        scrollTask?.cancel()
        scrollTask = nil
        guard scroll else {
            slots = target
            return
        }

        // A 64-slot strip: what is showing, then the new message. The 32-slot window slides across it.
        let strip = slots + target
        let columns = VFDDisplayModel.columns
        let start = ContinuousClock.now
        let step = Duration.seconds(VFDDisplayModel.scrollSeconds / Double(columns))
        scrollTask = Task { @MainActor [weak self] in
            for offset in 1...columns {
                try? await Task.sleep(until: start + step * offset, clock: .continuous)
                if Task.isCancelled { return }
                self?.slots = Array(strip[offset..<(offset + columns)])
            }
        }
    }

    /// The text padded with spaces to exactly 32 slots, centred (an odd leftover space goes on the right).
    static func centred(_ text: String) -> [Character] {
        let chars = Array(text.prefix(columns))
        let left = (columns - chars.count) / 2
        let right = columns - chars.count - left
        return Array(repeating: " ", count: left) + chars + Array(repeating: " ", count: right)
    }
}

// MARK: - View

struct VFDDisplay: View {
    @ObservedObject var model: VFDDisplayModel

    /// Full width of the TONE SELECTOR section's contents, and 32 points high.
    static let width: CGFloat = 456
    static let height: CGFloat = 32

    private static let inset: CGFloat = 6
    /// Width of one character slot.
    private static let cell: CGFloat = (VFDDisplay.width - 2 * VFDDisplay.inset) / CGFloat(VFDDisplayModel.columns)
    /// Menlo's characters are 0.602 of the font size wide, so this is the largest size that fits
    /// 32 slots across the display (about 23 pt: a 32 pt font would need 620 pt of width).
    private static let fontSize: CGFloat = (VFDDisplay.cell / 0.602).rounded(.down)

    // These two colours were looked up, not linked: the dark blue of the container behind the modules
    // (RGB 0, 10, 25) and the bright blue of the lit WHEEL button. Changing the panel colours does not
    // change the display.
    private static let glass = Color(red: 0.0, green: 10.0 / 255.0, blue: 25.0 / 255.0)
    private static let glow = Color(red: 0.30, green: 0.58, blue: 1.0)

    var body: some View {
        HStack(spacing: 0) {
            ForEach(0..<VFDDisplayModel.columns, id: \.self) { index in
                Text(String(model.slots[index]))
                    .font(.custom("Menlo-Bold", size: VFDDisplay.fontSize))   // Menlo is on macOS and iOS
                    .foregroundStyle(VFDDisplay.glow)
                    .frame(width: VFDDisplay.cell, height: VFDDisplay.height)
            }
        }
        .shadow(color: VFDDisplay.glow.opacity(0.85), radius: 4)
        .frame(width: VFDDisplay.width, height: VFDDisplay.height)
        .background(RoundedRectangle(cornerRadius: 5).fill(VFDDisplay.glass))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.black.opacity(0.6), lineWidth: 1))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(VFDDisplay.glow.opacity(0.18), lineWidth: 0.5))
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .contentShape(RoundedRectangle(cornerRadius: 5))
        .onTapGesture { model.showCredit() }
        .onAppear { model.introduceIfNeeded() }
    }
}
