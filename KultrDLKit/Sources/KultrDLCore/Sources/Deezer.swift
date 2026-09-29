import Foundation

/** Deezer's public catalogue API (no account needed). */
public final class Deezer: @unchecked Sendable {
    private let http: Http

    public init(http: Http) {
        self.http = http
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
        let json = try await http.getJSON("https://api.deezer.com/\(path)")
        if let message = json["error"]?["message"].string { throw KultrError("Deezer: \(message)") }
        return json
    }

    // ------------------------------------------------------------ parsing --

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
            year: Text.year(r["release_date"].string) ?? album?.year,
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
            year: Text.year(r["release_date"].string),
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
