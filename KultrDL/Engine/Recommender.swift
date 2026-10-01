import BackgroundTasks
import Foundation
import KultrDLCore
import Observation
import UserNotifications

/**
 * Recommendations: learns what the user likes from KultrDL's own history
 * (plays, skips, hearts, saves, downloads, playlists), the music on the
 * phone, their Navidrome server, Last.fm and ListenBrainz, and builds the
 * "For you" page once a day — new releases (with alerts), mixes, albums to
 * try, albums missing from their collection, and old favourites.
 */
@MainActor
@Observable
final class Recommender {
    enum Status: Equatable {
        case idle
        case working(String)
        case failed(String)

        var isWorking: Bool {
            if case .working = self { return true }
            return false
        }
    }

    static let backgroundTaskId = "app.kultr.dl.discover"
    /** A playlist saved from a mix with "Keep updated" has this, plus the mix's id, as its source. */
    static let mixUrl = "kultrdl:mix:"
    private static let hour: Int64 = 3_600_000
    private static let day: Int64 = 24 * hour
    private static let feedFile = "discover-feed.json"
    private static let cacheFile = "discover-cache.json"

    private(set) var status: Status = .idle
    private(set) var raw: Feed?
    private(set) var phoneSongs = 0
    private(set) var navidromeSongs = 0

    @ObservationIgnored private unowned let graph: AppGraph
    @ObservationIgnored private var cache: CacheData
    @ObservationIgnored private var running: Task<Feed, Error>?
    @ObservationIgnored private var filteredKey: FilterKey?
    @ObservationIgnored private var filteredFeed: Feed?
    @ObservationIgnored private let lastFm: LastFm
    @ObservationIgnored private let listenBrainz: ListenBrainz

    init(graph: AppGraph) {
        self.graph = graph
        let shared = graph.settings.shared
        lastFm = LastFm(http: graph.http, apiKey: { shared.value.lastFmApiKey })
        listenBrainz = ListenBrainz(http: graph.http)
        cache = Storage.load(CacheData.self, Self.cacheFile) ?? CacheData()
        raw = Storage.load(Feed.self, Self.feedFile)
        phoneSongs = cache.phoneSongs
        navidromeSongs = cache.navidromeSongs
    }

    private struct FilterKey: Equatable {
        var builtAt: Int64
        var taste: TasteData
        var genres: [String]
    }

    func rules(_ s: Settings? = nil) -> Rules {
        Rules(blocks: graph.taste.blocks, dismissed: graph.taste.dismissedKeys, excludedGenres: (s ?? graph.settings.settings).excludedGenres)
    }

    /** The feed as last built, without anything blocked or dismissed since. */
    var feed: Feed? {
        guard let raw else { return nil }
        let key = FilterKey(builtAt: raw.builtAt, taste: graph.taste.data, genres: graph.settings.settings.excludedGenres)
        if key == filteredKey, let filteredFeed { return filteredFeed }
        let filtered = raw.filtered(rules())
        filteredKey = key
        filteredFeed = filtered
        return filtered
    }

    /** Rebuild when the feed is more than a day old (on opening Home). */
    func refreshIfStale() {
        let s = graph.settings.settings
        guard s.suggestions, !status.isWorking else { return }
        if s.releaseAlerts != .off { askForNotifications() }
        guard nowMs() - (raw?.builtAt ?? 0) >= 20 * Self.hour else { return }
        refreshInBackground()
    }

    func refreshInBackground() {
        Task { _ = try? await refresh() }
    }

    @discardableResult
    func refresh(daily: Bool = false) async throws -> Feed {
        if let running { return try await running.value }
        let task = Task { () throws -> Feed in try await self.build(daily: daily) }
        running = task
        defer { running = nil }
        do {
            // Cancelling the caller (the background task running out of time) stops the build too.
            let feed = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: {
                task.cancel()
            }
            status = .idle
            return feed
        } catch is CancellationError {
            status = .idle
            throw CancellationError()
        } catch {
            status = .failed(describe(error))
            throw error
        }
    }

    // ------------------------------------------------------------ building --

    private func build(daily: Bool) async throws -> Feed {
        let s = graph.settings.settings
        let now = nowMs()
        if s.usePhoneMusic, PhoneMusic.authorized, now - cache.phoneScannedAt > 12 * Self.hour {
            status = .working("Reading the music on this phone")
            _ = await scanPhone()
        }
        let nav = graph.navidrome.config
        if nav.configured, nav.useHistory, now - nav.lastSyncAt > 20 * Self.hour {
            status = .working("Reading your Navidrome")
            _ = try? await syncNavidrome()
        }
        try Task.checkCancellation()

        status = .working("Learning what you like")
        let useNavidrome = graph.navidrome.config.configured && graph.navidrome.config.useHistory
        let songs = await graph.listening.allSongs().filter { $0.owner == .phone ? s.usePhoneMusic : useNavidrome }
        let known = graph.library.tracks.values.filter { $0.playCount > 0 || $0.favorite || $0.saved || $0.localPath != nil }
        let plays = await graph.listening.plays(since: now - 365 * Self.day)
        let playlists = graph.library.playlists.filter { !($0.sourceUrl?.hasPrefix(Self.mixUrl) ?? false) }
        let feedback = graph.taste.data.feedback
        var outside: [Signal] = []
        if !s.lastFmUser.isEmpty && !s.lastFmApiKey.isEmpty {
            do {
                for a in try await lastFm.topArtists(s.lastFmUser) { outside.append(Signal(a.name, "", log(1 + Double(a.plays)) * 1.5)) }
            } catch {
                print("KultrDL: Last.fm: \(describe(error))")
            }
        }
        if !s.listenBrainzUser.isEmpty {
            do {
                for a in try await listenBrainz.topArtists(s.listenBrainzUser) { outside.append(Signal(a.name, "", log(1 + Double(a.plays)) * 1.5)) }
            } catch {
                print("KultrDL: ListenBrainz: \(describe(error))")
            }
        }
        let extraMixes = await listenBrainzMixes(s.listenBrainzUser)
        let rules = self.rules(s)
        let matched = Dictionary(known.compactMap { t in t.matchedUrl.map { (t.id, $0) } }, uniquingKeysWith: { a, _ in a })

        // The counting is done off the main thread: a big Navidrome makes it slow.
        let prepared = await Task.detached(priority: .utility) {
            Self.prepare(known: known, songs: songs, plays: plays, playlists: playlists, feedback: feedback, outside: outside, now: now)
        }.value
        print("KultrDL: Recommendations: \(prepared.signalCount) signals; top \(prepared.profile.top(8).map(\.name).joined(separator: ", "))")
        try Task.checkCancellation()

        status = .working("Looking for new music")
        let catalog = graph.catalog
        let shared = graph.settings.shared
        var similar: [SimilarNames] = []
        if lastFm.enabled { similar.append(LastFmSimilar(lastFm: lastFm)) }
        if useNavidrome, let client = graph.navidrome.client(graph.http) {
            var ids: [String: String] = [:]
            for song in songs where song.owner == .navidrome {
                if let id = song.artistId { ids[Credits.key(song.artist)] = id }
            }
            similar.append(NavidromeSimilar(client: client, ids: ids))
        }
        var radio: (@Sendable (Track) async throws -> [Track])?
        if s.useYouTubeRadio {
            radio = { (track: Track) async throws -> [Track] in
                let fromYouTube = track.source == .youtubeMusic || track.source == .youtube
                let url: String? = fromYouTube ? track.streamUrl : matched[track.id]
                guard let id = YouTubeMusic.videoId(url) else { return [] }
                let songs = try await catalog.youTubeMusic.radio(id)
                return Array(songs.prefix(25))
            }
        }
        let artistCache = ArtistCache(cache.artists)
        let discovery = Discovery(
            directory: CatalogDirectory(deezer: catalog.deezer, apple: catalog.apple, useDeezer: { shared.value.useDeezer }),
            similarNames: similar,
            radio: radio,
            cache: artistCache,
            log: { print("KultrDL: Recommendations: \($0)") }
        )
        let input = Discovery.Input(
            profile: prepared.profile,
            owned: prepared.owned,
            rules: rules,
            familiar: prepared.familiar,
            discover: s.discoverLevel,
            releaseWindowDays: s.releaseWindowDays,
            extraMixes: extraMixes,
            now: now
        )
        let feed = await discovery.build(input)
        try Task.checkCancellation()
        cache.artists = artistCache.snapshot()

        var kept = feed
        if feed.offline, let previous = raw, !previous.offline {
            // Offline: keep the last full feed, with today's offline mixes and rediscoveries.
            kept = previous
            kept.rediscover = feed.rediscover
            if kept.mixes.isEmpty { kept.mixes = feed.mixes }
        }
        raw = kept
        Storage.save(kept, Self.feedFile)
        alerts(kept, s, now)
        updateFollowedMixes(kept)
        saveCache()
        print("KultrDL: Recommendations ready: \(kept.releases.count) new releases, \(kept.mixes.count) mixes, \(kept.albums.count) albums, \(kept.missing.count) missing\(daily ? " (daily)" : "")")
        schedule()
        return kept
    }

    private struct Prepared: Sendable {
        var profile: TasteProfile
        var owned: Owned
        var familiar: [Played]
        var signalCount: Int
    }

    /** Everything the user did, as evidence for their taste; what they own; what they know and can play. */
    nonisolated private static func prepare(
        known: [StoredTrack], songs: [OwnedSong], plays: [PlayRecord], playlists: [Playlist],
        feedback: [FeedbackEntry], outside: [Signal], now: Int64
    ) -> Prepared {
        var signals: [Signal] = []
        let byId = Dictionary(known.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for e in known {
            let t = e.track
            if e.playCount > 0 { signals.append(Signal(t.artist, t.title, Double(e.playCount), e.lastPlayedAt, genre: t.genre)) }
            if e.favorite { signals.append(Signal(t.artist, t.title, 4, nil, genre: t.genre)) }
            if e.saved { signals.append(Signal(t.artist, t.title, 2, nil, genre: t.genre)) }
            if e.localPath != nil { signals.append(Signal(t.artist, t.title, 2.5, nil, genre: t.genre)) }
        }
        for p in plays {
            if p.skipped {
                signals.append(Signal(p.artist, p.title, -0.6, p.startedAt))
            } else if p.completed {
                signals.append(Signal(p.artist, p.title, 0.3, p.startedAt))
            }
        }
        for playlist in playlists {
            for id in playlist.trackIds {
                guard let t = byId[id]?.track else { continue }
                signals.append(Signal(t.artist, t.title, 1, nil, genre: t.genre))
            }
        }
        for song in songs {
            signals.append(Signal(song.artist, song.title, song.owner == .phone ? 0.15 : 0.1, nil, genre: song.genre))
            if song.playCount > 0 {
                signals.append(Signal(song.artist, song.title, Double(song.playCount), song.lastPlayedAt ?? song.addedAt, genre: song.genre))
            }
            if song.starred { signals.append(Signal(song.artist, song.title, 4, nil, genre: song.genre)) }
            if song.rating > 0 { signals.append(Signal(song.artist, song.title, (Double(song.rating) - 2.5) * 1.2, nil, genre: song.genre)) }
        }
        signals += outside
        for f in feedback {
            signals.append(Signal(f.artist, "", f.verdict == .like ? 5 : -1.5, f.at))
        }
        let profile = Taste.build(signals, now: now)

        let owned = Owned.Builder()
        for song in songs { owned.add(song.artist, song.title, album: song.album, albumArtist: song.albumArtist) }
        for e in known where e.localPath != nil || e.favorite || e.saved {
            owned.add(e.track.artist, e.track.title, album: e.track.album, albumArtist: e.track.albumArtist)
        }

        var familiar: [Played] = known.map { e in Played(e.track, plays: e.playCount + (e.favorite ? 3 : 0), lastPlayedAt: e.lastPlayedAt) }
        for song in songs {
            let inApp = byId[song.id]
            let plays = song.playCount + (inApp?.playCount ?? 0) + (song.starred ? 3 : 0)
            let last = max(song.lastPlayedAt ?? 0, inApp?.lastPlayedAt ?? 0)
            familiar.append(Played(song.toTrack(), plays: plays, lastPlayedAt: last > 0 ? last : nil))
        }
        var seen = Set<String>()
        familiar = familiar.filter { seen.insert($0.track.id).inserted }
        familiar = familiar.enumerated().sorted { a, b in
            a.element.plays != b.element.plays ? a.element.plays > b.element.plays : a.offset < b.offset
        }.map(\.element)
        return Prepared(profile: profile, owned: owned.build(), familiar: Array(familiar.prefix(4000)), signalCount: signals.count)
    }

    /** ListenBrainz's newest weekly playlists for the user, one of each kind. */
    private func listenBrainzMixes(_ user: String) async -> [Mix] {
        guard !user.isEmpty else { return [] }
        do {
            var kinds = Set<String>()
            var mixes: [Mix] = []
            for p in try await listenBrainz.createdFor(user) {
                guard let kind = ListenBrainz.kind(p.title), kinds.insert(kind).inserted, kinds.count <= 3 else { continue }
                let tracks = try await listenBrainz.playlist(p.id)
                guard !tracks.isEmpty else { continue }
                let title = p.title.components(separatedBy: " for ").first.flatMap { $0.isEmpty ? nil : $0 } ?? p.title
                mixes.append(Mix(id: "lb-\(kind)", title: title, subtitle: "From ListenBrainz", tracks: tracks))
            }
            return mixes
        } catch {
            print("KultrDL: ListenBrainz playlists: \(describe(error))")
            return []
        }
    }

    // ------------------------------------------------------------- sources --

    @discardableResult
    func scanPhone() async -> Int {
        let songs = await Task.detached(priority: .utility) { PhoneMusic.scan() }.value
        await graph.listening.replace(.phone, songs)
        cache.phoneScannedAt = nowMs()
        cache.phoneSongs = songs.count
        phoneSongs = songs.count
        saveCache()
        print("KultrDL: Phone music: \(songs.count) songs")
        return songs.count
    }

    func forgetPhone() async {
        await graph.listening.replace(.phone, [])
        cache.phoneSongs = 0
        cache.phoneScannedAt = 0
        phoneSongs = 0
        saveCache()
    }

    /** Reads every song on the user's Navidrome, with play counts, stars and ratings. */
    @discardableResult
    func syncNavidrome() async throws -> String {
        guard let client = graph.navidrome.client(graph.http) else {
            throw KultrError("Navidrome isn't set up, or its password needs entering again.")
        }
        do {
            let info = try await client.ping()
            let list = try await client.songs()
            let songs = list.map { song in
                OwnedSong(
                    id: "navidrome:\(song.id)", owner: .navidrome, title: song.title, artist: song.artist,
                    album: song.album, albumArtist: song.albumArtist, genre: song.genre, year: song.year,
                    trackNumber: song.track, durationMs: song.durationMs, playCount: song.playCount,
                    lastPlayedAt: song.playedAt, starred: song.starred, rating: song.rating,
                    artworkUrl: song.coverArt.map { client.coverUrl($0) }, streamUrl: client.streamUrl(song.id),
                    artistId: song.artistId, addedAt: nil
                )
            }
            await graph.listening.replace(.navidrome, songs)
            let note = "\(Format.count(songs.count, "song")) from \(info)"
            graph.navidrome.update {
                $0.lastSyncAt = nowMs()
                $0.lastSync = note
                $0.songCount = songs.count
            }
            cache.navidromeSongs = songs.count
            navidromeSongs = songs.count
            saveCache()
            print("KultrDL: Navidrome: synced \(note)")
            return note
        } catch {
            graph.navidrome.update { $0.lastSync = "Couldn't sync: \(describe(error))" }
            throw error
        }
    }

    func forgetNavidrome() async {
        await graph.listening.replace(.navidrome, [])
        cache.navidromeSongs = 0
        navidromeSongs = 0
        saveCache()
    }

    /** After downloads reached Navidrome's music folder: have it look for them now. */
    func afterUploads(_ destinations: Set<Destination>) async {
        let c = graph.navidrome.config
        guard let target = c.destination, c.rescan,
              destinations.contains(where: { $0.serverId == target.serverId && $0.folder == target.folder }),
              let client = graph.navidrome.client(graph.http)
        else { return }
        let note: String
        do {
            _ = try await client.startScan()
            note = "Rescan started after downloads"
        } catch {
            note = "Couldn't start a rescan: \(describe(error))"
        }
        print("KultrDL: Navidrome: \(note)")
        graph.navidrome.update { $0.lastScan = note }
    }

    // -------------------------------------------------------------- alerts --

    private func alerts(_ feed: Feed, _ s: Settings, _ now: Int64) {
        let fresh = feed.releases.filter { cache.seenReleases[$0.key] == nil }
        let firstRun = cache.seenReleases.isEmpty
        for pick in fresh { cache.seenReleases[pick.key] = now }
        cache.seenReleases = cache.seenReleases.filter { now - $0.value < 200 * Self.day }
        if firstRun || (fresh.isEmpty && cache.pending.isEmpty) { return }
        let items = fresh.map { Alert(key: $0.key, artist: $0.artist, title: $0.collection.title, type: $0.reason) }
        switch s.releaseAlerts {
        case .off:
            break
        case .asTheyCome:
            if !items.isEmpty { notify(items) }
        case .weekly:
            var pending = cache.pending
            for item in items where !pending.contains(where: { $0.key == item.key }) { pending.append(item) }
            if now - cache.lastSummaryAt >= 7 * Self.day && !pending.isEmpty {
                notify(pending)
                cache.pending = []
                cache.lastSummaryAt = now
            } else {
                cache.pending = pending
            }
        }
    }

    private func askForNotifications() {
        Task {
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            if settings.authorizationStatus == .notDetermined {
                _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
            }
        }
    }

    private func notify(_ items: [Alert]) {
        let content = UNMutableNotificationContent()
        content.title = items.count == 1 ? "New from \(items[0].artist)" : "\(items.count) new releases from artists you play"
        content.body = items.count == 1
            ? "\(items[0].title) · \(items[0].type)"
            : items.prefix(5).map { "\($0.artist) – \($0.title)" }.joined(separator: "\n")
        content.sound = .default
        content.userInfo = ["open": "home"]
        let request = UNNotificationRequest(identifier: "new-releases", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error { print("KultrDL: New releases notification: \(error)") }
        }
        print("KultrDL: New releases: \(content.title)")
    }

    /** Playlists saved from a mix with "Keep updated" get today's songs. */
    private func updateFollowedMixes(_ feed: Feed) {
        let mixes = Dictionary(feed.mixes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for playlist in graph.library.playlists {
            guard let source = playlist.sourceUrl, source.hasPrefix(Self.mixUrl) else { continue }
            guard let mix = mixes[String(source.dropFirst(Self.mixUrl.count))] else { continue }
            graph.library.replacePlaylistTracks(playlist.id, mix.tracks)
        }
    }

    // ---------------------------------------------------------- background --

    /** Once a day in the background, within the user's limits (iOS picks the moment). */
    func schedule() {
        let s = graph.settings.settings
        let scheduler = BGTaskScheduler.shared
        guard s.suggestions else {
            scheduler.cancel(taskRequestWithIdentifier: Self.backgroundTaskId)
            return
        }
        let request = BGProcessingTaskRequest(identifier: Self.backgroundTaskId)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = s.suggestionsWhileCharging
        let since = nowMs() - (raw?.builtAt ?? 0)
        let wait = max(Double(20 * Self.hour - since) / 1000, 15 * 60)
        request.earliestBeginDate = Date().addingTimeInterval(wait)
        do {
            try scheduler.submit(request)
        } catch {
            print("KultrDL: Couldn't schedule recommendations: \(error)")
        }
    }

    func run(_ task: BGProcessingTask) {
        let s = graph.settings.settings
        if !s.suggestions || (s.suggestionsOnWifiOnly && graph.network.expensive) || !graph.network.online {
            task.setTaskCompleted(success: true)
            schedule()
            return
        }
        let work = Task { () -> Bool in (try? await refresh(daily: true)) != nil }
        task.expirationHandler = {
            work.cancel()
        }
        Task {
            let ok = await work.value
            task.setTaskCompleted(success: ok)
            schedule()
        }
    }

    // --------------------------------------------------------------- cache --

    private func saveCache() { Storage.save(cache, Self.cacheFile) }

    struct CachedArtist: Codable, Sendable {
        var ref: ArtistRef?
        var at: Int64
    }

    struct Alert: Codable, Hashable {
        var key: String
        var artist: String
        var title: String
        var type: String
    }

    struct CacheData: Codable {
        var artists: [String: CachedArtist] = [:]
        var seenReleases: [String: Int64] = [:]
        var pending: [Alert] = []
        var lastSummaryAt: Int64 = 0
        var phoneScannedAt: Int64 = 0
        var phoneSongs = 0
        var navidromeSongs = 0

        init() {}

        enum CodingKeys: String, CodingKey {
            case artists, seenReleases, pending, lastSummaryAt, phoneScannedAt, phoneSongs, navidromeSongs
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            artists = c.value(.artists, [:])
            seenReleases = c.value(.seenReleases, [:])
            pending = c.value(.pending, [])
            lastSummaryAt = c.value(.lastSummaryAt, 0)
            phoneScannedAt = c.value(.phoneScannedAt, 0)
            phoneSongs = c.value(.phoneSongs, 0)
            navidromeSongs = c.value(.navidromeSongs, 0)
        }
    }
}

/** Which Deezer/Apple artist a name is: found ones for four months, "not found" for three weeks. */
private final class ArtistCache: ArtistIdCache, @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String: Recommender.CachedArtist]

    init(_ entries: [String: Recommender.CachedArtist]) {
        self.entries = entries
    }

    func lookup(_ key: String) -> ArtistRef?? {
        lock.lock()
        defer { lock.unlock() }
        guard let hit = entries[key] else { return nil }
        let age = nowMs() - hit.at
        let day: Int64 = 86_400_000
        let keep: Int64 = hit.ref == nil ? 21 * day : 120 * day
        return age < keep ? .some(hit.ref) : nil
    }

    func store(_ key: String, _ ref: ArtistRef?) {
        lock.lock()
        entries[key] = Recommender.CachedArtist(ref: ref, at: nowMs())
        lock.unlock()
    }

    func snapshot() -> [String: Recommender.CachedArtist] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }
}

private struct LastFmSimilar: SimilarNames {
    let lastFm: LastFm
    func similar(_ artist: String) async throws -> [String] { try await lastFm.similar(artist) }
}

/** Navidrome's similar artists (from its Last.fm integration), for artists it has. */
private struct NavidromeSimilar: SimilarNames {
    let client: Subsonic
    let ids: [String: String]

    func similar(_ artist: String) async throws -> [String] {
        guard let id = ids[Credits.key(artist)] else { return [] }
        return try await client.similarArtists(id)
    }
}
