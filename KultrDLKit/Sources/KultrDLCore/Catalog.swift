import Foundation

/**
 * Everything KultrDL can search and every link it can open, in one place:
 * each source's own API where there is one, song.link and page metadata
 * for stores without one, and YouTube's, SoundCloud's and Bandcamp's own
 * pages for the rest (what yt-dlp does on Android).
 */
public final class Catalog: @unchecked Sendable {
    public let http: Http
    public let youTubeMusic: YouTubeMusic
    public let youTube: YouTube
    public let apple: AppleMusic
    public let deezer: Deezer
    public let spotify: Spotify
    public let bandcamp: Bandcamp
    public let soundCloud: SoundCloud
    private let odesli: Odesli
    private let web: WebPage
    private let country: @Sendable () -> String

    public init(
        http: Http,
        country: @escaping @Sendable () -> String,
        spotifyCredentials: @escaping @Sendable () -> (id: String, secret: String)?
    ) {
        self.http = http
        self.country = country
        youTubeMusic = YouTubeMusic(http: http)
        youTube = YouTube(http: http)
        apple = AppleMusic(http: http, country: country)
        deezer = Deezer(http: http)
        spotify = Spotify(http: http, credentials: spotifyCredentials)
        bandcamp = Bandcamp(http: http)
        soundCloud = SoundCloud(http: http)
        odesli = Odesli(http: http)
        web = WebPage(http: http)
    }

    public func search(_ source: Source, _ query: String) async throws -> SearchResults {
        let q = query.trimmed()
        switch source {
        case .youtubeMusic:
            async let songs = youTubeMusic.searchSongs(q)
            async let albums = youTubeMusic.searchAlbums(q)
            let tracks: [Track]
            do {
                tracks = try await songs
            } catch {
                // The music site refused: plain YouTube search still finds the songs.
                guard let fallback = try? await youTube.search(q) else { throw error }
                tracks = fallback
            }
            return SearchResults(tracks: tracks, collections: (try? await albums) ?? [])
        case .youtube:
            return SearchResults(tracks: try await youTube.search(q))
        case .appleMusic:
            async let songs = apple.searchSongs(q)
            async let albums = apple.searchAlbums(q)
            let tracks = try await songs
            return SearchResults(tracks: tracks, collections: (try? await albums) ?? [])
        case .deezer:
            async let songs = deezer.searchTracks(q)
            async let albums = deezer.searchAlbums(q)
            let tracks = try await songs
            return SearchResults(tracks: tracks, collections: (try? await albums) ?? [])
        case .spotify:
            guard spotify.canSearch else {
                throw KultrError(
                    "Searching Spotify needs a free Spotify developer Client ID and secret (Settings → Search and sources). Spotify links work without one.",
                    notSupported: true
                )
            }
            async let songs = spotify.searchTracks(q)
            async let albums = spotify.searchAlbums(q)
            let tracks = try await songs
            return SearchResults(tracks: tracks, collections: (try? await albums) ?? [])
        case .soundcloud:
            return SearchResults(tracks: try await soundCloud.search(q))
        case .bandcamp:
            let (tracks, albums) = try await bandcamp.search(q)
            return SearchResults(tracks: tracks, collections: albums)
        default:
            throw KultrError("\(source.label) can't be searched. Paste a \(source.label) link instead.", notSupported: true)
        }
    }

    /** An album or playlist from search results, with its tracks. */
    public func load(_ collection: TrackCollection) async throws -> TrackCollection {
        if !collection.tracks.isEmpty { return collection }
        let id = collection.id
        var loaded: TrackCollection?
        if id.hasPrefix("ytm:VL") {
            loaded = try await youTubeMusic.playlist(String(id.dropFirst(4)))
        } else if id.hasPrefix("ytm:") {
            loaded = try await youTubeMusic.album(String(id.dropFirst(4)))
        } else if id.hasPrefix("apple:album:") {
            loaded = try await apple.album(String(id.dropFirst("apple:album:".count)))
        } else if id.hasPrefix("deezer:album:") {
            loaded = try await deezer.album(String(id.dropFirst("deezer:album:".count)))
        } else if id.hasPrefix("deezer:playlist:") {
            loaded = try await deezer.playlist(String(id.dropFirst("deezer:playlist:".count)))
        } else if id.hasPrefix("spotify:album:") || id.hasPrefix("spotify:playlist:") {
            let kind = id.hasPrefix("spotify:album:") ? "album" : "playlist"
            if case .collection(let c)? = try await spotify.load(kind, id.afterLast(":")) { loaded = c }
        } else if let page = collection.pageUrl {
            if case .many(let c) = try await extract(page) { loaded = c }
        }
        guard var result = loaded else { throw KultrError("Couldn't load “\(collection.title)”.") }
        if result.title.isEmpty { result.title = collection.title }
        result.subtitle = result.subtitle ?? collection.subtitle
        result.artworkUrl = result.artworkUrl ?? collection.artworkUrl
        result.year = result.year ?? collection.year
        return result
    }

    /** Whatever a pasted or shared link points at. */
    public func resolve(_ text: String) async throws -> LinkResult {
        guard var url = Links.find(text) else { throw KultrError("That doesn't look like a link.") }
        if Links.isShortLink(url), let final = try? await http.finalUrl(url) { url = final }
        let target = Links.classify(url)
        switch target.source {
        case .spotify: return try await spotifyLink(target)
        case .appleMusic: return try await appleLink(target)
        case .deezer: return try await deezerLink(target)
        case .tidal, .amazonMusic: return try await odesliLink(target)
        case .qobuz: return try await pageLink(target)
        case .youtubeMusic, .youtube, .soundcloud, .bandcamp, .web: return try await extract(target.url)
        }
    }

    /**
     * A link to a site KultrDL reads itself: YouTube and YouTube Music
     * videos and playlists, SoundCloud tracks and sets, Bandcamp tracks and
     * albums, and links straight to an audio file.
     */
    public func extract(_ url: String) async throws -> LinkResult {
        let target = Links.classify(url)
        switch target.source {
        case .youtube, .youtubeMusic:
            if target.kind == .album, let id = target.id {
                guard let album = try await youTubeMusic.album(id) else { throw KultrError("Couldn't open that album.") }
                return .many(album)
            }
            if target.kind == .track, let id = target.id {
                return .single(try await video(id, music: target.source == .youtubeMusic))
            }
            if target.kind == .playlist, let id = target.id {
                // Mixes ("RD…") are endless and personal; open the video they started from instead.
                if id.hasPrefix("RD"), let v = Links.query(url, "v") { return .single(try await video(v, music: target.source == .youtubeMusic)) }
                let musicFirst = target.source == .youtubeMusic || id.hasPrefix("OLAK")
                if musicFirst, let found = try? await youTubeMusic.playlist(id) { return .many(found) }
                if let found = try? await youTube.playlist(id) { return .many(found) }
                if !musicFirst, let found = try? await youTubeMusic.playlist(id) { return .many(found) }
                throw KultrError("Couldn't open that playlist. Private playlists can't be read.")
            }
            throw KultrError("Channel links aren't supported. Open a video, album or playlist.", notSupported: true)
        case .soundcloud:
            return try await soundCloud.resolve(url)
        case .bandcamp:
            if target.kind == .artist { throw KultrError("Open a Bandcamp track or album page.", notSupported: true) }
            return try await bandcamp.page(url)
        default:
            if Links.isAudioFile(url) {
                let name = (URLComponents(string: url)?.path ?? url) as NSString
                let title = (name.lastPathComponent as NSString).deletingPathExtension.removingPercentEncoding ?? "Audio"
                return .single(Track(
                    id: "web:\(Self.hash(url))",
                    source: .web,
                    title: title,
                    artist: Links.host(url) ?? "Web",
                    pageUrl: url,
                    streamUrl: url
                ))
            }
            let meta = try await web.read(url)
            if let audio = meta.audio {
                return .single(Track(
                    id: "web:\(Self.hash(url))",
                    source: .web,
                    title: meta.title ?? "Audio",
                    artist: meta.musician ?? Links.host(url) ?? "Web",
                    artworkUrl: meta.image,
                    pageUrl: url,
                    streamUrl: audio
                ))
            }
            throw KultrError("KultrDL can't read this site. Links from YouTube, SoundCloud, Bandcamp, the music stores, and links straight to an audio file work.", notSupported: true)
        }
    }

    /** A video's details: YouTube Music's view of it first for music links, then YouTube's, then oEmbed. */
    public func video(_ id: String, music: Bool) async throws -> Track {
        if music, let t = try? await youTubeMusic.song(id) { return t }
        if let t = try? await youTube.video(id) {
            if music {
                var m = t
                m.source = .youtubeMusic
                m.pageUrl = YouTubeMusic.watchUrl(id)
                m.streamUrl = YouTubeMusic.watchUrl(id)
                return m
            }
            return t
        }
        if !music, let t = try? await youTubeMusic.song(id) {
            var y = t
            y.source = .youtube
            y.pageUrl = YouTube.watchUrl(id)
            y.streamUrl = YouTube.watchUrl(id)
            return y
        }
        let watch = music ? YouTubeMusic.watchUrl(id) : YouTube.watchUrl(id)
        let oembed = try await http.getJSON("https://www.youtube.com/oembed?format=json&url=\(YouTube.watchUrl(id).urlQueryEncoded)")
        let raw = oembed["title"].string ?? "Video"
        let (artist, title) = Text.artistAndTitle(raw, channel: oembed["author_name"].string)
        return Track(
            id: "yt:\(id)",
            source: music ? .youtubeMusic : .youtube,
            title: title,
            artist: artist.nonEmpty ?? "Unknown artist",
            artworkUrl: oembed["thumbnail_url"].string,
            pageUrl: watch,
            streamUrl: watch
        )
    }

    private func spotifyLink(_ target: LinkTarget) async throws -> LinkResult {
        guard let id = target.id else { throw KultrError("That Spotify link isn't a track, album or playlist.", notSupported: true) }
        switch target.kind {
        case .track:
            guard case .track(let track)? = try await spotify.load("track", id) else { throw KultrError("Couldn't read that Spotify track.") }
            return .single(await withOdesliHint(track, target.url))
        case .album:
            guard case .collection(let c)? = try await spotify.load("album", id) else { throw KultrError("Couldn't read that Spotify album.") }
            return .many(c)
        case .playlist:
            guard case .collection(let c)? = try await spotify.load("playlist", id) else { throw KultrError("Couldn't read that Spotify playlist.") }
            return .many(c)
        default:
            throw KultrError("Artist links aren't supported yet. Open a track, album or playlist.", notSupported: true)
        }
    }

    private func appleLink(_ target: LinkTarget) async throws -> LinkResult {
        let id = target.id.map { $0.filter(\.isASCIIDigitChar) }?.nonEmpty
        switch target.kind {
        case .track:
            guard let id else { throw KultrError("Unknown Apple Music song.") }
            guard let song = try await apple.song(id) else { throw KultrError("Apple Music didn't find that song.") }
            return .single(song)
        case .album:
            guard let id else { throw KultrError("Unknown Apple Music album.") }
            guard let album = try await apple.album(id) else { throw KultrError("Apple Music didn't find that album.") }
            return .many(album)
        case .playlist:
            return try await pageLink(target)
        default:
            throw KultrError("Artist links aren't supported yet. Open a song, album or playlist.", notSupported: true)
        }
    }

    private func deezerLink(_ target: LinkTarget) async throws -> LinkResult {
        guard let id = target.id else { throw KultrError("That Deezer link isn't a track, album or playlist.", notSupported: true) }
        switch target.kind {
        case .track:
            guard let t = try await deezer.track(id) else { throw KultrError("Deezer didn't find that track.") }
            return .single(t)
        case .album:
            guard let a = try await deezer.album(id) else { throw KultrError("Deezer didn't find that album.") }
            return .many(a)
        case .playlist:
            guard let p = try await deezer.playlist(id) else { throw KultrError("Deezer didn't find that playlist.") }
            return .many(p)
        default:
            throw KultrError("Artist links aren't supported yet. Open a track, album or playlist.", notSupported: true)
        }
    }

    /** Tidal and Amazon Music: song.link knows what the link is, and where it is on YouTube. */
    private func odesliLink(_ target: LinkTarget) async throws -> LinkResult {
        if target.kind == .playlist { return try await pageLink(target) }
        guard let entity = try? await odesli.lookup(target.url, country: country().uppercased().nonEmpty ?? "US") else {
            return try await pageLink(target)
        }
        let artist = entity.artist ?? "Unknown artist"
        if entity.type == "album" {
            return .many(try await albumByName(entity.title, artist: artist, target: target, artwork: entity.artworkUrl))
        }
        return .single(Track(
            id: "\(target.source.key):\(target.id ?? Text.normalize(entity.title))",
            source: target.source,
            title: entity.title,
            artist: artist,
            artworkUrl: entity.artworkUrl,
            pageUrl: target.url,
            matchUrl: entity.youtubeUrl
        ))
    }

    /** Qobuz, and playlists on stores without an API: read the page itself. */
    private func pageLink(_ target: LinkTarget) async throws -> LinkResult {
        let meta = try await web.read(target.url)
        let store = target.source.label.before(" ")
        let (pageTitle, pageArtist) = WebPage.splitTitle(meta.schemaName ?? meta.title ?? "", store: store)
        let artist = meta.byArtist ?? pageArtist ?? meta.musician
        let key = target.source.key
        if !meta.recordings.isEmpty {
            let isAlbum = meta.schemaType == "MusicAlbum" || target.kind == .album
            let tracks = meta.recordings.enumerated().map { i, r in
                Track(
                    id: "\(key):\(target.id ?? "page"):\(i)",
                    source: target.source,
                    title: r.title,
                    artist: r.artist ?? artist ?? "Unknown artist",
                    album: isAlbum ? pageTitle : nil,
                    albumArtist: isAlbum ? artist : nil,
                    durationMs: r.durationMs,
                    artworkUrl: isAlbum ? meta.image : nil,
                    pageUrl: target.url,
                    trackNumber: isAlbum ? i + 1 : nil
                )
            }
            return .many(TrackCollection(
                id: "\(key):\(isAlbum ? "album" : "playlist"):\(target.id ?? "page")",
                source: target.source,
                kind: isAlbum ? .album : .playlist,
                title: pageTitle.nonEmpty ?? "Untitled",
                subtitle: artist,
                artworkUrl: meta.image,
                pageUrl: target.url,
                trackCount: tracks.count,
                tracks: tracks
            ))
        }
        guard !pageTitle.isEmpty else { throw KultrError("Couldn't read that \(target.source.label) page.") }
        switch target.kind {
        case .album:
            return .many(try await albumByName(pageTitle, artist: artist ?? "", target: target, artwork: meta.image))
        case .track:
            return .single(Track(
                id: "\(key):\(target.id ?? Text.normalize(pageTitle))",
                source: target.source,
                title: pageTitle,
                artist: artist ?? "Unknown artist",
                artworkUrl: meta.image,
                pageUrl: target.url
            ))
        default:
            throw KultrError("\(target.source.label) links of this kind can't be read yet. Try a track or album link.", notSupported: true)
        }
    }

    /** An album known only by name: its track list from Deezer, or else Apple Music. */
    private func albumByName(_ title: String, artist: String, target: LinkTarget, artwork: String?) async throws -> TrackCollection {
        let query = "\(artist) \(title)".trimmed()
        func pick(_ options: [TrackCollection]) -> TrackCollection? {
            let core = Text.coreTitle(title)
            return options
                .max { a, b in
                    Text.similarity(core, Text.coreTitle(a.title)) * 2 + Text.similarity(artist, a.subtitle ?? "")
                        < Text.similarity(core, Text.coreTitle(b.title)) * 2 + Text.similarity(artist, b.subtitle ?? "")
                }
                .flatMap { Text.similarity(core, Text.coreTitle($0.title)) > 0.6 ? $0 : nil }
        }
        var found: TrackCollection?
        if let hit = pick((try? await deezer.searchAlbums(query)) ?? []) { found = try? await load(hit) }
        if found == nil, let hit = pick((try? await apple.searchAlbums(query)) ?? []) { found = try? await load(hit) }
        guard var album = found else { throw KultrError("Couldn't find the tracks of “\(title)”.") }
        let key = target.source.key
        album.id = "\(key):album:\(target.id ?? album.id)"
        album.source = target.source
        album.pageUrl = target.url
        album.artworkUrl = artwork ?? album.artworkUrl
        album.tracks = album.tracks.map { t in
            var t = t
            t.source = target.source
            t.id = "\(key):\(t.id)"
            t.pageUrl = target.url
            return t
        }
        return album
    }

    private func withOdesliHint(_ track: Track, _ url: String) async -> Track {
        guard let hint = (try? await odesli.lookup(url))?.youtubeUrl else { return track }
        var t = track
        t.matchUrl = hint
        return t
    }

    /**
     * The recording to play or download for a catalogue track: YouTube
     * Music songs first, then music videos, then YouTube.
     */
    public func match(_ track: Track) async throws -> Track? {
        if !track.needsMatch { return track }
        let query = Matcher.query(track)
        let songs = (try? await youTubeMusic.searchSongs(query)) ?? []
        if let best = Matcher.best(track, songs) { return best }
        let videos = (try? await youTubeMusic.searchVideos(query)) ?? []
        if let best = Matcher.best(track, videos) { return best }
        let uploads = (try? await youTube.search(query)) ?? []
        if let best = Matcher.best(track, uploads) { return best }
        // Nothing clearly right: the top song result is still better than nothing when it is close.
        let closest = (songs + videos).max { Matcher.score(track, $0) < Matcher.score(track, $1) }
        if let closest, Matcher.score(track, closest) >= Matcher.accept - 15 { return closest }
        return nil
    }

    static func hash(_ text: String) -> String {
        var h: UInt64 = 1_469_598_103_934_665_603
        for b in text.utf8 {
            h ^= UInt64(b)
            h = h &* 1_099_511_628_211
        }
        return String(h, radix: 16)
    }
}
