import Foundation

/** Last.fm's public API, with the user's own (free) API key: their top artists, and similar artists. */
public final class LastFm: @unchecked Sendable {
    private let http: Http
    private let apiKey: @Sendable () -> String

    public init(http: Http, apiKey: @escaping @Sendable () -> String) {
        self.http = http
        self.apiKey = apiKey
    }

    public var enabled: Bool { !apiKey().trimmed().isEmpty }

    /** The user's most played artists, with play counts. */
    public func topArtists(_ user: String, period: String = "6month", limit: Int = 60) async throws -> [(name: String, plays: Int64)] {
        try await call("user.gettopartists", ("user", user), ("period", period), ("limit", "\(limit)"))["topartists"]["artist"].array
            .compactMap { a in a["name"].string.map { (name: $0, plays: a["playcount"].int64 ?? 0) } }
    }

    public func similar(_ artist: String, limit: Int = 20) async throws -> [String] {
        try await call("artist.getsimilar", ("artist", artist), ("limit", "\(limit)"), ("autocorrect", "1"))["similarartists"]["artist"].array
            .compactMap { $0["name"].string }
    }

    private func call(_ method: String, _ params: (String, String)...) async throws -> JSON {
        let key = apiKey().trimmed()
        if key.isEmpty { throw KultrError("Last.fm needs an API key.") }
        let query = params.map { "&\($0.0)=\($0.1.urlQueryEncoded)" }.joined()
        let json: JSON
        do {
            json = try await http.getJSON("https://ws.audioscrobbler.com/2.0/?method=\(method)&api_key=\(key.urlQueryEncoded)&format=json\(query)")
        } catch let error as HttpError {
            // Last.fm explains a refusal (a wrong key, an unknown user) in the body.
            if let message = JSON.tryParse(error.body)?["message"].string { throw KultrError("Last.fm: \(message)") }
            throw error
        }
        if json["error"] != nil, let message = json["message"].string { throw KultrError("Last.fm: \(message)") }
        return json
    }
}
