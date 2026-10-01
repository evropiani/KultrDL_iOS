import Foundation

/**
 * YouTube Music's own search (the InnerTube API its web player uses).
 * Results are read loosely: rows are found wherever they sit in the
 * response, so a rearranged page still gives tracks.
 */
public final class YouTubeMusic: @unchecked Sendable {
    public enum Filter: String {
        case songs = "EgWKAQIIAWoKEAkQBRAKEAMQBA%3D%3D"
        case videos = "EgWKAQIQAWoKEAkQChAFEAMQBA%3D%3D"
        case albums = "EgWKAQIYAWoKEAkQChAFEAMQBA%3D%3D"
        case playlists = "EgeKAQQoAEABagoQAxAEEAoQCRAF"
    }

    public static let base = "https://music.youtube.com"
    /** Replaced by the engine settings when they name a newer one. */
    nonisolated(unsafe) public static var clientVersion = "1.20260707.12.00"

    private let http: Http

    public init(http: Http) {
        self.http = http
    }

    public func searchSongs(_ query: String) async throws -> [Track] {
        Self.parseTracks(try await search(query, .songs), source: .youtubeMusic)
    }

    public func searchVideos(_ query: String) async throws -> [Track] {
        Self.parseTracks(try await search(query, .videos), source: .youtubeMusic)
    }

    public func searchAlbums(_ query: String) async throws -> [TrackCollection] {
        Self.parseCollections(try await search(query, .albums))
    }

    public func album(_ browseId: String) async throws -> TrackCollection? {
        Self.parseAlbumPage(browseId, try await browse(browseId))
    }

    /** A YouTube Music playlist ("VL…" browse id, or a bare playlist id), with its tracks. */
    public func playlist(_ playlistId: String) async throws -> TrackCollection? {
        let browseId = playlistId.hasPrefix("VL") ? playlistId : "VL" + playlistId
        var root = try await browse(browseId)
        var tracks = Self.parseTracks(root, source: .youtubeMusic)
        // Long playlists come in pages.
        var seen = Set(tracks.map(\.id))
        for _ in 0..<20 {
            guard let token = Self.continuationToken(root) else { break }
            root = try await post("browse", ["continuation": .str(token)])
            let more = Self.parseTracks(root, source: .youtubeMusic).filter { seen.insert($0.id).inserted }
            if more.isEmpty { break }
            tracks += more
        }
        guard !tracks.isEmpty else { return nil }
        var header = Self.header(root)
        if header == nil { header = Self.header(try await browse(browseId)) }
        let title = header.flatMap { Self.text(Self.runs($0["title"])).nonEmpty } ?? "Playlist"
        let subtitle = header.flatMap { h in Self.segments(Self.runs(h["subtitle"])).map { Self.text($0) }.first { !$0.isEmpty } }
        return TrackCollection(
            id: "ytm:\(browseId)",
            source: .youtubeMusic,
            kind: .playlist,
            title: title,
            subtitle: header.flatMap { Self.text(Self.runs($0["straplineTextOne"])).nonEmpty } ?? subtitle,
            artworkUrl: Self.bigThumbnail(header.flatMap { Self.thumbnail($0) }) ?? tracks.first?.artworkUrl,
            pageUrl: "\(Self.base)/playlist?list=\(browseId.removingPrefix("VL"))",
            trackCount: tracks.count,
            tracks: tracks
        )
    }

    /** Title, artist, album and cover of a song by its video id (YouTube Music's "next" page). */
    public func song(_ videoId: String) async throws -> Track? {
        let root = try await post("next", ["videoId": .str(videoId), "isAudioOnly": true])
        let rows = root.objectsUnder("playlistPanelVideoRenderer")
        guard let row = rows.first(where: { $0["videoId"].string == videoId }) ?? rows.first else { return nil }
        return Self.parsePanelVideo(row)
    }

    /** The radio YouTube Music plays after [videoId]: songs like it, from it and from similar artists. */
    public func radio(_ videoId: String) async throws -> [Track] {
        let root = try await post("next", [
            "videoId": .str(videoId),
            "playlistId": .str("RDAMVM\(videoId)"),
            "isAudioOnly": true,
            "enablePersistentPlaylistPanel": true,
        ])
        return Self.parseRadio(root).filter { $0.id != "yt:\(videoId)" }
    }

    private func search(_ query: String, _ filter: Filter) async throws -> JSON {
        try await post("search", ["query": .str(query), "params": .str(filter.rawValue)])
    }

    private func browse(_ browseId: String) async throws -> JSON {
        try await post("browse", ["browseId": .str(browseId)])
    }

    private func post(_ endpoint: String, _ fields: [String: JSON]) async throws -> JSON {
        let context: JSON = ["client": [
            "clientName": "WEB_REMIX",
            "clientVersion": .str(Self.clientVersion),
            "hl": "en",
            "gl": "US",
        ]]
        var body = JSONObject()
        body["context"] = context
        for key in fields.keys.sorted() { body[key] = fields[key] }
        return try await http.postJSON(
            "\(Self.base)/youtubei/v1/\(endpoint)?prettyPrint=false",
            body: .obj(body),
            headers: [
                "Origin": Self.base,
                "Referer": "\(Self.base)/",
                "X-YouTube-Client-Name": "67",
                "X-YouTube-Client-Version": Self.clientVersion,
                "Cookie": "SOCS=CAI",
            ]
        )
    }

    // ------------------------------------------------------------ parsing --

    private static let typeWords: Set<String> = ["song", "video", "album", "single", "ep", "playlist", "artist", "episode", "podcast"]
    private static let views = Rx(#"(?i)^[\d.,]+\s*[KMB]?\s+(views|plays)$"#)
    private static let sizedThumb = Rx(#"=w\d+-h\d+"#)
    private static let smallThumb = Rx(#"/(default|mqdefault|hqdefault|sddefault)\.jpg"#)

    public static func watchUrl(_ videoId: String) -> String { "https://music.youtube.com/watch?v=\(videoId)" }

    /** Thumbnails come small; the same URL serves any size. */
    public static func bigThumbnail(_ url: String?) -> String? {
        guard let url else { return nil }
        return smallThumb.replace(sizedThumb.replace(url, with: "=w544-h544"), with: "/hqdefault.jpg")
    }

    static func runs(_ element: JSON?) -> [JSON] {
        element?["runs"].array.filter { $0.object != nil } ?? []
    }

    static func pageType(_ run: JSON) -> String? { run.firstString("pageType") }

    static func column(_ row: JSON, _ index: Int) -> [JSON] {
        runs(row["flexColumns"]?[index]?["musicResponsiveListItemFlexColumnRenderer"]?["text"])
    }

    static func thumbnail(_ row: JSON) -> String? {
        for node in row.walk() {
            if let thumbs = node["thumbnails"], case .arr(let list) = thumbs, let url = list.last?["url"].string {
                return url
            }
        }
        return nil
    }

    /** A subtitle's runs split into their " • "-separated parts. */
    static func segments(_ runs: [JSON]) -> [[JSON]] {
        var out: [[JSON]] = [[]]
        for run in runs {
            let text = run["text"].string ?? ""
            if text.trimmed() == "•" {
                out.append([])
            } else {
                out[out.count - 1].append(run)
            }
        }
        return out.filter { seg in seg.contains { !($0["text"].string ?? "").trimmed().isEmpty } }
    }

    static func text(_ runs: [JSON]) -> String {
        runs.map { $0["text"]?.rawString ?? $0["text"].string ?? "" }.joined().trimmed()
    }

    /** A song in the queue of a "next" answer. */
    static func parsePanelVideo(_ r: JSON) -> Track? {
        guard let videoId = r["videoId"].string ?? r["navigationEndpoint"]?["watchEndpoint"]?["videoId"].string else { return nil }
        let title = text(runs(r["title"]))
        guard !title.isEmpty else { return nil }
        let long = runs(r["longBylineText"])
        let byline = long.isEmpty ? runs(r["shortBylineText"]) : long
        let artists = byline.filter { run in pageType(run).map { $0.contains("ARTIST") || $0.contains("USER_CHANNEL") } ?? false }
        let parts = segments(byline).map { text($0) }
        let artist = artists.isEmpty ? parts.first : artists.compactMap { $0["text"].string }.joined(separator: ", ")
        let album = byline.first { pageType($0)?.contains("ALBUM") == true }?["text"].string
        let year = parts.compactMap { p -> Int? in p.count == 4 && p.allSatisfy(\.isASCIIDigitChar) ? Int(p) : nil }.first
        return Track(
            id: "yt:\(videoId)",
            source: .youtubeMusic,
            title: title,
            artist: (artist ?? "Unknown artist").removingSuffix(" - Topic"),
            album: album,
            durationMs: TextTools.parseClock(text(runs(r["lengthText"])).nonEmpty ?? r["lengthText"]?["simpleText"].string),
            artworkUrl: bigThumbnail(thumbnail(r)),
            pageUrl: watchUrl(videoId),
            streamUrl: watchUrl(videoId),
            year: year
        )
    }

    /** The queue of a "next" (radio) answer. */
    public static func parseRadio(_ root: JSON) -> [Track] {
        root.objectsUnder("playlistPanelVideoRenderer").compactMap(parsePanelVideo).distinct { $0.id }
    }

    private static let watchId = Rx(#"[?&]v=([A-Za-z0-9_-]{11})"#)

    /** The video id in a YouTube or YouTube Music watch link. */
    public static func videoId(_ url: String?) -> String? { url.flatMap { watchId.group($0) } }

    public static func parseTracks(_ root: JSON, source: Source) -> [Track] {
        root.objectsUnder("musicResponsiveListItemRenderer")
            .compactMap { parseRow($0, source: source, album: nil) }
            .distinct { $0.id }
    }

    /** One row of a song, video or album-track list; nil for rows that are not playable. */
    public static func parseRow(_ row: JSON, source: Source, album: TrackCollection?) -> Track? {
        var videoId = row.path("playlistItemData", "videoId").string
        if videoId == nil {
            for node in row.walk() {
                if let id = node["watchEndpoint"]?["videoId"].string {
                    videoId = id
                    break
                }
            }
        }
        guard let videoId else { return nil }
        let title = text(column(row, 0))
        guard !title.isEmpty else { return nil }
        let subtitle = column(row, 1)
        var artist: String?
        var albumName = album?.title
        var durationMs: Int64?
        let artistRuns = subtitle.filter { run in pageType(run).map { $0.contains("ARTIST") || $0.contains("USER_CHANNEL") } ?? false }
        if !artistRuns.isEmpty { artist = artistRuns.map { $0["text"].string ?? "" }.joined(separator: ", ") }
        if let albumRun = subtitle.first(where: { pageType($0)?.contains("ALBUM") == true }) { albumName = albumRun["text"].string }
        for segment in segments(subtitle) {
            let t = text(segment)
            if let clock = TextTools.parseClock(t) {
                durationMs = clock
            } else if typeWords.contains(t.lowercased()) || views.matches(t) {
                continue
            } else if artist == nil {
                artist = t
            }
        }
        if durationMs == nil {
            let fixed = row["fixedColumns"]?[0]?["musicResponsiveListItemFixedColumnRenderer"]?["text"]
            let t = text(runs(fixed))
            durationMs = TextTools.parseClock(t.isEmpty ? (fixed?["simpleText"].string ?? "") : t)
        }
        let finalArtist = artist?.removingSuffix(" - Topic") ?? album?.subtitle ?? "Unknown artist"
        return Track(
            id: "yt:\(videoId)",
            source: source,
            title: title,
            artist: finalArtist,
            album: albumName,
            albumArtist: album?.subtitle,
            durationMs: durationMs,
            artworkUrl: bigThumbnail(thumbnail(row)) ?? album?.artworkUrl,
            pageUrl: watchUrl(videoId),
            streamUrl: watchUrl(videoId),
            year: album?.year
        )
    }

    public static func parseCollections(_ root: JSON) -> [TrackCollection] {
        root.objectsUnder("musicResponsiveListItemRenderer").compactMap { row -> TrackCollection? in
            guard let browse = row["navigationEndpoint"]?["browseEndpoint"], let browseId = browse["browseId"].string else { return nil }
            let type = browse.firstString("pageType") ?? ""
            let kind: CollectionKind
            if type.contains("ALBUM") {
                kind = .album
            } else if type.contains("PLAYLIST") {
                kind = .playlist
            } else {
                return nil
            }
            let title = text(column(row, 0))
            guard !title.isEmpty else { return nil }
            let parts = segments(column(row, 1)).map { text($0) }
            let year = parts.compactMap { p -> Int? in p.count == 4 && p.allSatisfy(\.isASCIIDigitChar) ? Int(p) : nil }.first
            let artist = parts.first { p in !typeWords.contains(p.lowercased()) && !(p.count == 4 && p.allSatisfy(\.isASCIIDigitChar)) }
            return TrackCollection(
                id: "ytm:\(browseId)",
                source: .youtubeMusic,
                kind: kind,
                title: title,
                subtitle: artist,
                artworkUrl: bigThumbnail(thumbnail(row)),
                pageUrl: "\(base)/browse/\(browseId)",
                year: year
            )
        }.distinct { $0.id }
    }

    /** The headers of a whole page, as opposed to those of the shelves on it ("Other versions"). */
    private static let pageHeaders = [
        "musicResponsiveHeaderRenderer", "musicDetailHeaderRenderer", "musicImmersiveHeaderRenderer",
        "musicVisualHeaderRenderer", "musicEditablePlaylistDetailHeaderRenderer",
    ]

    /** The page's header: a page header with a title, else the first "…HeaderRenderer" that isn't a shelf's. */
    static func header(_ root: JSON) -> JSON? {
        var fallback: JSON?
        for node in root.walk() {
            guard case .obj(let o) = node else { continue }
            for (key, value) in o.entries where key.hasSuffix("HeaderRenderer") {
                guard case .obj(let h) = value, h["title"] != nil else { continue }
                if pageHeaders.contains(key) { return value }
                let shelf = key.contains("Shelf") || key.contains("Carousel") || key.contains("Section") || key.contains("Chip")
                if fallback == nil && !shelf { fallback = value }
            }
        }
        return fallback
    }

    static func continuationToken(_ root: JSON) -> String? {
        for node in root.walk() {
            if let token = node["continuationCommand"]?["token"].string { return token }
            if let token = node["nextContinuationData"]?["continuation"].string { return token }
        }
        return nil
    }

    public static func parseAlbumPage(_ browseId: String, _ root: JSON) -> TrackCollection? {
        let header = header(root)
        let title = header.flatMap { text(runs($0["title"])).nonEmpty } ?? "Album"
        let strap = header.flatMap { text(runs($0["straplineTextOne"])).nonEmpty }
        let subtitleParts = header.map { h in segments(runs(h["subtitle"])).map { text($0) } } ?? []
        let year = subtitleParts.compactMap { p -> Int? in p.count == 4 && p.allSatisfy(\.isASCIIDigitChar) ? Int(p) : nil }.first
        let artist = strap ?? subtitleParts.first { !typeWords.contains($0.lowercased()) && Int($0) == nil }
        var shell = TrackCollection(
            id: "ytm:\(browseId)",
            source: .youtubeMusic,
            kind: .album,
            title: title,
            subtitle: artist,
            artworkUrl: bigThumbnail(header.flatMap { thumbnail($0) }),
            pageUrl: "\(base)/browse/\(browseId)",
            year: year
        )
        let tracks = root.objectsUnder("musicResponsiveListItemRenderer")
            .compactMap { parseRow($0, source: .youtubeMusic, album: shell) }
            .distinct { $0.id }
            .enumerated()
            .map { i, t -> Track in
                var t = t
                t.trackNumber = i + 1
                return t
            }
        guard !tracks.isEmpty else { return nil }
        shell.tracks = tracks
        shell.trackCount = tracks.count
        return shell
    }
}
