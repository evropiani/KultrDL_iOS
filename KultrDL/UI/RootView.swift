import KultrDLCore
import SwiftUI
import UIKit

/**
 * The root of the interface: the theme, tinted by the artwork of what is
 * playing, around the tabs, the mini player and the full-screen player.
 */
struct RootView: View {
    @Environment(\.colorScheme) private var systemScheme
    @State private var accent: UInt32 = defaultAccent

    var body: some View {
        let settings = AppGraph.shared.settings.settings
        let dark: Bool = {
            switch settings.theme {
            case .dark: return true
            case .light: return false
            case .system: return systemScheme == .dark
            }
        }()
        let theme = KultrTheme(colors: .make(dark: dark, accent: accent), settings: settings)
        let artwork = AppGraph.shared.player.state.current?.artworkUrl
        MainUI()
            .environment(\.kultr, theme)
            .preferredColorScheme(settings.theme == .system ? nil : (dark ? .dark : .light))
            .tint(theme.colors.accent)
            .task(id: AccentKey(artwork: artwork, fromArtwork: settings.accentFromArtwork, accent: settings.accent)) {
                let next = await Self.resolveAccent(artwork: artwork, settings: settings)
                withAnimation(.easeInOut(duration: settings.reduceMotion ? 0 : 0.9)) { accent = next }
            }
    }

    private struct AccentKey: Hashable {
        let artwork: String?
        let fromArtwork: Bool
        let accent: String
    }

    /** The colour the whole interface is tinted with: from the artwork of what is playing, or the chosen one. */
    @MainActor
    private static func resolveAccent(artwork: String?, settings: Settings) async -> UInt32 {
        let chosen = ArtworkColor.parseHex(settings.accent) ?? defaultAccent
        guard settings.accentFromArtwork, let url = artwork.flatMap(URL.init(string:)),
              let sampled = await ImageLoader.shared.dominantColor(url)
        else { return chosen }
        return sampled
    }
}
