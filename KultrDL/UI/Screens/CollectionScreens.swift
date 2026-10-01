import KultrDLCore
import SwiftUI

/** The big artwork, eyebrow, title and details at the top of an album or playlist. */
private struct CollectionHeader: View {
    @Environment(\.kultr) private var theme
    let artworkUrl: String?
    let eyebrow: String
    let title: String
    let meta: String

    var body: some View {
        let c = theme.colors
        VStack(spacing: 0) {
            ArtworkFill(url: artworkUrl, radius: theme.radii.lg, label: title, pixels: 600)
                .frame(width: 220, height: 220)
                .shadow(color: .black.opacity(0.3), radius: 20, y: 10)
            Eyebrow(eyebrow)
                .padding(.top, 16)
            Text(title)
                .font(KFont.headlineSmall)
                .foregroundStyle(c.ink)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .padding(.top, 4)
            Text(meta)
                .font(KFont.bodyMedium)
                .foregroundStyle(c.ink2)
                .multilineTextAlignment(.center)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.bottom, 10)
    }
}

/** An album or playlist from any source, with its tracks. */
struct CollectionScreen: View {
    @Environment(\.kultr) private var theme
    let id: String
    @State private var loaded: TrackCollection?
    @State private var error: String?

    var body: some View {
        let graph = AppGraph.shared
        let actions = graph.actions
        let shell = graph.ui.collections[id]
        let shown = loaded ?? shell
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if let c = shown {
                    CollectionHeader(artworkUrl: c.artworkUrl, eyebrow: Self.eyebrow(c), title: c.title, meta: Self.meta(c))
                }
                if let error {
                    EmptyState(icon: "icloud.slash", title: "Couldn't open this", message: error)
                } else if let c = loaded {
                    PillRow {
                        Pill("Play", icon: "play.fill", accent: true, enabled: !c.tracks.isEmpty) { actions.play(c.tracks) }
                        Pill("Shuffle", icon: "shuffle", enabled: !c.tracks.isEmpty) { actions.shuffle(c.tracks) }
                        if let mix = c.id.hasPrefix("mix:") ? graph.recommender.feed?.mixes.first(where: { "mix:" + $0.id == c.id }) : nil {
                            Pill("Keep updated", icon: "arrow.triangle.2.circlepath") { actions.followMix(mix) }
                        }
                        Pill("Download all", icon: "arrow.down.circle", enabled: !c.tracks.isEmpty) { actions.download(c.tracks) }
                        if actions.canDownloadToNavidrome {
                            Pill("Download to Navidrome", icon: "externaldrive.badge.icloud", enabled: !c.tracks.isEmpty) { actions.downloadToNavidrome(c.tracks) }
                        }
                        Pill("Download as…", icon: "slider.horizontal.3", enabled: !c.tracks.isEmpty) { actions.downloadAs(c.tracks) }
                        Pill("Save as playlist", icon: "text.badge.plus", enabled: !c.tracks.isEmpty) { actions.saveAsPlaylist(c) }
                        Pill("Save tracks", icon: "bookmark", enabled: !c.tracks.isEmpty) { actions.setSaved(c.tracks, true) }
                    }
                    let hidden = c.tracks.filter { graph.taste.blocks.blocks($0) }.count
                    if hidden > 0 {
                        Text("\(Format.count(hidden, "song")) by blocked artists hidden")
                            .font(KFont.bodySmall)
                            .foregroundStyle(theme.colors.ink3)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 4)
                    }
                    TrackRows(tracks: c.tracks, numbered: c.kind == .album, keyPrefix: "c") { actions.play(c.tracks, $0) }
                } else {
                    LoadingView()
                }
            }
            .padding(.bottom, 24)
        }
        .background(alignment: .top) { AccentWash() }
        .navigationTitle(shown?.title ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .kultrScreen()
        .task(id: id) {
            guard loaded == nil else { return }
            guard let shell else {
                error = "This page was closed by the system. Open it again from search."
                return
            }
            if !shell.tracks.isEmpty && shell.kind == .playlist && shell.trackCount == nil {
                loaded = shell
                return
            }
            do {
                let full = try await graph.catalog.load(shell)
                graph.ui.collections[id] = full
                loaded = full
            } catch {
                if error is CancellationError { return }
                if !shell.tracks.isEmpty {
                    loaded = shell
                } else {
                    self.error = describe(error)
                }
            }
        }
    }
}

extension CollectionScreen {
    static func eyebrow(_ c: TrackCollection) -> String {
        if c.id.hasPrefix("mix:") { return "Made for you" }
        switch c.recordType {
        case "single": return "\(c.source.label) · Single"
        case "ep": return "\(c.source.label) · EP"
        default: return "\(c.source.label) · \(c.kind.label)"
        }
    }

    /** Artist, when it came out (how long ago, for this year's releases), how many tracks and how long. */
    static func meta(_ c: TrackCollection) -> String {
        var parts: [String] = []
        if let subtitle = c.subtitle { parts.append(subtitle) }
        if let date = c.releaseDate, Day(date)?.year == Day.today().year, let released = Format.released(date) {
            parts.append(released)
        } else if let year = c.year {
            parts.append(String(year))
        }
        if let count = c.tracks.isEmpty ? c.trackCount : c.tracks.count { parts.append(Format.count(count, "track")) }
        if let duration = totalDuration(c.tracks) { parts.append(duration) }
        return parts.joined(separator: " · ")
    }
}

/** One of the user's own playlists. */
struct PlaylistScreen: View {
    @Environment(\.kultr) private var theme
    let id: String
    @State private var renaming = false
    @State private var deleting = false
    @State private var name = ""

    var body: some View {
        let graph = AppGraph.shared
        let library = graph.library
        let actions = graph.actions
        let playlist = library.playlist(id)
        let tracks = library.playlistTracks(id)
        let title = playlist?.name ?? "Playlist"
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                CollectionHeader(
                    artworkUrl: playlist?.artworkUrl ?? tracks.first?.artworkUrl,
                    eyebrow: "Playlist",
                    title: title,
                    meta: [Format.count(tracks.count, "track"), totalDuration(tracks)].compactMap { $0 }.joined(separator: " · ")
                )
                PillRow {
                    Pill("Play", icon: "play.fill", accent: true, enabled: !tracks.isEmpty) { actions.play(tracks) }
                    Pill("Shuffle", icon: "shuffle", enabled: !tracks.isEmpty) { actions.shuffle(tracks) }
                    Pill("Download all", icon: "arrow.down.circle", enabled: !tracks.isEmpty) { actions.download(tracks) }
                    Pill("Rename", icon: "pencil") {
                        name = title
                        renaming = true
                    }
                    Pill("Delete", icon: "trash") { deleting = true }
                }
                if tracks.isEmpty {
                    EmptyState(icon: "music.note.list", title: "Nothing in here yet", message: "Add tracks with “Add to playlist…” from any track's menu.")
                }
                TrackRows(tracks: tracks, keyPrefix: "p", extra: { index, _ in
                    var entries = [MenuAction(label: "Remove from playlist", icon: "minus.circle", destructive: true) { library.removeFromPlaylist(id, at: index) }]
                    if index > 0 {
                        entries.append(MenuAction(label: "Move up", icon: "arrow.up") { library.movePlaylistTrack(id, from: index, to: index - 1) })
                    }
                    if index < tracks.count - 1 {
                        entries.append(MenuAction(label: "Move down", icon: "arrow.down") { library.movePlaylistTrack(id, from: index, to: index + 1) })
                    }
                    return entries
                }) { actions.play(tracks, $0) }
            }
            .padding(.bottom, 24)
        }
        .background(alignment: .top) { AccentWash() }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .kultrScreen()
        .alert("Rename playlist", isPresented: $renaming) {
            TextField("Name", text: $name)
            Button("Cancel", role: .cancel) {}
            Button("Rename") { library.renamePlaylist(id, name) }
        }
        .confirmationDialog("Delete “\(title)”?", isPresented: $deleting, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                library.deletePlaylist(id)
                actions.back()
            }
        } message: {
            Text("The playlist goes; its tracks stay in your library and downloads.")
        }
    }
}
