import Foundation

/**
 * SoundCloud through the API its website uses: search, links to tracks
 * and sets, and each track's stream (a plain MP3, or HLS in AAC or MP3).
 * The API key is the website's own, read from its scripts as yt-dlp does.
 */
public final class SoundCloud: @unchecked Sendable {
    public struct Stream: Sendable {
        public let url: String
        public let hls: Bool
        /** "mp3", "m4a" or "opus". */
        public let ext: String
        public let preview: Bool
    }

    private static let api = "https://api-v2.soundcloud.com/"
    private let http: Http
    private let lock = NSLock()
    private var clientId: String?

    public init(http: Http) {
        self.http = http
    }

    public func search(_ query: String, limit: Int = 25) async throws -> [Track] {
        let json = try await call("search/tracks", ["q": query, "limit": "\(limit)"])
        return json["collection"].array.compactMap { Self.parseTrack($0, album: nil) }
    }

    /** Whatever a soundcloud.com link is: a track, or a set (album or playlist). */
    public func resolve(_ url: String) async throws -> LinkResult {
        let json = try await call("resolve", ["url": url])
        switch json["kind"].string {
        case "track":
            guard let t = Self.parseTrack(json, album: nil) else { break }
            return .single(t)
        case "playlist", "system-playlist":
            return .many(try await set(json))
        default:
            break
        }
        throw KultrError("That SoundCloud link isn't a track or a set.")
    }

    private func set(_ json: JSON) async throws -> TrackCollection {
        var stubs = json["tracks"].array
        // Sets list their first few tracks in full and the rest by id only.
        let missing = stubs.filter { $0["title"].string == nil }.compactMap { $0["id"].string }
        if !missing.isEmpty {
            var full: [String: JSON] = [:]
            for chunk in stride(from: 0, to: missing.count, by: 50).map({ Array(missing[$0..<min($0 + 50, missing.count)]) }) {
                let list = try await call("tracks", ["ids": chunk.joined(separator: ",")])
                for t in list.array { if let id = t["id"].string { full[id] = t } }
            }
            stubs = stubs.map { stub in stub["title"].string == nil ? (stub["id"].string.flatMap { full[$0] } ?? stub) : stub }
        }
        let isAlbum = ["album", "ep", "single", "compilation"].contains(json["set_type"].string ?? "")
        let title = json["title"].string ?? "Playlist"
        let owner = json["user"]?["username"].string
        var shell = TrackCollection(
            id: "soundcloud:set:\(json["id"].string ?? title)",
            source: .soundcloud,
            kind: isAlbum ? .album : .playlist,
            title: title,
            subtitle: owner,
            artworkUrl: Self.artwork(json["artwork_url"].string),
            pageUrl: json["permalink_url"].string,
            year: Text.year(json["release_date"].string ?? json["created_at"].string)
        )
        shell.tracks = stubs.enumerated().compactMap { i, t -> Track? in
            guard var track = Self.parseTrack(t, album: isAlbum ? shell : nil) else { return nil }
            if isAlbum { track.trackNumber = i + 1 }
            if track.artworkUrl == nil { track.artworkUrl = shell.artworkUrl }
            return track
        }
        shell.trackCount = shell.tracks.count
        return shell
    }

    /** The best stream of a track page: MP3 or AAC, never the encrypted ones. */
    public func stream(_ trackUrl: String) async throws -> Stream {
        let info = try await call("resolve", ["url": trackUrl])
        if info["policy"].string == "BLOCK" { throw KultrError("SoundCloud doesn't offer this track in your country.") }
        struct Candidate {
            let url: String
            let hls: Bool
            let ext: String
            let preview: Bool
            let rank: Int
        }
        var candidates: [Candidate] = []
        for t in info["media"]?["transcodings"].array ?? [] {
            guard let url = t["url"].string, let preset = t["preset"].string else { continue }
            var proto = t["format"]?["protocol"].string ?? "http"
            if proto.hasPrefix("ctr-") || proto.hasPrefix("cbc-") || proto.contains("encrypted") || url.contains("/encrypted-hls") { continue }
            if preset.hasPrefix("abr") { continue }
            if proto == "progressive" { proto = "http" }
            if url.contains("/hls") { proto = "hls" }
            let mime = t["format"]?["mime_type"].string ?? ""
            let codec = Rx(#"codecs="([^"]+)""#).group(mime) ?? ""
            let ext = codec.hasPrefix("mp4a") ? "m4a" : codec.hasPrefix("opus") ? "opus" : (mime.contains("mpeg") ? "mp3" : preset.before("_"))
            let preview = t["snipped"].bool == true || url.contains("/preview/")
            // Plain MP3 first (one file), then AAC over HLS, then MP3 over HLS; Opus last (AVFoundation can't play it in HLS).
            var rank = proto == "http" ? (ext == "mp3" ? 0 : 1) : (ext == "m4a" ? 2 : ext == "mp3" ? 3 : 5)
            if preview { rank += 10 }
            if t["quality"].string == "hq" { rank -= 1 }
            candidates.append(Candidate(url: url, hls: proto == "hls", ext: ext, preview: preview, rank: rank))
        }
        guard !candidates.isEmpty else { throw KultrError("SoundCloud has no stream for this track.") }
        var lastError: Error?
        for c in candidates.sorted(by: { $0.rank < $1.rank }) {
            do {
                let resolved = try await call(c.url, [:])
                if let streamUrl = resolved["url"].string {
                    return Stream(url: streamUrl, hls: c.hls || streamUrl.contains(".m3u8"), ext: c.ext, preview: c.preview)
                }
            } catch {
                lastError = error
            }
        }
        throw lastError ?? KultrError("SoundCloud has no stream for this track.")
    }

    // --------------------------------------------------------- API key --

    private func cachedClientId() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return clientId
    }

    private func setClientId(_ id: String?) {
        lock.lock()
        clientId = id
        lock.unlock()
    }

    private static let scriptSrc = Rx(#"<script[^>]+src="([^"]+)""#)
    private static let clientIdPattern = Rx(#"client_id\s*:\s*"([0-9a-zA-Z]{32})""#)

    private func freshClientId() async throws -> String {
        let page = try await http.get("https://soundcloud.com/")
        let scripts = Self.scriptSrc.findAll(page).compactMap { $0[1] }
        for src in scripts.reversed() where src.contains("sndcdn.com") {
            guard let script = try? await http.get(src) else { continue }
            if let id = Self.clientIdPattern.group(script) {
                setClientId(id)
                return id
            }
        }
        throw KultrError("SoundCloud changed its website; its API key couldn't be found.")
    }

    private func call(_ path: String, _ query: [String: String]) async throws -> JSON {
        for attempt in 0..<2 {
            let id: String
            if attempt == 0, let known = cachedClientId() {
                id = known
            } else {
                id = try await freshClientId()
            }
            var parts = query.map { "\($0.key)=\($0.value.urlQueryEncoded)" }
            parts.append("client_id=\(id)")
            let base = path.hasPrefix("http") ? path : Self.api + path
            let url = base + (base.contains("?") ? "&" : "?") + parts.joined(separator: "&")
            do {
                return try await http.getJSON(url, headers: ["Origin": "https://soundcloud.com", "Referer": "https://soundcloud.com/"])
            } catch let error as HttpError where (error.code == 401 || error.code == 403) && attempt == 0 {
                setClientId(nil)
                continue
            }
        }
        throw KultrError("SoundCloud refused the request.")
    }

    // ------------------------------------------------------------ parsing --

    static func artwork(_ url: String?) -> String? {
        url?.replacingOccurrences(of: "-large.", with: "-t500x500.")
    }

    public static func parseTrack(_ t: JSON, album: TrackCollection?) -> Track? {
        guard let id = t["id"].string, let title = t["title"].string else { return nil }
        let meta = t["publisher_metadata"]
        let url = t["permalink_url"].string
        return Track(
            id: "soundcloud:\(id)",
            source: .soundcloud,
            title: title,
            artist: meta?["artist"].string ?? t["user"]?["username"].string ?? "Unknown artist",
            album: meta?["album_title"].string ?? album?.title,
            albumArtist: album?.subtitle,
            durationMs: t["full_duration"].int64 ?? t["duration"].int64,
            artworkUrl: artwork(t["artwork_url"].string) ?? artwork(t["user"]?["avatar_url"].string),
            pageUrl: url,
            streamUrl: url,
            isrc: meta?["isrc"].string,
            year: Text.year(t["release_date"].string ?? t["display_date"].string ?? t["created_at"].string),
            genre: t["genre"].string?.nonEmpty,
            explicit: meta?["explicit"].bool == true
        )
    }
}
