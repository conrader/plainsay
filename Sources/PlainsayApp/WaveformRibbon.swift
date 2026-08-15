import SwiftUI

/// The signature element: a ribbon that writes itself left to right as you
/// speak, older bars fading out, so the HUD shows the shape of the sentence
/// rather than an abstract "mic is on" light.
///
/// It carries every state — live while recording, frozen while transcribing —
/// which is why there is no spinner anywhere in this app.
struct WaveformRibbon: View {
    /// Oldest first, 0...1.
    var levels: [Float]
    /// Frozen ribbons desaturate so "still listening" and "thinking about what
    /// you said" are distinguishable at a glance.
    var isLive: Bool
    var capacity: Int
    /// Colours the flatline drawn when there is no signal at all.
    var tint: Color = Palette.bone

    private let barWidth: CGFloat = 2
    private let barGap: CGFloat = 2

    var body: some View {
        Canvas { context, size in
            let slotWidth = barWidth + barGap
            let visibleCount = max(1, Int(size.width / slotWidth))
            let shown = levels.suffix(visibleCount)

            // No audio at all — a flatline, not an empty void. Keeps the ribbon
            // as the one element that carries every state.
            guard !shown.isEmpty else {
                let line = CGRect(x: 0, y: size.height / 2 - 0.5, width: size.width, height: 1)
                context.fill(Path(line), with: .color(tint.opacity(0.35)))
                return
            }

            let midY = size.height / 2
            let maxHalf = size.height / 2
            let minHalf: CGFloat = 0.75

            // Right-align: new bars appear at the leading edge of empty space so
            // a short utterance doesn't stretch across the whole ribbon.
            let startX = size.width - CGFloat(shown.count) * slotWidth

            for (index, level) in shown.enumerated() {
                let x = startX + CGFloat(index) * slotWidth
                guard x >= -slotWidth else { continue }

                // Slight curve: quiet speech still shows visible movement.
                let magnitude = pow(CGFloat(max(0, min(1, level))), 0.7)
                let half = max(minHalf, magnitude * maxHalf)

                // Age ramp — the ribbon reads as time passing, not decoration.
                let age = Double(index) / Double(max(1, shown.count - 1))
                let opacity = isLive ? (0.28 + 0.72 * age) : 0.30

                let rect = CGRect(x: x, y: midY - half, width: barWidth, height: half * 2)
                context.fill(
                    Path(roundedRect: rect, cornerRadius: barWidth / 2),
                    with: .color(Palette.bone.opacity(opacity))
                )
            }
        }
        .drawingGroup()
        .animation(.linear(duration: 0.06), value: levels.count)
    }
}

/// Hairline that sweeps beneath the frozen ribbon while work is in flight.
/// Indeterminate progress without borrowing a spinner.
struct ProgressSweep: View {
    var tint: Color = Palette.signal
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            if reduceMotion {
                // A steady bar still communicates "working" without motion.
                Capsule().fill(tint.opacity(0.5))
            } else {
                TimelineView(.animation) { timeline in
                    let period = 1.4
                    let t = timeline.date.timeIntervalSinceReferenceDate
                        .truncatingRemainder(dividingBy: period) / period
                    let segment = geometry.size.width * 0.35
                    // Travels fully off both edges so it never appears to bounce.
                    let x = -segment + (geometry.size.width + segment * 2) * t

                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [tint.opacity(0), tint, tint.opacity(0)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: segment)
                        .offset(x: x)
                }
            }
        }
        .frame(height: 1.5)
        .clipped()
    }
}
