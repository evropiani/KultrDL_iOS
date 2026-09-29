import Foundation

/**
 * What a music page says about itself: its Open Graph tags and any
 * schema.org JSON-LD (MusicRecording, MusicAlbum, MusicPlaylist). This is
 * how links from stores without a public API (Qobuz, Tidal playlists)
 * become a title, an artist and, where the page lists them, tracks.
 */
public final class WebPage: @unchecked Sendable {
    public struct Recording: Sendable {
        public let title: String
        public let artist: String?
        public let durationMs: Int64?
    }

    public struct Meta: Sendable {
        public let title: String?
        public let description: String?
        public let image: String?
        public let type: String?
        /** An audio file the page offers (og:audio). */
        public let audio: String?
        public let musician: String?
        /** Tracks listed in the page's structured data, if any. */
        public let recordings: [Recording]
        /** The artist named in the structured data, for an album or song. */
        public let byArtist: String?
        /** "MusicRecording", "MusicAlbum" or "MusicPlaylist" from the structured data. */
        public let schemaType: String?
        public let schemaName: String?
    }

    private let http: Http

    public init(http: Http) {
        self.http = http
    }

    public func read(_ url: String) async throws -> Meta {
        Self.parse(try await http.get(url, headers: ["Accept-Language": "en"]))
    }

    private static let ldJson = Rx.si(#"<script[^>]*type=["']application/ld\+json["'][^>]*>(.*?)</script>"#)
    private static let titleTag = Rx.si(#"<title[^>]*>(.*?)</title>"#)

    private static func meta(_ html: String, _ name: String) -> String? {
        let n = Rx.escape(name)
        let patterns = [
            Rx.i(#"<meta[^>]+(?:property|name)=["']"# + n + #"["'][^>]*content=["']([^"']*)["']"#),
            Rx.i(#"<meta[^>]+content=["']([^"']*)["'][^>]*(?:property|name)=["']"# + n + #"["']"#),
        ]
        for p in patterns {
            if let v = p.group(html) {
                let t = Text.unescapeHtml(v).trimmed()
                if !t.isEmpty { return t }
            }
        }
        return nil
    }

    private static func name(_ el: JSON?) -> String? {
        switch el {
        case .arr(let list)?: return list.compactMap { name($0) }.joined(separator: ", ").nonEmpty
        case .obj(let o)?: return o["name"].string
        default: return el.string
        }
    }

    private static func typeOf(_ o: JSON) -> String? {
        let t = o["@type"]
        if case .arr(let list)? = t { return list.first?.string }
        return t.string
    }

    public static func parse(_ html: String) -> Meta {
        let blocks = ldJson.findAll(html).compactMap { g in g[1].flatMap { JSON.tryParse($0.trimmed()) } }
        var objects: [JSON] = []
        for b in blocks { for node in b.walk() where node.object != nil { objects.append(node) } }
        let main = objects.first { ["MusicAlbum", "MusicPlaylist"].contains(typeOf($0) ?? "") }
            ?? objects.first { typeOf($0) == "MusicRecording" }
        var recordings: [Recording] = []
        if let main, typeOf(main) != "MusicRecording" {
            let track = main["track"]
            let list = track?["itemListElement"] ?? track
            recordings = list.array.compactMap { item -> Recording? in
                let rec = item["item"] ?? item
                guard let title = rec["name"].string else { return nil }
                return Recording(
                    title: Text.unescapeHtml(title),
                    artist: name(rec["byArtist"]).map(Text.unescapeHtml),
                    durationMs: Text.parseIsoDuration(rec["duration"].string)
                )
            }
        }
        let titleText = titleTag.group(html).map { Text.unescapeHtml($0).trimmed() }
        return Meta(
            title: meta(html, "og:title") ?? meta(html, "twitter:title") ?? titleText,
            description: meta(html, "og:description") ?? meta(html, "description"),
            image: meta(html, "og:image") ?? meta(html, "twitter:image"),
            type: meta(html, "og:type"),
            audio: meta(html, "og:audio:secure_url") ?? meta(html, "og:audio") ?? meta(html, "og:audio:url"),
            musician: meta(html, "music:musician_description") ?? meta(html, "music:musician"),
            recordings: recordings,
            byArtist: main.flatMap { name($0["byArtist"]) }.map(Text.unescapeHtml),
            schemaType: main.flatMap(typeOf),
            schemaName: main?["name"].string.map(Text.unescapeHtml)
        )
    }

    /**
     * A store page's title is usually "Title - Artist | Store" or
     * "Title by Artist on Store"; take it apart.
     */
    public static func splitTitle(_ raw: String, store: String) -> (title: String, artist: String?) {
        let s = Rx.escape(store)
        var t = Rx.i(#"\s*[|–—-]\s*"# + s + ".*$").replace(raw, with: "")
        t = Rx.i(#"\s+on\s+"# + s + ".*$").replace(t, with: "")
        t = Rx.i(#"^(listen to|stream|buy|download)\s+"#).replace(t, with: "").trimmed()
        t = Rx.i(#"\s*[|]\s*(hi-?res|high resolution|download).*$"#).replace(t, with: "").trimmed()
        if let g = Rx.i(#"^(.+?)\s+by\s+(.+)$"#).find(t), let a = g[1], let b = g[2] { return (a.trimmed(), b.trimmed()) }
        if let g = Rx(#"^(.+?)\s+[-–—]\s+(.+)$"#).find(t), let a = g[1], let b = g[2] { return (a.trimmed(), b.trimmed()) }
        return (t, nil)
    }
}
