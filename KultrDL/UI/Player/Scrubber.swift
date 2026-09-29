import KultrDLCore
import SwiftUI

/** The progress bar. Drag or tap to seek. */
struct Scrubber: View {
    @Environment(\.kultr) private var theme
    let positionMs: Int64
    let durationMs: Int64
    let onSeek: (Int64) -> Void

    @State private var dragFraction: Double?

    var body: some View {
        let c = theme.colors
        let fraction = dragFraction ?? (durationMs > 0 ? min(1, max(0, Double(positionMs) / Double(durationMs))) : 0)
        VStack(spacing: 0) {
            GeometryReader { proxy in
                let width = proxy.size.width
                Canvas { context, size in
                    let h: CGFloat = 4
                    let y = size.height / 2
                    context.fill(Path(roundedRect: CGRect(x: 0, y: y - h / 2, width: size.width, height: h), cornerRadius: h / 2), with: .color(c.ink4))
                    let played = fraction * size.width
                    context.fill(Path(roundedRect: CGRect(x: 0, y: y - h / 2, width: played, height: h), cornerRadius: h / 2), with: .color(c.accent))
                    let thumb: CGFloat = dragFraction != nil ? 9 : 6
                    context.fill(Path(ellipseIn: CGRect(x: played - thumb, y: y - thumb, width: thumb * 2, height: thumb * 2)), with: .color(c.accent))
                    let dot = thumb * 0.35
                    context.fill(Path(ellipseIn: CGRect(x: played - dot, y: y - dot, width: dot * 2, height: dot * 2)), with: .color(.white.opacity(0.9)))
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            dragFraction = min(1, max(0, value.location.x / max(1, width)))
                        }
                        .onEnded { value in
                            let f = min(1, max(0, value.location.x / max(1, width)))
                            if durationMs > 0 { onSeek(Int64(f * Double(durationMs))) }
                            dragFraction = nil
                        }
                )
            }
            .frame(height: 28)
            HStack {
                let shownMs = dragFraction.map { Int64($0 * Double(durationMs)) } ?? positionMs
                Text(Format.timeMs(shownMs))
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(c.ink3)
                Spacer()
                Text(durationMs > 0 ? Format.timeMs(durationMs) : "--:--")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(c.ink3)
            }
            .padding(.horizontal, 2)
        }
        .accessibilityElement()
        .accessibilityLabel("Position")
        .accessibilityValue("\(Format.timeMs(positionMs)) of \(Format.timeMs(durationMs))")
        .accessibilityAdjustableAction { direction in
            let step: Int64 = 15_000
            switch direction {
            case .increment: onSeek(min(durationMs, positionMs + step))
            case .decrement: onSeek(max(0, positionMs - step))
            @unknown default: break
            }
        }
    }
}
