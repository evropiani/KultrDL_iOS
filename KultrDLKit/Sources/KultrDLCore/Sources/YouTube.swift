import Foundation

/** Plain YouTube: video search, playlists and a video's details, for live sets, covers and uploads not on YouTube Music. */
public final class YouTube: @unchecked Sendable {
    nonisolated(unsafe) public static var clientVersion = "2.20260708.00.00"

    private let http: Http

    public init(http: Http) {
        self.http = http
    }

    public func search(_ query: String) async throws -> [Track] {
        Self.parse(try await post("search", ["query": .str(query), "params": "EgIQAQ%3D%3D"]))
    }

    /** A playlist with its videos (up to about 1000). */
    public func playlist(_ playlistId: String) async throws -> TrackCollection? {
        var root = try await post("browse", ["browseId": .str("VL" + playlistId)])
        var tracks = Self.parsePlaylistVideos(root)
        var seen = Set(tracks.map(\.id))
        for _ in 0..<10 {
            guard let token = YouTubeMusic.continuationToken(root) else { break }
            root = try await post("browse", ["continuation": .str(token)])
            let more = Self.parsePlaylistVideos(root).filter { seen.insert($0.id).inserted }
            if more.isEmpty { break }
            tracks += more
        }
        guard !tracks.isEmpty else { return nil }
        let first = try? await post("browse", ["browseId": .str("VL" + playlistId)])
        let title = first.flatMap { Self.playlistTitle($0) } ?? "Playlist"
        let owner = first.flatMap { Self.playlistOwner($0) }
        return TrackCollection(
            id: "yt:list:\(playlistId)",
            source: .youtube,
            kind: .playlist,
            title: title,
            subtitle: owner,
            artworkUrl: tracks.first?.artworkUrl,
            pageUrl: "https://www.youtube.com/playlist?list=\(playlistId)",
            trackCount: tracks.count,
            tracks: tracks
        )
    }

    /** A video's title, channel, length and thumbnail. */
    public func video(_ videoId: String) async throws -> Track? {
        let root = try await post("player", [
            "videoId": .str(videoId),
            "contentCheckOk": true,
            "racyCheckOk": true,
        ])
        return Self.parseVideoDetails(root, source: .youtube)
    }

    private func post(_ endpoint: String, _ fields: [String: JSON]) async throws -> JSON {
        let context: JSON = ["client": [
            "clientName": "WEB",
            "clientVersion": .str(Self.clientVersion),
            "hl": "en",
            "gl": "US",
        ]]
        var body = JSONObject()
        body["context"] = context
        for key in fields.keys.sorted() { body[key] = fields[key] }
        return try await http.postJSON(
            "https://www.youtube.com/youtubei/v1/\(endpoint)?prettyPrint=false",
            body: .obj(body),
            headers: [
                "Origin": "https://www.youtube.com",
                "Referer": "https://www.youtube.com/",
                "X-YouTube-Client-Name": "1",
                "X-YouTube-Client-Version": Self.clientVersion,
                "Cookie": "SOCS=CAI",
            ]
        )
    }

    // ------------------------------------------------------------ parsing --

    public static func watchUrl(_ videoId: String) -> String { "https://www.youtube.com/watch?v=\(videoId)" }

    static func text(_ element: JSON?) -> String {
        if let simple = element?["simpleText"].string { return simple }
        return element?["runs"].array.map { $0["text"].string ?? "" }.joined() ?? ""
    }

    public static func parse(_ root: JSON) -> [Track] {
        root.objectsUnder("videoRenderer").compactMap { parseVideo($0) }.distinct { $0.id }
    }

    static func lastThumbnail(_ v: JSON) -> String? {
        v["thumbnail"]?["thumbnails"].array.last?["url"].string?.before("?")
    }

    private static func parseVideo(_ v: JSON) -> Track? {
        guard let id = v["videoId"].string else { return nil }
        let rawTitle = text(v["title"])
        guard !rawTitle.isEmpty else { return nil }
        let owner = text(v["ownerText"])
        let channel = (owner.isEmpty ? text(v["longBylineText"]) : owner).nonEmpty
        let (artist, title) = Text.artistAndTitle(rawTitle, channel: channel)
        return Track(
            id: "yt:\(id)",
            source: .youtube,
            title: title,
            artist: artist.isEmpty ? (channel ?? "Unknown artist") : artist,
            durationMs: Text.parseClock(text(v["lengthText"])),
            artworkUrl: lastThumbnail(v),
            pageUrl: watchUrl(id),
            streamUrl: watchUrl(id)
        )
    }

    static func parsePlaylistVideos(_ root: JSON) -> [Track] {
        let renderers = root.objectsUnder("playlistVideoRenderer") + root.objectsUnder("playlistPanelVideoRenderer")
        return renderers.compactMap { v -> Track? in
            guard let id = v["videoId"].string, v["isPlayable"].bool != false else { return nil }
            let rawTitle = text(v["title"])
            guard !rawTitle.isEmpty else { return nil }
            let channel = text(v["shortBylineText"]).nonEmpty ?? text(v["longBylineText"]).nonEmpty
            let (artist, title) = Text.artistAndTitle(rawTitle, channel: channel)
            let seconds = v["lengthSeconds"].int64
            return Track(
                id: "yt:\(id)",
                source: .youtube,
                title: title,
                artist: artist.isEmpty ? (channel ?? "Unknown artist") : artist,
                durationMs: seconds.map { $0 * 1000 } ?? Text.parseClock(text(v["lengthText"])),
                artworkUrl: lastThumbnail(v),
                pageUrl: watchUrl(id),
                streamUrl: watchUrl(id)
            )
        }.distinct { $0.id }
    }

    static func playlistTitle(_ root: JSON) -> String? {
        if let t = root.path("metadata", "playlistMetadataRenderer", "title").string { return t }
        if let h = root.first("playlistHeaderRenderer") { return text(h["title"]).nonEmpty }
        if let h = root.first("pageHeaderViewModel") { return h["title"]?["dynamicTextViewModel"]?["text"]?["content"].string }
        return nil
    }

    static func playlistOwner(_ root: JSON) -> String? {
        if let h = root.first("playlistHeaderRenderer"), let owner = text(h["ownerText"]).nonEmpty { return owner }
        return root.first("videoOwnerRenderer").flatMap { text($0["title"]).nonEmpty }
    }

    /** A player response's videoDetails as a track. */
    public static func parseVideoDetails(_ root: JSON, source: Source) -> Track? {
        guard let d = root["videoDetails"], let id = d["videoId"].string, let rawTitle = d["title"].string else { return nil }
        let author = d["author"].string
        let named: (artist: String, title: String) = source == .youtubeMusic || author?.hasSuffix(" - Topic") == true
            ? (artist: (author ?? "").removingSuffix(" - Topic"), title: rawTitle)
            : Text.artistAndTitle(rawTitle, channel: author)
        let (artist, title) = (named.artist, named.title)
        let thumbs = d["thumbnail"]?["thumbnails"].array ?? []
        let best = thumbs.max { ($0["width"].int ?? 0) < ($1["width"].int ?? 0) }?["url"].string?.before("?")
        let year = Text.year(root.path("microformat", "playerMicroformatRenderer", "publishDate").string)
        let url = source == .youtubeMusic ? YouTubeMusic.watchUrl(id) : watchUrl(id)
        return Track(
            id: "yt:\(id)",
            source: source,
            title: title,
            artist: artist.isEmpty ? (author ?? "Unknown artist") : artist,
            durationMs: d["lengthSeconds"].int64.map { $0 * 1000 },
            artworkUrl: source == .youtubeMusic ? YouTubeMusic.bigThumbnail(best) : best,
            pageUrl: url,
            streamUrl: url,
            year: year
        )
    }
}
