import Foundation
import KultrDLCore
import Observation
import SwiftUI
import UIKit

enum LibraryTab: String, CaseIterable, Hashable {
    case favourites, saved, playlists, downloaded, history

    var label: String {
        switch self {
        case .favourites: return "Favourites"
        case .saved: return "Saved"
        case .playlists: return "Playlists"
        case .downloaded: return "Downloaded"
        case .history: return "History"
        }
    }
}

/** The tabs. Search is last: it is the round button beside the bar. */
enum MainTab: String, CaseIterable, Hashable {
    case home, library, downloads, settings, search

    /** The tabs inside the bar; search sits beside it. */
    static let bar: [MainTab] = [.home, .library, .downloads, .settings]

    var label: String {
        switch self {
        case .home: return "Home"
        case .library: return "Library"
        case .downloads: return "Downloads"
        case .settings: return "Settings"
        case .search: return "Search"
        }
    }

    var icon: String {
        switch self {
        case .home: return "house.fill"
        case .library: return "square.stack.fill"
        case .downloads: return "arrow.down.circle.fill"
        case .settings: return "gearshape.fill"
        case .search: return "magnifyingglass"
        }
    }
}

enum Route: Hashable {
    case library(LibraryTab)
    case collection(String)
    case playlist(String)
    case servers
    /** A saved server's editor, or "new" to add one. */
    case server(String)
}

/** Navigation and the dialogs any screen can ask for; the root view shows them. */
@MainActor
@Observable
final class AppUI {
    var tab: MainTab = .home
    /** Each tab keeps its own stack of pages. */
    var paths: [MainTab: [Route]] = [:]
    var playerOpen = false
    /** What is typed in the search field, kept while you look at other tabs. */
    var searchQuery = ""
    /** The tab you came to search from; the folded tab bar goes back to it. */
    var previousTab: MainTab = .home
    var addToPlaylist: [Track]?
    var downloadAs: [Track]?
    var sendTo: [Track]?
    /** Albums and playlists opened from search, by id, for their pages. */
    @ObservationIgnored var collections: [String: TrackCollection] = [:]

    var path: [Route] {
        get { paths[tab] ?? [] }
        set { paths[tab] = newValue }
    }

    func path(for tab: MainTab) -> [Route] { paths[tab] ?? [] }

    func setPath(_ path: [Route], for tab: MainTab) { paths[tab] = path }
}

/**
 * Everything a screen can ask the app to do: navigate, play, change the
 * library, download. Screens reach it as `graph.actions`.
 */
@MainActor
final class AppActions {
    private unowned let graph: AppGraph

    init(graph: AppGraph) {
        self.graph = graph
    }

    private var ui: AppUI { graph.ui }
    private var messages: UiMessages { graph.messages }

    // --------------------------------------------------------- navigation --

    func navigate(_ route: Route) {
        if ui.playerOpen { closePlayer() }
        if ui.path.last == route { return }
        ui.path.append(route)
    }

    func back() {
        if !ui.path.isEmpty { ui.path.removeLast() }
    }

    func openPlayer() {
        withAnimation(.easeOut(duration: 0.32)) { ui.playerOpen = true }
    }

    func closePlayer() {
        withAnimation(.easeIn(duration: 0.26)) { ui.playerOpen = false }
    }

    /** Switch tabs; choosing the tab you are on goes back to its start page. */
    func selectTab(_ tab: MainTab) {
        if ui.tab == tab {
            ui.setPath([], for: tab)
        } else {
            if tab == .search { ui.previousTab = ui.tab }
            ui.tab = tab
        }
    }

    /** Search for [query] (or open it, when it is a link). */
    func search(_ query: String) {
        if ui.playerOpen { closePlayer() }
        ui.searchQuery = query
        if ui.tab != .search { selectTab(.search) }
        ui.setPath([], for: .search)
    }

    /** kultrdl://open?url=… from Shortcuts or the share sheet, or a link handed to the app. */
    func open(_ url: URL) {
        var text = url.absoluteString
        if url.scheme?.lowercased() == "kultrdl" {
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            text = items.first { $0.name == "url" || $0.name == "q" || $0.name == "text" }?.value ?? ""
        }
        let link = Links.find(text) ?? text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !link.isEmpty else { return }
        search(link)
    }

    func openCollection(_ collection: TrackCollection) {
        ui.collections[collection.id] = collection
        navigate(.collection(collection.id))
    }

    func openPlaylist(_ id: String) { navigate(.playlist(id)) }

    func openLibrary(_ tab: LibraryTab) {
        if ui.tab == .library {
            ui.setPath([], for: .library)
        }
        navigate(.library(tab))
    }

    func openDownloads() {
        if ui.playerOpen { closePlayer() }
        selectTabKeeping(.downloads)
    }

    private func selectTabKeeping(_ tab: MainTab) {
        if ui.tab != tab {
            if tab == .search { ui.previousTab = ui.tab }
            ui.tab = tab
        }
    }

    func openInBrowser(_ link: String?) {
        guard let link, let url = URL(string: link) else { return }
        UIApplication.shared.open(url)
    }

    // ------------------------------------------------------------ playing --

    func play(_ tracks: [Track], _ index: Int = 0) {
        graph.player.play(tracks, startIndex: index)
    }

    func shuffle(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        graph.player.play(tracks, shuffle: true)
    }

    func playNext(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        graph.player.playNext(tracks)
        messages.show(tracks.count == 1 ? "“\(tracks[0].title)” plays next" : "\(tracks.count) tracks play next")
    }

    func enqueue(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        graph.player.enqueue(tracks)
        messages.show(tracks.count == 1 ? "Added “\(tracks[0].title)” to the queue" : "Added \(tracks.count) tracks to the queue")
    }

    // ------------------------------------------------------------ library --

    func toggleFavorite(_ track: Track) {
        setFavorite([track], !graph.library.isFavorite(track.id))
    }

    func setFavorite(_ tracks: [Track], _ on: Bool) {
        Haptics.tap()
        graph.library.setFavorite(tracks, on)
        if on && tracks.count > 1 { messages.success("Added \(tracks.count) tracks to favourites") }
    }

    func toggleSaved(_ track: Track) {
        setSaved([track], !graph.library.isSaved(track.id))
    }

    func setSaved(_ tracks: [Track], _ on: Bool) {
        graph.library.setSaved(tracks, on)
        messages.show(
            !on ? "Removed from your library" : tracks.count == 1 ? "Saved to your library" : "Saved \(tracks.count) tracks to your library",
            .success
        )
    }

    func addToPlaylist(_ tracks: [Track]) {
        if !tracks.isEmpty { ui.addToPlaylist = tracks }
    }

    func saveAsPlaylist(_ collection: TrackCollection) {
        graph.library.createPlaylist(collection.title, collection.tracks, sourceUrl: collection.pageUrl, artworkUrl: collection.artworkUrl)
        messages.success("Saved “\(collection.title)” to your playlists")
    }

    // ---------------------------------------------------------- downloads --

    /** Download with the default format, or ask when that is the setting. */
    func download(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        let s = graph.settings.settings
        if s.askEachTime {
            ui.downloadAs = tracks
        } else {
            download(tracks, preset: s.download, destination: s.destination)
        }
    }

    func downloadAs(_ tracks: [Track]) {
        if !tracks.isEmpty { ui.downloadAs = tracks }
    }

    func download(_ tracks: [Track], preset: DownloadPreset, destination: Destination?) {
        let server = destination.flatMap { graph.servers.get($0.serverId) }
        graph.downloads.enqueue(tracks, preset: preset, destination: destination)
        let what = tracks.count == 1 ? "“\(tracks[0].title)”" : "\(tracks.count) tracks"
        messages.show("Downloading \(what) · \(preset.label)" + (server.map { " → \($0.name)" } ?? ""))
    }

    /** Asks which server folder, then sends tracks that are on the phone there. */
    func sendToServer(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        if graph.servers.servers.isEmpty {
            navigate(.server("new"))
        } else {
            ui.sendTo = tracks
        }
    }

    func send(_ tracks: [Track], to destination: Destination) {
        let count = graph.downloads.send(tracks, to: destination)
        let name = graph.servers.get(destination.serverId)?.name ?? "the server"
        if count == 0 {
            messages.show("Nothing to send: download it to the phone first")
        } else if count == 1 && tracks.count == 1 {
            messages.show("Sending “\(tracks[0].title)” to \(name)")
        } else {
            messages.show("Sending \(Format.count(count, "track")) to \(name)")
        }
    }

    func removeDownload(_ track: Track) {
        graph.downloads.deleteFile(track.id)
        messages.show("Removed the download of “\(track.title)”")
    }

    func rematch(_ track: Track) {
        graph.resolver.rematch(track.id)
        messages.show("“\(track.title)” will be matched again next time it plays")
    }
}
