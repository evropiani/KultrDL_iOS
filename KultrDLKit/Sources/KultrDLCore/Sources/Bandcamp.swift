import Foundation

/** Bandcamp: its search box, and track and album pages with their streams. */
public final class Bandcamp: @unchecked Sendable {
    private let http: Http

    public init(http: Http) {
        self.http = http
    }

    public func search(_ query: String) async throws -> (tracks: [Track], albums: [TrackCollection]) {
        let tracks = Self.parse(try await request(query, filter: "t")).tracks
        let albums = (try? await request(query, filter: "a")).map { Self.parse($0).albums } ?? []
        return (tracks, albums)
    }

    private func request(_ query: String, filter: String) async throws -> JSON {
        let body: JSON = [
            "search_text": .str(query),
            "search_filter": .str(filter),
            "full_page": false,
            "fan_id": .null,
        ]
        return try await http.postJSON(
            "https://bandcamp.com/api/bcsearch_public_api/1/autocomplete_elastic",
            body: body,
            headers: ["Origin": "https://bandcamp.com", "Referer": "https://bandcamp.com/"]
        )
    }

    /** A track or album page: what it is, and the tracks on it. */
    public func page(_ url: String) async throws -> LinkResult {
        let html = try await http.get(url)
        guard let page = Self.parsePage(html, url: url) else { throw KultrError("Couldn't read that Bandcamp page.") }
        return page
    }

    /** The MP3 stream of a track page (Bandcamp streams 128 kbps MP3). */
    public func stream(_ trackPageUrl: String) async throws -> String {
        let html = try await http.get(trackPageUrl)
        guard let data = Self.tralbum(html) else { throw KultrError("Couldn't read that Bandcamp page.") }
        let infos = data["trackinfo"].array
        let wanted = URL(string: trackPageUrl)?.path
        let info = infos.first { $0["title_link"].string == wanted } ?? infos.first
        guard let file = info?["file"]?["mp3-128"].string else {
            throw KultrError("Bandcamp doesn't stream this track (it may be for sale only).")
        }
        return file.hasPrefix("//") ? "https:" + file : file
    }

    // ------------------------------------------------------------ parsing --

    private static let artSize = Rx(#"_\d+\.jpg$"#)
    private static let tralbumAttr = Rx.s(#"data-tralbum="([^"]*)""#)
    private static let bandAttr = Rx.s(#"data-band="([^"]*)""#)

    public static func parse(_ root: JSON) -> (tracks: [Track], albums: [TrackCollection]) {
        var results = root["auto"]?["results"].array ?? []
        if results.isEmpty {
            for node in root.walk() {
                if case .arr(let list) = node["results"] ?? .null {
                    results = list
                    break
                }
            }
        }
        var tracks: [Track] = []
        var albums: [TrackCollection] = []
        for r in results {
            guard let url = r["item_url_path"].string ?? r["item_url_root"].string, let name = r["name"].string else { continue }
            let artist = r["band_name"].string ?? "Unknown artist"
            let art = r["img"].string.map { artSize.replace($0, with: "_10.jpg") }
            switch r["type"].string {
            case "t":
                tracks.append(Track(
                    id: "bandcamp:\(r["id"].string ?? url)",
                    source: .bandcamp,
                    title: name,
                    artist: artist,
                    album: r["album_name"].string,
                    artworkUrl: art,
                    pageUrl: url,
                    streamUrl: url
                ))
            case "a":
                albums.append(TrackCollection(
                    id: "bandcamp:album:\(r["id"].string ?? url)",
                    source: .bandcamp,
                    kind: .album,
                    title: name,
                    subtitle: artist,
                    artworkUrl: art,
                    pageUrl: url
                ))
            default:
                break
            }
        }
        return (tracks, albums)
    }

    static func tralbum(_ html: String) -> JSON? {
        tralbumAttr.group(html).flatMap { JSON.tryParse(Text.unescapeHtml($0)) }
    }

    public static func parsePage(_ html: String, url: String) -> LinkResult? {
        guard let data = tralbum(html) else { return nil }
        let band = bandAttr.group(html).flatMap { JSON.tryParse(Text.unescapeHtml($0)) }
        let artist = data["artist"].string ?? band?["name"].string ?? "Unknown artist"
        let current = data["current"]
        let albumTitle = current?["title"].string
        let artId = data["art_id"].int64 ?? current?["art_id"].int64
        let art = artId.map { "https://f4.bcbits.com/img/a\(String(format: "%010lld", $0))_10.jpg" }
        let year = Text.year(data["album_release_date"].string.flatMap { d in
            // "16 Oct 2020 00:00:00 GMT"
            Rx(#"(\d{4})"#).group(d)
        })
        let base = URL(string: url).flatMap { u -> String? in
            guard let scheme = u.scheme, let host = u.host else { return nil }
            return "\(scheme)://\(host)"
        } ?? ""
        let isAlbum = data["item_type"].string == "album" || url.contains("/album/")
        let tracks = data["trackinfo"].array.enumerated().compactMap { i, t -> Track? in
            guard let title = t["title"].string else { return nil }
            let link = t["title_link"].string.map { $0.hasPrefix("http") ? $0 : base + $0 } ?? url
            let id = t["track_id"].string ?? t["id"].string ?? link
            return Track(
                id: "bandcamp:\(id)",
                source: .bandcamp,
                title: title,
                artist: t["artist"].string ?? artist,
                album: isAlbum ? albumTitle : (data["album_title"].string ?? current?["album_title"].string),
                albumArtist: isAlbum ? artist : nil,
                durationMs: t["duration"].double.map { Int64($0 * 1000) },
                artworkUrl: art,
                pageUrl: link,
                streamUrl: link,
                year: year,
                trackNumber: t["track_num"].int ?? (isAlbum ? i + 1 : nil)
            )
        }
        guard !tracks.isEmpty else { return nil }
        if isAlbum {
            return .many(TrackCollection(
                id: "bandcamp:album:\(current?["id"].string ?? url)",
                source: .bandcamp,
                kind: .album,
                title: albumTitle ?? "Album",
                subtitle: artist,
                artworkUrl: art,
                pageUrl: url,
                year: year,
                trackCount: tracks.count,
                tracks: tracks
            ))
        }
        var track = tracks[0]
        track.pageUrl = url
        track.streamUrl = url
        return .single(track)
    }
}
