import CryptoKit
import Foundation

/**
 * A Navidrome server (or any Subsonic / OpenSubsonic server), read through
 * its API with the user's login: the collection with play counts, stars
 * and ratings, playlists, similar artists, streams, covers and scans.
 */
public final class Subsonic: @unchecked Sendable {
    public static let apiVersion = "1.16.1"
    public static let client = "KultrDL"
    private static let maxSongs = 200_000

    public struct Server: Sendable, Equatable {
        public var url: String
        public var username: String
        public var password: String

        public init(url: String, username: String, password: String) {
            self.url = url
            self.username = username
            self.password = password
        }

        public var base: String { Subsonic.baseUrl(url) }
    }

    public struct Info: Sendable, CustomStringConvertible {
        public var type: String?
        public var version: String?
        public var openSubsonic: Bool

        public var description: String {
            var name = "Subsonic server"
            if let type, let first = type.first { name = String(first).uppercased() + String(type.dropFirst()) }
            guard let version else { return name }
            return name + " " + version
        }
    }

    public struct Song: Sendable, Equatable {
        public var id: String
        public var title: String
        public var artist: String
        public var album: String?
        public var albumArtist: String?
        public var albumId: String?
        public var artistId: String?
        public var genre: String?
        public var year: Int?
        public var track: Int?
        public var disc: Int?
        public var durationMs: Int64?
        public var coverArt: String?
        public var playCount: Int
        /** Milliseconds since 1970. */
        public var playedAt: Int64?
        public var starred: Bool
        public var rating: Int
        public var isrc: String?
    }

    public struct Playlist: Sendable, Equatable {
        public var id: String
        public var name: String
        public var songCount: Int
    }

    public struct SubsonicError: LocalizedError, Sendable {
        public let code: Int?
        public let message: String
        public var errorDescription: String? { message }
    }

    private let http: Http
    public let server: Server

    public init(http: Http, server: Server) {
        self.http = http
        self.server = server
    }

    public func ping() async throws -> Info {
        let r = try await call("ping")
        return Info(type: r["type"].string, version: r["serverVersion"].string ?? r["version"].string, openSubsonic: r["openSubsonic"].string == "true")
    }

    /** Every song on the server, a page at a time (an empty search3 query lists everything on Navidrome). */
    public func songs(pageSize: Int = 500, onPage: (Int) -> Void = { _ in }) async throws -> [Song] {
        var out: [Song] = []
        var offset = 0
        while true {
            let page = try await call(
                "search3",
                ("query", ""), ("songCount", "\(pageSize)"), ("songOffset", "\(offset)"), ("artistCount", "0"), ("albumCount", "0")
            )["searchResult3"]["song"].array.compactMap(Self.parseSong)
            out += page
            onPage(out.count)
            if page.count < pageSize || out.count >= Self.maxSongs { break }
            offset += pageSize
        }
        return out
    }

    public func playlists() async throws -> [Playlist] {
        try await call("getPlaylists")["playlists"]["playlist"].array.compactMap { p in
            guard let id = p["id"].string else { return nil }
            return Playlist(id: id, name: p["name"].string ?? "Playlist", songCount: p["songCount"].int ?? 0)
        }
    }

    public func playlistSongs(_ id: String) async throws -> [Song] {
        try await call("getPlaylist", ("id", id))["playlist"]["entry"].array.compactMap(Self.parseSong)
    }

    /** Artists like this one (needs the server's Last.fm integration); [artistId] is the server's id. */
    public func similarArtists(_ artistId: String, count: Int = 20) async throws -> [String] {
        try await call("getArtistInfo2", ("id", artistId), ("count", "\(count)"), ("includeNotPresent", "true"))["artistInfo2"]["similarArtist"]
            .array.compactMap { $0["name"].string }
    }

    /**
     * Whether the signed-in account is an admin, or nil when the server doesn't say.
     * Plays, stars and ratings belong to each account; only admins may start scans.
     */
    public func isAdmin() async throws -> Bool? {
        try await call("getUser", ("username", server.username))["user"]["adminRole"].bool
    }

    /** Ask the server to look for new files now (only admins may). */
    public func startScan() async throws -> Bool {
        try await call("startScan")["scanStatus"]?["scanning"].string == "true"
    }

    /** Where a song streams from, without the login; [authenticate] adds it when the request is made. */
    public func streamUrl(_ songId: String) -> String { "\(server.base)/rest/stream?id=\(songId.urlQueryEncoded)" }

    public func coverUrl(_ coverArt: String, size: Int = 600) -> String {
        "\(server.base)/rest/getCoverArt?id=\(coverArt.urlQueryEncoded)&size=\(size)"
    }

    /** [url] with the login added (a fresh salt and token each time), for a request to this server. */
    public func authenticate(_ url: String) -> String {
        url + (url.contains("?") ? "&" : "?") + Self.query(authParams())
    }

    public func authParams() -> [(String, String)] {
        let salt = Self.salt()
        return [("u", server.username), ("t", Self.md5(server.password + salt)), ("s", salt), ("v", Self.apiVersion), ("c", Self.client), ("f", "json")]
    }

    public func owns(_ url: String) -> Bool { url.hasPrefix(server.base + "/rest/") }

    public func toTrack(_ song: Song) -> Track {
        Track(
            id: "navidrome:\(song.id)",
            source: .navidrome,
            title: song.title,
            artist: song.artist,
            album: song.album,
            albumArtist: song.albumArtist,
            durationMs: song.durationMs,
            artworkUrl: song.coverArt.map { coverUrl($0) },
            streamUrl: streamUrl(song.id),
            isrc: song.isrc,
            year: song.year,
            trackNumber: song.track,
            discNumber: song.disc,
            genre: song.genre
        )
    }

    private func call(_ method: String, _ params: (String, String)...) async throws -> JSON {
        let url = "\(server.base)/rest/\(method).view?" + Self.query(authParams() + params)
        let data: Data
        do {
            data = try await http.getData(url)
        } catch let error as HttpError where error.code == 404 {
            throw SubsonicError(code: nil, message: "That doesn't look like a Navidrome or Subsonic server.")
        }
        guard let json = try? JSON.parse(data) else {
            throw SubsonicError(code: nil, message: "That doesn't look like a Navidrome or Subsonic server.")
        }
        return try Self.check(json)
    }

    private static func query(_ params: [(String, String)]) -> String {
        params.map { "\($0.0)=\($0.1.urlQueryEncoded)" }.joined(separator: "&")
    }

    // ------------------------------------------------------------ parsing --

    private static let appPart = Rx(#"/app(/.*)?$"#)
    private static let restPart = Rx(#"/rest(/.*)?$"#)

    /** "nas.local:4533/" → "http://nas.local:4533"; a pasted web-UI link loses its "/app/…" part. */
    public static func baseUrl(_ url: String) -> String {
        var u = url.trimmed()
        while u.hasSuffix("/") { u.removeLast() }
        if !u.hasPrefix("http://") && !u.hasPrefix("https://") { u = "http://" + u }
        u = restPart.replace(appPart.replace(u, with: ""), with: "")
        while u.hasSuffix("/") { u.removeLast() }
        return u
    }

    private static func salt() -> String {
        (0..<8).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }

    public static func md5(_ text: String) -> String {
        Insecure.MD5.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /** The answer inside "subsonic-response", or the server's reason for refusing. */
    public static func check(_ json: JSON) throws -> JSON {
        guard let r = json["subsonic-response"] else {
            throw SubsonicError(code: nil, message: "That doesn't look like a Navidrome or Subsonic server.")
        }
        if r["status"].string == "ok" { return r }
        let code = r["error"]?["code"].int
        let message = r["error"]?["message"].string
        let text: String
        switch code {
        case 40: text = "The server didn't accept the username or password."
        case 41: text = "This account can't sign in with a token (LDAP accounts can't). Use a local Navidrome account."
        case 50: text = "This account isn't allowed to do that\(message.map { " (\($0))" } ?? "")."
        case 70: text = "Not found on the server."
        default: text = "The server refused: \(message ?? "error \(code.map(String.init) ?? "?")")"
        }
        throw SubsonicError(code: code, message: text)
    }

    public static func parseSong(_ r: JSON) -> Song? {
        if r["isVideo"].string == "true" { return nil }
        guard let id = r["id"].string, let title = r["title"].string else { return nil }
        let artists = r["artists"].array.compactMap { $0["name"].string }
        return Song(
            id: id,
            title: title,
            artist: r["displayArtist"].string ?? r["artist"].string ?? (artists.isEmpty ? "Unknown artist" : artists.joined(separator: ", ")),
            album: r["album"].string,
            albumArtist: r["displayAlbumArtist"].string ?? r["albumArtists"]?[0]?["name"].string,
            albumId: r["albumId"].string,
            artistId: r["artistId"].string ?? r["artists"]?[0]?["id"].string,
            genre: r["genre"].string ?? r["genres"]?[0]?["name"].string,
            year: r["year"].int,
            track: r["track"].int,
            disc: r["discNumber"].int,
            durationMs: r["duration"].int64.map { $0 * 1000 },
            coverArt: r["coverArt"].string,
            playCount: r["playCount"].int ?? 0,
            playedAt: parseDate(r["played"].string),
            starred: r["starred"].string != nil,
            rating: r["userRating"].int ?? 0,
            isrc: r["isrc"]?[0].string ?? r["isrc"].string
        )
    }

    /** "2026-09-20T18:30:00Z", with or without fractions of a second, in milliseconds. */
    static func parseDate(_ text: String?) -> Int64? {
        guard let text else { return nil }
        let date = (try? Date.ISO8601FormatStyle().parse(text))
            ?? (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text))
        return date.map { Int64(($0.timeIntervalSince1970 * 1000).rounded()) }
    }
}
