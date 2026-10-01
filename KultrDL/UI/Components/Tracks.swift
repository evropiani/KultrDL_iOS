import KultrDLCore
import SwiftUI

/** An extra entry for a track's menu, for screen-specific actions. */
struct MenuAction: Identifiable {
    let id = UUID()
    let label: String
    let icon: String
    var destructive = false
    let action: () -> Void
}

/** The menu entries for one track; used by the "…" button and the long-press menu. */
struct TrackMenuItems: View {
    let track: Track
    var extra: [MenuAction] = []

    var body: some View {
        let graph = AppGraph.shared
        let actions = graph.actions
        let stored = graph.library.stored(track.id)
        Button { actions.play([track]) } label: { Label("Play", systemImage: "play.fill") }
        Button { actions.playNext([track]) } label: { Label("Play next", systemImage: "text.line.first.and.arrowtriangle.forward") }
        Button { actions.enqueue([track]) } label: { Label("Add to queue", systemImage: "text.line.last.and.arrowtriangle.forward") }
        Divider()
        if stored?.favorite == true {
            Button { actions.setFavorite([track], false) } label: { Label("Remove from favourites", systemImage: "heart.slash") }
        } else {
            Button { actions.setFavorite([track], true) } label: { Label("Add to favourites", systemImage: "heart") }
        }
        if stored?.saved == true {
            Button { actions.setSaved([track], false) } label: { Label("Remove from library", systemImage: "bookmark.slash") }
        } else {
            Button { actions.setSaved([track], true) } label: { Label("Save to library", systemImage: "bookmark") }
        }
        Button { actions.addToPlaylist([track]) } label: { Label("Add to playlist…", systemImage: "text.badge.plus") }
        Divider()
        Button { actions.download([track]) } label: { Label("Download", systemImage: "arrow.down.circle") }
        Button { actions.downloadAs([track]) } label: { Label("Download as…", systemImage: "slider.horizontal.3") }
        if actions.canDownloadToNavidrome && track.source != .navidrome {
            Button { actions.downloadToNavidrome([track]) } label: { Label("Download to Navidrome", systemImage: "externaldrive.badge.icloud") }
        }
        if stored?.localPath != nil {
            if !graph.servers.servers.isEmpty {
                Button { actions.sendToServer([track]) } label: { Label("Send to server…", systemImage: "icloud.and.arrow.up") }
            }
            Button(role: .destructive) { actions.removeDownload(track) } label: { Label("Remove download", systemImage: "trash") }
        }
        if track.needsMatch {
            Button { actions.rematch(track) } label: { Label("Find another recording", systemImage: "arrow.triangle.2.circlepath") }
        }
        Button(role: .destructive) { actions.blockArtist(track) } label: { Label("Block artist…", systemImage: "nosign") }
        if let page = track.pageUrl, let url = URL(string: page) {
            Divider()
            Button { actions.openInBrowser(page) } label: { Label("Open on \(track.source.label)", systemImage: "safari") }
            ShareLink(item: url, subject: Text(track.title), message: Text("\(track.artist) – \(track.title)")) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
        }
        if !extra.isEmpty {
            Divider()
            ForEach(extra) { item in
                Button(role: item.destructive ? .destructive : nil, action: item.action) { Label(item.label, systemImage: item.icon) }
            }
        }
    }
}

/** A "…" button that opens a track's menu. */
struct TrackMenuButton: View {
    @Environment(\.kultr) private var theme
    let track: Track
    var extra: [MenuAction] = []

    var body: some View {
        Menu {
            TrackMenuItems(track: track, extra: extra)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(theme.colors.ink3)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("More for \(track.title)")
    }
}

/** Downloading, waiting, or on the phone: the little mark on a track row. */
private struct DownloadMark: View {
    @Environment(\.kultr) private var theme
    let trackId: String

    var body: some View {
        let graph = AppGraph.shared
        let c = theme.colors
        let job = graph.downloads.job(trackId)
        if job?.state == .running {
            let fraction = graph.downloads.live?.trackId == trackId ? graph.downloads.live?.fraction ?? 0 : 0
            ZStack {
                Circle().stroke(c.ink4, lineWidth: 2)
                Circle().trim(from: 0, to: max(0.03, fraction)).stroke(c.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round)).rotationEffect(.degrees(-90))
            }
            .frame(width: 15, height: 15)
            .padding(.trailing, 7)
            .accessibilityLabel("Downloading")
        } else if job?.state == .queued {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 13))
                .foregroundStyle(c.ink3)
                .padding(.trailing, 6)
                .accessibilityLabel("Waiting to download")
        } else if graph.library.isDownloaded(trackId) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 13))
                .foregroundStyle(c.accent)
                .padding(.trailing, 6)
                .accessibilityLabel("Downloaded")
        }
    }
}

struct TrackRow: View {
    @Environment(\.kultr) private var theme
    let track: Track
    var number: Int?
    var isCurrent = false
    var showSource = false
    var extra: [MenuAction] = []
    let onTap: () -> Void

    var body: some View {
        let c = theme.colors
        let favorite = AppGraph.shared.library.isFavorite(track.id)
        HStack(spacing: 0) {
            if let number {
                ZStack {
                    if isCurrent {
                        Image(systemName: "waveform").font(.system(size: 15)).foregroundStyle(c.accent)
                    } else {
                        Text("\(number)").font(KFont.bodyMedium).foregroundStyle(c.ink3)
                    }
                }
                .frame(width: 32)
            } else {
                ZStack {
                    Artwork(url: track.artworkUrl, size: 46)
                    if isCurrent {
                        RoundedRectangle(cornerRadius: theme.radii.xs, style: .continuous).fill(.black.opacity(0.45))
                        Image(systemName: "waveform").foregroundStyle(c.accent)
                    }
                }
                .frame(width: 46, height: 46)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(KFont.bodyLarge.weight(.medium))
                    .foregroundStyle(isCurrent ? c.accent : c.ink)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    if track.explicit {
                        Text("E")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(c.background)
                            .padding(.horizontal, 4)
                            .background(RoundedRectangle(cornerRadius: 3).fill(c.ink3))
                    }
                    let sub = [track.artist.isEmpty ? nil : track.artist, number == nil ? track.album : nil, showSource ? track.source.label : nil]
                        .compactMap { $0 }
                        .joined(separator: " · ")
                    Text(sub)
                        .font(KFont.bodySmall)
                        .foregroundStyle(c.ink3)
                        .lineLimit(1)
                }
            }
            .padding(.leading, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            DownloadMark(trackId: track.id)
            if favorite {
                Image(systemName: "heart.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(c.accent)
                    .padding(.trailing, 6)
            }
            if let duration = track.durationMs {
                Text(Format.duration(duration))
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(c.ink3)
            }
            TrackMenuButton(track: track, extra: extra)
        }
        .padding(.leading, 16)
        .padding(.trailing, 4)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .contextMenu { TrackMenuItems(track: track, extra: extra) }
    }
}

/** Track rows for a list; tapping plays the list from that track. */
struct TrackRows: View {
    let tracks: [Track]
    var numbered = false
    var showSource = false
    var keyPrefix = "track"
    var extra: (Int, Track) -> [MenuAction] = { _, _ in [] }
    let onPlay: (Int) -> Void

    var body: some View {
        let playing = AppGraph.shared.player.state.current?.id
        let blocks = AppGraph.shared.taste.blocks
        // Songs by blocked artists keep their place (for playlist positions) but aren't shown; play skips them.
        ForEach(Array(tracks.enumerated()).filter { !blocks.blocks($0.element) }, id: \.offset) { index, track in
            TrackRow(
                track: track,
                number: numbered ? (track.trackNumber ?? index + 1) : nil,
                isCurrent: track.id == playing,
                showSource: showSource,
                extra: extra(index, track),
                onTap: { onPlay(index) }
            )
            .id("\(keyPrefix):\(index):\(track.id)")
        }
    }
}

/** A track as a card on a shelf. */
struct TrackCard: View {
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
        .contextMenu { TrackMenuItems(track: track) }
    }
}

/** An album or playlist as a card. */
struct CollectionCard: View {
    @Environment(\.kultr) private var theme
    let title: String
    var subtitle: String?
    var artworkUrl: String?
    let onTap: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ArtworkFill(url: artworkUrl, label: title)
            Spacer().frame(height: 8)
            Text(title)
                .font(KFont.bodyMedium.weight(.semibold))
                .foregroundStyle(theme.colors.ink)
                .lineLimit(1)
            Text(subtitle ?? "")
                .font(KFont.bodySmall)
                .foregroundStyle(theme.colors.ink3)
                .lineLimit(1)
        }
        .padding(6)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }
}

/** A round icon button, like Material's IconButton. */
struct IconButton: View {
    @Environment(\.kultr) private var theme
    let icon: String
    var tint: Color?
    var size: CGFloat = 20
    var label = ""
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(tint ?? theme.colors.ink)
                .frame(width: max(44, size * 1.8), height: max(44, size * 1.8))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(label)
    }
}

/** A row of pills that scrolls sideways. */
struct PillRow<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) { content }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
        }
    }
}

/** Segmented choice between a few options, scrolling when they don't fit. */
struct Chips<Option: Hashable>: View {
    @Environment(\.kultr) private var theme
    let options: [Option]
    let selected: Option
    let label: (Option) -> String
    let onSelect: (Option) -> Void

    var body: some View {
        let c = theme.colors
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(options, id: \.self) { option in
                    let on = option == selected
                    Button {
                        Haptics.select()
                        onSelect(option)
                    } label: {
                        Text(label(option))
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(on ? c.onAccent : c.ink2)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(Capsule().fill(on ? c.accent : c.glass))
                            .overlay(Capsule().strokeBorder(on ? Color.clear : c.edge, lineWidth: 1))
                    }
                    .buttonStyle(PressScaleStyle())
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
        }
    }
}
