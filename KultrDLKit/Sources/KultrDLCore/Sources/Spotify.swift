import Foundation

/**
 * Spotify metadata. Links work without an account: the public embed page
 * carries a track's details, or an album's or playlist's track list.
 * Searching needs the Web API, so it is available once a Client ID and
 * secret from developer.spotify.com are entered in Settings.
 */
public final class Spotify: @unchecked Sendable {
    public enum Loaded {
        case track(Track)
        case collection(TrackCollection)
    }

    private let http: Http
    private let credentials: @Sendable () -> (id: String, secret: String)?
    private let lock = NSLock()
    private var token: String?
    private var tokenExpires = Date.distantPast

    public init(http: Http, credentials: @escaping @Sendable () -> (id: String, secret: String)?) {
        self.http = http
        self.credentials = credentials
    }

    public var canSearch: Bool { credentials() != nil }

    public func searchTracks(_ query: String) async throws -> [Track] {
        try await api("search?type=track&limit=30&q=\(query.urlQueryEncoded)")["tracks"]?["items"].array.compactMap { Self.parseApiTrack($0, album: nil) } ?? []
    }

    public func searchAlbums(_ query: String) async throws -> [TrackCollection] {
        try await api("search?type=album&limit=20&q=\(query.urlQueryEncoded)")["albums"]?["items"].array.compactMap { Self.parseApiAlbum($0) } ?? []
    }

    /** A track, album or playlist by its Spotify id, from the embed page (or the API when signed in). */
    public func load(_ kind: String, _ id: String) async throws -> Loaded? {
        if canSearch && kind == "album", let album = try? await api("albums/\(id)"), let parsed = Self.parseApiAlbumPage(album) {
            return .collection(parsed)
        }
        let html = try await http.get("https://open.spotify.com/embed/\(kind)/\(id)")
        guard let data = Self.nextData(html) else { throw KultrError("Spotify did not return the \(kind).") }
        if kind == "track" { return Self.parseEmbedTrack(data, fallbackId: id).map { .track($0) } }
        return Self.parseEmbedList(data, kind: kind, id: id).map { .collection($0) }
    }

    private func api(_ path: String) async throws -> JSON {
        guard let bearer = try await accessToken() else { throw KultrError("Add a Spotify Client ID and secret in Settings to search Spotify.") }
        return try await http.getJSON("https://api.spotify.com/v1/\(path)", headers: ["Authorization": "Bearer \(bearer)"])
    }

    private func cachedToken() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return Date() < tokenExpires ? token : nil
    }

    private func store(_ fresh: String, expires: Date) {
        lock.lock()
        token = fresh
        tokenExpires = expires
        lock.unlock()
    }

    private func accessToken() async throws -> String? {
        guard let creds = credentials() else { return nil }
        if let token = cachedToken() { return token }
        let basic = Data("\(creds.id):\(creds.secret)".utf8).base64EncodedString()
        let text = try await http.postForm(
            "https://accounts.spotify.com/api/token",
            fields: ["grant_type": "client_credentials"],
            headers: ["Authorization": "Basic \(basic)"]
        )
        let json = try JSON.parse(text)
        guard let fresh = json["access_token"].string else { throw KultrError("Spotify refused the Client ID and secret.") }
        store(fresh, expires: Date().addingTimeInterval(Double((json["expires_in"].int64 ?? 3600) - 60)))
        return fresh
    }

    // ------------------------------------------------------------ parsing --

    public static func pageUrl(_ kind: String, _ id: String) -> String { "https://open.spotify.com/\(kind)/\(id)" }

    private static func biggestImage(_ images: JSON?) -> String? {
        images.array.max { ($0["width"].int ?? 0) < ($1["width"].int ?? 0) }?["url"].string
    }

    private static func names(_ list: JSON?) -> String {
        list.array.compactMap { $0["name"].string }.joined(separator: ", ")
    }

    public static func parseApiTrack(_ r: JSON, album: TrackCollection?) -> Track? {
        guard let id = r["id"].string, let title = r["name"].string else { return nil }
        let albumJSON = r["album"]
        return Track(
            id: "spotify:\(id)",
            source: .spotify,
            title: title,
            artist: names(r["artists"]).nonEmpty ?? "Unknown artist",
            album: albumJSON?["name"].string ?? album?.title,
            albumArtist: albumJSON?["artists"]?[0]?["name"].string ?? album?.subtitle,
            durationMs: r["duration_ms"].int64,
            artworkUrl: biggestImage(albumJSON?["images"]) ?? album?.artworkUrl,
            pageUrl: pageUrl("track", id),
            isrc: r["external_ids"]?["isrc"].string,
            year: TextTools.year(albumJSON?["release_date"].string) ?? album?.year,
            trackNumber: r["track_number"].int,
            discNumber: r["disc_number"].int,
            explicit: r["explicit"].bool == true
        )
    }

    public static func parseApiAlbum(_ r: JSON) -> TrackCollection? {
        guard let id = r["id"].string, let title = r["name"].string else { return nil }
        return TrackCollection(
            id: "spotify:album:\(id)",
            source: .spotify,
            kind: .album,
            title: title,
            subtitle: names(r["artists"]),
            artworkUrl: biggestImage(r["images"]),
            pageUrl: pageUrl("album", id),
            year: TextTools.year(r["release_date"].string),
            trackCount: r["total_tracks"].int
        )
    }

    public static func parseApiAlbumPage(_ r: JSON) -> TrackCollection? {
        guard var shell = parseApiAlbum(r) else { return nil }
        let tracks = r["tracks"]?["items"].array.compactMap { parseApiTrack($0, album: shell) } ?? []
        shell.tracks = tracks
        shell.trackCount = tracks.count
        return shell
    }

    private static let nextDataScript = Rx.s(#"<script[^>]*id="__NEXT_DATA__"[^>]*>(.*?)</script>"#)

    /** The JSON the embed page is rendered from. */
    public static func nextData(_ html: String) -> JSON? {
        JSON.tryParse(nextDataScript.group(html))
    }

    /** The object describing the embedded track, album or playlist. */
    private static func entity(_ data: JSON) -> JSON? {
        for node in data.walk() {
            if let e = node["entity"], e.object != nil { return e }
        }
        for node in data.walk() {
            if let o = node.object, o["trackList"] != nil || (o["uri"] != nil && o["name"] != nil) { return node }
        }
        return nil
    }

    private static func cover(_ entity: JSON) -> String? {
        biggestImage(entity["coverArt"]?["sources"]) ?? biggestImage(entity["visualIdentity"]?["image"]) ?? biggestImage(entity["images"])
    }

    private static func idFromUri(_ uri: String?) -> String? { uri?.afterLast(":").nonEmpty }

    public static func parseEmbedTrack(_ data: JSON, fallbackId: String) -> Track? {
        guard let e = entity(data), let title = e["name"].string ?? e["title"].string else { return nil }
        let artists = names(e["artists"]).nonEmpty ?? e["subtitle"].string ?? ""
        let id = idFromUri(e["uri"].string) ?? fallbackId
        return Track(
            id: "spotify:\(id)",
            source: .spotify,
            title: title,
            artist: artists.nonEmpty ?? "Unknown artist",
            durationMs: e["duration"].int64 ?? e["maxDuration"].int64,
            artworkUrl: cover(e),
            pageUrl: pageUrl("track", id),
            year: TextTools.year(e["releaseDate"]?["isoString"].string ?? e["releaseDate"].string),
            explicit: e["isExplicit"].bool == true
        )
    }

    public static func parseEmbedList(_ data: JSON, kind: String, id: String) -> TrackCollection? {
        guard let e = entity(data), let title = e["name"].string ?? e["title"].string else { return nil }
        let owner = e["subtitle"].string ?? names(e["artists"]).nonEmpty
        let art = cover(e)
        let isAlbum = kind == "album"
        let tracks = e["trackList"].array.enumerated().compactMap { i, t -> Track? in
            guard let trackId = idFromUri(t["uri"].string), let trackTitle = t["title"].string else { return nil }
            return Track(
                id: "spotify:\(trackId)",
                source: .spotify,
                title: trackTitle,
                artist: t["subtitle"].string?.replacingOccurrences(of: "\u{00A0}", with: " ") ?? owner ?? "Unknown artist",
                album: isAlbum ? title : nil,
                albumArtist: isAlbum ? owner : nil,
                durationMs: t["duration"].int64,
                artworkUrl: isAlbum ? art : nil,
                pageUrl: pageUrl("track", trackId),
                trackNumber: isAlbum ? i + 1 : nil,
                explicit: t["isExplicit"].bool == true
            )
        }
        return TrackCollection(
            id: "spotify:\(kind):\(id)",
            source: .spotify,
            kind: isAlbum ? .album : .playlist,
            title: title,
            subtitle: owner,
            artworkUrl: art,
            pageUrl: pageUrl(kind, id),
            year: TextTools.year(e["releaseDate"]?["isoString"].string),
            trackCount: tracks.count,
            tracks: tracks
        )
    }
}
