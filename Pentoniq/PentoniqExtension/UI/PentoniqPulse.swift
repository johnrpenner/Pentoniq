//
//  PentoniqPulse.swift
//  Pentoniq
//
//  macOS Audio Unit version of the Minuet Calc PulseLayer ("raindrop" pulse).
//  Add to the EXTENSION target.
//
//  Same recipe as the iOS original: two concentric rings per event, a thick fainter one that starts at
//  once and a thin brighter one a moment later, both expanding while they fade. The iOS code was
//  already pure SwiftUI (TimelineView + Canvas), so nothing platform specific had to change. What
//  changed is the setting:
//    - rings are centred in their own square canvas instead of at a key's position on a big board,
//    - sizes are multiples of the KNOB's diameter (a 48 pt WHEEL) instead of a key's,
//    - the colour is the panel's blue, and the glow is smaller to suit a small knob,
//    - the layer is drawn BEHIND the knob, and never takes clicks.
//

import SwiftUI

// MARK: - Tunable style constants

/// Timing and weight for one ring.
struct PulseRingSpec {
    let lineWidth: CGFloat      // thick / thin
    let alpha: Double           // starting opacity
    let delay: Double           // seconds before the ring appears
    let scaleDuration: Double   // seconds spent expanding
    let fadeDuration: Double    // seconds spent fading out (starts with the ring)

    var totalDuration: Double { delay + fadeDuration }

    /// Size multiplier and opacity `elapsed` seconds after the event, or nil before the ring
    /// starts or after it has finished.
    func state(at elapsed: Double) -> (scale: CGFloat, alpha: Double)? {
        let t = elapsed - delay
        guard t >= 0, t < fadeDuration else { return nil }
        let progress = min(t / scaleDuration, 1.0)
        let scale = PentoniqPulse.startScale
            + (PentoniqPulse.endScale - PentoniqPulse.startScale) * CGFloat(progress)
        let a = alpha * (1.0 - t / fadeDuration)
        return (scale, a)
    }
}

enum PentoniqPulse {
    /// The panel's blue (same as the WHEEL button).
    static let color = Panel.blue

    /// Ring OUTER diameters as multiples of the knob's own diameter (1.0).
    static let startScale: CGFloat = 0.95
    static let endScale: CGFloat = 1.7

    /// Soft glow around each ring (0 = none).
    static let glowRadius: CGFloat = 12

    /// Side of the square canvas the rings are drawn in. Big enough for the largest ring plus glow.
    static let canvasSide: CGFloat = 150

    /// Safety cap for a very busy wheel.
    static let maxActive = 8

    static let thick = PulseRingSpec(lineWidth: 8, alpha: 0.45, delay: 0.0,
                                     scaleDuration: 0.25, fadeDuration: 0.60)
    static let thin = PulseRingSpec(lineWidth: 2.5, alpha: 0.75, delay: 0.05,
                                    scaleDuration: 0.20, fadeDuration: 0.50)

    /// How long a pulse stays in the layer before it is removed.
    static var lifetime: Double { max(thick.totalDuration, thin.totalDuration) + 0.1 }
}

// MARK: - Model

/// One event's pulse: when it started (rings are drawn from the time elapsed since then).
struct KnobPulse: Identifiable {
    let id = UUID()
    let startDate = Date()
}

// MARK: - Layer

/// Draws every active pulse, centred in its frame. Use it as a `.background` of the knob, with a
/// frame of `PentoniqPulse.canvasSide`, so the rings appear behind the knob.
struct PulseLayerView: View {
    let pulses: [KnobPulse]
    let knobDiameter: CGFloat

    var body: some View {
        TimelineView(.animation(paused: pulses.isEmpty)) { timeline in
            Canvas { context, size in
                let centre = CGPoint(x: size.width / 2, y: size.height / 2)
                for pulse in pulses {
                    let elapsed = timeline.date.timeIntervalSince(pulse.startDate)
                    drawRing(centre: centre, spec: PentoniqPulse.thick, elapsed: elapsed, in: &context)
                    drawRing(centre: centre, spec: PentoniqPulse.thin, elapsed: elapsed, in: &context)
                }
            }
        }
        .frame(width: PentoniqPulse.canvasSide, height: PentoniqPulse.canvasSide)
        .allowsHitTesting(false)
    }

    private func drawRing(centre: CGPoint, spec: PulseRingSpec, elapsed: Double,
                          in context: inout GraphicsContext) {
        guard let state = spec.state(at: elapsed) else { return }

        // Outer diameter = knob diameter x scale. The stroke is drawn inside that edge, so the
        // ring never exceeds its target size.
        let diameter = knobDiameter * state.scale
        let outer = CGRect(x: centre.x - diameter / 2, y: centre.y - diameter / 2,
                           width: diameter, height: diameter)
        let path = Path(ellipseIn: outer.insetBy(dx: spec.lineWidth / 2, dy: spec.lineWidth / 2))

        context.drawLayer { layer in
            layer.addFilter(.shadow(color: PentoniqPulse.color.opacity(0.6 * state.alpha),
                                    radius: PentoniqPulse.glowRadius))
            layer.stroke(path,
                         with: .color(PentoniqPulse.color.opacity(state.alpha)),
                         lineWidth: spec.lineWidth)
        }
    }
}
