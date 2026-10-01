import Foundation

/** Deezer's public catalogue API (no account needed). */
public final class Deezer: @unchecked Sendable {
    private let http: Http
    private let pace = Pace()
    private let lock = NSLock()
    private var genreNames: [Int64: String]?

    public init(http: Http) {
        self.http = http
    }

    public func searchArtists(_ name: String) async throws -> [ArtistRef] {
        try await get("search/artist?q=\(name.urlQueryEncoded)&limit=8")["data"].array.compactMap(Self.parseArtist)
    }

    /** An artist's albums, EPs and singles, newest first. */
    public func artistAlbums(_ artistId: String, artistName: String) async throws -> [TrackCollection] {
        let names = await genres()
        return try await get("artist/\(artistId)/albums?limit=100")["data"].array
            .compactMap { Self.parseArtistAlbum($0, artistName: artistName, genres: names) }
            .sorted { ($0.releaseDate ?? "") > ($1.releaseDate ?? "") }
    }

    /** The same albums, most loved (by Deezer fans) first; albums only. */
    public func popularAlbums(_ artistId: String, artistName: String) async throws -> [TrackCollection] {
        let names = await genres()
        let rows = try await get("artist/\(artistId)/albums?limit=100")["data"].array
        var albums: [(album: TrackCollection, fans: Int64, order: Int)] = []
        for r in rows {
            guard let album = Self.parseArtistAlbum(r, artistName: artistName, genres: names), album.recordType == "album" else { continue }
            albums.append((album, r["fans"].int64 ?? 0, albums.count))
        }
        albums.sort { a, b in a.fans != b.fans ? a.fans > b.fans : a.order < b.order }
        return albums.map(\.album)
    }

    public func related(_ artistId: String) async throws -> [ArtistRef] {
        try await get("artist/\(artistId)/related?limit=25")["data"].array.compactMap(Self.parseArtist)
    }

    public func top(_ artistId: String, limit: Int) async throws -> [Track] {
        try await get("artist/\(artistId)/top?limit=\(limit)")["data"].array.compactMap { Self.parseTrack($0, album: nil) }
    }

    /** Deezer genre ids to names ("Rap/Hip Hop"), fetched once. */
    private func genres() async -> [Int64: String] {
        if let known = lock.withLock({ genreNames }) { return known }
        var names: [Int64: String] = [:]
        if let list = try? await get("genre")["data"].array {
            for g in list {
                if let id = g["id"].int64, let name = g["name"].string { names[id] = name }
            }
        }
        if !names.isEmpty { lock.withLock { genreNames = names } }
        return names
    }

    public func searchTracks(_ query: String) async throws -> [Track] {
        try await get("search?q=\(query.urlQueryEncoded)&limit=30")["data"].array.compactMap { Self.parseTrack($0, album: nil) }
    }

    public func searchAlbums(_ query: String) async throws -> [TrackCollection] {
        try await get("search/album?q=\(query.urlQueryEncoded)&limit=20")["data"].array.compactMap { Self.parseAlbum($0) }
    }

    public func album(_ id: String) async throws -> TrackCollection? { Self.parseAlbumPage(try await get("album/\(id)")) }

    public func playlist(_ id: String) async throws -> TrackCollection? { Self.parsePlaylistPage(try await get("playlist/\(id)")) }

    public func track(_ id: String) async throws -> Track? { Self.parseTrack(try await get("track/\(id)"), album: nil) }

    public func chart() async throws -> [Track] {
        try await get("chart/0/tracks?limit=30")["data"].array.compactMap { Self.parseTrack($0, album: nil) }
    }

    private func get(_ path: String) async throws -> JSON {
        await pace.wait()
        var json = try await http.getJSON("https://api.deezer.com/\(path)")
        // Error 4 is Deezer's "too many requests": wait and ask once more.
        if json["error"]?["code"].int64 == 4 {
            try await Task.sleep(nanoseconds: 5_000_000_000)
            json = try await http.getJSON("https://api.deezer.com/\(path)")
        }
        if let message = json["error"]?["message"].string { throw KultrError("Deezer: \(message)") }
        return json
    }

    /** Deezer allows 50 requests in 5 seconds; stay well under that. */
    private actor Pace {
        private static let window: TimeInterval = 5
        private static let most = 35
        private var recent: [Date] = []

        func wait() async {
            while true {
                let now = Date()
                recent.removeAll { now.timeIntervalSince($0) > Self.window }
                if recent.count < Self.most {
                    recent.append(now)
                    return
                }
                let pause = Self.window - now.timeIntervalSince(recent[0]) + 0.01
                try? await Task.sleep(nanoseconds: UInt64(max(0.01, pause) * 1_000_000_000))
            }
        }
    }

    // ------------------------------------------------------------ parsing --

    public static func parseArtist(_ r: JSON) -> ArtistRef? {
        guard let id = r["id"].int64, let name = r["name"].string else { return nil }
        if let type = r["type"].string, type != "artist" { return nil }
        return ArtistRef(id: "deezer:\(id)", name: name, fans: r["nb_fan"].int64 ?? 0, pictureUrl: r["picture_xl"].string ?? r["picture_big"].string)
    }

    /** An album in an artist's discography (it doesn't name the artist; [artistName] does). */
    public static func parseArtistAlbum(_ r: JSON, artistName: String, genres: [Int64: String]) -> TrackCollection? {
        guard var album = parseAlbum(r) else { return nil }
        album.subtitle = r["artist"]?["name"].string ?? artistName
        album.releaseDate = r["release_date"].string
        album.recordType = r["record_type"].string
        album.genre = r["genre_id"].int64.flatMap { genres[$0] }
        return album
    }

    public static func parseTrack(_ r: JSON, album: TrackCollection?) -> Track? {
        guard let id = r["id"].int64, let title = r["title"].string else { return nil }
        if let type = r["type"].string, type != "track" { return nil }
        let albumJSON = r["album"]
        return Track(
            id: "deezer:\(id)",
            source: .deezer,
            title: title,
            artist: r["artist"]?["name"].string ?? album?.subtitle ?? "Unknown artist",
            album: albumJSON?["title"].string ?? album?.title,
            albumArtist: album?.subtitle,
            durationMs: r["duration"].int64.map { $0 * 1000 },
            artworkUrl: albumJSON?["cover_xl"].string ?? albumJSON?["cover_big"].string ?? album?.artworkUrl,
            pageUrl: r["link"].string,
            isrc: r["isrc"].string,
            year: TextTools.year(r["release_date"].string) ?? album?.year,
            trackNumber: r["track_position"].int,
            discNumber: r["disk_number"].int,
            explicit: r["explicit_lyrics"].bool == true
        )
    }

    public static func parseAlbum(_ r: JSON) -> TrackCollection? {
        guard let id = r["id"].int64, let title = r["title"].string else { return nil }
        return TrackCollection(
            id: "deezer:album:\(id)",
            source: .deezer,
            kind: .album,
            title: title,
            subtitle: r["artist"]?["name"].string,
            artworkUrl: r["cover_xl"].string ?? r["cover_big"].string,
            pageUrl: r["link"].string,
            year: TextTools.year(r["release_date"].string),
            trackCount: r["nb_tracks"].int
        )
    }

    public static func parseAlbumPage(_ r: JSON) -> TrackCollection? {
        guard var shell = parseAlbum(r) else { return nil }
        let genre = r["genres"]?["data"]?[0]?["name"].string
        let tracks = r["tracks"]?["data"].array.enumerated().compactMap { i, t -> Track? in
            guard var track = parseTrack(t, album: shell) else { return nil }
            track.trackNumber = track.trackNumber ?? (i + 1)
            track.genre = genre
            track.album = shell.title
            return track
        } ?? []
        shell.tracks = tracks
        shell.trackCount = tracks.count
        return shell
    }

    public static func parsePlaylistPage(_ r: JSON) -> TrackCollection? {
        guard let id = r["id"].int64 else { return nil }
        let tracks = r["tracks"]?["data"].array.compactMap { parseTrack($0, album: nil) } ?? []
        return TrackCollection(
            id: "deezer:playlist:\(id)",
            source: .deezer,
            kind: .playlist,
            title: r["title"].string ?? "Playlist",
            subtitle: r["creator"]?["name"].string,
            artworkUrl: r["picture_xl"].string ?? r["picture_big"].string,
            pageUrl: r["link"].string,
            trackCount: tracks.count,
            tracks: tracks
        )
    }
}
