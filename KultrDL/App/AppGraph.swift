import Foundation
import KultrDLCore

/**
 * The app's object graph, built once and reached through [AppGraph.shared]
 * from the player, background work and the interface.
 */
@MainActor
final class AppGraph {
    static let shared = AppGraph()

    let settings = SettingsStore()
    let messages = UiMessages()
    let network = NetworkMonitor()
    let library = LibraryStore()
    let servers = ServerStore()
    let taste = TasteStore()
    let navidrome = NavidromeStore()
    let listening = ListeningStore()
    let ui = AppUI()
    let http = Http()
    let catalog: Catalog
    let engine: Engine
    let finder: StreamFinder
    // Lazy only so they can be handed `self`; all are created in init.
    private(set) lazy var resolver = StreamResolver(graph: self)
    private(set) lazy var downloads = Downloads(graph: self)
    private(set) lazy var player = PlayerController(graph: self)
    private(set) lazy var actions = AppActions(graph: self)
    private(set) lazy var recommender = Recommender(graph: self)

    private init() {
        let shared = settings.shared
        catalog = Catalog(
            http: http,
            country: {
                let chosen = shared.value.country.trimmingCharacters(in: .whitespaces).uppercased()
                if chosen.count == 2 { return chosen }
                return Locale.current.region?.identifier.uppercased() ?? "US"
            },
            spotifyCredentials: {
                let s = shared.value
                let id = s.spotifyClientId.trimmingCharacters(in: .whitespaces)
                let secret = s.spotifyClientSecret.trimmingCharacters(in: .whitespaces)
                return id.isEmpty || secret.isEmpty ? nil : (id, secret)
            }
        )
        engine = Engine(http: http)
        finder = StreamFinder(catalog: catalog, youtube: engine.youtube)
        _ = (resolver, downloads, player, actions, recommender)
        // Navidrome covers are stored without the login; it is added to each request.
        let navidromeClient = navidrome.shared
        ImageLoader.shared.sign = { url in
            guard let client = navidromeClient.value, client.owns(url.absoluteString) else { return url }
            return URL(string: client.authenticate(url.absoluteString)) ?? url
        }

        network.onChange = { [unowned self] in self.downloads.start() }
        library.checkFiles()
        player.start()
        downloads.recover()
        updateEngineIfDue()
        recommender.schedule()
    }

    /** Looks for newer YouTube clients once a day, when that is switched on. */
    func updateEngineIfDue() {
        let s = settings.settings
        guard s.autoUpdateEngine, nowMs() - s.lastEngineCheck > 20 * 3600 * 1000 else { return }
        Task {
            if (try? await engine.update(http: http)) != nil {
                settings.update { $0.lastEngineCheck = nowMs() }
            }
        }
    }
}
