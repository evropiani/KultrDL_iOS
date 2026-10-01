import KultrDLCore
import SwiftUI

private enum PlayerTab: CaseIterable {
    case queue, details

    var label: String { self == .queue ? "Up next" : "Details" }
}

private struct TopOffsetKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/** The full-screen player. Pull it down (from the top of its list) to close it. */
struct NowPlayingScreen: View {
    @Environment(\.kultr) private var theme
    @State private var tab: PlayerTab = .queue
    @State private var pull: CGFloat = 0
    @State private var topOffset: CGFloat = 0
    @State private var pulling = false

    var body: some View {
        let graph = AppGraph.shared
        let state = graph.player.state
        ZStack {
            if let track = state.current {
                ScrollView {
                    VStack(spacing: 0) {
                        PlayerTopBar(track: track, onClose: close)
                            .background(
                                GeometryReader { proxy in
                                    Color.clear.preference(key: TopOffsetKey.self, value: proxy.frame(in: .named("player")).minY)
                                }
                            )
                        header(track, state: state)
                        Picker("Show", selection: Binding(get: { tab }, set: { value in withAnimation(theme.ease) { tab = value } })) {
                            ForEach(PlayerTab.allCases, id: \.self) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .padding(.horizontal, 20)
                        .padding(.top, 18)
                        .padding(.bottom, 12)
                        switch tab {
                        case .queue: QueueList(state: state)
                        case .details: DetailsPanel(track: track)
                        }
                    }
                    .padding(.bottom, 32)
                }
                .coordinateSpace(name: "player")
                // Once the pull has started the list stops scrolling, so the whole
                // card moves with your finger instead of the list sliding inside it.
                .scrollDisabled(pulling)
                .onPreferenceChange(TopOffsetKey.self) { topOffset = $0 }
                .simultaneousGesture(
                    DragGesture(minimumDistance: 15, coordinateSpace: .global)
                        .onChanged { value in
                            if !pulling {
                                guard value.translation.height > 0, abs(value.translation.height) > abs(value.translation.width), topOffset >= -2 else { return }
                                pulling = true
                            }
                            pull = max(0, value.translation.height)
                        }
                        .onEnded { value in
                            guard pulling else { return }
                            pulling = false
                            if pull > 140 || value.predictedEndTranslation.height > 420 {
                                close()
                            } else {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { pull = 0 }
                            }
                        }
                )
            } else {
                VStack {
                    HStack {
                        IconButton(icon: "chevron.down", label: "Close player", action: close)
                        Spacer()
                    }
                    Spacer()
                    Text("Nothing is playing.").foregroundStyle(theme.colors.ink2)
                    Spacer()
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { ArtworkBackdrop(artworkUrl: state.current?.artworkUrl) }
        .mask {
            RoundedRectangle(cornerRadius: pull > 0 ? 44 : 0, style: .continuous).ignoresSafeArea()
        }
        .shadow(color: .black.opacity(pull > 0 ? 0.35 : 0), radius: 24, y: -4)
        .scaleEffect(1 - min(1, pull / 900) * 0.08, anchor: .top)
        .offset(y: pull)
        .background {
            Color.black
                .opacity(0.35 * Double(1 - min(1, pull / 500)))
                .ignoresSafeArea()
                .allowsHitTesting(false)
        }
    }

    private func close() {
        AppGraph.shared.actions.closePlayer()
    }

    @ViewBuilder
    private func header(_ track: Track, state: PlayerUiState) -> some View {
        let graph = AppGraph.shared
        let c = theme.colors
        let stored = graph.library.stored(track.id)
        VStack(spacing: 0) {
            SwipeArtwork(track: track)
                .padding(.top, 8)
            Text(track.title)
                .font(KFont.headlineSmall)
                .foregroundStyle(c.ink)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.top, 20)
            Text([track.artist.isEmpty ? nil : track.artist, track.album].compactMap { $0 }.joined(separator: " — "))
                .font(KFont.bodyLarge)
                .foregroundStyle(c.ink2)
                .lineLimit(1)
                .padding(.top, 4)
            HStack(spacing: 6) {
                Tag(track.source.label)
                if let year = track.year { Tag("\(year)") }
                if let format = stored?.localFormat, graph.resolver.local(track.id) != nil {
                    Tag(format)
                } else {
                    Tag("Streaming")
                }
            }
            .padding(.top, 10)
            PositionReader { position in
                Scrubber(positionMs: position, durationMs: state.durationMs, onSeek: { graph.player.seekTo($0) })
            }
            .padding(.top, 16)
            Transport(state: state, track: track)
        }
        .padding(.horizontal, 20)
    }
}

private struct PlayerTopBar: View {
    @Environment(\.kultr) private var theme
    let track: Track
    let onClose: () -> Void

    var body: some View {
        let graph = AppGraph.shared
        let actions = graph.actions
        let saved = graph.library.isSaved(track.id)
        VStack(spacing: 6) {
            // The grabber says "pull me down", as on any sheet.
            Capsule()
                .fill(theme.colors.ink3.opacity(0.6))
                .frame(width: 38, height: 5)
                .padding(.top, 6)
                .accessibilityHidden(true)
            HStack(spacing: 8) {
                GlassIconButton(icon: "chevron.down", size: 40, label: "Close player", action: onClose)
                Eyebrow(track.album ?? "Now playing")
                    .frame(maxWidth: .infinity, alignment: .leading)
                CastButton(tint: theme.colors.ink)
                Menu {
                    Button { actions.download([track]) } label: { Label("Download", systemImage: "arrow.down.circle") }
                    Button { actions.downloadAs([track]) } label: { Label("Download as…", systemImage: "slider.horizontal.3") }
                    Button { actions.addToPlaylist([track]) } label: { Label("Add to playlist…", systemImage: "text.badge.plus") }
                    Button { actions.setSaved([track], !saved) } label: {
                        Label(saved ? "Remove from library" : "Save to library", systemImage: saved ? "bookmark.slash" : "bookmark")
                    }
                    if let page = track.pageUrl, let url = URL(string: page) {
                        ShareLink(item: url, subject: Text(track.title), message: Text("\(track.artist) – \(track.title)")) {
                            Label("Share", systemImage: "square.and.arrow.up")
                        }
                    }
                    Button(role: .destructive) {
                        graph.player.stop()
                        onClose()
                    } label: { Label("Stop and clear queue", systemImage: "xmark") }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(theme.colors.ink)
                        .frame(width: 40, height: 40)
                        .kultrGlass(Circle(), interactive: true, shadow: false)
                }
                .accessibilityLabel("More")
            }
            .padding(.horizontal, 12)
        }
    }
}

/** The big artwork; swipe it sideways to skip. */
private struct SwipeArtwork: View {
    @Environment(\.kultr) private var theme
    let track: Track
    @State private var drag: CGFloat = 0

    var body: some View {
        ArtworkFill(url: track.artworkUrl, radius: theme.radii.xl, label: track.album ?? track.title, pixels: 800)
            .shadow(color: .black.opacity(0.35), radius: 24, y: 10)
            .padding(.horizontal, 12)
            .offset(x: drag)
            .rotationEffect(.degrees(Double(drag) / 60))
            .gesture(
                DragGesture(minimumDistance: 20)
                    .onChanged { value in
                        if abs(value.translation.width) > abs(value.translation.height) { drag = value.translation.width }
                    }
                    .onEnded { _ in
                        let player = AppGraph.shared.player
                        if drag > 90 { player.previous() } else if drag < -90 { player.next() }
                        withAnimation(.spring()) { drag = 0 }
                    }
            )
            .onChange(of: track.id) { _, _ in drag = 0 }
    }
}

private struct Transport: View {
    @Environment(\.kultr) private var theme
    let state: PlayerUiState
    let track: Track

    var body: some View {
        let graph = AppGraph.shared
        let player = graph.player
        let c = theme.colors
        let favorite = graph.library.isFavorite(track.id)
        VStack(spacing: 0) {
            HStack {
                IconButton(icon: "shuffle", tint: state.shuffle ? c.accent : c.ink2, label: "Shuffle") { player.setShuffle(!state.shuffle) }
                Spacer()
                IconButton(icon: "backward.end.fill", size: 30, label: "Previous") { player.previous() }
                Spacer()
                Button {
                    Haptics.tap()
                    player.toggle()
                } label: {
                    ZStack {
                        if state.buffering && state.playWhenReady {
                            ProgressView().tint(c.ink).controlSize(.large)
                        } else {
                            Image(systemName: state.playWhenReady && !state.ended ? "pause.fill" : "play.fill")
                                .font(.system(size: 46, weight: .bold))
                                .foregroundStyle(c.ink)
                                .contentTransition(.symbolEffect(.replace))
                        }
                    }
                    .frame(width: 84, height: 84)
                    .contentShape(Circle())
                }
                .buttonStyle(PressScaleStyle())
                .accessibilityLabel(state.playWhenReady ? "Pause" : "Play")
                Spacer()
                IconButton(icon: "forward.end.fill", size: 30, label: "Next") { player.next() }
                Spacer()
                IconButton(
                    icon: state.repeatMode == .one ? "repeat.1" : "repeat",
                    tint: state.repeatMode != .off ? c.accent : c.ink2,
                    label: "Repeat"
                ) { player.cycleRepeat() }
            }
            .padding(.top, 4)
            HStack(spacing: 8) {
                IconButton(
                    icon: favorite ? "heart.fill" : "heart",
                    tint: favorite ? c.accent : c.ink2,
                    label: favorite ? "Remove from favourites" : "Add to favourites"
                ) { graph.actions.toggleFavorite(track) }
                IconButton(icon: "text.badge.plus", tint: c.ink2, label: "Add to playlist") { graph.actions.addToPlaylist([track]) }
                IconButton(
                    icon: graph.library.isDownloaded(track.id) ? "arrow.down.circle.fill" : "arrow.down.circle",
                    tint: graph.library.isDownloaded(track.id) ? c.accent : c.ink2,
                    label: "Download"
                ) { graph.actions.download([track]) }
            }
        }
    }
}

// ------------------------------------------------------------------ queue --

private struct QueueList: View {
    @Environment(\.kultr) private var theme
    let state: PlayerUiState

    var body: some View {
        let upNext = state.upNext
        LazyVStack(spacing: 0) {
            HStack {
                Text(upNext.isEmpty ? "Nothing queued after this track." : "\(upNext.count) up next")
                    .font(KFont.bodyMedium)
                    .foregroundStyle(theme.colors.ink3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !upNext.isEmpty {
                    IconButton(icon: "trash", tint: theme.colors.ink2, size: 18, label: "Clear up next") {
                        AppGraph.shared.player.clearUpcoming()
                    }
                }
            }
            .padding(.leading, 20)
            .padding(.trailing, 4)
            .padding(.vertical, 4)
            ForEach(upNext) { entry in
                QueueRow(index: entry.index, track: entry.track, size: state.queue.count, currentIndex: state.index)
            }
        }
    }
}

private struct QueueRow: View {
    @Environment(\.kultr) private var theme
    let index: Int
    let track: Track
    let size: Int
    let currentIndex: Int
    @State private var drag: CGFloat = 0

    private static let rowHeight: CGFloat = 64

    var body: some View {
        let player = AppGraph.shared.player
        let c = theme.colors
        HStack(spacing: 0) {
            Artwork(url: track.artworkUrl, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title).font(KFont.bodyLarge.weight(.medium)).foregroundStyle(c.ink).lineLimit(1)
                Text(track.artist).font(KFont.bodySmall).foregroundStyle(c.ink3).lineLimit(1)
            }
            .padding(.leading, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            if let duration = track.durationMs {
                Text(Format.duration(duration)).font(.system(size: 12).monospacedDigit()).foregroundStyle(c.ink3)
            }
            Menu {
                Button("Play now") { player.choose(index) }
                Button("Move to top") {
                    let target = currentIndex + 1
                    if target >= 0 && target < size { player.move(index, target) }
                }
                Button("Remove from queue", role: .destructive) { player.remove(index) }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(c.ink3)
                    .frame(width: 40, height: 44)
            }
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(c.ink3)
                .frame(width: 40, height: 44)
                .contentShape(Rectangle())
                .highPriorityGesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { drag = $0.translation.height }
                        .onEnded { _ in
                            let steps = Int((drag / Self.rowHeight).rounded())
                            let target = min(max(index + steps, currentIndex + 1), size - 1)
                            drag = 0
                            if target != index { player.move(index, target) }
                        }
                )
                .accessibilityLabel("Drag to reorder")
        }
        .padding(.leading, 20)
        .padding(.trailing, 4)
        .frame(height: Self.rowHeight)
        .background(drag != 0 ? c.elevated : .clear)
        .shadow(color: .black.opacity(drag != 0 ? 0.3 : 0), radius: 8)
        .offset(y: drag)
        .zIndex(drag != 0 ? 1 : 0)
        .contentShape(Rectangle())
        .onTapGesture { player.choose(index) }
    }
}

// ---------------------------------------------------------------- details --

private struct DetailsPanel: View {
    @Environment(\.kultr) private var theme
    let track: Track

    var body: some View {
        let graph = AppGraph.shared
        let c = theme.colors
        let stored = graph.library.stored(track.id)
        let played = stored?.matchedUrl ?? track.streamUrl
        GlassPanel {
            VStack(alignment: .leading, spacing: 10) {
                detail("Source", track.source.label)
                if track.needsMatch {
                    detail("Plays from", played != nil ? "The matching recording on YouTube Music" : "Matched when it first plays")
                }
                if let format = stored?.localFormat {
                    detail("Downloaded", format + (stored?.localSize.map { " · " + Format.bytes($0) } ?? ""))
                }
                if let genre = track.genre { detail("Genre", genre) }
                if let isrc = track.isrc { detail("ISRC", isrc) }
                if let count = stored?.playCount, count > 0 { detail("Played", Format.count(count, "time")) }
                HStack(spacing: 4) {
                    if track.pageUrl != nil {
                        IconButton(icon: "safari", tint: c.ink2, label: "Open on \(track.source.label)") { graph.actions.openInBrowser(track.pageUrl) }
                    }
                    if let played, played != track.pageUrl {
                        IconButton(icon: "play.rectangle", tint: c.ink2, label: "Open the recording") { graph.actions.openInBrowser(played) }
                    }
                    if track.needsMatch {
                        IconButton(icon: "arrow.triangle.2.circlepath", tint: c.ink2, label: "Find another recording") { graph.actions.rematch(track) }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
    }

    private func detail(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label).font(KFont.bodyMedium).foregroundStyle(theme.colors.ink3).frame(width: 96, alignment: .leading)
            Text(value).font(KFont.bodyMedium).foregroundStyle(theme.colors.ink).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
