import KultrDLCore
import SwiftUI

/** Snap to a few sizes, so the same cover isn't decoded at every pixel size. */
private func bucketFor(_ size: Int) -> Int {
    size <= 96 ? 96 : size <= 200 ? 200 : size <= 400 ? 400 : 800
}

/**
 * Cover art with a graceful placeholder: a gradient in the accent with the
 * initials of whatever it is, so something without artwork still looks placed.
 */
struct Artwork: View {
    @Environment(\.kultr) private var theme
    let url: String?
    var size: CGFloat = 48
    var circle = false
    var label: String?
    var icon = "music.note"

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: circle ? size / 2 : theme.radii.xs, style: .continuous)
        ZStack {
            LinearGradient(
                colors: [theme.colors.accent.opacity(0.55), theme.colors.accent.opacity(0.15)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            if let label {
                Text(Format.initials(label))
                    .font(.system(size: min(48, max(10, size * 0.3)), weight: .bold))
                    .foregroundStyle(.white.opacity(0.85))
            } else {
                Image(systemName: icon)
                    .font(.system(size: size * 0.36, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
            }
            if let link = url, let parsed = URL(string: link) {
                RemoteImage(url: parsed, pixelSize: bucketFor(Int(size * 3)))
                    .frame(width: size, height: size)
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
    }
}

/** Artwork that fills its parent's width (square), for cards and headers. */
struct ArtworkFill: View {
    @Environment(\.kultr) private var theme
    let url: String?
    var circle = false
    var radius: CGFloat?
    var label: String?
    var pixels = 400

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius ?? theme.radii.md, style: .continuous)
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                ZStack {
                    LinearGradient(
                        colors: [theme.colors.accent.opacity(0.55), theme.colors.accent.opacity(0.12)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    if let label {
                        Text(Format.initials(label))
                            .font(.system(size: 28, weight: .bold))
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    if let link = url, let parsed = URL(string: link) {
                        RemoteImage(url: parsed, pixelSize: bucketFor(pixels))
                    }
                }
            }
            .clipShape(circle ? AnyShape(Circle()) : AnyShape(shape))
    }
}
