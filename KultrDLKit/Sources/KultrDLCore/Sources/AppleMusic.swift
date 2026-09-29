import Foundation

/** The Apple Music catalogue through the public iTunes Search API. */
public final class AppleMusic: @unchecked Sendable {
    private let http: Http
    private let country: @Sendable () -> String

    public init(http: Http, country: @escaping @Sendable () -> String) {
        self.http = http
        self.country = country
    }

    public func searchSongs(_ query: String, limit: Int = 30) async throws -> [Track] {
        Self.parseResults(try await get("search?term=\(query.urlQueryEncoded)&media=music&entity=song&limit=\(limit)")).tracks
    }

    public func searchAlbums(_ query: String, limit: Int = 20) async throws -> [TrackCollection] {
        Self.parseResults(try await get("search?term=\(query.urlQueryEncoded)&media=music&entity=album&limit=\(limit)")).albums
    }

    /** An album with its tracks. */
    public func album(_ collectionId: String) async throws -> TrackCollection? {
        let (tracks, albums) = Self.parseResults(try await get("lookup?id=\(collectionId)&entity=song&limit=200"))
        guard var album = albums.first else { return nil }
        album.tracks = tracks.sorted { ($0.discNumber ?? 1, $0.trackNumber ?? 0) < ($1.discNumber ?? 1, $1.trackNumber ?? 0) }
        album.trackCount = tracks.count
        return album
    }

    public func song(_ trackId: String) async throws -> Track? {
        Self.parseResults(try await get("lookup?id=\(trackId)")).tracks.first
    }

    /** The most played songs in the user's country right now. */
    public func topSongs(limit: Int = 25) async throws -> [Track] {
        let cc = country().lowercased().nonEmpty ?? "us"
        return Self.parseChart(try await http.getJSON("https://rss.applemarketingtools.com/api/v2/\(cc)/music/most-played/\(limit)/songs.json"))
    }

    private func get(_ path: String) async throws -> JSON {
        let cc = country().uppercased().nonEmpty ?? "US"
        let sep = path.contains("?") ? "&" : "?"
        return try await http.getJSON("https://itunes.apple.com/\(path)\(sep)country=\(cc)")
    }

    // ------------------------------------------------------------ parsing --

    private static let sized = Rx(#"/\d+x\d+(bb)?\.(jpg|png|webp)$"#)

    public static func bigArtwork(_ url: String?) -> String? {
        url.map { sized.replace($0, with: "/600x600bb.jpg") }
    }

    public static func parseResults(_ root: JSON) -> (tracks: [Track], albums: [TrackCollection]) {
        var tracks: [Track] = []
        var albums: [TrackCollection] = []
        for r in root["results"].array {
            switch r["wrapperType"].string {
            case "track":
                if r["kind"].string == nil || r["kind"].string == "song", let t = parseTrack(r) { tracks.append(t) }
            case "collection":
                if let a = parseAlbum(r) { albums.append(a) }
            default:
                break
            }
        }
        return (tracks, albums)
    }

    private static func parseTrack(_ r: JSON) -> Track? {
        guard let id = r["trackId"].int64, let title = r["trackName"].string else { return nil }
        return Track(
            id: "apple:\(id)",
            source: .appleMusic,
            title: title,
            artist: r["artistName"].string ?? "Unknown artist",
            album: r["collectionName"].string,
            albumArtist: r["collectionArtistName"].string ?? r["artistName"].string,
            durationMs: r["trackTimeMillis"].int64,
            artworkUrl: bigArtwork(r["artworkUrl100"].string ?? r["artworkUrl60"].string),
            pageUrl: r["trackViewUrl"].string?.before("&uo="),
            year: Text.year(r["releaseDate"].string),
            trackNumber: r["trackNumber"].int,
            discNumber: r["discNumber"].int,
            genre: r["primaryGenreName"].string,
            explicit: r["trackExplicitness"].string == "explicit"
        )
    }

    private static func parseAlbum(_ r: JSON) -> TrackCollection? {
        guard let id = r["collectionId"].int64, let title = r["collectionName"].string else { return nil }
        return TrackCollection(
            id: "apple:album:\(id)",
            source: .appleMusic,
            kind: .album,
            title: title,
            subtitle: r["artistName"].string,
            artworkUrl: bigArtwork(r["artworkUrl100"].string),
            pageUrl: r["collectionViewUrl"].string?.before("?uo="),
            year: Text.year(r["releaseDate"].string),
            trackCount: r["trackCount"].int
        )
    }

    public static func parseChart(_ root: JSON) -> [Track] {
        root["feed"]?["results"].array.compactMap { r -> Track? in
            guard let id = r["id"].string, let title = r["name"].string else { return nil }
            return Track(
                id: "apple:\(id)",
                source: .appleMusic,
                title: title,
                artist: r["artistName"].string ?? "Unknown artist",
                artworkUrl: bigArtwork(r["artworkUrl100"].string),
                pageUrl: r["url"].string,
                year: Text.year(r["releaseDate"].string),
                genre: r["genres"]?[0]?["name"].string
            )
        } ?? []
    }
}
