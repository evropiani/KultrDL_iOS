import KultrDLCore
import SwiftUI

/** Where the Library pager is, for the tab strip's underline: 2.5 is halfway between the third and fourth tab. */
@MainActor
@Observable
private final class PagerModel {
    var progress: CGFloat = 0
}

private struct PagerOffsetKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/**
 * Favourites, saved tracks, playlists, downloads and history as pages you
 * swipe through; the underline follows your finger.
 */
struct LibraryScreen: View {
    @Environment(\.kultr) private var theme
    let initialTab: LibraryTab
    var isRoot = false
    @State private var page: LibraryTab?
    @State private var pager = PagerModel()

    var body: some View {
        let current = page ?? initialTab
        let tabs = LibraryTab.allCases
        VStack(spacing: 0) {
            LibraryTabStrip(current: current, pager: pager) { tab in
                withAnimation(theme.spring ?? .linear(duration: 0)) { page = tab }
            }
            GeometryReader { outer in
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 0) {
                        ForEach(tabs, id: \.self) { tab in
                            pageView(tab)
                                .frame(width: outer.size.width, height: outer.size.height, alignment: .top)
                                .id(tab)
                        }
                    }
                    .scrollTargetLayout()
                    .background(
                        GeometryReader { inner in
                            Color.clear.preference(key: PagerOffsetKey.self, value: inner.frame(in: .named("pager")).minX)
                        }
                    )
                }
                .scrollIndicators(.hidden)
                .scrollTargetBehavior(.paging)
                .scrollPosition(id: $page)
                .coordinateSpace(name: "pager")
                .onPreferenceChange(PagerOffsetKey.self) { minX in
                    let width = max(1, outer.size.width)
                    pager.progress = min(CGFloat(tabs.count - 1), max(0, -minX / width))
                }
            }
        }
        .navigationTitle("Library")
        .navigationBarTitleDisplayMode(isRoot ? .large : .inline)
        .kultrScreen()
        .onAppear {
            if page == nil {
                page = initialTab
                pager.progress = CGFloat(tabs.firstIndex(of: initialTab) ?? 0)
            }
        }
        .onChange(of: page) { _, value in
            guard let value else { return }
            Haptics.select()
            let index = CGFloat(tabs.firstIndex(of: value) ?? 0)
            if abs(pager.progress - index) > 0.01 {
                withAnimation(theme.spring) { pager.progress = index }
            }
        }
    }

    @ViewBuilder
    private func pageView(_ tab: LibraryTab) -> some View {
        let graph = AppGraph.shared
        let library = graph.library
        let actions = graph.actions
        switch tab {
        case .favourites:
            TrackListPage(tracks: library.favorites, icon: "heart.fill", emptyTitle: "No favourites yet", emptyMessage: "Tap the heart on anything you love.", keyPrefix: "fav") { tracks in
                Pill("Download all", icon: "arrow.down.circle") { actions.download(tracks) }
            }
        case .saved:
            TrackListPage(tracks: library.saved, icon: "bookmark.fill", emptyTitle: "Nothing saved yet", emptyMessage: "Choose “Save to library” from a track's menu to keep it here.", keyPrefix: "saved") { tracks in
                Pill("Download all", icon: "arrow.down.circle") { actions.download(tracks) }
            }
        case .playlists:
            PlaylistsPage()
        case .downloaded:
            TrackListPage(tracks: library.downloaded.map { $0.track }, icon: "arrow.down.circle.fill", emptyTitle: "No downloads yet", emptyMessage: "Downloaded tracks play without a connection, and show in the Files app.", keyPrefix: "dl") { tracks in
                if !graph.servers.servers.isEmpty {
                    Pill("Send all…", icon: "icloud.and.arrow.up") { actions.sendToServer(tracks) }
                }
            }
        case .history:
            TrackListPage(tracks: library.history(200), icon: "clock.arrow.circlepath", emptyTitle: "Nothing played yet", emptyMessage: "What you play shows up here.", keyPrefix: "hist") { _ in
                Pill("Clear", icon: "trash") { library.clearHistory() }
            }
        }
    }
}

/** The page names, with an underline that slides between them as the pages move. */
private struct LibraryTabStrip: View {
    @Environment(\.kultr) private var theme
    let current: LibraryTab
    let pager: PagerModel
    let onPick: (LibraryTab) -> Void
    @State private var frames: [LibraryTab: CGRect] = [:]

    private struct FramesKey: PreferenceKey {
        static let defaultValue: [LibraryTab: CGRect] = [:]
        static func reduce(value: inout [LibraryTab: CGRect], nextValue: () -> [LibraryTab: CGRect]) {
            value.merge(nextValue()) { $1 }
        }
    }

    var body: some View {
        let c = theme.colors
        let tabs = LibraryTab.allCases
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(tabs, id: \.self) { entry in
                        let on = entry == current
                        Button { onPick(entry) } label: {
                            Text(entry.label)
                                .font(.system(size: 15, weight: on ? .semibold : .medium))
                                .foregroundStyle(on ? c.ink : c.ink3)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .fixedSize()
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(PressScaleStyle())
                        .background(
                            GeometryReader { g in
                                Color.clear.preference(key: FramesKey.self, value: [entry: g.frame(in: .named("strip"))])
                            }
                        )
                        .id(entry)
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }
                .padding(.horizontal, 6)
                .overlay(alignment: .topLeading) { underline(tabs) }
                .coordinateSpace(name: "strip")
                .onPreferenceChange(FramesKey.self) { frames = $0 }
            }
            .onChange(of: current) { _, value in
                withAnimation(theme.spring) { proxy.scrollTo(value, anchor: .center) }
            }
            .onAppear { proxy.scrollTo(current, anchor: .center) }
        }
        .overlay(alignment: .bottom) { Rule().opacity(0.6) }
    }

    /** Between the tabs the pager is between, as far along as it is. */
    private func underline(_ tabs: [LibraryTab]) -> some View {
        let progress = pager.progress
        let lower = min(tabs.count - 1, max(0, Int(progress.rounded(.down))))
        let upper = min(tabs.count - 1, lower + 1)
        let t = progress - CGFloat(lower)
        let a = frames[tabs[lower]] ?? .zero
        let b = frames[tabs[upper]] ?? a
        let x = a.minX + (b.minX - a.minX) * t + 12
        let width = max(0, a.width + (b.width - a.width) * t - 24)
        let y = max(a.maxY, b.maxY) - 3
        return Capsule()
            .fill(theme.colors.accent)
            .frame(width: width, height: 3)
            .offset(x: x, y: y)
            .opacity(frames.isEmpty ? 0 : 1)
            .allowsHitTesting(false)
    }
}

/** A list of tracks with Play and Shuffle on top, or a friendly empty state. */
private struct TrackListPage<Extra: View>: View {
    @Environment(\.kultr) private var theme
    let tracks: [Track]
    let icon: String
    let emptyTitle: String
    let emptyMessage: String
    let keyPrefix: String
    @ViewBuilder let extra: ([Track]) -> Extra

    var body: some View {
        let actions = AppGraph.shared.actions
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if tracks.isEmpty {
                    EmptyState(icon: icon, title: emptyTitle, message: emptyMessage)
                } else {
                    PillRow {
                        Pill("Play", icon: "play.fill", accent: true) { actions.play(tracks) }
                        Pill("Shuffle", icon: "shuffle") { actions.shuffle(tracks) }
                        extra(tracks)
                        Text(Format.count(tracks.count, "track"))
                            .font(KFont.bodySmall)
                            .foregroundStyle(theme.colors.ink3)
                    }
                    TrackRows(tracks: tracks, showSource: true, keyPrefix: keyPrefix) { actions.play(tracks, $0) }
                }
            }
            .padding(.bottom, 24)
        }
    }
}

private struct PlaylistsPage: View {
    @Environment(\.kultr) private var theme
    @State private var creating = false
    @State private var name = ""

    var body: some View {
        let graph = AppGraph.shared
        let library = graph.library
        let c = theme.colors
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                PillRow {
                    Pill("New playlist", icon: "plus", accent: true) {
                        name = ""
                        creating = true
                    }
                }
                if library.playlists.isEmpty {
                    EmptyState(
                        icon: "music.note.list",
                        title: "No playlists yet",
                        message: "Make one here, or save an album or playlist from any source with “Save as playlist”."
                    )
                }
                ForEach(library.playlistsByDate) { playlist in
                    HStack(spacing: 12) {
                        Artwork(url: playlist.artworkUrl ?? library.playlistTracks(playlist.id).first?.artworkUrl, size: 52, label: playlist.name)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(playlist.name).font(KFont.bodyLarge).foregroundStyle(c.ink).lineLimit(1)
                            Text(Format.count(playlist.trackIds.count, "track")).font(KFont.bodySmall).foregroundStyle(c.ink3)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(c.ink3)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .contentShape(Rectangle())
                    .onTapGesture { graph.actions.openPlaylist(playlist.id) }
                }
            }
            .padding(.bottom, 24)
        }
        .alert("New playlist", isPresented: $creating) {
            TextField("Name", text: $name)
            Button("Cancel", role: .cancel) {}
            Button("Create") {
                let id = library.createPlaylist(name)
                graph.actions.openPlaylist(id)
            }
        }
    }
}
