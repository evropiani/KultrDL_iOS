#if DEBUG
import Foundation
import KultrDLCore

/**
 * For CI's simulator screenshots only (Debug builds). With KULTRDL_SCREEN
 * set, KultrDL fills its library from real searches, opens that screen and
 * drops a marker file in Documents so the script knows when to take the
 * picture. The "downloads" screen runs a real download and conversion on
 * the way, and notes how it went in the marker.
 */
@MainActor
enum ScreenshotDriver {
    static func start() {
        let env = ProcessInfo.processInfo.environment
        guard let screen = env["KULTRDL_SCREEN"], !screen.isEmpty else { return }
        Task { @MainActor in
            let graph = AppGraph.shared
            let look: ThemeMode = env["KULTRDL_LOOK"] == "light" ? .light : .dark
            if graph.settings.settings.theme != look { graph.settings.update { $0.theme = look } }
            try? await Task.sleep(nanoseconds: 800_000_000)
            let note = await open(screen, graph)
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            mark(screen, note)
        }
    }

    private static func seed(_ graph: AppGraph) async -> [Track] {
        if graph.library.favorites.count >= 4 { return graph.library.favorites }
        guard let found = try? await graph.catalog.search(.youtubeMusic, "Daft Punk") else { return [] }
        let tracks = Array(found.tracks.prefix(8))
        graph.library.setFavorite(Array(tracks.prefix(5)), true)
        for track in tracks.suffix(4) { graph.library.markPlayed(track.id) }
        if graph.library.playlists.isEmpty, tracks.count > 3 {
            graph.library.createPlaylist("Late night", Array(tracks.prefix(4)))
        }
        return tracks
    }

    private static func open(_ screen: String, _ graph: AppGraph) async -> String {
        let actions = graph.actions
        switch screen {
        case "home":
            let tracks = await seed(graph)
            actions.selectTab(.home)
            return "ok \(tracks.count) seeded"
        case "search":
            graph.ui.searchQuery = ""
            actions.selectTab(.search)
        case "found":
            actions.search("Get Lucky")
            try? await Task.sleep(nanoseconds: 4_000_000_000)
        case "album":
            guard let found = try? await graph.catalog.search(.youtubeMusic, "Random Access Memories"), let album = found.collections.first else {
                return "no album found"
            }
            actions.selectTab(.home)
            actions.openCollection(album)
            try? await Task.sleep(nanoseconds: 4_000_000_000)
        case "player", "mini":
            let tracks = await seed(graph)
            guard !tracks.isEmpty else { return "nothing to play" }
            actions.selectTab(.home)
            actions.play(tracks, 0)
            for _ in 0..<40 {
                if graph.player.state.isPlaying { break }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            let state = graph.player.state
            if screen == "player" { actions.openPlayer() }
            return state.isPlaying ? "ok playing \(graph.player.positionMs()) ms" : "not playing (buffering \(state.buffering))"
        case "library":
            _ = await seed(graph)
            actions.selectTab(.library)
        case "downloads":
            let tracks = await seed(graph)
            actions.selectTab(.downloads)
            guard let track = tracks.first else { return "nothing to download" }
            if !graph.library.isDownloaded(track.id) {
                graph.downloads.enqueue([track], preset: DownloadPreset(format: .mp3, quality: .k320), destination: nil)
                for _ in 0..<150 {
                    let state = graph.downloads.job(track.id)?.state
                    if state == .done || state == .failed { break }
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }
            let job = graph.downloads.job(track.id)
            let stored = graph.library.stored(track.id)
            return "download \(job?.state.rawValue ?? "none"): \(job?.message ?? "") file=\(stored?.localPath ?? "-") size=\(stored?.localSize ?? 0)"
        case "settings":
            actions.selectTab(.settings)
        case "servers":
            actions.selectTab(.settings)
            graph.ui.setPath([.servers], for: .settings)
        default:
            actions.selectTab(.home)
        }
        return "ok"
    }

    private static func mark(_ screen: String, _ note: String) {
        let url = Storage.documents.appendingPathComponent(".kultrdl-ready-\(screen)")
        try? note.write(to: url, atomically: true, encoding: .utf8)
    }
}
#endif
