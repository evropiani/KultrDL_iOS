import Foundation

/**
 * Karousel: when the queue runs out, more music like what has been playing,
 * so it never stops.
 *
 * It draws on a station started from the song now playing (YouTube Music's
 * radio), on songs by artists like the ones playing, on those artists' own
 * best-known songs, and on the user's own music by any of them. Short of
 * those (with no connection, say) it carries on with the user's own music:
 * the same genres first, then what they play most.
 */
public struct Karousel: Sendable {
    public struct Input: Sendable {
        /** What has been playing, the song now playing first. */
        public var seeds: [Track]
        /** [Keys.track] keys not to play: what is queued and what played lately. */
        public var exclude: Set<String>
        public var rules: Rules
        /** The user's own songs (on the phone, on Navidrome, downloaded, hearted), most played first. */
        public var owned: [Track]
        public var count: Int
        /** Fixes the shuffling, for tests; nil shuffles differently each time. */
        public var seed: Int64?

        public init(seeds: [Track], exclude: Set<String> = [], rules: Rules = Rules(), owned: [Track] = [], count: Int = 10, seed: Int64? = nil) {
            self.seeds = seeds
            self.exclude = exclude
            self.rules = rules
            self.owned = owned
            self.count = count
            self.seed = seed
        }
    }

    /** No more than this many songs by one artist in a batch. */
    public static let maxPerArtist = 2

    /** Which pool each pick comes from first: 0 the station, 1 similar artists, 2 the same artists, 3 the user's own. */
    private static let mix = [0, 1, 0, 2, 0, 1, 3, 0, 1, 2]

    private struct Around: Sendable {
        var same: [Track] = []
        var similar: [Track] = []
        var similarArtists: [String] = []
    }

    private let directory: ArtistDirectory?
    private let radio: (@Sendable (Track) async throws -> [Track])?
    private let cache: ArtistIdCache
    private let log: @Sendable (String) -> Void

    public init(
        directory: ArtistDirectory?,
        radio: (@Sendable (Track) async throws -> [Track])?,
        cache: ArtistIdCache = MemoryArtistIdCache(),
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.directory = directory
        self.radio = radio
        self.cache = cache
        self.log = log
    }

    public func next(_ input: Input) async -> [Track] {
        let seeds = input.seeds.filter { !$0.artist.trimmed().isEmpty }
        if seeds.isEmpty || input.count <= 0 { return [] }
        let seed = input.seed ?? Int64.random(in: Int64.min...Int64.max)
        var random = SeededRandom(seed)
        var artists: [String] = []
        for track in seeds {
            let name = Keys.primary(track.artist)
            if !artists.contains(where: { Credits.key($0) == Credits.key(name) }) { artists.append(name) }
            if artists.count == 3 { break }
        }

        async let station = stationSongs(Array(seeds.prefix(2)))
        let found: [Around] = await withTaskGroup(of: (Int, Around).self) { group in
            for (i, name) in artists.enumerated() {
                group.addTask {
                    let around = await self.around(name, i == 0 ? 4 : 2, seed &+ Int64(i + 1) &* 7919)
                    return (i, around)
                }
            }
            var out = [Around](repeating: Around(), count: artists.count)
            for await (i, around) in group { out[i] = around }
            return out
        }
        let fromStation = await station

        let seedArtists = Set(artists.map(Credits.key))
        let nearArtists = seedArtists.union(found.flatMap(\.similarArtists).map(Credits.key))
        let seedGenres = Set(seeds.compactMap { $0.genre?.lowercased() })
        func artistOf(_ t: Track) -> String { Credits.key(Keys.primary(t.artist)) }

        // In order of preference: the station, artists like these, these artists, the user's own songs by any of them.
        let mine = input.owned.filter { nearArtists.contains(artistOf($0)) }.shuffled(using: &random)
        var pools: [Pool] = [
            Pool(fromStation),
            Pool(Self.roundRobin(found.map(\.similar))),
            Pool(Self.roundRobin(found.map(\.same))),
            Pool(mine),
        ]
        let sameGenre = input.owned.filter { t in
            guard let genre = t.genre?.lowercased() else { return false }
            return seedGenres.contains(genre) && !nearArtists.contains(artistOf(t))
        }
        var backups: [Pool] = [
            Pool(sameGenre.shuffled(using: &random)),
            Pool(Array(input.owned.prefix(200)).shuffled(using: &random)),
        ]

        var picked: [Track] = []
        var keys = input.exclude
        var perArtist: [String: Int] = [:]
        func take(_ pool: inout Pool) -> Bool {
            while let t = pool.pop() {
                let key = Keys.track(t.artist, t.title)
                let artist = artistOf(t)
                if keys.contains(key) || !input.rules.allows(t) || (perArtist[artist] ?? 0) >= Self.maxPerArtist { continue }
                keys.insert(key)
                perArtist[artist, default: 0] += 1
                picked.append(t)
                return true
            }
            return false
        }
        /** One song from the first of [list] that has one left. */
        func takeAny(_ list: inout [Pool]) -> Bool {
            for i in list.indices {
                if take(&list[i]) { return true }
            }
            return false
        }
        // Mostly the station, with artists like these, these artists and the user's own songs mixed in.
        var turn = 0
        while picked.count < input.count {
            let first = Self.mix[turn % Self.mix.count]
            turn += 1
            if take(&pools[first]) { continue }
            if !takeAny(&pools) { break }
        }
        while picked.count < input.count {
            if !takeAny(&backups) { break }
        }

        let sources: [Set<Track>] = [Set(fromStation), Set(found.flatMap(\.similar)), Set(found.flatMap(\.same))]
        let counts = sources.map { s in picked.filter { s.contains($0) }.count }
        let own = picked.count - counts.reduce(0, +)
        log("\(picked.count) songs like \(artists.joined(separator: ", ")): \(counts[0]) from the station, \(counts[1]) by similar artists, \(counts[2]) by the same artists, \(own) of the user's own")
        return Self.spread(picked)
    }

    /**
     * The same order, moved only so one artist never plays twice in a row
     * where any order avoids it: an artist with more than half of what is
     * left goes next, else the first song by someone else.
     */
    static func spread(_ tracks: [Track]) -> [Track] {
        var left = tracks
        var out: [Track] = []
        out.reserveCapacity(tracks.count)
        var last: String?
        func artist(_ t: Track) -> String { Credits.key(Keys.primary(t.artist)) }
        while !left.isEmpty {
            var counts: [String: Int] = [:]
            for t in left { counts[artist(t), default: 0] += 1 }
            let crowded = counts.first { $0.key != last && $0.value * 2 > left.count }?.key
            let i = crowded.flatMap { c in left.firstIndex { artist($0) == c } }
                ?? left.firstIndex { artist($0) != last }
                ?? 0
            let next = left.remove(at: i)
            out.append(next)
            last = artist(next)
        }
        return out
    }

    // ------------------------------------------------------------ sources --

    /** A station from the song playing (or the one before it, when that gives nothing). */
    private func stationSongs(_ seeds: [Track]) async -> [Track] {
        guard let radio else { return [] }
        for seed in seeds {
            let found = await safe("radio for \(seed.title)", []) { try await radio(seed) }
            if !found.isEmpty { return found }
        }
        return []
    }

    /** The artist's best-known songs, and songs by artists like them. */
    private func around(_ name: String, _ similarArtists: Int, _ seed: Int64) async -> Around {
        guard let dir = directory, let ref = await resolve(dir, name) else { return Around() }
        var random = SeededRandom(seed)
        async let top = safe("top songs of \(ref.name)", [Track]()) { try await dir.topTracks(ref, limit: 6) }
        let related = Array(await safe("artists like \(ref.name)", [ArtistRef]()) { try await dir.similar(ref) }.prefix(8))
        let chosen = Array(related.shuffled(using: &random).prefix(similarArtists))
        let theirs: [[Track]] = await withTaskGroup(of: (Int, [Track]).self) { group in
            for (i, artist) in chosen.enumerated() {
                group.addTask {
                    var own = SeededRandom(seed &+ Int64(i + 1))
                    let songs = await self.safe("top songs of \(artist.name)", [Track]()) { try await dir.topTracks(artist, limit: 5) }
                    return (i, Array(songs.shuffled(using: &own).prefix(3)))
                }
            }
            var out = [[Track]](repeating: [], count: chosen.count)
            for await (i, songs) in group { out[i] = songs }
            return out
        }
        let best = await top
        return Around(same: Array(best.shuffled(using: &random).prefix(3)), similar: Self.roundRobin(theirs), similarArtists: related.map(\.name))
    }

    /** Who [name] is in the catalogue; "not found" is remembered, a failed lookup isn't. */
    private func resolve(_ dir: ArtistDirectory, _ name: String) async -> ArtistRef? {
        let key = Credits.key(name)
        if key.isEmpty { return nil }
        if let known = cache.lookup(key) { return known }
        do {
            let found = try await dir.find(name)
            cache.store(key, found)
            return found
        } catch {
            log("couldn't look up \(name): \(error.localizedDescription)")
            return nil
        }
    }

    private func safe<T: Sendable>(_ what: String, _ empty: T, _ body: () async throws -> T) async -> T {
        do {
            return try await body()
        } catch {
            if !(error is CancellationError) { log("\(what) failed: \(error.localizedDescription)") }
            return empty
        }
    }

    private struct Pool {
        private var items: [Track]
        private var at = 0

        init(_ items: [Track]) { self.items = items }

        mutating func pop() -> Track? {
            guard at < items.count else { return nil }
            defer { at += 1 }
            return items[at]
        }
    }

    private static func roundRobin<T>(_ lists: [[T]]) -> [T] {
        var out: [T] = []
        let longest = lists.map(\.count).max() ?? 0
        for i in 0..<longest {
            for list in lists where i < list.count { out.append(list[i]) }
        }
        return out
    }
}
