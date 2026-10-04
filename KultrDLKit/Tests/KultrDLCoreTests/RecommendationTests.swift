import XCTest
@testable import KultrDLCore

final class CreditsTests: XCTestCase {
    func testFindsEveryoneOnATrack() {
        XCTAssertEqual(Credits.people("Drake & Future", "Life Is Good"), ["Drake", "Future", "Drake & Future"])
        XCTAssertEqual(Credits.people("Mumford & Sons", "The Cave"), ["Mumford", "Sons", "Mumford & Sons"])
        XCTAssertEqual(Credits.people("AC/DC", "Back in Black"), ["AC/DC"])
        XCTAssertEqual(Credits.people("Burial / Four Tet", "Moth"), ["Burial", "Four Tet", "Burial / Four Tet"])
        XCTAssertEqual(Credits.people("Rihanna", "Work (feat. Drake)"), ["Rihanna", "Drake"])
        XCTAssertEqual(Credits.people("A", "Song ft. B & C"), ["A", "B", "C"])
        XCTAssertEqual(Credits.people("A", "Song [with B]"), ["A", "B"])
        XCTAssertEqual(Credits.key("Drake - Topic"), "drake")
        XCTAssertEqual(Credits.key("Drake VEVO"), "drake")
        XCTAssertEqual(TextTools.splitArtists("AC/DC"), ["AC/DC"])
        XCTAssertEqual(TextTools.splitArtists("A / B"), ["A", "B"])
    }

    func testBlockingAnArtistBlocksTheirSongsAndSongsTheyAreOn() {
        let blocks = ArtistBlocks(["Drake"])
        XCTAssertTrue(blocks.blocks("Drake", "Hotline Bling"))
        XCTAssertTrue(blocks.blocks("Drake & Future", "Life Is Good"))
        XCTAssertTrue(blocks.blocks("Future, Drake", "Way 2 Sexy"))
        XCTAssertTrue(blocks.blocks("Rihanna", "Work (feat. Drake)"))
        XCTAssertTrue(blocks.blocks("Rihanna", "Work ft. Drake"))
        XCTAssertTrue(blocks.blocks("Rihanna feat. Drake", "Work"))
        XCTAssertTrue(blocks.blocks("Drake - Topic", "Passionfruit"))
        XCTAssertTrue(blocks.blocks("DJ Khaled", "Popstar", albumArtist: "Drake"))
        // A name that merely contains the blocked one is someone else.
        XCTAssertFalse(blocks.blocks("Drake Bell", "Found a Way"))
        XCTAssertFalse(blocks.blocks("Nick Drake", "Pink Moon"))
        XCTAssertFalse(blocks.blocks("Rihanna", "Umbrella"))
        XCTAssertTrue(blocks.blocksArtist("Drake"))
        XCTAssertFalse(ArtistBlocks.none.blocks("Drake", "Hotline Bling"))
        let album = TrackCollection(id: "x", source: .deezer, kind: .album, title: "Scorpion", subtitle: "Drake")
        XCTAssertTrue(blocks.blocks(album))
    }
}

final class TasteTests: XCTestCase {
    private let now: Int64 = 1_800_000_000_000
    private let day: Int64 = 86_400_000

    func testRecentPlaysOutweighOldOnesAndSkipsCountAgainst() throws {
        let profile = Taste.build([
            Signal("Massive Attack", "Teardrop", 1, now - 2 * day),
            Signal("Massive Attack", "Angel", 1, now - 3 * day),
            Signal("Old Band", "Song", 1, now - 400 * day),
            Signal("Old Band", "Song 2", 1, now - 400 * day),
            Signal("Skipped", "Meh", 1, now - day),
            Signal("Skipped", "Meh", -1.5, now - day),
            Signal("Portishead feat. Beth", "Roads (feat. Tricky)", 1, now, genre: "trip hop"),
        ], now: now)
        let top = profile.top(10).map(\.name)
        XCTAssertEqual(top.first, "Massive Attack")
        XCTAssertGreaterThan(profile.score("Massive Attack"), profile.score("Old Band"))
        XCTAssertLessThan(profile.score("Skipped"), 0)
        XCTAssertFalse(top.contains("Skipped"))
        // Featured artists count, but half.
        XCTAssertEqual(profile.score("Tricky"), 0.5, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(profile.get("Portishead feat. Beth")).genres, ["Trip Hop"])
        XCTAssertEqual(Taste.genreName("rap / hip hop"), "Rap/Hip-Hop")
    }

    func testSuggestionsGrowFromArtistsCreditedOnTheirOwn() {
        let now: Int64 = 1_750_000_000_000
        let profile = Taste.build([
            Signal("Mumford & Sons", "The Cave", 3, now),
            Signal("AC/DC", "Back in Black", 2, now),
            Signal("Daft Punk", "One More Time", 1, now),
            Signal("Daft Punk & Pharrell Williams", "Get Lucky", 1, now),
        ], now: now)
        // "Sons" and "Pharrell Williams" still count (they're known), but only as part of a credit.
        XCTAssertGreaterThan(profile.score("Sons"), 0)
        XCTAssertEqual(profile.seeds(10).map(\.name), ["Mumford & Sons", "AC/DC", "Daft Punk", "Daft Punk & Pharrell Williams"])
        XCTAssertNil(profile.get("AC"))
    }

    func testDaysAndDates() {
        XCTAssertEqual(Day("1970-01-01")?.number, 0)
        XCTAssertEqual(Day("2026-10-01")?.number, 20727)
        XCTAssertEqual(Day(number: 20727).description, "2026-10-01")
        XCTAssertEqual(Day("2024-02-28")?.adding(days: 1).description, "2024-02-29")
        XCTAssertNil(Day("next week"))
        let today = Day("2026-10-01")!
        XCTAssertEqual(Format.released("2026-10-01", today: today), "Today")
        XCTAssertEqual(Format.released("2026-09-30", today: today), "Yesterday")
        XCTAssertEqual(Format.released("2026-09-26", today: today), "5 days ago")
        XCTAssertEqual(Format.released("2026-09-03", today: today), "4 weeks ago")
        XCTAssertEqual(Format.released("2026-03-12T00:00:00Z", today: today), "12 Mar 2026")
        XCTAssertEqual(Format.released("2026-10-09", today: today), "Out 9 Oct")
        XCTAssertEqual(Format.ago(0, now: 5 * 60_000), "5 min ago")
    }
}

final class KeysTests: XCTestCase {
    func testEditionsAndRemastersAreTheSameAlbum() {
        XCTAssertEqual(Keys.album("Radiohead", "OK Computer"), Keys.album("Radiohead", "OK Computer (Remastered)"))
        XCTAssertEqual(Keys.album("Radiohead", "Kid A"), Keys.album("Radiohead", "Kid A [Deluxe Edition]"))
        XCTAssertEqual(Keys.track("Radiohead", "Creep"), Keys.track("Radiohead feat. Nobody", "Creep - 2009 Remaster"))
        let owned = Owned.Builder()
            .add("Radiohead", "Airbag", album: "OK Computer OKNOTOK 1997 2017", albumArtist: "Radiohead")
            .add("Björk", "Joga", album: "Homogenic")
            .build()
        XCTAssertTrue(owned.hasSong("radiohead", "Airbag"))
        XCTAssertTrue(owned.hasAlbum("Björk", "Homogenic (Deluxe Edition)"))
        XCTAssertTrue(owned.hasArtist("Bjork"))
        XCTAssertFalse(owned.hasAlbum("Björk", "Vespertine"))
    }
}

private func track(_ artist: String, _ title: String, id: String? = nil) -> Track {
    Track(id: id ?? "deezer:\(artist)-\(title)", source: .deezer, title: title, artist: artist, artworkUrl: "https://img/\(artist)-\(title).jpg")
}

final class DiscoveryTests: XCTestCase {
    private let today = Day("2026-10-01")!

    private static func album(_ artist: String, _ title: String, _ date: String, _ type: String = "album", genre: String? = "Electro") -> TrackCollection {
        TrackCollection(id: "deezer:album:\(artist)-\(title)", source: .deezer, kind: .album, title: title, subtitle: artist, releaseDate: date, recordType: type, genre: genre)
    }

    private struct Offline: Error {}

    private final class Fake: ArtistDirectory, @unchecked Sendable {
        let artists: [String: ArtistRef]
        let releasesById: [String: [TrackCollection]]
        let similarById: [String: [ArtistRef]]
        let top: [String: [Track]]
        let fail: Bool

        init(artists: [String: ArtistRef], releases: [String: [TrackCollection]], similar: [String: [ArtistRef]], top: [String: [Track]], fail: Bool = false) {
            self.artists = artists
            releasesById = releases
            similarById = similar
            self.top = top
            self.fail = fail
        }

        func find(_ name: String) async throws -> ArtistRef? {
            if fail { throw Offline() }
            return artists[Credits.key(name)]
        }

        func releases(_ artist: ArtistRef) async throws -> [TrackCollection] { releasesById[artist.id] ?? [] }

        func bestAlbums(_ artist: ArtistRef, limit: Int) async throws -> [TrackCollection] {
            Array((releasesById[artist.id] ?? []).filter { $0.recordType == "album" }.prefix(limit))
        }

        func similar(_ artist: ArtistRef) async throws -> [ArtistRef] { similarById[artist.id] ?? [] }

        func topTracks(_ artist: ArtistRef, limit: Int) async throws -> [Track] { Array((top[artist.id] ?? []).prefix(limit)) }

        func tracks(_ release: TrackCollection) async throws -> [Track] { [track(release.subtitle!, release.title + " (title track)")] }
    }

    private static func ref(_ name: String) -> ArtistRef { ArtistRef(id: "deezer:\(name)", name: name, fans: 1000) }

    private let world = Fake(
        artists: Dictionary(uniqueKeysWithValues: ["Daft Punk", "Justice", "Air", "Cassius", "Drake", "Phoenix"].map { (Credits.key($0), ref($0)) }),
        releases: [
            "deezer:Daft Punk": [
                album("Daft Punk", "New Thing", "2026-09-26", "single"),
                album("Daft Punk", "Homework", "1997-01-20"),
                album("Daft Punk", "Discovery", "2001-03-12"),
                album("Daft Punk", "Too Old News", "2026-06-01", "single"),
            ],
            "deezer:Justice": [album("Justice", "Hyperdrama", "2024-04-26"), album("Justice", "Cross", "2007-06-11")],
            "deezer:Cassius": [album("Cassius", "1999", "1999-01-01")],
            "deezer:Drake": [album("Drake", "Blocked Album", "2026-09-30", genre: "Rap/Hip Hop")],
            "deezer:Phoenix": [album("Phoenix", "Wolfgang", "2009-05-25", genre: "Alternative")],
        ],
        similar: [
            "deezer:Daft Punk": [ref("Justice"), ref("Cassius"), ref("Drake"), ref("Air")],
            "deezer:Air": [ref("Phoenix"), ref("Cassius")],
        ],
        top: [
            "deezer:Cassius": (1...6).map { track("Cassius", "C\($0)") },
            "deezer:Phoenix": (1...6).map { track("Phoenix", "P\($0)") },
            "deezer:Drake": (1...6).map { track("Drake", "D\($0)") },
            "deezer:Daft Punk": (1...8).map { track("Daft Punk", "New DP \($0)") } + [track("Daft Punk", "One More Time")],
            "deezer:Air": (1...6).map { track("Air", "Air \($0)") },
        ]
    )

    private let now: Int64 = 1_790_000_000_000
    private var familiar: [Played] {
        let day: Int64 = 86_400_000
        return [
            Played(track("Daft Punk", "One More Time", id: "phone:1"), plays: 40, lastPlayedAt: now - 2 * day),
            Played(track("Daft Punk", "Aerodynamic", id: "phone:2"), plays: 25, lastPlayedAt: now - 100 * day),
            Played(track("Daft Punk", "Digital Love", id: "phone:3"), plays: 3, lastPlayedAt: now - 50 * day),
            Played(track("Air", "La Femme d'Argent", id: "phone:4"), plays: 12, lastPlayedAt: now - 3 * day),
            Played(track("Air", "Sexy Boy", id: "phone:5"), plays: 8, lastPlayedAt: now - 200 * day),
            Played(track("Justice", "D.A.N.C.E.", id: "phone:6"), plays: 5, lastPlayedAt: now - 5 * day),
        ] + (1...10).map { Played(track("Air", "Air old \($0)", id: "phone:a\($0)"), plays: 2, lastPlayedAt: now - 5 * day) }
    }

    private func input(blocks: [String] = [], dismissed: Set<String> = [], discover: Double = 0.5) -> Discovery.Input {
        let signals = familiar.map { Signal($0.track.artist, $0.track.title, Double($0.plays), $0.lastPlayedAt) }
        let owned = Owned.Builder()
            .add("Daft Punk", "One More Time", album: "Discovery")
            .add("Air", "Sexy Boy", album: "Moon Safari")
            .add("Justice", "D.A.N.C.E.", album: "Cross")
            .build()
        return Discovery.Input(
            profile: Taste.build(signals, now: now),
            owned: owned,
            rules: Rules(blocks: ArtistBlocks(blocks), dismissed: dismissed),
            familiar: familiar,
            discover: discover,
            today: today,
            now: now
        )
    }

    func testBuildsTheFeed() async {
        let feed = await Discovery(directory: world).build(input())
        // New releases: within the last 30 days, newest first; older singles left out.
        XCTAssertEqual(feed.releases.filter { $0.artist == "Daft Punk" }.map(\.collection.title), ["New Thing"])
        XCTAssertEqual(feed.releases.first { $0.collection.title == "New Thing" }?.reason, "Single")
        // Missing: albums by artists the user owns, minus the ones they have (Discovery, Cross).
        let missing = feed.missing.map(\.collection.title)
        XCTAssertTrue(missing.contains("Homework"), "\(missing)")
        XCTAssertFalse(missing.contains("Discovery"))
        XCTAssertTrue(missing.contains("Hyperdrama"))
        XCTAssertFalse(missing.contains("Cross"))
        // Albums for you come from artists new to the user.
        let albums = feed.albums.map(\.artist)
        XCTAssertTrue(albums.contains("Cassius") || albums.contains("Phoenix"), "\(albums)")
        XCTAssertFalse(albums.contains("Daft Punk"))
        // Mixes: Release Radar, daily mixes, Discover, "Because you play…".
        let ids = feed.mixes.map(\.id)
        XCTAssertTrue(ids.contains("release-radar"), "\(ids)")
        XCTAssertTrue(ids.contains { $0.hasPrefix("daily-") }, "\(ids)")
        XCTAssertTrue(ids.contains { $0.hasPrefix("because-") }, "\(ids)")
        for mix in feed.mixes {
            let keys = mix.tracks.map { Keys.track($0.artist, $0.title) }
            XCTAssertEqual(Set(keys).count, keys.count, "\(mix.id) repeats a song")
            // Six artists in this world: at most five songs each in a mix of thirty.
            let perArtist = Dictionary(grouping: mix.tracks) { Credits.key($0.artist) }
            XCTAssertTrue(perArtist.values.allSatisfy { $0.count <= 5 }, "\(mix.id): too many by one artist")
        }
        // Rediscover: played a lot, not for a while.
        XCTAssertEqual(feed.rediscover.map(\.title), ["Aerodynamic", "Sexy Boy", "Digital Love"])
        XCTAssertFalse(feed.offline)
    }

    func testBlockedArtistsAndDismissedAlbumsNeverShowUp() async {
        let feed = await Discovery(directory: world).build(input(blocks: ["Drake"], dismissed: [Keys.album("Justice", "Hyperdrama")]))
        let everything = feed.releases.map(\.artist) + feed.albums.map(\.artist) + feed.missing.map(\.artist) +
            feed.mixes.flatMap { $0.tracks.map(\.artist) }
        XCTAssertFalse(everything.contains { Credits.key($0) == "drake" }, "\(everything)")
        XCTAssertFalse(feed.missing.contains { $0.collection.title == "Hyperdrama" })
        let unblocked = await Discovery(directory: world).build(input())
        XCTAssertTrue(unblocked.releases.contains { $0.artist == "Drake" } || unblocked.mixes.contains { $0.tracks.contains { $0.artist == "Drake" } })
    }

    func testTheDiscoverSliderChangesTheMix() async {
        func freshShare(_ feed: Feed) -> Double {
            guard let mix = feed.mixes.first(where: { $0.id.hasPrefix("daily-") }) else { return -1 }
            return Double(mix.tracks.filter { !$0.id.hasPrefix("phone:") }.count) / Double(mix.tracks.count)
        }
        let familiarFeed = await Discovery(directory: world).build(input(discover: 0))
        let adventurous = await Discovery(directory: world).build(input(discover: 1))
        XCTAssertGreaterThan(freshShare(adventurous), freshShare(familiarFeed))
    }

    func testWithoutAConnectionItStillMakesMixesFromWhatIsThere() async {
        let offline = Fake(artists: [:], releases: [:], similar: [:], top: [:], fail: true)
        let feed = await Discovery(directory: offline).build(input())
        XCTAssertTrue(feed.offline)
        XCTAssertTrue(feed.releases.isEmpty)
        XCTAssertTrue(feed.mixes.contains { $0.id.hasPrefix("daily-") && $0.tracks.allSatisfy { $0.id.hasPrefix("phone:") } }, "\(feed.mixes.map(\.id))")
        XCTAssertFalse(feed.rediscover.isEmpty)
    }

    func testSpreadKeepsTheSameArtistApart() {
        let list = [track("A", "1"), track("A", "2"), track("A", "3"), track("B", "1"), track("B", "2"), track("C", "1")]
        let spread = Discovery.spread(list)
        XCTAssertEqual(spread.count, list.count)
        XCTAssertEqual(zip(spread, spread.dropFirst()).filter { $0.artist == $1.artist }.count, 0, "\(spread.map(\.artist))")
    }

    func testFeedSurvivesSavingAndRules() throws {
        let feed = Feed(builtAt: 5, releases: [Pick(Self.album("Drake", "X", "2026-09-30"), artist: "Drake", reason: "Album", key: Keys.album("Drake", "X"))],
                        mixes: [Mix(id: "daily-1", title: "Daily Mix 1", subtitle: "A", tracks: [track("Drake", "D1"), track("Air", "A1")])])
        let again = try JSONDecoder().decode(Feed.self, from: JSONEncoder().encode(feed))
        XCTAssertEqual(again, feed)
        let filtered = feed.filtered(Rules(blocks: ArtistBlocks(["Drake"])))
        XCTAssertTrue(filtered.releases.isEmpty)
        XCTAssertEqual(filtered.mixes.first?.tracks.map(\.artist), ["Air"])
        XCTAssertEqual(feed.mixes[0].asCollection().id, "mix:daily-1")
    }
}

final class RecommendationSourceTests: XCTestCase {
    func testDeezerDiscography() throws {
        let json = try JSON.parse(#"""
        {"id":302127,"title":"Discovery","cover_xl":"https://e-cdns/x.jpg","genre_id":106,"fans":123,
         "release_date":"2001-03-07","record_type":"album","link":"https://www.deezer.com/album/302127"}
        """#)
        let album = try XCTUnwrap(Deezer.parseArtistAlbum(json, artistName: "Daft Punk", genres: [106: "Electro"]))
        XCTAssertEqual(album.id, "deezer:album:302127")
        XCTAssertEqual(album.subtitle, "Daft Punk")
        XCTAssertEqual(album.releaseDate, "2001-03-07")
        XCTAssertEqual(album.recordType, "album")
        XCTAssertEqual(album.genre, "Electro")
        let artist = try XCTUnwrap(Deezer.parseArtist(try JSON.parse(#"{"id":27,"name":"Daft Punk","nb_fan":4500000,"picture_xl":"p","type":"artist"}"#)))
        XCTAssertEqual(artist.id, "deezer:27")
        XCTAssertEqual(artist.fans, 4_500_000)
    }

    func testAppleMusicSinglesAndEPs() throws {
        let json = try JSON.parse(#"""
        {"results":[
          {"wrapperType":"artist","artistId":5468295,"artistName":"Daft Punk"},
          {"wrapperType":"collection","collectionId":1,"collectionName":"New Thing - Single","artistName":"Daft Punk","releaseDate":"2026-09-26T07:00:00Z","primaryGenreName":"Electronic"},
          {"wrapperType":"collection","collectionId":2,"collectionName":"Alive - EP","artistName":"Daft Punk","releaseDate":"1997-01-01T07:00:00Z"},
          {"wrapperType":"collection","collectionId":3,"collectionName":"Homework","artistName":"Daft Punk","releaseDate":"1997-01-20T08:00:00Z"}
        ]}
        """#)
        let albums = AppleMusic.parseResults(json).albums
        XCTAssertEqual(albums.map(\.title), ["New Thing", "Alive", "Homework"])
        XCTAssertEqual(albums.map(\.recordType), ["single", "ep", "album"])
        XCTAssertEqual(albums[0].releaseDate, "2026-09-26")
        XCTAssertEqual(albums[0].genre, "Electronic")
    }

    func testYouTubeMusicRadio() throws {
        let json = try JSON.parse(#"""
        {"contents":{"x":{"playlistPanelRenderer":{"contents":[
          {"playlistPanelVideoRenderer":{"videoId":"abcdefghijk","title":{"runs":[{"text":"Teardrop"}]},
            "longBylineText":{"runs":[
              {"text":"Massive Attack","navigationEndpoint":{"browseEndpoint":{"browseEndpointContextSupportedConfigs":{"browseEndpointContextMusicConfig":{"pageType":"MUSIC_PAGE_TYPE_ARTIST"}}}}},
              {"text":" • "},
              {"text":"Mezzanine","navigationEndpoint":{"browseEndpoint":{"browseEndpointContextSupportedConfigs":{"browseEndpointContextMusicConfig":{"pageType":"MUSIC_PAGE_TYPE_ALBUM"}}}}},
              {"text":" • "},{"text":"1998"}]},
            "lengthText":{"runs":[{"text":"5:31"}]},
            "thumbnail":{"thumbnails":[{"url":"https://lh3.googleusercontent.com/x=w60-h60"}]}}},
          {"playlistPanelVideoWrapperRenderer":{"primaryRenderer":{"playlistPanelVideoRenderer":{"videoId":"bbbbbbbbbbb",
            "title":{"runs":[{"text":"Glory Box"}]},"shortBylineText":{"runs":[{"text":"Portishead"}]}}}}}
        ]}}}}
        """#)
        let tracks = YouTubeMusic.parseRadio(json)
        XCTAssertEqual(tracks.map(\.title), ["Teardrop", "Glory Box"])
        XCTAssertEqual(tracks[0].artist, "Massive Attack")
        XCTAssertEqual(tracks[0].album, "Mezzanine")
        XCTAssertEqual(tracks[0].durationMs, 331_000)
        XCTAssertEqual(tracks[0].year, 1998)
        XCTAssertEqual(tracks[0].streamUrl, "https://music.youtube.com/watch?v=abcdefghijk")
        XCTAssertEqual(tracks[1].artist, "Portishead")
        XCTAssertEqual(YouTubeMusic.videoId("https://music.youtube.com/watch?v=abcdefghijk&list=x"), "abcdefghijk")
    }

    func testListenBrainzPlaylists() throws {
        let json = try JSON.parse(#"""
        {"playlist":{"title":"Weekly Exploration for rob","track":[
           {"title":"Roads","creator":"Portishead","album":"Dummy","identifier":["https://musicbrainz.org/recording/1234-abcd"]},
           {"title":"Angel","creator":"Massive Attack","identifier":"https://musicbrainz.org/recording/5678"}]}}
        """#)
        let tracks = ListenBrainz.parsePlaylist(json)
        XCTAssertEqual(tracks.map(\.id), ["listenbrainz:1234-abcd", "listenbrainz:5678"])
        XCTAssertTrue(tracks.allSatisfy(\.needsMatch))
        XCTAssertEqual(ListenBrainz.kind("Weekly Exploration for rob, week of 2026-09-28 Mon"), "weekly-exploration")
        XCTAssertNil(ListenBrainz.kind("My own playlist"))
    }

    func testSubsonicAnswersAndErrors() throws {
        let ok = try Subsonic.check(try JSON.parse(#"{"subsonic-response":{"status":"ok","version":"1.16.1","type":"navidrome","serverVersion":"0.58.0","openSubsonic":true}}"#))
        XCTAssertEqual(ok["type"].string, "navidrome")
        XCTAssertThrowsError(try Subsonic.check(try JSON.parse(#"{"subsonic-response":{"status":"failed","error":{"code":40,"message":"Wrong username or password"}}}"#))) { error in
            let e = error as? Subsonic.SubsonicError
            XCTAssertEqual(e?.code, 40)
            XCTAssertTrue(e?.message.contains("didn't accept") == true)
        }
        let song = try XCTUnwrap(Subsonic.parseSong(try JSON.parse(#"""
        {"id":"s1","title":"Teardrop","artist":"Massive Attack","album":"Mezzanine","albumId":"al1","artistId":"ar1",
         "genre":"Trip-Hop","year":1998,"track":3,"duration":331,"coverArt":"al-1","playCount":42,
         "played":"2026-09-20T18:30:00Z","starred":"2025-01-01T00:00:00Z","userRating":5,"isrc":["GBAAA9800001"]}
        """#)))
        XCTAssertEqual(song.playCount, 42)
        XCTAssertEqual(song.durationMs, 331_000)
        XCTAssertTrue(song.starred)
        XCTAssertEqual(song.rating, 5)
        XCTAssertEqual(song.isrc, "GBAAA9800001")
        XCTAssertEqual(song.playedAt, 1_789_929_000_000)
        XCTAssertEqual(Subsonic.parseDate("2026-09-20T18:30:00.250Z"), 1_789_929_000_250)
        XCTAssertEqual(Subsonic.baseUrl("nas.local:4533/app/#/album/all"), "http://nas.local:4533")
        XCTAssertEqual(Subsonic.baseUrl("https://music.example.com/"), "https://music.example.com")
        XCTAssertEqual(Subsonic.md5("sesame"), "c8dae1c50e092f3d877192fc555b1dcf")
    }

    func testSubsonicClientSignsEveryRequest() async throws {
        let songs = (1...3).map { #"{"id":"s\#($0)","title":"Song \#($0)","artist":"A","playCount":\#($0)}"# }.joined(separator: ",")
        StubServer.answers = [
            #"{"subsonic-response":{"status":"ok","type":"navidrome","serverVersion":"0.58.0","openSubsonic":true}}"#,
            #"{"subsonic-response":{"status":"ok","searchResult3":{"song":[\#(songs)]}}}"#,
        ]
        StubServer.requests = []
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubServer.self]
        let client = Subsonic(http: Http(session: URLSession(configuration: config)), server: .init(url: "http://stub.test:4533/", username: "kultr", password: "sesame"))
        let info = try await client.ping()
        XCTAssertEqual(info.description, "Navidrome 0.58.0")
        let all = try await client.songs(pageSize: 500)
        XCTAssertEqual(all.map(\.playCount), [1, 2, 3])
        let ping = try XCTUnwrap(StubServer.requests.first.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) })
        func param(_ c: URLComponents, _ name: String) -> String? { c.queryItems?.first { $0.name == name }?.value }
        XCTAssertEqual(ping.path, "/rest/ping.view")
        let salt = try XCTUnwrap(param(ping, "s"))
        XCTAssertEqual(param(ping, "t"), Subsonic.md5("sesame" + salt))
        XCTAssertEqual(param(ping, "u"), "kultr")
        XCTAssertEqual(param(ping, "f"), "json")
        XCTAssertNil(param(ping, "p"), "the password itself must never be sent")
        let search = try XCTUnwrap(URLComponents(url: StubServer.requests[1], resolvingAgainstBaseURL: false))
        XCTAssertEqual(param(search, "query"), "")
        XCTAssertEqual(param(search, "songOffset"), "0")
        let stream = client.streamUrl("s1")
        XCTAssertTrue(client.owns(stream))
        XCTAssertTrue(client.authenticate(stream).contains("&t="))
    }

    func testSubsonicSaysWhetherTheAccountIsAnAdmin() async throws {
        StubServer.answers = [
            #"{"subsonic-response":{"status":"ok","user":{"username":"me","adminRole":false,"streamRole":true}}}"#,
            #"{"subsonic-response":{"status":"ok","user":{"username":"admin","adminRole":true}}}"#,
            #"{"subsonic-response":{"status":"ok","user":{"username":"x"}}}"#,
        ]
        StubServer.requests = []
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubServer.self]
        let client = Subsonic(http: Http(session: URLSession(configuration: config)), server: .init(url: "http://stub.test:4533", username: "me", password: "pw"))
        let first = try await client.isAdmin()
        let second = try await client.isAdmin()
        let third = try await client.isAdmin()
        XCTAssertEqual(first, false)
        XCTAssertEqual(second, true)
        XCTAssertNil(third)
        let asked = try XCTUnwrap(StubServer.requests.first.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) })
        XCTAssertEqual(asked.path, "/rest/getUser.view")
        XCTAssertEqual(asked.queryItems?.first { $0.name == "username" }?.value, "me")
    }
}

/** Answers requests from a list, in order, and remembers what was asked. */
final class StubServer: URLProtocol {
    nonisolated(unsafe) static var answers: [String] = []
    nonisolated(unsafe) static var requests: [URL] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if let url = request.url { Self.requests.append(url) }
        let body = Self.answers.isEmpty ? "{}" : Self.answers.removeFirst()
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
