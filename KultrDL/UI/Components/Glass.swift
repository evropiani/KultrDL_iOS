import SwiftUI
import UIKit

// Liquid glass on iOS 26 and later; a frosted material with a lit edge before.
// Glass is for the layer that floats over the content (tab bar, mini player,
// floating buttons), not for the content itself.

private struct GlassSurface<S: InsettableShape>: ViewModifier {
    @Environment(\.kultr) private var theme
    let shape: S
    var tint: Color?
    var interactive = false
    var shadow = true

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(glass, in: shape)
        } else {
            // As close to liquid glass as a material gets: a thin, see-through
            // frost so the colours behind show, a bright rim where light
            // catches the edge, and a soft shadow.
            let dark = theme.colors.dark
            content
                .background(
                    LinearGradient(
                        colors: [.white.opacity(dark ? 0.10 : 0.45), .white.opacity(dark ? 0.02 : 0.15)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    in: shape
                )
                .background(tint.map { $0.opacity(0.18) } ?? .clear, in: shape)
                .background(Material.ultraThinMaterial, in: shape)
                .overlay(
                    shape.strokeBorder(
                        LinearGradient(
                            colors: [.white.opacity(dark ? 0.45 : 0.95), .white.opacity(dark ? 0.08 : 0.3), .white.opacity(dark ? 0.2 : 0.6)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
                )
                // The thickness: light gathers in the rounded edge all the way round,
                // brightest along the top, like a slab of glass lying on the screen.
                .overlay(
                    shape
                        .strokeBorder(
                            LinearGradient(
                                colors: [.white.opacity(dark ? 0.35 : 0.9), .white.opacity(dark ? 0.1 : 0.35), .white.opacity(dark ? 0.22 : 0.6)],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 5
                        )
                        .blur(radius: 4)
                        .clipShape(shape)
                        .allowsHitTesting(false)
                )
                .overlay(
                    // A faint dark line outside the rim, so the edge reads against light content too.
                    shape.stroke(.black.opacity(dark ? 0.35 : 0.08), lineWidth: 0.5).allowsHitTesting(false)
                )
                .shadow(color: .black.opacity(shadow ? (dark ? 0.3 : 0.1) : 0), radius: 14, y: 6)
        }
    }

    @available(iOS 26.0, *)
    private var glass: Glass {
        var glass = Glass.regular
        if let tint { glass = glass.tint(tint) }
        if interactive { glass = glass.interactive() }
        return glass
    }
}

extension View {
    /** A piece of glass in [shape]: liquid glass on iOS 26, frosted before. */
    func kultrGlass<S: InsettableShape>(_ shape: S, tint: Color? = nil, interactive: Bool = false, shadow: Bool = true) -> some View {
        modifier(GlassSurface(shape: shape, tint: tint, interactive: interactive, shadow: shadow))
    }
}

/**
 * Pieces of glass close together melt into each other on iOS 26 (and morph
 * when one appears or goes). Before iOS 26 this is just a stack.
 */
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 12
    @ViewBuilder let content: Content

    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

/** A round glass button with an icon: the player's controls, floating actions. */
struct GlassIconButton: View {
    @Environment(\.kultr) private var theme
    let icon: String
    var size: CGFloat = 44
    var iconSize: CGFloat?
    var tint: Color?
    var prominent = false
    var label = ""
    let action: () -> Void

    var body: some View {
        let c = theme.colors
        Button {
            Haptics.tap()
            action()
        } label: {
            Image(systemName: icon)
                .font(.system(size: iconSize ?? size * 0.4, weight: .semibold))
                .foregroundStyle(prominent ? c.onAccent : (tint ?? c.ink))
                .frame(width: size, height: size)
                .contentShape(Circle())
        }
        .buttonStyle(PressScaleStyle())
        .kultrGlass(Circle(), tint: prominent ? c.accent : nil, interactive: true, shadow: false)
        .accessibilityLabel(label)
    }
}

/** A wide button (Play, Shuffle, Connect): glass on iOS 26, filled with the accent when prominent. */
struct WideGlassButton: View {
    @Environment(\.kultr) private var theme
    let title: String
    let icon: String
    let prominent: Bool
    var enabled = true
    let action: () -> Void

    var body: some View {
        let c = theme.colors
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        Button {
            Haptics.tap()
            action()
        } label: {
            Label(title, systemImage: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle((prominent ? c.onAccent : c.accent).opacity(enabled ? 1 : 0.5))
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .contentShape(shape)
        }
        .buttonStyle(PressScaleStyle())
        .disabled(!enabled)
        .background(shape.fill(prominent && !Self.glassTints ? c.accent : .clear))
        .kultrGlass(shape, tint: prominent ? c.accent : nil, interactive: true, shadow: false)
    }

    /** On iOS 26 the glass itself carries the accent; before, the button is filled with it. */
    private static var glassTints: Bool {
        if #available(iOS 26.0, *) { return true }
        return false
    }
}

/** Shrinks a little while pressed, like the system's own controls. */
struct PressScaleStyle: ButtonStyle {
    @Environment(\.kultr) private var theme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !theme.reduceMotion ? 0.94 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(theme.reduceMotion ? nil : .spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/** Light taps of feedback, the way system controls give them. */
@MainActor
enum Haptics {
    private static let impact = UIImpactFeedbackGenerator(style: .light)
    private static let selection = UISelectionFeedbackGenerator()

    static func tap() { impact.impactOccurred(intensity: 0.6) }

    static func select() { selection.selectionChanged() }

    static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
}

extension KultrTheme {
    /** Reduce motion, from Kultr's setting or the system's. */
    var reduceMotion: Bool { settings.reduceMotion || UIAccessibility.isReduceMotionEnabled }

    /** The spring used for moving highlights and rows, or none with Reduce motion. */
    var spring: Animation? { reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.82) }

    /** A quick ease for things appearing and going. */
    var ease: Animation? { reduceMotion ? nil : .easeInOut(duration: 0.22) }
}
