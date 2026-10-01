import Foundation

/** ListenBrainz's open API: a user's top artists and the playlists it makes for them each week. */
public final class ListenBrainz: @unchecked Sendable {
    private static let base = "https://api.listenbrainz.org/1"

    public struct PlaylistRef: Sendable, Equatable {
        public var id: String
        public var title: String
    }

    private let http: Http

    public init(http: Http) {
        self.http = http
    }

    public func topArtists(_ user: String, range: String = "half_yearly", count: Int = 60) async throws -> [(name: String, plays: Int64)] {
        let text = try await http.get("\(Self.base)/stats/user/\(user.urlQueryEncoded)/artists?range=\(range)&count=\(count)")
        // 204 No Content: statistics not worked out yet for this user.
        if text.trimmed().isEmpty { return [] }
        return try JSON.parse(text)["payload"]["artists"].array.compactMap { a in
            a["artist_name"].string.map { (name: $0, plays: a["listen_count"].int64 ?? 0) }
        }
    }

    /** Playlists ListenBrainz made for the user (Weekly Exploration, Weekly Jams…), newest first. */
    public func createdFor(_ user: String) async throws -> [PlaylistRef] {
        let text = try await http.get("\(Self.base)/user/\(user.urlQueryEncoded)/playlists/createdfor?count=25")
        if text.trimmed().isEmpty { return [] }
        return try JSON.parse(text)["playlists"].array.compactMap { p in
            let pl = p["playlist"]
            guard let identifier = pl["identifier"].string else { return nil }
            let id = identifier.trimmingCharacters(in: CharacterSet(charactersIn: "/")).components(separatedBy: "/").last ?? identifier
            return PlaylistRef(id: id, title: pl["title"].string ?? "Playlist")
        }
    }

    public func playlist(_ id: String) async throws -> [Track] {
        Self.parsePlaylist(try await http.getJSON("\(Self.base)/playlist/\(id.urlQueryEncoded)"))
    }

    /** A JSPF playlist's tracks, as names to match on YouTube Music. */
    public static func parsePlaylist(_ root: JSON) -> [Track] {
        root["playlist"]?["track"].array.compactMap { t in
            guard let title = t["title"].string, let artist = t["creator"].string else { return nil }
            let identifier = t["identifier"]?[0].string ?? t["identifier"].string
            let mbid = identifier.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "/")).components(separatedBy: "/").last ?? $0 }
            return Track(
                id: "listenbrainz:" + (mbid ?? TextTools.normalize("\(artist) \(title)").replacingOccurrences(of: " ", with: "-")),
                source: .listenbrainz,
                title: title,
                artist: artist,
                album: t["album"].string,
                durationMs: t["duration"].int64,
                pageUrl: mbid.map { "https://musicbrainz.org/recording/\($0)" }
            )
        } ?? []
    }

    private static let kinds = Rx(#"(?i)^(weekly exploration|weekly jams|daily jams|top discoveries|top missed recordings)"#)

    /** Which kind of weekly playlist a title is, as a stable id: "weekly-exploration", "weekly-jams"… */
    public static func kind(_ title: String) -> String? {
        kinds.group(title, 0).map { $0.lowercased().replacingOccurrences(of: " ", with: "-") }
    }
}
