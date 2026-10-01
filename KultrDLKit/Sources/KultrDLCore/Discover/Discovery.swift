import Foundation

/** An artist as a catalogue knows them ("deezer:27", "apple:5468295"). */
public struct ArtistRef: Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var fans: Int64
    public var pictureUrl: String?

    public init(id: String, name: String, fans: Int64 = 0, pictureUrl: String? = nil) {
        self.id = id
        self.name = name
        self.fans = fans
        self.pictureUrl = pictureUrl
    }
}

/** Where artists, their releases, similar artists and top songs come from. */
public protocol ArtistDirectory: Sendable {
    func find(_ name: String) async throws -> ArtistRef?
    /** Albums, EPs and singles, with releaseDate, recordType and genre where known. */
    func releases(_ artist: ArtistRef) async throws -> [TrackCollection]
    /** The artist's best-loved albums, most popular first. */
    func bestAlbums(_ artist: ArtistRef, limit: Int) async throws -> [TrackCollection]
    func similar(_ artist: ArtistRef) async throws -> [ArtistRef]
    func topTracks(_ artist: ArtistRef, limit: Int) async throws -> [Track]
    /** The tracks of a release, for Release Radar. */
    func tracks(_ release: TrackCollection) async throws -> [Track]
}

/** Another opinion on similar artists (Last.fm, Navidrome): names only. */
public protocol SimilarNames: Sendable {
    func similar(_ artist: String) async throws -> [String]
}

/** Which catalogue artist a name is, remembered between runs. */
public protocol ArtistIdCache: Sendable {
    /** nil: never looked up; .some(nil): looked up and not found. */
    func lookup(_ key: String) -> ArtistRef??
    func store(_ key: String, _ ref: ArtistRef?)
}

public final class MemoryArtistIdCache: ArtistIdCache, @unchecked Sendable {
    private let lock = NSLock()
    private var map: [String: ArtistRef?] = [:]

    public init() {}

    public func lookup(_ key: String) -> ArtistRef?? {
        lock.lock()
        defer { lock.unlock() }
        return map[key]
    }

    public func store(_ key: String, _ ref: ArtistRef?) {
        lock.lock()
        map[key] = .some(ref)
        lock.unlock()
    }
}

/** A song the user has, with how often they played it. */
public struct Played: Sendable {
    public var track: Track
    public var plays: Int
    /** Milliseconds since 1970. */
    public var lastPlayedAt: Int64?

    public init(_ track: Track, plays: Int, lastPlayedAt: Int64?) {
        self.track = track
        self.plays = plays
        self.lastPlayedAt = lastPlayedAt
    }
}

/**
 * Works out the "For you" page from what the user listens to: new
 * releases from their artists, mixes of what they love and what they
 * might, albums they may like, albums missing from their collection, and
 * old favourites to rediscover. Every step tolerates a source failing;
 * with no connection at all, it still makes mixes from what is on hand.
 */
public final class Discovery: @unchecked Sendable {
    public static let mixSize = 30

    public struct Input: Sendable {
        public var profile: TasteProfile
        public var owned: Owned
        public var rules: Rules
        /** Songs the user knows and can play: their library and their files, most played first. */
        public var familiar: [Played]
        /** 0 = mostly what they know, 1 = mostly new to them. */
        public var discover: Double
        public var releaseWindowDays: Int
        public var today: Day
        public var seedCount: Int
        /** Ready-made mixes from elsewhere (ListenBrainz's weekly playlists). */
        public var extraMixes: [Mix]
        /** Milliseconds since 1970. */
        public var now: Int64

        public init(
            profile: TasteProfile,
            owned: Owned,
            rules: Rules,
            familiar: [Played],
            discover: Double = 0.5,
            releaseWindowDays: Int = 30,
            today: Day = .today(),
            seedCount: Int = 25,
            extraMixes: [Mix] = [],
            now: Int64 = Int64(Date().timeIntervalSince1970 * 1000)
        ) {
            self.profile = profile
            self.owned = owned
            self.rules = rules
            self.familiar = familiar
            self.discover = discover
            self.releaseWindowDays = releaseWindowDays
            self.today = today
            self.seedCount = seedCount
            self.extraMixes = extraMixes
            self.now = now
        }
    }

    private let directory: ArtistDirectory
    private let similarNames: [SimilarNames]
    private let radio: (@Sendable (Track) async throws -> [Track])?
    private let cache: ArtistIdCache
    private let parallel: Int
    private let log: @Sendable (String) -> Void

    public init(
        directory: ArtistDirectory,
        similarNames: [SimilarNames] = [],
        radio: (@Sendable (Track) async throws -> [Track])? = nil,
        cache: ArtistIdCache = MemoryArtistIdCache(),
        parallel: Int = 4,
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.directory = directory
        self.similarNames = similarNames
        self.radio = radio
        self.cache = cache
        self.parallel = parallel
        self.log = log
    }

    /** One run's requests: at most [parallel] at a time, successes and failures counted. */
    private final class Run: @unchecked Sendable {
        let gate: AsyncGate
        private let lock = NSLock()
        private(set) var successes = 0
        private(set) var failures = 0

        init(parallel: Int) { gate = AsyncGate(parallel) }

        func count(_ ok: Bool) {
            lock.lock()
            if ok { successes += 1 } else { failures += 1 }
            lock.unlock()
        }
    }

    /** One request to a source; a failure is logged and counted, never fatal. */
    private func fetch<T: Sendable>(_ run: Run, _ what: String, _ block: @Sendable () async throws -> T) async -> T? {
        await run.gate.acquire()
        defer { run.gate.release() }
        do {
            let value = try await block()
            run.count(true)
            return value
        } catch is CancellationError {
            return nil
        } catch {
            run.count(false)
            log("\(what): \(error.localizedDescription)")
            return nil
        }
    }

    public func build(_ input: Input) async -> Feed {
        let run = Run(parallel: parallel)
        let base = input.rules
        let seeds = Array(input.profile.seeds(input.seedCount * 2).filter { base.allowsArtist($0.name) }.prefix(input.seedCount))
        let shown = seeds.prefix(10).map(\.name).joined(separator: ", ")
        log("Seeds: \(shown)\(seeds.count > 10 ? " and \(seeds.count - 10) more" : "")")

        // Who each seed artist is in the catalogue.
        let resolved = await parallelMap(seeds) { s in (s.key, await self.resolve(run, s.name)) }
        let refs: [String: ArtistRef] = Dictionary(
            resolved.compactMap { key, ref in ref.map { (key, $0) } },
            uniquingKeysWith: { a, _ in a }
        )
        let seedsWithRefs = seeds.filter { refs[$0.key] != nil }

        // Their releases: new ones, missing ones, and their genres.
        let releaseLists = await parallelMap(seedsWithRefs) { s in
            (s.key, await self.fetch(run, "releases of \(refs[s.key]!.name)") { try await self.directory.releases(refs[s.key]!) } ?? [])
        }
        var genres: [String: [String]] = [:]
        for (key, list) in releaseLists {
            let ranked = Self.byCount(list.compactMap(\.genre))
            if !ranked.isEmpty { genres[key] = ranked }
        }
        var profileGenres: [String: [String]] = [:]
        for s in seeds where !s.genres.isEmpty { profileGenres[s.key] = s.genres }
        let rules = base.withGenres(profileGenres.merging(genres) { _, new in new })
        let byKey = Dictionary(seeds.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })

        let newReleases = pickNewReleases(releaseLists, byKey, input, rules)
        let missing = pickMissing(releaseLists, byKey, input, rules)

        // Similar artists, new to the user, weighted by how much they like the artists they resemble.
        let similar = await findSimilar(run, seeds, refs, input, rules)
        let topSimilar = Array(similar.prefix(14))
        var similarTracks: [String: [Track]] = [:]
        for (id, list) in await parallelMap(topSimilar, { s in
            (s.ref.id, await self.fetch(run, "top tracks of \(s.ref.name)") { try await self.directory.topTracks(s.ref, limit: 6) } ?? [])
        }) { similarTracks[id] = list }
        var similarAlbums: [String: [TrackCollection]] = [:]
        for (id, list) in await parallelMap(Array(topSimilar.prefix(12)), { s in
            (s.ref.id, await self.fetch(run, "albums of \(s.ref.name)") { try await self.directory.bestAlbums(s.ref, limit: 2) } ?? [])
        }) { similarAlbums[id] = list }

        // Songs of the seed artists the user doesn't have yet: familiar artists, new songs.
        let strongest = seedsWithRefs.sorted { $0.score > $1.score }.prefix(10)
        var seedTracks: [String: [Track]] = [:]
        for (key, list) in await parallelMap(Array(strongest), { s in
            (s.key, await self.fetch(run, "top tracks of \(refs[s.key]!.name)") { try await self.directory.topTracks(refs[s.key]!, limit: 8) } ?? [])
        }) { seedTracks[key] = list.filter { !input.owned.hasSong($0.artist, $0.title) } }

        let albums = pickAlbums(topSimilar, similarAlbums, input, rules)

        let day = Int64(input.today.number)
        var mixes: [Mix] = []
        if let radar = await releaseRadar(run, newReleases, input, rules) { mixes.append(radar) }
        mixes += dailyMixes(seeds, rules, input, similar, similarTracks, seedTracks, day)
        if let discover = discoverMix(topSimilar, similarTracks, input, rules, day) { mixes.append(discover) }
        mixes += await becauseMixes(run, seeds, refs, similar, similarTracks, seedTracks, input, rules, day)
        mixes += input.extraMixes.map { m in
            var m = m
            m.tracks = m.tracks.filter { rules.allows($0) }
            return m
        }.filter { !$0.tracks.isEmpty }

        let rediscover = rediscover(input, rules)
        let offline = run.successes == 0 && run.failures > 0
        log("Feed: \(newReleases.count) new releases, \(mixes.count) mixes, \(albums.count) albums, \(missing.count) missing, \(rediscover.count) to rediscover\(offline ? " (offline)" : "")")
        return Feed(
            builtAt: input.now,
            releases: newReleases,
            mixes: mixes.filter { !$0.tracks.isEmpty },
            albums: albums,
            missing: missing,
            rediscover: rediscover,
            seeds: seeds.map(\.name),
            offline: offline
        )
    }

    /** The catalogue artist for a name: remembered, or looked up (and "not found" remembered too, but not a failed lookup). */
    private func resolve(_ run: Run, _ name: String) async -> ArtistRef? {
        let key = Credits.key(name)
        if let known = cache.lookup(key) { return known }
        await run.gate.acquire()
        defer { run.gate.release() }
        do {
            let ref = try await directory.find(name)
            run.count(true)
            cache.store(key, ref)
            return ref
        } catch is CancellationError {
            return nil
        } catch {
            run.count(false)
            log("find \(name): \(error.localizedDescription)")
            return nil
        }
    }

    private func pickNewReleases(_ releases: [(String, [TrackCollection])], _ seeds: [String: ArtistScore], _ input: Input, _ rules: Rules) -> [Pick] {
        let from = input.today.adding(days: -input.releaseWindowDays)
        let until = input.today.adding(days: 1)
        var found: [(Day, Double, Int, Pick)] = []
        for (key, list) in releases {
            guard let seed = seeds[key] else { continue }
            for c in list {
                guard let date = Day(c.releaseDate), date >= from, date <= until else { continue }
                var withArtist = c
                withArtist.subtitle = c.subtitle ?? seed.name
                if input.owned.hasAlbum(withArtist.subtitle, c.title) || !rules.allows(withArtist) { continue }
                let pick = Pick(withArtist, artist: seed.name, reason: Self.kindLabel(c.recordType), key: Keys.album(withArtist.subtitle, c.title))
                found.append((date, seed.score, found.count, pick))
            }
        }
        let sorted = found.sorted { a, b in
            if a.0 != b.0 { return a.0 > b.0 }
            if a.1 != b.1 { return a.1 > b.1 }
            return a.2 < b.2
        }
        return Array(sorted.map(\.3).distinct { $0.key }.prefix(40))
    }

    private func pickMissing(_ releases: [(String, [TrackCollection])], _ seeds: [String: ArtistScore], _ input: Input, _ rules: Rules) -> [Pick] {
        if input.owned.isEmpty { return [] }
        let recent = input.today.adding(days: -input.releaseWindowDays)
        var owners: [(seed: ArtistScore, list: [TrackCollection], order: Int)] = []
        for (key, list) in releases {
            guard let seed = seeds[key], input.owned.hasArtist(seed.name) else { continue }
            owners.append((seed, list, owners.count))
        }
        owners.sort { a, b in a.seed.score != b.seed.score ? a.seed.score > b.seed.score : a.order < b.order }
        var out: [Pick] = []
        for (seed, list, _) in owners {
            var seen = Set<String>()
            var taken = 0
            for original in list where taken < 2 {
                if let type = original.recordType, type != "album" { continue }
                if let date = Day(original.releaseDate), date >= recent { continue }
                var c = original
                c.subtitle = c.subtitle ?? seed.name
                if input.owned.hasAlbum(c.subtitle, c.title) || !rules.allows(c) { continue }
                let key = Keys.album(c.subtitle, c.title)
                if !seen.insert(key).inserted { continue }
                out.append(Pick(c, artist: seed.name, reason: "You have other music by \(seed.name)", key: key))
                taken += 1
            }
        }
        return Array(out.prefix(24))
    }

    private struct Similar: Sendable {
        let ref: ArtistRef
        let score: Double
        let because: String
        let seedKey: String
    }

    private func findSimilar(_ run: Run, _ seeds: [ArtistScore], _ refs: [String: ArtistRef], _ input: Input, _ rules: Rules) async -> [Similar] {
        // Ask each source about the strongest seeds, all at once…
        let asked = Array(seeds.prefix(12))
        let answers = await parallelMap(asked) { seed -> (catalogue: [ArtistRef], names: [[String]]) in
            var catalogue: [ArtistRef] = []
            if let ref = refs[seed.key] {
                catalogue = await self.fetch(run, "similar to \(seed.name)") { try await self.directory.similar(ref) } ?? []
            }
            var names: [[String]] = []
            for source in self.similarNames {
                names.append(await self.fetch(run, "more similar to \(seed.name)") { try await source.similar(seed.name) } ?? [])
            }
            return (catalogue, names)
        }

        // …then add the answers up, in seed order so the result doesn't depend on timing.
        final class Tally {
            var score: Double
            var because: ArtistScore
            var best: Double
            var ref: ArtistRef?
            let name: String
            let order: Int

            init(score: Double, because: ArtistScore, best: Double, ref: ArtistRef?, name: String, order: Int) {
                self.score = score
                self.because = because
                self.best = best
                self.ref = ref
                self.name = name
                self.order = order
            }
        }
        var tally: [String: Tally] = [:]
        func add(_ name: String, _ ref: ArtistRef?, _ weight: Double, _ seed: ArtistScore) {
            let key = Credits.key(name)
            if key.isEmpty || input.profile.knows(name) || input.owned.hasArtist(name) || !rules.allowsArtist(name) { return }
            let t: Tally
            if let existing = tally[key] {
                t = existing
            } else {
                t = Tally(score: 0, because: seed, best: 0, ref: ref, name: name, order: tally.count)
                tally[key] = t
            }
            t.score += weight
            if weight > t.best {
                t.best = weight
                t.because = seed
            }
            if t.ref == nil { t.ref = ref }
        }
        for (seed, answer) in zip(asked, answers) {
            for (i, s) in answer.catalogue.prefix(20).enumerated() { add(s.name, s, seed.score * (1.0 - Double(i) / 25.0), seed) }
            for names in answer.names {
                for (i, n) in names.prefix(15).enumerated() { add(n, nil, seed.score * 0.8 * (1.0 - Double(i) / 20.0), seed) }
            }
        }

        // Names without a catalogue entry yet: look up the strongest ones.
        let ranked = tally.values.sorted { a, b in a.score != b.score ? a.score > b.score : a.order < b.order }.prefix(24)
        let lookups = await parallelMap(ranked.filter { $0.ref == nil }.map(\.name)) { name in (name, await self.resolve(run, name)) }
        for (name, ref) in lookups { tally[Credits.key(name)]?.ref = ref }
        return ranked
            .compactMap { t in t.ref.map { Similar(ref: $0, score: t.score, because: t.because.name, seedKey: t.because.key) } }
            .filter { rules.allowsArtist($0.ref.name) }
            .distinct { $0.ref.id }
    }

    private func pickAlbums(_ similar: [Similar], _ albums: [String: [TrackCollection]], _ input: Input, _ rules: Rules) -> [Pick] {
        Array(similar.compactMap { s -> Pick? in
            let album = (albums[s.ref.id] ?? [])
                .map { c -> TrackCollection in
                    var c = c
                    c.subtitle = c.subtitle ?? s.ref.name
                    return c
                }
                .first { !input.owned.hasAlbum($0.subtitle, $0.title) && rules.allows($0) }
            return album.map { Pick($0, artist: s.ref.name, reason: "Because you play \(s.because)", key: Keys.album($0.subtitle, $0.title)) }
        }.prefix(20))
    }

    private func releaseRadar(_ run: Run, _ releases: [Pick], _ input: Input, _ rules: Rules) async -> Mix? {
        if releases.isEmpty { return nil }
        let lists = await parallelMap(Array(releases.prefix(15))) { pick -> [Track] in
            let list = await self.fetch(run, "tracks of \(pick.collection.title)") { try await self.directory.tracks(pick.collection) } ?? []
            let wanted = pick.collection.recordType == "single" ? 1 : 2
            return Array(list.filter { rules.allows($0) && !input.owned.hasSong($0.artist, $0.title) }.prefix(wanted))
        }
        let tracks = lists.flatMap { $0 }
        if tracks.isEmpty { return nil }
        return Mix(
            id: "release-radar",
            title: "Release Radar",
            subtitle: "New songs from artists you play",
            tracks: Self.spread(tracks.distinct { Keys.track($0.artist, $0.title) })
        )
    }

    private func dailyMixes(
        _ seeds: [ArtistScore],
        _ rules: Rules,
        _ input: Input,
        _ similar: [Similar],
        _ similarTracks: [String: [Track]],
        _ seedTracks: [String: [Track]],
        _ day: Int64
    ) -> [Mix] {
        let groups = group(seeds, rules)
        return groups.enumerated().compactMap { i, group -> Mix? in
            let keys = Set(group.map(\.key))
            let familiar = input.familiar.filter { !Credits.keys($0.track.artist, $0.track.title).isDisjoint(with: keys) }.map(\.track)
            var fresh: [Track] = []
            for s in group { fresh += seedTracks[s.key] ?? [] }
            for s in similar where keys.contains(s.seedKey) { fresh += similarTracks[s.ref.id] ?? [] }
            let tracks = compose(familiar, fresh, input, rules, day &* 31 &+ Int64(i))
            if tracks.count < 5 { return nil }
            let names = group.sorted { $0.score > $1.score }.map(\.name)
            return Mix(
                id: "daily-\(i + 1)",
                title: "Daily Mix \(i + 1)",
                subtitle: names.prefix(3).joined(separator: ", ") + (names.count > 3 ? " and more" : ""),
                tracks: tracks
            )
        }
    }

    /** Seed artists in up to three groups that sound alike: by genre where known, otherwise by rank. */
    private func group(_ seeds: [ArtistScore], _ rules: Rules) -> [[ArtistScore]] {
        if seeds.isEmpty { return [] }
        var genreOf: [String: String] = [:]
        for s in seeds {
            if let g = rules.artistGenres[s.key]?.first ?? s.genres.first { genreOf[s.key] = g }
        }
        // Grouped by genre in the order the genres first turn up, then the biggest groups first.
        var genreOrder: [String] = []
        var byGenre: [String: [ArtistScore]] = [:]
        for s in seeds {
            guard let g = genreOf[s.key] else { continue }
            if byGenre[g] == nil { genreOrder.append(g) }
            byGenre[g, default: []].append(s)
        }
        var ranked: [(list: [ArtistScore], total: Double, order: Int)] = []
        for g in genreOrder {
            let list = byGenre[g] ?? []
            var total = 0.0
            for s in list { total += s.score }
            ranked.append((list, total, ranked.count))
        }
        ranked.sort { a, b in a.total != b.total ? a.total > b.total : a.order < b.order }
        var groups: [[ArtistScore]]
        if ranked.count >= 2 {
            groups = ranked.prefix(3).map(\.list)
        } else {
            let count = min(3, max(1, (seeds.count + 3) / 4))
            groups = Array(repeating: [], count: count)
        }
        let placed = Set(groups.flatMap { $0 }.map(\.key))
        // Artists without a genre (or beyond the third genre) go round the groups, strongest first.
        for (i, s) in seeds.filter({ !placed.contains($0.key) }).enumerated() { groups[i % groups.count].append(s) }
        return groups.filter { !$0.isEmpty }
    }

    private func discoverMix(_ similar: [Similar], _ tracks: [String: [Track]], _ input: Input, _ rules: Rules, _ day: Int64) -> Mix? {
        var candidates: [Track] = []
        for s in similar { candidates += (tracks[s.ref.id] ?? []).prefix(3) }
        let fresh = candidates
            .filter { rules.allows($0) && !input.owned.hasSong($0.artist, $0.title) }
            .distinct { Keys.track($0.artist, $0.title) }
        if fresh.count < 5 { return nil }
        var random = SeededRandom(day &* 7 &+ 3)
        let list = Array(Self.limitPerArtist(fresh.shuffled(using: &random), 2).prefix(Self.mixSize))
        return Mix(id: "discover", title: "Discover", subtitle: "Artists new to you", tracks: Self.spread(list))
    }

    private func becauseMixes(
        _ run: Run,
        _ seeds: [ArtistScore],
        _ refs: [String: ArtistRef],
        _ similar: [Similar],
        _ similarTracks: [String: [Track]],
        _ seedTracks: [String: [Track]],
        _ input: Input,
        _ rules: Rules,
        _ day: Int64
    ) async -> [Mix] {
        let chosen = Array(seeds.filter { refs[$0.key] != nil }.prefix(2))
        let mixes = await parallelMap(Array(chosen.enumerated())) { pair -> Mix? in
            let (i, seed) = pair
            let mine = input.familiar.filter { Credits.keys($0.track.artist, $0.track.title).contains(seed.key) }.map(\.track)
            var radioTracks: [Track] = []
            if let radio = self.radio, let own = mine.first {
                radioTracks = await self.fetch(run, "radio of \(own.title)") { try await radio(own) } ?? []
            }
            // Mostly artists like them, with a few of their own songs.
            var fresh: [Track] = Array((seedTracks[seed.key] ?? []).prefix(2))
            for s in similar where s.seedKey == seed.key { fresh += (similarTracks[s.ref.id] ?? []).prefix(3) }
            fresh += radioTracks
            var adventurous = input
            adventurous.discover = max(input.discover, 0.6)
            let tracks = self.compose(Array(mine.prefix(3)), fresh, adventurous, rules, day &* 13 &+ Int64(i))
            if tracks.count < 5 { return nil }
            return Mix(
                id: "because-" + seed.key.replacingOccurrences(of: " ", with: "-"),
                title: "Because you play \(seed.name)",
                subtitle: "\(seed.name) and artists like them",
                tracks: tracks
            )
        }
        return mixes.compactMap { $0 }
    }

    private func rediscover(_ input: Input, _ rules: Rules) -> [Track] {
        let cutoff: Int64 = input.now - 45 * 86_400_000
        var old: [(played: Played, order: Int)] = []
        for p in input.familiar {
            let at: Int64 = p.lastPlayedAt ?? 0
            if p.plays >= 3 && at >= 1 && at < cutoff { old.append((p, old.count)) }
        }
        old.sort { a, b in a.played.plays != b.played.plays ? a.played.plays > b.played.plays : a.order < b.order }
        let tracks = old.map(\.played.track).filter { rules.allows($0) }.distinct { Keys.track($0.artist, $0.title) }
        return Array(Self.limitPerArtist(tracks, 3).prefix(30))
    }

    /**
     * A mix of songs the user knows and songs new to them, in the
     * proportion [Input.discover] asks for, at most three by one artist
     * and never the same artist twice in a row where it can be helped.
     */
    private func compose(_ familiar: [Track], _ fresh: [Track], _ input: Input, _ rules: Rules, _ seed: Int64) -> [Track] {
        var random = SeededRandom(seed)
        let known = familiar.filter { rules.allows($0) }.distinct { Keys.track($0.artist, $0.title) }
        let knownKeys = Set(known.map { Keys.track($0.artist, $0.title) })
        let new = fresh.filter { rules.allows($0) && !input.owned.hasSong($0.artist, $0.title) }
            .distinct { Keys.track($0.artist, $0.title) }
            .filter { !knownKeys.contains(Keys.track($0.artist, $0.title)) }
        let size = Self.mixSize
        let level: Double = min(1.0, max(0.0, input.discover))
        let share: Double = 0.15 + 0.7 * level
        var freshCount = Int((Double(size) * share).rounded())
        freshCount = min(freshCount, new.count)
        let familiarCount = min(size - freshCount, known.count)
        if familiarCount < size - freshCount { freshCount = min(new.count, size - familiarCount) }
        // No artist takes over: three songs each, or more when there are only a few artists to choose from.
        let artists = max(1, Set((known + new).map { Credits.key(Keys.primary($0.artist)) }).count)
        let cap = min(10, max(3, (size + artists - 1) / artists))
        // Favourites first, but not always the same ones: a shuffled pick from the most played.
        let pool = Array(known.prefix(max(familiarCount * 2, 10))).shuffled(using: &random)
        let pickedKnown = Array(Self.limitPerArtist(pool, cap).prefix(familiarCount))
        var counts: [String: Int] = [:]
        for t in pickedKnown { counts[Credits.key(Keys.primary(t.artist)), default: 0] += 1 }
        let pickedNew = Self.limitPerArtist(new.shuffled(using: &random), 2).filter { t in
            let key = Credits.key(Keys.primary(t.artist))
            let n = counts[key] ?? 0
            counts[key] = n + 1
            return n < cap
        }.prefix(freshCount)
        return Self.spread((pickedKnown + pickedNew).shuffled(using: &random))
    }

    public static func kindLabel(_ recordType: String?) -> String {
        switch recordType {
        case "single": return "Single"
        case "ep": return "EP"
        case "compile": return "Compilation"
        default: return "Album"
        }
    }

    public static func limitPerArtist(_ tracks: [Track], _ max: Int) -> [Track] {
        var counts: [String: Int] = [:]
        return tracks.filter { t in
            let key = Credits.key(Keys.primary(t.artist))
            let n = counts[key] ?? 0
            counts[key] = n + 1
            return n < max
        }
    }

    /** Reorders so the same artist doesn't play twice in a row, where another can go between. */
    public static func spread(_ tracks: [Track]) -> [Track] {
        var left = tracks
        var out: [Track] = []
        out.reserveCapacity(tracks.count)
        var last: String?
        while !left.isEmpty {
            let i = left.firstIndex { Credits.key(Keys.primary($0.artist)) != last } ?? 0
            let next = left.remove(at: i)
            out.append(next)
            last = Credits.key(Keys.primary(next.artist))
        }
        return out
    }

    /** Values from most to least common; equal counts in the order they first turn up. */
    static func byCount(_ values: [String]) -> [String] {
        var order: [String] = []
        var counts: [String: Int] = [:]
        for v in values {
            if counts[v] == nil { order.append(v) }
            counts[v, default: 0] += 1
        }
        return order.enumerated().sorted { a, b in
            let ca = counts[a.element]!, cb = counts[b.element]!
            return ca > cb || (ca == cb && a.offset < b.offset)
        }.map(\.element)
    }
}

/** [transform] on every element at once; the results in the elements' order. */
func parallelMap<T: Sendable, R: Sendable>(_ items: [T], _ transform: @escaping @Sendable (T) async -> R) async -> [R] {
    await withTaskGroup(of: (Int, R).self) { group in
        for (i, item) in items.enumerated() { group.addTask { (i, await transform(item)) } }
        var out: [(Int, R)] = []
        out.reserveCapacity(items.count)
        for await r in group { out.append(r) }
        return out.sorted { $0.0 < $1.0 }.map(\.1)
    }
}

/** A counting semaphore for async code: at most [permits] holders at a time. */
final class AsyncGate: @unchecked Sendable {
    private let lock = NSLock()
    private var free: Int
    private var waiting: [CheckedContinuation<Void, Never>] = []

    init(_ permits: Int) { free = max(1, permits) }

    func acquire() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            lock.lock()
            if free > 0 {
                free -= 1
                lock.unlock()
                c.resume()
            } else {
                waiting.append(c)
                lock.unlock()
            }
        }
    }

    func release() {
        lock.lock()
        if waiting.isEmpty {
            free += 1
            lock.unlock()
        } else {
            let next = waiting.removeFirst()
            lock.unlock()
            next.resume()
        }
    }
}

/** A small, fast generator that gives the same sequence for the same seed (SplitMix64). */
public struct SeededRandom: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(_ seed: Int64) { state = UInt64(bitPattern: seed) }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
