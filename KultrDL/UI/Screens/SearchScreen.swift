import KultrDLCore
import SwiftUI

/**
 * Search one source at a time, or open a link from any of them. The field
 * lives in the tab bar; this page shows what it finds.
 */
struct SearchScreen: View {
    @Environment(\.kultr) private var theme
    @State private var results = SearchResults()
    @State private var link: LinkResult?
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        let graph = AppGraph.shared
        let actions = graph.actions
        let c = theme.colors
        let source = graph.settings.settings.searchSource
        let query = graph.ui.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let isLink = Links.isLink(query)
        let playing = graph.player.state.current?.id
        VStack(alignment: .leading, spacing: 0) {
            if !isLink {
                Chips(options: Source.searchSources, selected: source, label: { $0.label }) { next in
                    graph.settings.update { $0.searchSource = next }
                }
                .padding(.top, 4)
                if !source.streams {
                    Text("\(source.label) tracks play and download from the matching recording on YouTube Music, with \(source.label)'s tags and cover.")
                        .font(KFont.bodySmall)
                        .foregroundStyle(c.ink3)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 4)
                }
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if query.count < 2 {
                        RecentSearches()
                    } else if loading {
                        LoadingView()
                    } else if let error {
                        EmptyState(icon: "icloud.slash", title: isLink ? "Couldn't open that link" : "Search failed", message: error)
                    } else if let link {
                        LinkResultView(result: link, playing: playing)
                    } else if results.isEmpty {
                        EmptyState(icon: "magnifyingglass", title: "Nothing matches “\(query)”", message: "Try another source above.")
                    } else {
                        // Albums by blocked artists are left out (their songs are hidden row by row).
                        let albums = results.collections.filter { !graph.taste.blocks.blocks($0) }
                        if !albums.isEmpty {
                            SectionHeader("Albums")
                            Shelf(items: albums) { collection in
                                CollectionCard(
                                    title: collection.title,
                                    subtitle: [collection.subtitle, collection.year.map(String.init)].compactMap { $0 }.joined(separator: " · "),
                                    artworkUrl: collection.artworkUrl
                                ) { actions.openCollection(collection) }
                            }
                        }
                        if !results.tracks.isEmpty {
                            SectionHeader("Tracks") {
                                Button { actions.play(results.tracks) } label: {
                                    Text("Play all").font(KFont.labelLarge).foregroundStyle(c.accent).frame(minHeight: 44)
                                }
                                .buttonStyle(PressScaleStyle())
                            }
                            TrackRows(tracks: results.tracks, keyPrefix: "s") { actions.play(results.tracks, $0) }
                        }
                    }
                }
                .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.immediately)
        }
        .navigationTitle("Search")
        .kultrScreen()
        .task(id: "\(query)|\(source.rawValue)") {
            error = nil
            guard query.count >= 2 else {
                results = SearchResults()
                link = nil
                loading = false
                return
            }
            try? await Task.sleep(nanoseconds: isLink ? 50_000_000 : 450_000_000)
            if Task.isCancelled { return }
            loading = true
            do {
                if isLink {
                    results = SearchResults()
                    let found = try await graph.catalog.resolve(query)
                    if Task.isCancelled { return }
                    link = found
                } else {
                    link = nil
                    let found = try await graph.catalog.search(source, query)
                    if Task.isCancelled { return }
                    results = found
                    graph.library.rememberSearch(query)
                }
            } catch {
                if Task.isCancelled || error is CancellationError { return }
                self.error = describe(error)
                results = SearchResults()
                link = nil
            }
            loading = false
        }
    }
}

private struct RecentSearches: View {
    @Environment(\.kultr) private var theme

    var body: some View {
        let graph = AppGraph.shared
        let recent = graph.library.recentSearches
        let c = theme.colors
        if recent.isEmpty {
            EmptyState(
                icon: "magnifyingglass",
                title: "Find anything",
                message: "Type a song, artist or album, or paste a link from Spotify, Apple Music, Tidal, Qobuz, Deezer, Amazon Music, YouTube, SoundCloud or Bandcamp."
            )
        } else {
            SectionHeader("Recent searches", icon: "clock.arrow.circlepath") {
                Button { graph.library.clearSearches() } label: {
                    Text("Clear").font(KFont.labelLarge).foregroundStyle(c.accent).frame(minHeight: 44)
                }
                .buttonStyle(PressScaleStyle())
            }
            ForEach(recent, id: \.self) { query in
                HStack(spacing: 12) {
                    Image(systemName: "magnifyingglass").font(.system(size: 15)).foregroundStyle(c.ink3)
                    Text(query).font(KFont.bodyLarge).foregroundStyle(c.ink).lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    IconButton(icon: "xmark", tint: c.ink3, size: 14, label: "Forget") { graph.library.forgetSearch(query) }
                }
                .padding(.leading, 16)
                .padding(.trailing, 4)
                .contentShape(Rectangle())
                .onTapGesture { graph.actions.search(query) }
            }
        }
    }
}

/** What a pasted link turned out to be: one track, or an album or playlist. */
private struct LinkResultView: View {
    @Environment(\.kultr) private var theme
    let result: LinkResult
    let playing: String?

    var body: some View {
        let actions = AppGraph.shared.actions
        let c = theme.colors
        switch result {
        case .single(let track):
            GlassPanel {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: "link").foregroundStyle(c.accent)
                        Eyebrow("\(track.source.label) track")
                    }
                    TrackRow(track: track, isCurrent: track.id == playing) { actions.play([track]) }
                        .padding(.horizontal, -16)
                    HStack(spacing: 8) {
                        Pill("Play", icon: "play.fill", accent: true) { actions.play([track]) }
                        Pill("Download", icon: "arrow.down.circle") { actions.download([track]) }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        case .many(let collection):
            GlassPanel {
                HStack(spacing: 14) {
                    ArtworkFill(url: collection.artworkUrl, label: collection.title)
                        .frame(width: 92, height: 92)
                    VStack(alignment: .leading, spacing: 4) {
                        Eyebrow("\(collection.source.label) \(collection.kind.label.lowercased())")
                        Text(collection.title).font(KFont.titleMedium).foregroundStyle(c.ink).lineLimit(2)
                        Text([collection.subtitle, Format.count(collection.tracks.count, "track")].compactMap { $0 }.joined(separator: " · "))
                            .font(KFont.bodySmall)
                            .foregroundStyle(c.ink3)
                            .lineLimit(1)
                        Pill("Open", accent: true) { actions.openCollection(collection) }
                            .padding(.top, 4)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            TrackRows(tracks: collection.tracks, numbered: collection.kind == .album, keyPrefix: "l") { actions.play(collection.tracks, $0) }
        }
    }
}
