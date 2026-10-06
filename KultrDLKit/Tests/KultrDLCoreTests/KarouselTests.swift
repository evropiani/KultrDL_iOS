import XCTest
@testable import KultrDLCore

final class KarouselTests: XCTestCase {
    private func song(_ artist: String, _ title: String, _ source: Source = .deezer, genre: String? = nil) -> Track {
        Track(id: "\(source.rawValue):\(artist)-\(title)", source: source, title: title, artist: artist, genre: genre)
    }

    private struct Offline: Error {}

    private final class World: ArtistDirectory, @unchecked Sendable {
        let offline: Bool
        let refs: [String: ArtistRef]
        private let lock = NSLock()
        private var lookedUp: [String] = []

        init(offline: Bool = false) {
            self.offline = offline
            refs = Dictionary(uniqueKeysWithValues: ["Daft Punk", "Justice", "Cassius", "Air", "Phoenix", "Drake"].map { (Credits.key($0), ArtistRef(id: "deezer:\($0)", name: $0)) })
        }

        var looked: [String] {
            lock.lock()
            defer { lock.unlock() }
            return lookedUp
        }

        func find(_ name: String) async throws -> ArtistRef? {
            if offline { throw Offline() }
            lock.lock()
            lookedUp.append(name)
            lock.unlock()
            return refs[Credits.key(name)]
        }

        func releases(_ artist: ArtistRef) async throws -> [TrackCollection] { [] }
        func bestAlbums(_ artist: ArtistRef, limit: Int) async throws -> [TrackCollection] { [] }

        func similar(_ artist: ArtistRef) async throws -> [ArtistRef] {
            artist.name == "Daft Punk" ? ["Justice", "Cassius", "Air", "Drake"].map { ArtistRef(id: "deezer:\($0)", name: $0) } : []
        }

        func topTracks(_ artist: ArtistRef, limit: Int) async throws -> [Track] {
            Array((1...6).map { Track(id: "deezer:\(artist.name)-\($0)", source: .deezer, title: "\(artist.name) hit \($0)", artist: artist.name) }.prefix(limit))
        }

        func tracks(_ release: TrackCollection) async throws -> [Track] { [] }
    }

    private var playing: Track { song("Daft Punk", "One More Time") }

    private var station: [Track] {
        let artists = ["Phoenix", "Air", "Justice", "Daft Punk"]
        return (1...12).map { song(artists[$0 % 4], "Station song \($0)", .youtubeMusic) } + [song("Daft Punk", "One More Time", .youtubeMusic)]
    }

    func testKeepsTheMusicGoingWithMusicLikeWhatIsPlaying() async {
        let songs = station
        let karousel = Karousel(directory: World(), radio: { _ in songs })
        let next = await karousel.next(Karousel.Input(
            seeds: [playing],
            exclude: [Keys.track("Air", "Station song 1"), Keys.track(playing.artist, playing.title)],
            rules: Rules(blocks: ArtistBlocks(["drake"])),
            count: 10,
            seed: 7
        ))
        XCTAssertEqual(next.count, 10)
        let keys = next.map { Keys.track($0.artist, $0.title) }
        XCTAssertEqual(keys.count, Set(keys).count, "no song twice")
        // What is queued (the song playing, and its other recording on the station) isn't picked again.
        XCTAssertFalse(keys.contains(Keys.track("Air", "Station song 1")))
        XCTAssertFalse(next.contains { $0.title == "One More Time" })
        // Blocked artists never come up, even when the catalogue calls them similar.
        XCTAssertFalse(next.contains { $0.artist == "Drake" })
        // Mostly the station, with songs by similar artists and by the artist playing.
        XCTAssertGreaterThanOrEqual(next.filter { $0.source == .youtubeMusic }.count, 4)
        XCTAssertTrue(next.contains { $0.source == .deezer && $0.artist != "Daft Punk" })
        XCTAssertTrue(next.contains { $0.source == .deezer && $0.artist == "Daft Punk" })
        // At most two songs by one artist, and never the same artist twice in a row.
        XCTAssertTrue(Dictionary(grouping: next, by: \.artist).values.allSatisfy { $0.count <= Karousel.maxPerArtist })
        XCTAssertFalse(zip(next, next.dropFirst()).contains { $0.artist == $1.artist })
    }

    func testSpreadKeepsAnArtistFromPlayingTwiceInARow() {
        // The first song by someone else each time would leave the two by C together at the end.
        let order = ["A", "B", "A", "B", "C", "C"].enumerated().map { song($1, "Song \($0)") }
        let spread = Karousel.spread(order)
        XCTAssertEqual(Set(spread), Set(order))
        XCTAssertFalse(zip(spread, spread.dropFirst()).contains { $0.artist == $1.artist }, spread.map(\.artist).joined())
        // Already apart: left as it is.
        let apart = ["A", "B", "A", "C"].enumerated().map { song($1, "Song \($0)") }
        XCTAssertEqual(Karousel.spread(apart), apart)
    }

    func testWithNoConnectionItCarriesOnWithTheUsersOwnMusic() async {
        let mine = [
            song("Daft Punk", "Aerodynamic", .navidrome),
            song("Massive Attack", "Teardrop", .navidrome, genre: "Trip Hop"),
            song("Portishead", "Roads", .phone, genre: "Trip Hop"),
            song("Air", "Sexy Boy", .navidrome),
            song("Daft Punk", "One More Time", .navidrome),
        ]
        let karousel = Karousel(directory: World(offline: true), radio: { _ in throw Offline() })
        let next = await karousel.next(Karousel.Input(
            seeds: [song("Massive Attack", "Angel", .navidrome, genre: "Trip Hop")],
            exclude: [Keys.track("Massive Attack", "Angel")],
            owned: mine,
            count: 4,
            seed: 1
        ))
        XCTAssertEqual(next.count, 4)
        // The same artist first, then the same genre, then what the user plays.
        XCTAssertEqual(Set(next.map(\.title).filter { $0 == "Teardrop" || $0 == "Roads" }), ["Teardrop", "Roads"])
        XCTAssertTrue(next.allSatisfy { $0.source == .navidrome || $0.source == .phone })
    }

    func testNothingToGoOnMeansNothingAdded() async {
        let karousel = Karousel(directory: World(offline: true), radio: nil)
        let none = await karousel.next(Karousel.Input(seeds: [playing]))
        XCTAssertEqual(none, [])
        let noSeeds = await karousel.next(Karousel.Input(seeds: [], owned: [playing]))
        XCTAssertEqual(noSeeds, [])
    }

    func testAnArtistTheCatalogueDoesNotKnowIsAskedForOnce() async {
        let world = World()
        let karousel = Karousel(directory: world, radio: nil, cache: MemoryArtistIdCache())
        let stranger = song("Nobody Knows Me", "Song")
        for _ in 0..<2 {
            _ = await karousel.next(Karousel.Input(seeds: [stranger], owned: [playing], seed: 3))
        }
        XCTAssertEqual(world.looked.filter { $0 == "Nobody Knows Me" }.count, 1)
    }
}
