import KultrDLCore
import SwiftUI

/** Home: open a link, pick up where you left off, favourites, playlists and the charts. */
struct HomeScreen: View {
    @Environment(\.kultr) private var theme
    @State private var charts: [Track] = []
    @State private var hour = Calendar.current.component(.hour, from: Date())

    var body: some View {
        let graph = AppGraph.shared
        let library = graph.library
        let actions = graph.actions
        let blocks = graph.taste.blocks
        let history = blocks.tracks(library.history(20))
        let favorites = blocks.tracks(library.favorites)
        let topSongs = blocks.tracks(charts)
        let playlists = library.playlistsByDate
        let playing = graph.player.state.current?.id
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                LinkCard()
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                Chips(options: Source.searchSources, selected: graph.settings.settings.searchSource, label: { $0.label }) { source in
                    graph.settings.update { $0.searchSource = source }
                    actions.search("")
                }
                .padding(.vertical, 8)

                if graph.settings.settings.suggestions {
                    ForYouSection()
                        .padding(.top, 4)
                }
                if !history.isEmpty {
                    SectionHeader("Jump back in", icon: "clock.arrow.circlepath")
                        .padding(.top, 8)
                    Shelf(items: history) { track in
                        TrackCard(track: track) { actions.play(history, history.firstIndex { $0.id == track.id } ?? 0) }
                    }
                }
                if !favorites.isEmpty {
                    SectionHeader("Favourites", icon: "heart.fill") {
                        seeAll("Shuffle") { actions.shuffle(favorites) }
                    }
                    .padding(.top, 8)
                    Shelf(items: Array(favorites.prefix(20))) { track in
                        TrackCard(track: track) { actions.play(favorites, favorites.firstIndex { $0.id == track.id } ?? 0) }
                    }
                }
                if !playlists.isEmpty {
                    SectionHeader("Your playlists", icon: "music.note.list") {
                        seeAll("See all") { actions.openLibrary(.playlists) }
                    }
                    .padding(.top, 8)
                    Shelf(items: playlists) { playlist in
                        CollectionCard(
                            title: playlist.name,
                            subtitle: Format.count(playlist.trackIds.count, "track"),
                            artworkUrl: playlist.artworkUrl ?? library.playlistTracks(playlist.id).first?.artworkUrl
                        ) { actions.openPlaylist(playlist.id) }
                    }
                }
                if !topSongs.isEmpty {
                    SectionHeader("Top songs right now", icon: "chart.line.uptrend.xyaxis") {
                        seeAll("Play all") { actions.play(topSongs) }
                    }
                    .padding(.top, 8)
                    let top = Array(topSongs.prefix(15))
                    ForEach(Array(top.enumerated()), id: \.offset) { index, track in
                        TrackRow(track: track, number: index + 1, isCurrent: track.id == playing) { actions.play(topSongs, index) }
                    }
                }
                if history.isEmpty && favorites.isEmpty && !graph.settings.settings.suggestions {
                    Welcome()
                }
            }
            .padding(.bottom, 24)
        }
        .navigationTitle(Format.greeting(hour))
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                CastButton(tint: theme.colors.ink)
            }
        }
        .kultrScreen()
        .task {
            guard charts.isEmpty else { return }
            if let top = try? await graph.catalog.apple.topSongs(limit: 25), !top.isEmpty {
                charts = top
            } else if let top = try? await graph.catalog.deezer.chart() {
                charts = top
            }
        }
        .onAppear { hour = Calendar.current.component(.hour, from: Date()) }
    }

    private func seeAll(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(KFont.labelLarge)
                .foregroundStyle(theme.colors.accent)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScaleStyle())
    }
}

/** "Got a link?": paste one from any of the services KultrDL knows. */
private struct LinkCard: View {
    @Environment(\.kultr) private var theme

    var body: some View {
        let c = theme.colors
        GlassPanel {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Image("KultrDLLogo")
                        .resizable()
                        .frame(width: 36, height: 36)
                        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    Text("Got a link?")
                        .font(KFont.titleMedium)
                        .foregroundStyle(c.ink)
                }
                Text("Spotify, Apple Music, Tidal, Qobuz, Deezer, Amazon Music, YouTube, SoundCloud, Bandcamp and more. Paste it here, or share it to KultrDL from any app with the Shortcut in Settings.")
                    .font(KFont.bodyMedium)
                    .foregroundStyle(c.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                PasteButton(payloadType: String.self) { strings in
                    let text = strings.joined(separator: " ")
                    Task { @MainActor in
                        if let link = Links.find(text) {
                            AppGraph.shared.actions.search(link)
                        } else {
                            AppGraph.shared.messages.show("There's no link on the clipboard.")
                        }
                    }
                }
                .buttonBorderShape(.capsule)
                .tint(c.accent)
                .labelStyle(.titleAndIcon)
            }
        }
    }
}

private struct Welcome: View {
    @Environment(\.kultr) private var theme

    var body: some View {
        let actions = AppGraph.shared.actions
        VStack(spacing: 12) {
            Image("KultrDLLogo")
                .resizable()
                .frame(width: 96, height: 96)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            Text("Find something to play")
                .font(KFont.titleLarge)
                .foregroundStyle(theme.colors.ink)
            Text("Search YouTube Music, Spotify, Apple Music, Deezer, SoundCloud or Bandcamp with the round button. Heart what you love, save it to your library and download it as FLAC, MP3 and more — to this phone or straight to your server.")
                .font(KFont.bodyMedium)
                .foregroundStyle(theme.colors.ink2)
                .multilineTextAlignment(.center)
            HStack(spacing: 8) {
                Pill("Search", icon: "magnifyingglass", accent: true) { actions.search("") }
                Pill("Downloads", icon: "arrow.down.circle") { actions.openDownloads() }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.vertical, 28)
    }
}
