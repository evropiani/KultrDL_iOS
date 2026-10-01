import KultrDLCore
import SwiftUI

/**
 * What can be said about a suggestion: more like this, not interested,
 * never this artist; and download it, to the phone or to Navidrome.
 */
struct SuggestionMenuItems: View {
    let key: String
    let artist: String
    let label: String
    /** The songs to download, when the suggestion can be downloaded. */
    var tracks: (@MainActor () async -> [Track])?

    var body: some View {
        let actions = AppGraph.shared.actions
        Button { actions.like(key, artist: artist, label: label) } label: { Label("More like this", systemImage: "hand.thumbsup") }
        Button { actions.dismiss(key, artist: artist, label: label) } label: { Label("Not interested", systemImage: "hand.thumbsdown") }
        Button(role: .destructive) {
            actions.blockArtist(Track(id: "", source: .web, title: "", artist: artist))
        } label: { Label("Never this artist…", systemImage: "nosign") }
        if let tracks {
            Divider()
            Button {
                Task { @MainActor in actions.download(await tracks()) }
            } label: { Label("Download", systemImage: "arrow.down.circle") }
            if actions.canDownloadToNavidrome {
                Button {
                    Task { @MainActor in actions.downloadToNavidrome(await tracks()) }
                } label: { Label("Download to Navidrome", systemImage: "externaldrive.badge.icloud") }
            }
        }
    }
}

extension Pick {
    /** The album or release page opened from a suggestion. */
    var page: TrackCollection {
        var c = collection
        c.subtitle = c.subtitle ?? artist
        return c
    }
}

/** An album or single suggested: cover, title, artist and why (or when it came out). Long-press for more. */
struct PickCard: View {
    @Environment(\.kultr) private var theme
    let pick: Pick
    var showDate = false

    var body: some View {
        let c = pick.collection
        let line = showDate ? [pick.reason, Format.released(c.releaseDate)].compactMap { $0 }.joined(separator: " · ") : pick.reason
        VStack(alignment: .leading, spacing: 0) {
            ArtworkFill(url: c.artworkUrl, label: c.title)
            Spacer().frame(height: 8)
            Text(c.title)
                .font(KFont.bodyMedium.weight(.semibold))
                .foregroundStyle(theme.colors.ink)
                .lineLimit(1)
            Text(pick.artist)
                .font(KFont.bodySmall)
                .foregroundStyle(theme.colors.ink2)
                .lineLimit(1)
            Text(line)
                .font(KFont.bodySmall)
                .foregroundStyle(theme.colors.ink3)
                .lineLimit(1)
        }
        .padding(6)
        .contentShape(Rectangle())
        .onTapGesture { AppGraph.shared.actions.openCollection(pick.page) }
        .contextMenu {
            SuggestionMenuItems(key: pick.key, artist: pick.artist, label: c.title) {
                let graph = AppGraph.shared
                do {
                    return try await graph.catalog.load(pick.page).tracks
                } catch {
                    graph.messages.error("Couldn't open “\(c.title)”: \(describe(error))")
                    return []
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the album")
    }
}

/** A mix: a 2×2 mosaic of its covers, its name and who is in it. */
struct MixCard: View {
    @Environment(\.kultr) private var theme
    let mix: Mix

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Mosaic(urls: mix.artworkUrls, label: mix.title)
            Spacer().frame(height: 8)
            Text(mix.title)
                .font(KFont.bodyMedium.weight(.semibold))
                .foregroundStyle(theme.colors.ink)
                .lineLimit(1)
            Text(mix.subtitle)
                .font(KFont.bodySmall)
                .foregroundStyle(theme.colors.ink3)
                .lineLimit(2, reservesSpace: true)
        }
        .padding(6)
        .contentShape(Rectangle())
        .onTapGesture { AppGraph.shared.actions.openCollection(mix.asCollection()) }
        .contextMenu {
            let actions = AppGraph.shared.actions
            Button { actions.play(mix.tracks) } label: { Label("Play", systemImage: "play.fill") }
            Button { actions.shuffle(mix.tracks) } label: { Label("Shuffle", systemImage: "shuffle") }
            Button { actions.followMix(mix) } label: { Label("Keep updated", systemImage: "arrow.triangle.2.circlepath") }
            Button { actions.download(mix.tracks) } label: { Label("Download all", systemImage: "arrow.down.circle") }
        }
    }
}

/** Four covers in a square, or one when there aren't four. */
struct Mosaic: View {
    @Environment(\.kultr) private var theme
    let urls: [String]
    let label: String

    var body: some View {
        if urls.count < 4 {
            ArtworkFill(url: urls.first, label: label)
        } else {
            let shape = RoundedRectangle(cornerRadius: theme.radii.md, style: .continuous)
            Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    tile(urls[0])
                    tile(urls[1])
                }
                GridRow {
                    tile(urls[2])
                    tile(urls[3])
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(shape)
            .overlay(shape.strokeBorder(theme.colors.edge, lineWidth: 1))
            .accessibilityLabel(label)
        }
    }

    private func tile(_ url: String) -> some View {
        ArtworkFill(url: url, radius: 0, pixels: 200)
    }
}

/** A suggested song (Rediscover): long-press for the same choices as any suggestion. */
struct SuggestedTrackCard: View {
    @Environment(\.kultr) private var theme
    let track: Track
    let onTap: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ArtworkFill(url: track.artworkUrl, label: track.album ?? track.title)
            Spacer().frame(height: 8)
            Text(track.title)
                .font(KFont.bodyMedium.weight(.semibold))
                .foregroundStyle(theme.colors.ink)
                .lineLimit(1)
            Text(track.artist)
                .font(KFont.bodySmall)
                .foregroundStyle(theme.colors.ink3)
                .lineLimit(1)
        }
        .padding(6)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .contextMenu {
            SuggestionMenuItems(key: Keys.track(track.artist, track.title), artist: Keys.primary(track.artist), label: track.title) { return [track] }
        }
    }
}

/** "Block artist…": everyone on the song, to tick the ones never to hear again. */
struct BlockArtistSheet: View {
    @Environment(\.kultr) private var theme
    let track: Track
    let onDismiss: () -> Void
    @State private var chosen: Set<String> = []
    @State private var ready = false

    var body: some View {
        let people = Credits.people(track.artist, track.title)
        let c = theme.colors
        SheetScaffold(title: "Block which artist?") {
            VStack(alignment: .leading, spacing: 4) {
                Text("Their songs, and every song they're on, are hidden everywhere and skipped. Undo it in Settings → Recommendations → Blocked artists.")
                    .font(KFont.bodySmall)
                    .foregroundStyle(c.ink3)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 8)
                ForEach(people, id: \.self) { name in
                    let on = chosen.contains(name)
                    Button {
                        Haptics.select()
                        if on { chosen.remove(name) } else { chosen.insert(name) }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: on ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 22))
                                .foregroundStyle(on ? c.danger : c.ink3)
                            Text(name)
                                .font(KFont.bodyLarge)
                                .foregroundStyle(c.ink)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PressableStyle())
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
        } buttons: {
            TextButton("Cancel", color: c.ink2, action: onDismiss)
            TextButton("Block", color: c.danger, enabled: !chosen.isEmpty) {
                AppGraph.shared.actions.block(people.filter { chosen.contains($0) })
                onDismiss()
            }
        }
        .onAppear {
            guard !ready else { return }
            ready = true
            if let first = people.first { chosen = [first] }
        }
    }
}
