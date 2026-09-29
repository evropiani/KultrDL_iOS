import XCTest
@testable import KultrDLCore

final class JSONTests: XCTestCase {
    func testKeepsOrderAndReadsLoosely() throws {
        let json = try JSON.parse(#"{"b":1,"a":{"x":[true,null,"s",1.5e2,"é🎵"]},"id":12345678901234567890}"#)
        XCTAssertEqual(json.object?.keys, ["b", "a", "id"])
        XCTAssertEqual(json["b"].int, 1)
        XCTAssertEqual(json.path("a", "x", 0).bool, true)
        XCTAssertTrue(json.path("a", "x", 1)?.isNull == true)
        XCTAssertEqual(json.path("a", "x", 3).double, 150)
        XCTAssertEqual(json.path("a", "x", 4).string, "é🎵")
        XCTAssertEqual(json["id"].string, "12345678901234567890")
        XCTAssertNil(json["missing"]["deeper"].string)
        XCTAssertEqual(json["a"]?["x"].array.count, 5)
    }

    func testWalksInDocumentOrder() throws {
        let json = try JSON.parse(#"{"z":{"row":{"n":1}},"a":[{"row":{"n":2}},{"row":{"n":3}}]}"#)
        XCTAssertEqual(json.objectsUnder("row").map { $0["n"].int ?? 0 }, [1, 2, 3])
        XCTAssertEqual(json.firstString("n"), "1")
    }

    func testRoundTrips() throws {
        let built: JSON = ["context": ["client": ["clientName": "WEB", "n": 5]], "flag": true, "list": ["a", "\u{01}"]]
        let again = try JSON.parse(built.compact)
        XCTAssertEqual(again, built)
        XCTAssertEqual(built.object?.keys, ["context", "flag", "list"])
    }

    func testSkipsGoogleGuard() throws {
        XCTAssertEqual(try JSON.parse(")]}'\n{\"a\":1}")["a"].int, 1)
    }
}

final class TextTests: XCTestCase {
    func testCoreTitleDropsFeaturesAndRemasters() {
        XCTAssertEqual(Text.coreTitle("Paper Boats (feat. Somebody)"), "paper boats")
        XCTAssertEqual(Text.coreTitle("Paper Boats - 2011 Remastered Version"), "paper boats")
        XCTAssertEqual(Text.coreTitle("Paper Boats [Remastered 2009]"), "paper boats")
        XCTAssertEqual(Text.normalize("Café"), "cafe")
        XCTAssertEqual(Text.normalize("Simon & Garfunkel"), "simon and garfunkel")
    }

    func testYouTubeTitles() {
        let a = Text.artistAndTitle("Some Band - Paper Boats (Official Music Video)", channel: "SomeBandVEVO")
        XCTAssertEqual(a.artist, "Some Band")
        XCTAssertEqual(a.title, "Paper Boats")
        let b = Text.artistAndTitle("Paper Boats", channel: "Some Band - Topic")
        XCTAssertEqual(b.artist, "Some Band")
        XCTAssertEqual(b.title, "Paper Boats")
    }

    func testClocksAndDates() {
        XCTAssertEqual(Text.parseClock("3:45"), 225_000)
        XCTAssertEqual(Text.parseClock("1:02:03"), 3_723_000)
        XCTAssertNil(Text.parseClock("1.2M views"))
        XCTAssertEqual(Text.parseIsoDuration("PT3M45S"), 225_000)
        XCTAssertEqual(Text.year("2019-05-17T00:00:00Z"), 2019)
    }

    func testSimilarityAndArtists() {
        XCTAssertEqual(Text.similarity("Paper Boats", "paper boats"), 1.0)
        XCTAssertLessThan(Text.similarity("Paper Boats", "Glass Houses"), 0.4)
        XCTAssertEqual(Text.splitArtists("A, B & C"), ["A", "B", "C"])
        XCTAssertEqual(Text.splitArtists("A feat. B"), ["A", "B"])
        XCTAssertEqual(Text.fileName("A/B"), "A_B")
        XCTAssertEqual(Text.unescapeHtml("Tom &amp; Jerry &#39;s &#x263A;"), "Tom & Jerry 's ☺")
    }

    func testFormat() {
        XCTAssertEqual(Format.duration(225_000), "3:45")
        XCTAssertEqual(Format.duration(3_723_000), "1:02:03")
        XCTAssertEqual(Format.count(1, "track"), "1 track")
        XCTAssertEqual(Format.count(3, "track"), "3 tracks")
        XCTAssertEqual(Format.initials("paper boats"), "PB")
    }

    func testArtworkColor() {
        XCTAssertEqual(ArtworkColor.parseHex("#7c8cff"), 0xFF7C_8CFF)
        XCTAssertEqual(ArtworkColor.toHex(0xFF7C_8CFF), "#7c8cff")
        let red = [UInt32](repeating: 0xFFC0_2020, count: 100)
        XCTAssertNotNil(ArtworkColor.dominant(red))
        XCTAssertNil(ArtworkColor.dominant([UInt32](repeating: 0xFF00_0000, count: 10)))
        XCTAssertLessThanOrEqual(ArtworkColor.luminance(ArtworkColor.readableOnLight(0xFFFF_FF80)), 0.23)
    }
}

final class LinksTests: XCTestCase {
    private func check(_ url: String, _ source: Source, _ kind: LinkTarget.Kind, _ id: String?, file: StaticString = #filePath, line: UInt = #line) {
        let t = Links.classify(url)
        XCTAssertEqual(t.source, source, url, file: file, line: line)
        XCTAssertEqual(t.kind, kind, url, file: file, line: line)
        XCTAssertEqual(t.id, id, url, file: file, line: line)
    }

    func testYouTube() {
        check("https://www.youtube.com/watch?v=abc123XYZ_-&t=10", .youtube, .track, "abc123XYZ_-")
        check("https://youtu.be/abc123XYZ_-?si=x", .youtube, .track, "abc123XYZ_-")
        check("https://music.youtube.com/watch?v=abc123XYZ_-&list=RD", .youtubeMusic, .track, "abc123XYZ_-")
        check("https://music.youtube.com/playlist?list=OLAK5uy_x", .youtubeMusic, .playlist, "OLAK5uy_x")
        check("https://music.youtube.com/browse/MPREb_abc", .youtubeMusic, .album, "MPREb_abc")
        check("https://www.youtube.com/shorts/short1", .youtube, .track, "short1")
    }

    func testCatalogues() {
        check("https://open.spotify.com/track/4uLU6hMCjMI75M1A2tKUQC?si=abc", .spotify, .track, "4uLU6hMCjMI75M1A2tKUQC")
        check("https://open.spotify.com/intl-de/album/1ATL5GLyefJaxhQzSPVrLX", .spotify, .album, "1ATL5GLyefJaxhQzSPVrLX")
        check("spotify:playlist:37i9dQZF1DXcBWIGoYBM5M", .spotify, .playlist, "37i9dQZF1DXcBWIGoYBM5M")
        check("https://music.apple.com/us/album/some-album/1440857781?i=1440857795", .appleMusic, .track, "1440857795")
        check("https://music.apple.com/us/album/some-album/1440857781", .appleMusic, .album, "1440857781")
        check("https://music.apple.com/gb/playlist/todays-hits/pl.f4d106fed2bd41149aaacabb233eb5eb", .appleMusic, .playlist, "pl.f4d106fed2bd41149aaacabb233eb5eb")
        check("https://www.deezer.com/de/track/3135556", .deezer, .track, "3135556")
        check("https://www.deezer.com/album/302127", .deezer, .album, "302127")
        check("https://tidal.com/browse/track/77646169", .tidal, .track, "77646169")
        check("https://listen.tidal.com/album/77646168", .tidal, .album, "77646168")
        check("https://open.qobuz.com/track/12345678", .qobuz, .track, "12345678")
        check("https://www.qobuz.com/us-en/album/some-album-some-artist/abcdef123", .qobuz, .album, "abcdef123")
        check("https://music.amazon.com/albums/B0ABC?trackAsin=B0DEF", .amazonMusic, .track, "B0DEF")
        check("https://music.amazon.de/albums/B0ABC", .amazonMusic, .album, "B0ABC")
        check("https://soundcloud.com/artist/some-track", .soundcloud, .track, nil)
        check("https://soundcloud.com/artist/sets/some-set", .soundcloud, .playlist, nil)
        check("https://artist.bandcamp.com/album/record", .bandcamp, .album, nil)
        check("https://example.org/some/page", .web, .unknown, nil)
    }

    func testFindsLinksInSharedText() {
        XCTAssertEqual(Links.find("Listen: https://open.spotify.com/track/abc."), "https://open.spotify.com/track/abc")
        XCTAssertTrue(Links.isShortLink("https://spotify.link/xyz"))
        XCTAssertTrue(Links.isLink("https://tidal.com/track/1"))
        XCTAssertFalse(Links.isLink("daft punk"))
        XCTAssertTrue(Links.isAudioFile("https://example.org/a/song.mp3?x=1"))
    }
}

final class MatcherTests: XCTestCase {
    private func t(_ id: String, _ title: String, _ artist: String, _ seconds: Int64?, _ source: Source = .youtubeMusic) -> Track {
        Track(id: id, source: source, title: title, artist: artist, durationMs: seconds.map { $0 * 1000 }, streamUrl: "https://x/\(id)")
    }

    private let target = Track(id: "spotify:1", source: .spotify, title: "Paper Boats (feat. Guest)", artist: "Some Band, Guest", durationMs: 214_000)

    func testPrefersTheStudioRecording() {
        let candidates = [
            t("live", "Paper Boats (Live at Somewhere)", "Some Band", 260),
            t("remix", "Paper Boats (Club Remix)", "Some Band", 330),
            t("studio", "Paper Boats", "Some Band", 215),
            t("cover", "Paper Boats (Cover)", "Other Person", 214, .youtube),
        ]
        XCTAssertEqual(Matcher.best(target, candidates)?.id, "studio")
    }

    func testDurationBreaksTies() {
        XCTAssertEqual(Matcher.best(target, [t("long", "Paper Boats", "Some Band", 400), t("right", "Paper Boats", "Some Band", 213)])?.id, "right")
    }

    func testRejectsUnrelated() {
        XCTAssertNil(Matcher.best(target, [t("x", "Glass Houses", "Other Person", 180)]))
    }

    func testAsksForTheVersionWhenTheTargetIsLive() {
        var live = target
        live.title = "Paper Boats - Live"
        live.durationMs = 260_000
        XCTAssertEqual(Matcher.best(live, [t("studio", "Paper Boats", "Some Band", 215), t("live", "Paper Boats (Live)", "Some Band", 261)])?.id, "live")
    }
}

/** Parsers against small hand-written responses shaped like each service's. */
final class ParserTests: XCTestCase {
    private func run(_ text: String, _ pageType: String? = nil) -> String {
        var s = #"{"text":""# + text + "\""
        if let pageType {
            s += #","navigationEndpoint":{"browseEndpoint":{"browseId":"X","browseEndpointContextSupportedConfigs":{"browseEndpointContextMusicConfig":{"pageType":""#
            s += pageType + #""}}}}"#
        }
        return s + "}"
    }

    private func ytmRow(_ videoId: String, _ title: String, _ subtitleRuns: [String]) -> String {
        """
        {"musicResponsiveListItemRenderer":{
          "thumbnail":{"musicThumbnailRenderer":{"thumbnail":{"thumbnails":[{"url":"https://lh3.googleusercontent.com/abc=w60-h60-l90-rj","width":60}]}}},
          "flexColumns":[
            {"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[{"text":"\(title)","navigationEndpoint":{"watchEndpoint":{"videoId":"\(videoId)"}}}]}}},
            {"musicResponsiveListItemFlexColumnRenderer":{"text":{"runs":[\(subtitleRuns.joined(separator: ","))]}}}
          ],
          "playlistItemData":{"videoId":"\(videoId)"}
        }}
        """
    }

    func testYouTubeMusicSongs() throws {
        let rows = [
            ytmRow("vid00000001", "Paper Boats", [run("Some Band", "MUSIC_PAGE_TYPE_ARTIST"), run(" • "), run("Harbour", "MUSIC_PAGE_TYPE_ALBUM"), run(" • "), run("3:34")]),
            ytmRow("vid00000002", "Glass Houses", [run("Song"), run(" • "), run("Other Person"), run(" • "), run("1.2M plays"), run(" • "), run("4:01")]),
        ]
        let json = #"{"contents":{"tabbedSearchResultsRenderer":{"tabs":[{"tabRenderer":{"content":{"sectionListRenderer":{"contents":[{"musicShelfRenderer":{"contents":["#
            + rows.joined(separator: ",") + "]}}]}}}}]}}}"
        let tracks = YouTubeMusic.parseTracks(try JSON.parse(json), source: .youtubeMusic)
        XCTAssertEqual(tracks.count, 2)
        XCTAssertEqual(tracks[0].id, "yt:vid00000001")
        XCTAssertEqual(tracks[0].title, "Paper Boats")
        XCTAssertEqual(tracks[0].artist, "Some Band")
        XCTAssertEqual(tracks[0].album, "Harbour")
        XCTAssertEqual(tracks[0].durationMs, 214_000)
        XCTAssertEqual(tracks[0].artworkUrl, "https://lh3.googleusercontent.com/abc=w544-h544-l90-rj")
        XCTAssertEqual(tracks[0].streamUrl, "https://music.youtube.com/watch?v=vid00000001")
        XCTAssertEqual(tracks[1].artist, "Other Person")
        XCTAssertEqual(tracks[1].durationMs, 241_000)
    }

    func testYouTubeVideos() throws {
        let json = #"""
        {"contents":{"twoColumnSearchResultsRenderer":{"primaryContents":{"sectionListRenderer":{"contents":[{"itemSectionRenderer":{"contents":[
            {"videoRenderer":{"videoId":"vid00000003","title":{"runs":[{"text":"Some Band - Paper Boats (Official Video)"}]},
              "ownerText":{"runs":[{"text":"SomeBandVEVO"}]},"lengthText":{"simpleText":"3:36"},
              "thumbnail":{"thumbnails":[{"url":"https://i.ytimg.com/vi/vid00000003/hq720.jpg?sqp=x"}]}}}
        ]}}]}}}}}
        """#
        let tracks = YouTube.parse(try JSON.parse(json))
        XCTAssertEqual(tracks.count, 1)
        XCTAssertEqual(tracks[0].artist, "Some Band")
        XCTAssertEqual(tracks[0].title, "Paper Boats")
        XCTAssertEqual(tracks[0].durationMs, 216_000)
        XCTAssertEqual(tracks[0].artworkUrl, "https://i.ytimg.com/vi/vid00000003/hq720.jpg")
    }

    func testAppleMusicSearchAndAlbum() throws {
        let json = #"""
        {"resultCount":2,"results":[
            {"wrapperType":"collection","collectionId":111,"collectionName":"Harbour","artistName":"Some Band","artworkUrl100":"https://is1-ssl.mzstatic.com/image/thumb/a/100x100bb.jpg","trackCount":10,"releaseDate":"2012-03-01T08:00:00Z","collectionViewUrl":"https://music.apple.com/us/album/harbour/111?uo=4"},
            {"wrapperType":"track","kind":"song","trackId":222,"trackName":"Paper Boats","artistName":"Some Band","collectionName":"Harbour","trackTimeMillis":214000,"artworkUrl100":"https://is1-ssl.mzstatic.com/image/thumb/a/100x100bb.jpg","releaseDate":"2012-03-01T08:00:00Z","primaryGenreName":"Alternative","trackNumber":3,"discNumber":1,"trackExplicitness":"notExplicit","trackViewUrl":"https://music.apple.com/us/album/paper-boats/111?i=222&uo=4"}
        ]}
        """#
        let (tracks, albums) = AppleMusic.parseResults(try JSON.parse(json))
        XCTAssertEqual(tracks.first?.id, "apple:222")
        XCTAssertEqual(tracks.first?.artworkUrl, "https://is1-ssl.mzstatic.com/image/thumb/a/600x600bb.jpg")
        XCTAssertEqual(tracks.first?.year, 2012)
        XCTAssertEqual(tracks.first?.trackNumber, 3)
        XCTAssertEqual(albums.first?.id, "apple:album:111")
        XCTAssertEqual(albums.first?.kind, .album)
        XCTAssertEqual(tracks.first?.needsMatch, true)
    }

    func testDeezerAlbum() throws {
        let json = #"""
        {"id":302127,"title":"Harbour","cover_xl":"https://cdn/cover.jpg","release_date":"2012-03-01","nb_tracks":2,
            "artist":{"name":"Some Band"},"genres":{"data":[{"name":"Rock"}]},
            "tracks":{"data":[
              {"id":1,"type":"track","title":"Paper Boats","duration":214,"artist":{"name":"Some Band"},"link":"https://www.deezer.com/track/1"},
              {"id":2,"type":"track","title":"Glass Houses","duration":241,"artist":{"name":"Some Band"}}
            ]}}
        """#
        let album = try XCTUnwrap(Deezer.parseAlbumPage(try JSON.parse(json)))
        XCTAssertEqual(album.tracks.count, 2)
        XCTAssertEqual(album.tracks[0].album, "Harbour")
        XCTAssertEqual(album.tracks[1].artworkUrl, "https://cdn/cover.jpg")
        XCTAssertEqual(album.tracks[1].trackNumber, 2)
        XCTAssertEqual(album.tracks[0].genre, "Rock")
        XCTAssertEqual(album.tracks[0].durationMs, 214_000)
    }

    func testSpotifyEmbed() throws {
        let html = #"""
        <html><script id="__NEXT_DATA__" type="application/json">{"props":{"pageProps":{"state":{"data":{"entity":{
            "type":"album","name":"Harbour","uri":"spotify:album:AAA","subtitle":"Some Band",
            "coverArt":{"sources":[{"url":"https://i.scdn.co/small","width":64},{"url":"https://i.scdn.co/big","width":640}]},
            "releaseDate":{"isoString":"2012-03-01T00:00:00Z"},
            "trackList":[
              {"uri":"spotify:track:T1","title":"Paper Boats","subtitle":"Some Band","duration":214000},
              {"uri":"spotify:track:T2","title":"Glass Houses","subtitle":"Some Band, Guest","duration":241000}
            ]}}}}}}</script></html>
        """#
        let album = try XCTUnwrap(Spotify.parseEmbedList(try XCTUnwrap(Spotify.nextData(html)), kind: "album", id: "AAA"))
        XCTAssertEqual(album.title, "Harbour")
        XCTAssertEqual(album.artworkUrl, "https://i.scdn.co/big")
        XCTAssertEqual(album.tracks[1].id, "spotify:T2")
        XCTAssertEqual(album.tracks[1].artist, "Some Band, Guest")
        XCTAssertEqual(album.tracks[1].trackNumber, 2)
        XCTAssertEqual(album.year, 2012)

        let trackHtml = #"""
        <script id="__NEXT_DATA__" type="application/json">{"props":{"pageProps":{"state":{"data":{"entity":{
            "type":"track","name":"Paper Boats","uri":"spotify:track:T1","artists":[{"name":"Some Band"},{"name":"Guest"}],"duration":214000,
            "coverArt":{"sources":[{"url":"https://i.scdn.co/big","width":640}]}}}}}}}</script>
        """#
        let track = try XCTUnwrap(Spotify.parseEmbedTrack(try XCTUnwrap(Spotify.nextData(trackHtml)), fallbackId: "T1"))
        XCTAssertEqual(track.artist, "Some Band, Guest")
        XCTAssertEqual(track.durationMs, 214_000)
    }

    func testBandcampOdesliAndPages() throws {
        let bc = #"""
        {"auto":{"results":[
            {"type":"t","id":1,"name":"Paper Boats","band_name":"Some Band","album_name":"Harbour","img":"https://f4.bcbits.com/img/a1_3.jpg","item_url_path":"https://someband.bandcamp.com/track/paper-boats"},
            {"type":"a","id":2,"name":"Harbour","band_name":"Some Band","img":"https://f4.bcbits.com/img/a1_3.jpg","item_url_path":"https://someband.bandcamp.com/album/harbour"},
            {"type":"b","id":3,"name":"Some Band"}]}}
        """#
        let (tracks, albums) = Bandcamp.parse(try JSON.parse(bc))
        XCTAssertEqual(tracks.first?.streamUrl, "https://someband.bandcamp.com/track/paper-boats")
        XCTAssertEqual(tracks.first?.artworkUrl, "https://f4.bcbits.com/img/a1_10.jpg")
        XCTAssertEqual(albums.first?.title, "Harbour")

        let od = #"""
        {"entityUniqueId":"TIDAL_SONG::1","entitiesByUniqueId":{"TIDAL_SONG::1":{"type":"song","title":"Paper Boats","artistName":"Some Band","thumbnailUrl":"https://t/img.jpg"}},
            "linksByPlatform":{"tidal":{"url":"https://tidal.com/track/1"},"youtubeMusic":{"url":"https://music.youtube.com/watch?v=vid00000001"}}}
        """#
        let entity = try XCTUnwrap(Odesli.parse(try JSON.parse(od)))
        XCTAssertEqual(entity.title, "Paper Boats")
        XCTAssertEqual(entity.youtubeUrl, "https://music.youtube.com/watch?v=vid00000001")

        let page = #"""
        <html><head><title>x</title>
            <meta property="og:title" content="Harbour - Some Band | Qobuz">
            <meta property="og:image" content="https://static.qobuz.com/cover.jpg">
            <script type="application/ld+json">{"@context":"https://schema.org","@type":"MusicAlbum","name":"Harbour","byArtist":{"@type":"MusicGroup","name":"Some Band"},
              "track":{"@type":"ItemList","itemListElement":[{"@type":"ListItem","item":{"@type":"MusicRecording","name":"Paper Boats","duration":"PT3M34S"}}]}}</script>
            </head></html>
        """#
        let meta = WebPage.parse(page)
        XCTAssertEqual(meta.schemaType, "MusicAlbum")
        XCTAssertEqual(meta.byArtist, "Some Band")
        XCTAssertEqual(meta.recordings.first?.durationMs, 214_000)
        XCTAssertEqual(meta.image, "https://static.qobuz.com/cover.jpg")
        let split = WebPage.splitTitle("Harbour - Some Band | Qobuz", store: "Qobuz")
        XCTAssertEqual(split.title, "Harbour")
        XCTAssertEqual(split.artist, "Some Band")
        let byline = WebPage.splitTitle("Harbour by Some Band on TIDAL", store: "Tidal")
        XCTAssertEqual(byline.title, "Harbour")
        XCTAssertEqual(byline.artist, "Some Band")
    }

    func testBandcampPage() throws {
        let tralbum = #"{"artist":"Some Band","item_type":"album","current":{"title":"Harbour","id":77},"art_id":1234567890,"album_release_date":"01 Mar 2012 00:00:00 GMT","trackinfo":[{"title":"Paper Boats","track_num":1,"duration":214.5,"title_link":"/track/paper-boats","track_id":5,"file":{"mp3-128":"https://t4.bcbits.com/stream/abc"}},{"title":"Glass Houses","track_num":2,"duration":241,"title_link":"/track/glass-houses","track_id":6}]}"#
        let escaped = tralbum.replacingOccurrences(of: "\"", with: "&quot;")
        let html = "<div data-tralbum=\"\(escaped)\"></div>"
        guard case .many(let album)? = Bandcamp.parsePage(html, url: "https://someband.bandcamp.com/album/harbour") else {
            return XCTFail("Expected an album")
        }
        XCTAssertEqual(album.title, "Harbour")
        XCTAssertEqual(album.tracks.count, 2)
        XCTAssertEqual(album.tracks[1].streamUrl, "https://someband.bandcamp.com/track/glass-houses")
        XCTAssertEqual(album.tracks[0].durationMs, 214_500)
        XCTAssertEqual(album.year, 2012)
        XCTAssertEqual(album.artworkUrl, "https://f4.bcbits.com/img/a1234567890_10.jpg")
    }

    func testSoundCloudTrack() throws {
        let json = try JSON.parse(#"{"id":123,"title":"Late Set","user":{"username":"dj"},"full_duration":300000,"artwork_url":"https://i1.sndcdn.com/artworks-x-large.jpg","permalink_url":"https://soundcloud.com/dj/late-set","genre":"House","created_at":"2020-01-02T00:00:00Z"}"#)
        let track = try XCTUnwrap(SoundCloud.parseTrack(json, album: nil))
        XCTAssertEqual(track.id, "soundcloud:123")
        XCTAssertEqual(track.artist, "dj")
        XCTAssertEqual(track.artworkUrl, "https://i1.sndcdn.com/artworks-x-t500x500.jpg")
        XCTAssertEqual(track.streamUrl, "https://soundcloud.com/dj/late-set")
        XCTAssertEqual(track.year, 2020)
    }

    func testVideoDetails() throws {
        let json = try JSON.parse(#"{"videoDetails":{"videoId":"vid00000001","title":"Paper Boats","author":"Some Band - Topic","lengthSeconds":"214","thumbnail":{"thumbnails":[{"url":"https://i.ytimg.com/a.jpg","width":120},{"url":"https://i.ytimg.com/b.jpg?x=1","width":640}]}}}"#)
        let track = try XCTUnwrap(YouTube.parseVideoDetails(json, source: .youtube))
        XCTAssertEqual(track.artist, "Some Band")
        XCTAssertEqual(track.title, "Paper Boats")
        XCTAssertEqual(track.durationMs, 214_000)
        XCTAssertEqual(track.artworkUrl, "https://i.ytimg.com/b.jpg")
    }
}

final class StreamTests: XCTestCase {
    func testHLS() {
        let master = """
        #EXTM3U
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="a",NAME="en",URI="audio/index.m3u8"
        #EXT-X-STREAM-INF:BANDWIDTH=800000,CODECS="avc1.4d401f,mp4a.40.2",AUDIO="a"
        video/low.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=160000,CODECS="mp4a.40.2"
        https://cdn.example.org/audio-only.m3u8
        """
        XCTAssertTrue(HLS.isMaster(master))
        let best = HLS.bestAudio(master, base: "https://cdn.example.org/master/playlist.m3u8")
        XCTAssertEqual(best?.audioOnly, true)
        let media = HLS.media("""
        #EXTM3U
        #EXT-X-MAP:URI="init.mp4"
        #EXTINF:10.0,
        seg1.m4s
        #EXTINF:5.5,
        seg2.m4s
        """, base: "https://cdn.example.org/a/index.m3u8")
        XCTAssertEqual(media.initSegment, "https://cdn.example.org/a/init.mp4")
        XCTAssertEqual(media.segments, ["https://cdn.example.org/a/seg1.m4s", "https://cdn.example.org/a/seg2.m4s"])
        XCTAssertEqual(media.durationSeconds, 15.5, accuracy: 0.01)
        XCTAssertFalse(media.encrypted)
    }

    func testYouTubeLinks() {
        XCTAssertEqual(YouTubePlayer.query("https://x/videoplayback?expire=1700000000&n=abc%3D&sig=1")["n"], "abc=")
        let set = YouTubePlayer.setQuery("https://x/videoplayback?expire=1&n=old", "n", "new/value")
        XCTAssertTrue(set.contains("n=new%2Fvalue"))
        XCTAssertFalse(set.contains("n=old"))
        XCTAssertEqual(YouTubePlayer.expiry("https://x/videoplayback?expire=1700000000&a=1")?.timeIntervalSince1970, 1_700_000_000)
        XCTAssertEqual(StreamFinder.youtubeId("https://music.youtube.com/watch?v=abc123XYZ_-"), "abc123XYZ_-")
        XCTAssertEqual(JSChallengeSolver.canonicalPlayerUrl("/s/player/0123abcd/player-plasma-ias-phone-en_US.vflset/base.js"),
                       "https://www.youtube.com/s/player/0123abcd/player_ias.vflset/en_US/base.js")
    }

    func testSolverScriptsAreBundled() {
        let scripts = JSChallengeSolver.bundledScripts()
        XCTAssertNotNil(scripts)
        XCTAssertTrue(scripts?.lib.contains("meriyah") == true)
        XCTAssertTrue(scripts?.core.contains("jsc") == true)
    }

    func testTSDemux() throws {
        // A PAT, a PMT naming AAC on PID 0x101, and one PES packet with a few payload bytes.
        func packet(_ pid: Int, _ start: Bool, _ payload: [UInt8]) -> [UInt8] {
            var p: [UInt8] = [0x47, UInt8((start ? 0x40 : 0) | ((pid >> 8) & 0x1F)), UInt8(pid & 0xFF), 0x10]
            p += payload
            p += [UInt8](repeating: 0xFF, count: 188 - p.count)
            return p
        }
        let pat: [UInt8] = [0x00, 0x00, 0xB0, 0x0D, 0x00, 0x01, 0xC1, 0x00, 0x00, 0x00, 0x01, 0xF0, 0x00, 0, 0, 0, 0]
        let pmt: [UInt8] = [0x00, 0x02, 0xB0, 0x12, 0x00, 0x01, 0xC1, 0x00, 0x00, 0xE1, 0x01, 0xF0, 0x00, 0x0F, 0xE1, 0x01, 0xF0, 0x00, 0, 0, 0, 0]
        let pes: [UInt8] = [0x00, 0x00, 0x01, 0xC0, 0x00, 0x00, 0x80, 0x00, 0x00, 0xFF, 0xF1, 0x50, 0x80]
        let bytes = packet(0, true, pat) + packet(0x1000, true, pmt) + packet(0x101, true, pes)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("kdl-test.ts")
        try Data(bytes).write(to: url)
        let (audio, kind) = try TSDemuxer.extractAudio(from: url)
        XCTAssertEqual(kind, "aac")
        XCTAssertEqual(Array(audio.prefix(4)), [0xFF, 0xF1, 0x50, 0x80])
    }
}

final class MediaFileTests: XCTestCase {
    func testID3() {
        var tags = TrackTags(title: "Paper Boats", artist: "Some Band", album: "Harbour", year: 2012, trackNumber: 3)
        tags.cover = Data([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3])
        let tag = [UInt8](ID3.tag(tags))
        XCTAssertEqual(Array(tag.prefix(4)), [0x49, 0x44, 0x33, 0x04])
        XCTAssertEqual(ID3.tagSize(tag), tag.count)
        let text = String(decoding: tag, as: UTF8.self)
        XCTAssertTrue(text.contains("TIT2"))
        XCTAssertTrue(text.contains("Paper Boats"))
        XCTAssertTrue(text.contains("APIC"))
        XCTAssertTrue(text.contains("image/jpeg"))
    }

    func testVorbisComments() {
        let fields = VorbisComment.fields(TrackTags(title: "T", artist: "A", trackNumber: 1, cover: Data([0xFF, 0xD8])))
        XCTAssertEqual(fields.first, "TITLE=T")
        XCTAssertTrue(fields.contains("TRACKNUMBER=1"))
        XCTAssertTrue(fields.last?.hasPrefix("METADATA_BLOCK_PICTURE=") == true)
        let body = [UInt8](VorbisComment.body(vendor: "v", fields: ["A=1"]))
        XCTAssertEqual(body, [1, 0, 0, 0, 0x76, 1, 0, 0, 0, 3, 0, 0, 0, 0x41, 0x3D, 0x31])
    }

    func testWAV() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("kdl-test.wav")
        let writer = try WAVWriter(url: url, sampleRate: 44100, channels: 2, bits: 16, tags: TrackTags(title: "T", artist: "A"))
        let samples: [Float] = [0, 0.5, -0.5, 1, -1, 0.25]
        try samples.withUnsafeBufferPointer { try writer.write($0) }
        try writer.finish()
        let bytes = [UInt8](try Data(contentsOf: url))
        XCTAssertEqual(String(decoding: bytes[0..<4], as: UTF8.self), "RIFF")
        XCTAssertEqual(Int(bytes[4]) | Int(bytes[5]) << 8 | Int(bytes[6]) << 16 | Int(bytes[7]) << 24, bytes.count - 8)
        let dataAt = try XCTUnwrap(String(decoding: bytes, as: UTF8.self).range(of: "data")).lowerBound.utf16Offset(in: String(decoding: bytes, as: UTF8.self))
        XCTAssertGreaterThan(dataAt, 0)
        XCTAssertEqual(bytes.suffix(12).count, 12)
    }

    func testWebM() throws {
        // EBML header, then a segment with one Opus track and a cluster of two SimpleBlocks.
        func el(_ id: [UInt8], _ body: [UInt8]) -> [UInt8] {
            precondition(body.count < 0x7F)
            return id + [0x80 | UInt8(body.count)] + body
        }
        let head: [UInt8] = [0x4F, 0x70, 0x75, 0x73, 0x48, 0x65, 0x61, 0x64, 1, 2, 0x38, 0x01, 0x80, 0xBB, 0, 0, 0, 0, 0]
        let track = el([0xAE], el([0xD7], [1]) + el([0x83], [2]) + el([0x86], Array("A_OPUS".utf8)) + el([0x63, 0xA2], head)
            + el([0xE1], el([0x9F], [2])))
        let tracks = el([0x16, 0x54, 0xAE, 0x6B], track)
        let block1 = el([0xA3], [0x81, 0x00, 0x00, 0x80, 0xFC, 0x01, 0x02])
        let block2 = el([0xA3], [0x81, 0x00, 0x14, 0x80, 0xFC, 0x03])
        let cluster = el([0x1F, 0x43, 0xB6, 0x75], el([0xE7], [0x00]) + block1 + block2)
        let segment = [0x18, 0x53, 0x80, 0x67, 0x01, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF] + tracks + cluster
        let ebml = el([0x1A, 0x45, 0xDF, 0xA3], el([0x42, 0x82], Array("webm".utf8)))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("kdl-test.webm")
        try Data(ebml + segment).write(to: url)
        let audio = try WebMAudio.read(url)
        XCTAssertTrue(audio.isOpus)
        XCTAssertEqual(audio.channels, 2)
        XCTAssertEqual(audio.packets.count, 2)
        XCTAssertEqual([UInt8](audio.packets[0].data), [0xFC, 0x01, 0x02])
        XCTAssertEqual(audio.packets[1].timeNs, 20 * 1_000_000)
        XCTAssertEqual(audio.codecPrivate.count, head.count)
    }
}

final class RemotePathTests: XCTestCase {
    func testNormalisesAndJoins() {
        XCTAssertEqual(RemotePath.normalise("/a//b/"), "/a/b")
        XCTAssertEqual(RemotePath.normalise("a/./b"), "a/b")
        XCTAssertEqual(RemotePath.normalise("/"), "/")
        XCTAssertEqual(RemotePath.normalise("  "), "")
        XCTAssertEqual(RemotePath.normalise("/a/b/.."), "/a")
        XCTAssertEqual(RemotePath.resolve("/home/me", "music"), "/home/me/music")
        XCTAssertEqual(RemotePath.resolve("/home/me", "/srv/"), "/srv")
        XCTAssertEqual(RemotePath.resolve("/home/me", ""), "/home/me")
        XCTAssertEqual(RemotePath.join("/music", "Artist", "x.mp3"), "/music/Artist/x.mp3")
        XCTAssertEqual(RemotePath.join("/", "x.mp3"), "/x.mp3")
        XCTAssertEqual(RemotePath.parent("/a/b"), "/a")
        XCTAssertEqual(RemotePath.parent("/a"), "/")
        XCTAssertEqual(RemotePath.ancestors("/a/b"), ["/a", "/a/b"])
        XCTAssertEqual(RemotePath.ancestors("/"), [])
    }

    func testLayoutsNameFoldersSafely() {
        XCTAssertEqual(FolderLayout.flat.folders(artist: "A", albumArtist: nil, album: "B"), [])
        XCTAssertEqual(FolderLayout.artist.folders(artist: "AC/DC", albumArtist: nil, album: nil), ["AC_DC"])
        XCTAssertEqual(FolderLayout.artistAlbum.folders(artist: "A", albumArtist: "Various", album: "Hits: 1"), ["Various", "Hits_ 1"])
        XCTAssertEqual(sshFingerprint(Data("x".utf8)).prefix(7), "SHA256:")
    }

    func testModelsDecodeAndroidBackups() throws {
        let json = #"{"id":"yt:abc","source":"YOUTUBE_MUSIC","title":"T","artist":"A","durationMs":1000,"explicit":false,"unknownField":1}"#
        let track = try JSONDecoder().decode(Track.self, from: Data(json.utf8))
        XCTAssertEqual(track.source, .youtubeMusic)
        XCTAssertEqual(track.durationMs, 1000)
        let preset = try JSONDecoder().decode(DownloadPreset.self, from: Data(#"{"format":"FLAC","quality":"BIT24"}"#.utf8))
        XCTAssertEqual(preset.format, .flac)
        XCTAssertEqual(preset.label, "FLAC · 24-bit")
    }
}
