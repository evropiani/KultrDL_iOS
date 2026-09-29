import Foundation

/**
 * song.link: turns a link on one service into the same song or album on
 * the others. Used for services without a public catalogue API (Tidal,
 * Amazon Music), and to find a track's recording on YouTube directly.
 */
public final class Odesli: @unchecked Sendable {
    public struct Entity: Sendable {
        public let type: String
        public let title: String
        public let artist: String?
        public let artworkUrl: String?
        /** The same song or album on YouTube Music or YouTube, when song.link knows it. */
        public let youtubeUrl: String?
        public let links: [String: String]
    }

    private let http: Http

    public init(http: Http) {
        self.http = http
    }

    public func lookup(_ url: String, country: String = "US") async throws -> Entity? {
        Self.parse(try await http.getJSON("https://api.song.link/v1-alpha.1/links?userCountry=\(country)&url=\(url.urlQueryEncoded)"))
    }

    public static func parse(_ root: JSON) -> Entity? {
        guard let entities = root["entitiesByUniqueId"]?.object else { return nil }
        let main = root["entityUniqueId"].string.flatMap { entities[$0] } ?? entities.entries.first?.value
        guard let main, let title = main["title"].string else { return nil }
        var links: [String: String] = [:]
        for (platform, value) in root["linksByPlatform"]?.object?.entries ?? [] {
            if let url = value["url"].string { links[platform] = url }
        }
        return Entity(
            type: main["type"].string ?? "song",
            title: title,
            artist: main["artistName"].string,
            artworkUrl: main["thumbnailUrl"].string,
            youtubeUrl: links["youtubeMusic"] ?? links["youtube"],
            links: links
        )
    }
}
