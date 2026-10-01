import SwiftUI
import UIKit

/**
 * The app: a tab per section, each with its own navigation stack, the mini
 * player floating above the tab bar, and the full-screen player over
 * everything — the design of Kultr for iOS.
 *
 * On iOS 26 the tab bar is the system's own liquid glass bar (with the lens
 * that follows your finger, the round search button beside it, and the mini
 * player as its accessory). Before iOS 26, KultrDL draws a floating glass
 * bar that behaves the same way.
 */
struct MainUI: View {
    @Environment(\.kultr) private var theme

    var body: some View {
        let ui = AppGraph.shared.ui
        let graph = AppGraph.shared
        let playerOpen = ui.playerOpen && graph.player.state.current != nil
        ZStack(alignment: .top) {
            Group {
                if #available(iOS 26.0, *) {
                    SystemTabs()
                } else {
                    FloatingTabs()
                }
            }
            .allowsHitTesting(!playerOpen)
            .accessibilityHidden(playerOpen)

            if let message = graph.messages.current {
                ToastView(message: message)
                    .padding(.top, 6)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(5)
                    .id(message.id)
            }

            if playerOpen {
                NowPlayingScreen()
                    .transition(.move(edge: .bottom))
                    .zIndex(20)
            }
        }
        .animation(theme.ease, value: graph.messages.current)
        .sheet(isPresented: Binding(get: { ui.addToPlaylist != nil }, set: { if !$0 { ui.addToPlaylist = nil } })) {
            AddToPlaylistSheet(tracks: ui.addToPlaylist ?? []) { ui.addToPlaylist = nil }
                .environment(\.kultr, theme)
                .presentationDetents([.medium, .large])
                .presentationBackground(.regularMaterial)
        }
        .sheet(isPresented: Binding(get: { ui.downloadAs != nil }, set: { if !$0 { ui.downloadAs = nil } })) {
            DownloadAsSheet(tracks: ui.downloadAs ?? []) { ui.downloadAs = nil }
                .environment(\.kultr, theme)
                .presentationDetents([.large])
                .presentationBackground(.regularMaterial)
        }
        .sheet(isPresented: Binding(get: { ui.sendTo != nil }, set: { if !$0 { ui.sendTo = nil } })) {
            SendToServerSheet(tracks: ui.sendTo ?? []) { ui.sendTo = nil }
                .environment(\.kultr, theme)
                .presentationDetents([.medium, .large])
                .presentationBackground(.regularMaterial)
        }
        .sheet(isPresented: Binding(get: { ui.blockArtist != nil }, set: { if !$0 { ui.blockArtist = nil } })) {
            if let track = ui.blockArtist {
                BlockArtistSheet(track: track) { ui.blockArtist = nil }
                    .environment(\.kultr, theme)
                    .presentationDetents([.medium])
                    .presentationBackground(.regularMaterial)
            }
        }
    }
}

// ------------------------------------------------------------ iOS 26 tabs --

@available(iOS 26.0, *)
private struct SystemTabs: View {
    @Environment(\.kultr) private var theme
    @FocusState private var searchFocused: Bool

    var body: some View {
        let graph = AppGraph.shared
        @Bindable var ui = graph.ui
        let selection = Binding<MainTab>(get: { ui.tab }, set: { graph.actions.selectTab($0) })
        TabView(selection: selection) {
            Tab(MainTab.home.label, systemImage: MainTab.home.icon, value: MainTab.home) { TabStack(tab: .home) }
            Tab(MainTab.library.label, systemImage: MainTab.library.icon, value: MainTab.library) { TabStack(tab: .library) }
            Tab(MainTab.downloads.label, systemImage: MainTab.downloads.icon, value: MainTab.downloads) { TabStack(tab: .downloads) }
                .badge(graph.downloads.activeCount)
            Tab(MainTab.settings.label, systemImage: MainTab.settings.icon, value: MainTab.settings) { TabStack(tab: .settings) }
            Tab(MainTab.search.label, systemImage: MainTab.search.icon, value: MainTab.search, role: .search) {
                // On the tab's stack rather than inside it: then the field lives in the
                // tab bar, growing out of the search button while the other tabs fold
                // into one, and rides up above the keyboard while you type.
                TabStack(tab: .search)
                    .searchable(text: $ui.searchQuery, prompt: "Songs, albums or a link")
                    .searchFocused($searchFocused)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .modifier(PlayerAccessory(enabled: graph.player.state.current != nil))
        .tint(theme.colors.accent)
        .onChange(of: ui.tab) { _, tab in
            // Choosing Search goes straight to typing, unless there is a search to come back to.
            guard tab == .search, ui.searchQuery.isEmpty else { return }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 350_000_000)
                if AppGraph.shared.ui.tab == .search { searchFocused = true }
            }
        }
    }
}

/** The mini player, riding on the tab bar as its accessory. */
@available(iOS 26.0, *)
private struct PlayerAccessory: ViewModifier {
    let enabled: Bool

    func body(content: Content) -> some View {
        if #available(iOS 26.1, *) {
            content.tabViewBottomAccessory(isEnabled: enabled) { AccessoryPlayer() }
        } else {
            content.tabViewBottomAccessory { AccessoryPlayer() }
        }
    }
}

@available(iOS 26.0, *)
private struct AccessoryPlayer: View {
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement

    var body: some View {
        // Inline: the tab bar has shrunk while scrolling and the player sits beside it.
        MiniPlayerContent(compact: placement == .inline)
    }
}

// ------------------------------------------------------- floating tab bar --

/** Before iOS 26: every tab's stack kept alive, with Kultr's own glass bar floating over them. */
private struct FloatingTabs: View {
    @State private var keyboardOpen = false

    var body: some View {
        let ui = AppGraph.shared.ui
        ZStack {
            ForEach(MainTab.allCases, id: \.self) { tab in
                let shown = ui.tab == tab
                TabStack(tab: tab)
                    .opacity(shown ? 1 : 0)
                    .allowsHitTesting(shown)
                    .accessibilityHidden(!shown)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // While typing in search, the bar stays and rides up above the keyboard;
            // any other keyboard gets the screen to itself.
            if !keyboardOpen || ui.tab == .search { FloatingChrome(typing: keyboardOpen) }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) { _ in keyboardOpen = true }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboardOpen = false }
    }
}

private struct FloatingChrome: View {
    @Environment(\.kultr) private var theme
    var typing = false
    @Namespace private var glass

    var body: some View {
        let graph = AppGraph.shared
        let ui = graph.ui
        let playing = graph.player.state.current != nil
        let searching = ui.tab == .search
        VStack(spacing: 8) {
            if !typing {
                if ui.tab != .downloads { DownloadIndicator(floating: true) }
                if playing {
                    MiniPlayerContent(compact: false)
                        .frame(height: 56)
                        .kultrGlass(Capsule(), interactive: true)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            HStack(spacing: 10) {
                if searching {
                    // The tabs fold into one round button that goes back where you came from...
                    CollapsedTabs(tab: ui.previousTab)
                        .matchedGeometryEffect(id: "tabs", in: glass)
                        .transition(.opacity)
                    // ...and the search button grows to the left into the field.
                    SearchBar()
                        .matchedGeometryEffect(id: "search", in: glass)
                        .transition(.opacity)
                } else {
                    LensTabBar()
                        .matchedGeometryEffect(id: "tabs", in: glass)
                        .transition(.opacity)
                    SearchOrb()
                        .matchedGeometryEffect(id: "search", in: glass)
                        .transition(.opacity)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, typing ? 8 : 2)
        .animation(theme.spring, value: playing)
        .animation(theme.spring, value: searching)
        .animation(theme.spring, value: typing)
    }
}

/** The tab bar folded into a single round button while searching: back to the tab you were on. */
private struct CollapsedTabs: View {
    @Environment(\.kultr) private var theme
    let tab: MainTab

    var body: some View {
        Button {
            Haptics.select()
            withAnimation(theme.spring) { AppGraph.shared.actions.selectTab(tab) }
        } label: {
            Image(systemName: tab.icon)
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(theme.colors.ink)
                .frame(width: 62, height: 62)
                .contentShape(Circle())
        }
        .buttonStyle(PressScaleStyle())
        .kultrGlass(Circle())
        .accessibilityLabel("Back to \(tab.label)")
    }
}

/** The search field the search button becomes: in the bar, within reach of your thumb. */
private struct SearchBar: View {
    @Environment(\.kultr) private var theme
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var ui = AppGraph.shared.ui
        let c = theme.colors
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(c.ink2)
            TextField("", text: $ui.searchQuery, prompt: Text("Songs, albums or a link").foregroundStyle(c.ink3))
                .focused($focused)
                .foregroundStyle(c.ink)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
                .onSubmit { focused = false }
            if !ui.searchQuery.isEmpty {
                Button {
                    ui.searchQuery = ""
                    focused = true
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(c.ink3)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear")
                .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 62)
        .frame(maxWidth: .infinity)
        .contentShape(Capsule())
        .onTapGesture { focused = true }
        .kultrGlass(Capsule())
        .animation(theme.ease, value: ui.searchQuery.isEmpty)
        .task {
            // Choosing Search goes straight to typing, unless there is a search to come back to.
            guard ui.searchQuery.isEmpty else { return }
            try? await Task.sleep(nanoseconds: 300_000_000)
            focused = true
        }
    }
}

/**
 * The tabs as one piece of glass, like the iOS 26 bar. The tab you are on
 * sits in a soft glass pill. Touch the bar and the pill lifts into a clear
 * lens, bigger than the bar, that follows your finger and magnifies the tabs
 * underneath it; let go and it shrinks back onto the tab below. A plain tap
 * works as usual.
 */
private struct LensTabBar: View {
    @Environment(\.kultr) private var theme
    @State private var fingerX: CGFloat? = LensTabBar.initialFinger
    @State private var lastSlot: Int?

    private static let initialFinger: CGFloat? = nil

    private static let height: CGFloat = 62

    var body: some View {
        let ui = AppGraph.shared.ui
        let tabs = MainTab.bar
        let c = theme.colors
        GeometryReader { proxy in
            let width = proxy.size.width
            let slot = width / CGFloat(tabs.count)
            let selected = tabs.firstIndex(of: ui.tab)
            let lifted = fingerX != nil
            let grow = lifted && !theme.reduceMotion
            let pillWidth = grow ? slot + 14 : slot - 8
            let pillHeight = grow ? Self.height + 16 : Self.height - 8
            let center: CGFloat? = fingerX.map { min(max($0, slot / 2), width - slot / 2) }
                ?? selected.map { slot * (CGFloat($0) + 0.5) }
            let lens = Capsule()
            ZStack(alignment: .topLeading) {
                if let center {
                    let frameX = center - pillWidth / 2
                    let frameY = (Self.height - pillHeight) / 2
                    // The pill behind the tab you are on; it goes clear while lifted.
                    lens
                        .fill(.white.opacity(lifted ? 0 : (c.dark ? 0.13 : 0.55)))
                        .overlay(lens.strokeBorder(.white.opacity(lifted ? 0 : (c.dark ? 0.12 : 0.6)), lineWidth: 0.5))
                        .frame(width: pillWidth, height: pillHeight)
                        .offset(x: frameX, y: frameY)
                }
                row(tabs, slot: slot, current: ui.tab, lensed: false)
                    .mask {
                        // Under the lens only the magnified copy shows.
                        Rectangle()
                            .overlay(alignment: .topLeading) {
                                if let center, lifted {
                                    lens
                                        .frame(width: pillWidth, height: pillHeight)
                                        .offset(x: center - pillWidth / 2, y: (Self.height - pillHeight) / 2)
                                        .blendMode(.destinationOut)
                                }
                            }
                            .compositingGroup()
                    }
                if let center {
                    let frameX = center - pillWidth / 2
                    let frameY = (Self.height - pillHeight) / 2
                    // Lifted: a clear lens over the tabs, magnifying what is under it.
                    ZStack(alignment: .topLeading) {
                        row(tabs, slot: slot, current: ui.tab, lensed: true)
                            .frame(width: width, height: Self.height)
                            .scaleEffect(grow ? 1.2 : 1, anchor: UnitPoint(x: center / width, y: 0.5))
                            .offset(x: -frameX, y: -frameY)
                    }
                    .frame(width: pillWidth, height: pillHeight, alignment: .topLeading)
                    .background(.white.opacity(c.dark ? 0.06 : 0.25))
                    .clipShape(lens)
                    .overlay(
                        lens.strokeBorder(
                            LinearGradient(
                                colors: [.white.opacity(0.9), .white.opacity(0.15), .white.opacity(0.5)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1.2
                        )
                    )
                    .overlay(lens.stroke(c.accent.opacity(0.25), lineWidth: 3).blur(radius: 3).clipShape(lens))
                    .shadow(color: .black.opacity(0.3), radius: 12, y: 6)
                    .offset(x: frameX, y: frameY)
                    .opacity(lifted ? 1 : 0)
                    .allowsHitTesting(false)
                }
            }
            .frame(width: width, height: Self.height, alignment: .topLeading)
            .contentShape(Capsule())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let index = min(tabs.count - 1, max(0, Int(value.location.x / slot)))
                        if lastSlot != index {
                            if lastSlot != nil { Haptics.select() }
                            lastSlot = index
                        }
                        withAnimation(theme.reduceMotion ? nil : .interactiveSpring(response: 0.3, dampingFraction: 0.72)) {
                            fingerX = value.location.x
                        }
                    }
                    .onEnded { value in
                        let index = min(tabs.count - 1, max(0, Int(value.location.x / slot)))
                        lastSlot = nil
                        if tabs[index] != ui.tab { Haptics.select() }
                        withAnimation(theme.reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.7)) {
                            fingerX = nil
                            AppGraph.shared.actions.selectTab(tabs[index])
                        }
                    }
            )
        }
        .frame(height: Self.height)
        .kultrGlass(Capsule())
    }

    /** The tab icons and names; under the lens they all light up in the accent. */
    private func row(_ tabs: [MainTab], slot: CGFloat, current: MainTab, lensed: Bool) -> some View {
        let c = theme.colors
        return HStack(spacing: 0) {
            ForEach(tabs, id: \.self) { tab in
                VStack(spacing: 3) {
                    Image(systemName: tab.icon)
                        .font(.system(size: 20, weight: .semibold))
                        .frame(height: 24)
                    Text(tab.label)
                        .font(.system(size: 10, weight: .semibold))
                }
                .foregroundStyle(lensed || tab == current ? c.accent : c.ink)
                .frame(width: slot, height: Self.height)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(tab == current ? [.isButton, .isSelected] : .isButton)
                .accessibilityAction { AppGraph.shared.actions.selectTab(tab) }
            }
        }
        .accessibilityHidden(lensed)
    }
}

private struct SearchOrb: View {
    @Environment(\.kultr) private var theme

    var body: some View {
        let ui = AppGraph.shared.ui
        let on = ui.tab == .search
        Button {
            Haptics.select()
            withAnimation(theme.spring) { AppGraph.shared.actions.selectTab(.search) }
        } label: {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(on ? theme.colors.accent : theme.colors.ink)
                .frame(width: 62, height: 62)
                .contentShape(Circle())
        }
        .buttonStyle(PressScaleStyle())
        .kultrGlass(Circle(), tint: on ? theme.colors.accent.opacity(0.35) : nil)
        .accessibilityLabel("Search")
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

// ------------------------------------------------------------ the stacks --

/** One tab: its start page and the pages opened from it. */
private struct TabStack: View {
    let tab: MainTab

    var body: some View {
        let ui = AppGraph.shared.ui
        NavigationStack(path: Binding(get: { ui.path(for: tab) }, set: { ui.setPath($0, for: tab) })) {
            TabRoot(tab: tab)
                .navigationDestination(for: Route.self) { RouteView(route: $0) }
        }
        .modifier(FloatingDownloads())
    }
}

/** On iOS 26 the download strip floats above the system tab bar, as one more piece of glass. */
private struct FloatingDownloads: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.safeAreaInset(edge: .bottom, spacing: 0) {
                if AppGraph.shared.ui.tab != .downloads {
                    DownloadIndicator(floating: true)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 6)
                }
            }
        } else {
            content
        }
    }
}

/** The start page of each tab. */
private struct TabRoot: View {
    let tab: MainTab

    var body: some View {
        switch tab {
        case .home: HomeScreen()
        case .library: LibraryScreen(initialTab: .favourites, isRoot: true)
        case .downloads: DownloadsScreen()
        case .search: SearchScreen()
        case .settings: SettingsScreen()
        }
    }
}

private struct RouteView: View {
    let route: Route

    var body: some View {
        switch route {
        case .library(let tab): LibraryScreen(initialTab: tab, isRoot: false)
        case .collection(let id): CollectionScreen(id: id)
        case .playlist(let id): PlaylistScreen(id: id)
        case .servers: ServersScreen()
        case .server(let id): ServerEditorScreen(id: id)
        case .navidrome: NavidromeScreen()
        case .blockedArtists: BlockedArtistsScreen()
        case .recommendations: RecommendationSettings()
        }
    }
}
