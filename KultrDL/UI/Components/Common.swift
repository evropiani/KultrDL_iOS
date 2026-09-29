import SwiftUI

/** A button look that just dims while pressed, for custom-drawn controls. */
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.6 : 1)
            .contentShape(Rectangle())
    }
}

/** A translucent panel with an accent-tinted edge — Kultr's "glass". */
struct GlassPanel<Content: View>: View {
    @Environment(\.kultr) private var theme
    var strong = false
    var padding: CGFloat = 16
    var radius: CGFloat?
    @ViewBuilder var content: Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius ?? theme.radii.lg, style: .continuous)
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(shape.fill(strong ? theme.colors.glassStrong : theme.colors.glass))
            .overlay(shape.strokeBorder(theme.colors.edge, lineWidth: 1))
            .clipShape(shape)
    }
}

/** Rounded pill button, optionally filled with the accent. */
struct Pill: View {
    @Environment(\.kultr) private var theme
    let text: String
    var icon: String?
    var accent = false
    var enabled = true
    var badge: String?
    let action: () -> Void

    init(_ text: String, icon: String? = nil, accent: Bool = false, enabled: Bool = true, badge: String? = nil, action: @escaping () -> Void) {
        self.text = text
        self.icon = icon
        self.accent = accent
        self.enabled = enabled
        self.badge = badge
        self.action = action
    }

    var body: some View {
        let c = theme.colors
        let label = HStack(spacing: 7) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 18, height: 18)
            }
            Text(text)
                .font(KFont.labelLarge)
                .lineLimit(1)
            if let badge {
                Text(badge)
                    .font(.system(size: 11, weight: .bold).monospacedDigit())
                    .padding(.horizontal, 7)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(accent ? Color.white.opacity(0.22) : c.accentSoft))
            }
        }
        if #available(iOS 26.0, *) {
            if accent {
                Button(action: tapped) { label.foregroundStyle(.white) }
                    .buttonStyle(.glassProminent)
                    .tint(c.accent)
                    .disabled(!enabled)
            } else {
                Button(action: tapped) { label.foregroundStyle(c.ink.opacity(enabled ? 1 : 0.45)) }
                    .buttonStyle(.glass)
                    .disabled(!enabled)
            }
        } else {
            Button(action: tapped) {
                label
                    .foregroundStyle((accent ? c.onAccent : c.ink).opacity(enabled ? 1 : 0.5))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(accent ? c.accent.opacity(enabled ? 1 : 0.5) : c.glass))
                    .overlay(Capsule().strokeBorder(accent ? Color.clear : c.edge, lineWidth: 1))
            }
            .buttonStyle(PressScaleStyle())
            .disabled(!enabled)
        }
    }

    private func tapped() {
        Haptics.tap()
        action()
    }
}

/** A small chip used for years, genres, formats. */
struct Tag: View {
    @Environment(\.kultr) private var theme
    let text: String
    var action: (() -> Void)?

    init(_ text: String, action: (() -> Void)? = nil) {
        self.text = text
        self.action = action
    }

    var body: some View {
        let label = Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(theme.colors.ink2)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .background(Capsule().fill(theme.colors.glass))
            .overlay(Capsule().strokeBorder(theme.colors.edge, lineWidth: 1))
        if let action {
            Button(action: action) { label }.buttonStyle(PressableStyle())
        } else {
            label
        }
    }
}

struct SectionHeader<Action: View>: View {
    @Environment(\.kultr) private var theme
    let title: String
    var icon: String?
    @ViewBuilder var action: Action

    var body: some View {
        HStack(spacing: 8) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(theme.colors.accent)
                    .frame(width: 18)
            }
            Text(title)
                .font(KFont.titleMedium)
                .foregroundStyle(theme.colors.ink)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            action
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

extension SectionHeader where Action == EmptyView {
    init(_ title: String, icon: String? = nil) {
        self.title = title
        self.icon = icon
        self.action = EmptyView()
    }
}

extension SectionHeader {
    init(_ title: String, icon: String? = nil, @ViewBuilder action: () -> Action) {
        self.title = title
        self.icon = icon
        self.action = action()
    }
}

struct Eyebrow: View {
    @Environment(\.kultr) private var theme
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text.uppercased())
            .font(KFont.eyebrow)
            .tracking(1.4)
            .foregroundStyle(theme.colors.ink3)
            .lineLimit(1)
    }
}

struct EmptyState<Action: View>: View {
    @Environment(\.kultr) private var theme
    let icon: String
    let title: String
    var message: String?
    @ViewBuilder var action: Action

    var body: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle().fill(theme.colors.accentSoft)
                Image(systemName: icon)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(theme.colors.accent)
            }
            .frame(width: 64, height: 64)
            Text(title)
                .font(KFont.titleLarge)
                .foregroundStyle(theme.colors.ink)
                .multilineTextAlignment(.center)
            if let message {
                Text(message)
                    .font(KFont.bodyMedium)
                    .foregroundStyle(theme.colors.ink2)
                    .multilineTextAlignment(.center)
            }
            action
        }
        .frame(maxWidth: .infinity)
        .padding(32)
    }
}

extension EmptyState where Action == EmptyView {
    init(icon: String, title: String, message: String? = nil) {
        self.icon = icon
        self.title = title
        self.message = message
        self.action = EmptyView()
    }
}

struct LoadingView: View {
    @Environment(\.kultr) private var theme

    var body: some View {
        ProgressView()
            .tint(theme.colors.accent)
            .controlSize(.large)
            .frame(maxWidth: .infinity)
            .padding(48)
    }
}

/** A settings-style row: label and hint on the left, a control on the right. */
struct SettingRow<Control: View>: View {
    @Environment(\.kultr) private var theme
    let label: String
    var hint: String?
    var action: (() -> Void)?
    @ViewBuilder var control: Control

    var body: some View {
        let row = HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(KFont.bodyLarge)
                    .foregroundStyle(theme.colors.ink)
                if let hint {
                    Text(hint)
                        .font(KFont.bodySmall)
                        .foregroundStyle(theme.colors.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            control
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        if let action {
            Button(action: action) { row }.buttonStyle(PressableStyle())
        } else {
            row
        }
    }
}

extension SettingRow where Control == EmptyView {
    init(_ label: String, hint: String? = nil, action: (() -> Void)? = nil) {
        self.label = label
        self.hint = hint
        self.action = action
        self.control = EmptyView()
    }
}

extension SettingRow {
    init(_ label: String, hint: String? = nil, action: (() -> Void)? = nil, @ViewBuilder control: () -> Control) {
        self.label = label
        self.hint = hint
        self.action = action
        self.control = control()
    }
}

/** A thin horizontal rule in the theme's line colour. */
struct Rule: View {
    @Environment(\.kultr) private var theme

    var body: some View {
        Rectangle().fill(theme.colors.line).frame(height: 1)
    }
}

/** A soft wash of the accent behind a header, fading into the background. */
struct AccentWash: View {
    @Environment(\.kultr) private var theme
    var height: CGFloat = 320

    var body: some View {
        LinearGradient(colors: [theme.colors.accent.opacity(0.28), .clear], startPoint: .top, endPoint: .bottom)
            .frame(height: height)
            .frame(maxHeight: .infinity, alignment: .top)
            .ignoresSafeArea()
            .allowsHitTesting(false)
    }
}

/** The colour field behind screens that have no artwork of their own. */
struct PlainBackdrop: View {
    @Environment(\.kultr) private var theme

    var body: some View {
        ZStack {
            theme.colors.background
            RadialGradient(
                colors: [theme.colors.accent.opacity(theme.colors.dark ? 0.22 : 0.16), .clear],
                center: .topLeading,
                startRadius: 0,
                endRadius: 560
            )
        }
        .ignoresSafeArea()
    }
}

/** Blurred artwork behind everything, darkened so text stays readable. */
struct ArtworkBackdrop: View {
    @Environment(\.kultr) private var theme
    let artworkUrl: String?
    @State private var image: UIImage?

    var body: some View {
        let url = artworkUrl.flatMap(URL.init(string:))
        ZStack {
            theme.colors.background
            if let image {
                // Sized to the space it is given: a square image filled to a
                // tall screen is wider than the screen, and must not widen it.
                GeometryReader { proxy in
                    Image(uiImage: image)
                        .resizable()
                        .interpolation(.medium)
                        .scaledToFill()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .scaleEffect(1.2)
                        .clipped()
                }
                .opacity(theme.colors.dark ? 0.6 : 0.5)
                .transition(.opacity)
                .id(url)
            }
            LinearGradient(
                colors: [theme.colors.background.opacity(0.3), theme.colors.accent.opacity(0.1), theme.colors.background.opacity(0.9)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .task(id: url) {
            guard let url else {
                image = nil
                return
            }
            if let hit = ImageLoader.shared.cachedBlur(url) {
                image = hit
                return
            }
            let next = await ImageLoader.shared.blurred(url)
            withAnimation(theme.reduceMotion ? nil : .easeInOut(duration: 0.6)) { image = next }
        }
    }
}

/** What goes behind every page: the blurred artwork of what is playing, or the plain field. */
struct AppBackdrop: View {
    @Environment(\.kultr) private var theme

    var body: some View {
        let current = AppGraph.shared.player.state.current
        if theme.settings.backdropArtwork, let current {
            ArtworkBackdrop(artworkUrl: current.artworkUrl)
        } else {
            PlainBackdrop()
        }
    }
}

extension View {
    /** A page in a tab's navigation stack: Kultr's own background behind iOS's navigation bar. */
    func kultrScreen() -> some View {
        self
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background { AppBackdrop() }
    }
}

/** A horizontally scrolling row of cards. */
struct Shelf<Item: Identifiable, Card: View>: View {
    let items: [Item]
    var cardWidth: CGFloat = 150
    @ViewBuilder let card: (Item) -> Card

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 2) {
                ForEach(items) { item in
                    card(item).frame(width: cardWidth)
                }
            }
            .padding(.horizontal, 10)
        }
    }
}

/** A text field in Kultr's rounded style, with a search icon and a clear button. */
struct FilterField: View {
    @Environment(\.kultr) private var theme
    @Binding var text: String
    let placeholder: String
    var focused: FocusState<Bool>.Binding?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(theme.colors.ink3)
            field
                .foregroundStyle(theme.colors.ink)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(theme.colors.ink3)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: theme.radii.xl, style: .continuous).fill(theme.colors.glass))
        .overlay(RoundedRectangle(cornerRadius: theme.radii.xl, style: .continuous).strokeBorder(theme.colors.edge, lineWidth: 1))
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var field: some View {
        let input = TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(theme.colors.ink3))
        if let focused {
            input.focused(focused)
        } else {
            input
        }
    }
}

/** Kultr's switch, tinted with the accent. */
struct KultrSwitch: View {
    @Environment(\.kultr) private var theme
    let isOn: Bool
    var enabled = true
    let onChange: (Bool) -> Void

    var body: some View {
        Toggle("", isOn: Binding(get: { isOn }, set: { onChange($0) }))
            .labelsHidden()
            .tint(theme.colors.accent)
            .disabled(!enabled)
    }
}

/** A thin progress bar in the accent. */
struct ProgressBar: View {
    @Environment(\.kultr) private var theme
    /** 0..1, or nil for an indeterminate bar. */
    let value: Double?
    var height: CGFloat = 4

    var body: some View {
        if let value {
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(theme.colors.ink4)
                    Capsule().fill(theme.colors.accent).frame(width: proxy.size.width * min(1, max(0, value)))
                }
            }
            .frame(height: height)
        } else {
            ProgressView().progressViewStyle(.linear).tint(theme.colors.accent)
        }
    }
}
