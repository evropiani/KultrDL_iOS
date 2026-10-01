import Foundation

/**
 * One piece of evidence about what the user likes: a play, a skip (a
 * negative [weight]), a heart, a file they own, a Navidrome star…
 * [at] (milliseconds since 1970) dates it; undated evidence (files on the
 * phone) doesn't fade.
 */
public struct Signal: Sendable, Equatable {
    public var artist: String
    public var title: String
    public var weight: Double
    public var at: Int64?
    public var genre: String?

    public init(_ artist: String, _ title: String = "", _ weight: Double, _ at: Int64? = nil, genre: String? = nil) {
        self.artist = artist
        self.title = title
        self.weight = weight
        self.at = at
        self.genre = genre
    }
}

/**
 * [solo]: credited on their own somewhere, not only as part of a shared
 * credit ("Sons" in "Mumford & Sons") or as a feature.
 */
public struct ArtistScore: Sendable, Equatable {
    public var key: String
    public var name: String
    public var score: Double
    public var genres: [String]
    public var solo: Bool

    public init(key: String, name: String, score: Double, genres: [String], solo: Bool = true) {
        self.key = key
        self.name = name
        self.score = score
        self.genres = genres
        self.solo = solo
    }
}

/** Artists (and genres) by how much the user likes them now. */
public struct TasteProfile: Sendable {
    public static let known = 1.5
    public static let empty = TasteProfile(artists: [], genres: [:])

    public let artists: [ArtistScore]
    public let genres: [String: Double]
    private let byKey: [String: ArtistScore]

    public init(artists: [ArtistScore], genres: [String: Double]) {
        self.artists = artists
        self.genres = genres
        var map: [String: ArtistScore] = [:]
        for a in artists where map[a.key] == nil { map[a.key] = a }
        byKey = map
    }

    public var isEmpty: Bool { !artists.contains { $0.score > 0 } }

    public func score(_ name: String) -> Double { byKey[Credits.key(name)]?.score ?? 0 }

    /** Known well enough that suggesting them would be nothing new. */
    public func knows(_ name: String) -> Bool { score(name) >= Self.known }

    public func get(_ name: String) -> ArtistScore? { byKey[Credits.key(name)] }

    public func top(_ n: Int) -> [ArtistScore] { Array(artists.filter { $0.score > 0 }.prefix(n)) }

    /** The artists to build suggestions from: liked, and credited on their own somewhere. */
    public func seeds(_ n: Int) -> [ArtistScore] { Array(artists.filter { $0.score > 0 && $0.solo }.prefix(n)) }
}

public enum Taste {
    /** Evidence loses half its weight in this many days, so taste can move on. */
    public static let halfLifeDays = 90.0

    public static func decay(_ at: Int64?, now: Int64, halfLifeDays: Double = halfLifeDays) -> Double {
        guard let at else { return 1 }
        let days = Double(max(0, now - at)) / 86_400_000
        return pow(0.5, days / halfLifeDays)
    }

    /**
     * Adds the evidence up per artist. The artist field counts fully (a
     * credit like "Simon & Garfunkel" stays whole); each name in a shared
     * credit and each featured artist counts half.
     */
    public static func build(_ signals: [Signal], now: Int64) -> TasteProfile {
        var scores: [String: Double] = [:]
        var order: [String] = []
        var names: [String: [String: Double]] = [:]
        var genres: [String: [String: Double]] = [:]
        var allGenres: [String: Double] = [:]
        var solo = Set<String>()

        func add(_ name: String, _ w: Double, _ genre: String?) {
            let key = Credits.key(name)
            if key.isEmpty || key == "unknown artist" || key == "various artists" { return }
            if scores[key] == nil { order.append(key) }
            scores[key, default: 0] += w
            names[key, default: [:]][name.trimmed(), default: 0] += abs(w)
            if let genre, w > 0 { genres[key, default: [:]][genre, default: 0] += w }
        }

        for s in signals {
            let w = s.weight * decay(s.at, now: now)
            if w == 0 { continue }
            let genre = s.genre?.trimmed().nonEmpty.map(genreName)
            let whole = s.artist.trimmed()
            add(whole, w, genre)
            solo.insert(Credits.key(whole))
            let parts = TextTools.splitArtists(whole)
            if parts.count > 1 { parts.forEach { add($0, w * 0.5, genre) } }
            Credits.featured(s.title).forEach { add($0, w * 0.5, nil) }
            if let genre, w > 0 { allGenres[genre, default: 0] += w }
        }

        let artists = order.enumerated().map { index, key -> (Int, ArtistScore) in
            let name = names[key]?.max { a, b in a.value < b.value || (a.value == b.value && a.key > b.key) }?.key ?? key
            let topGenres = (genres[key] ?? [:]).sorted { a, b in a.value > b.value || (a.value == b.value && a.key < b.key) }.map(\.key)
            return (index, ArtistScore(key: key, name: name, score: scores[key] ?? 0, genres: Array(topGenres.prefix(3)), solo: solo.contains(key)))
        }
        // Highest score first; equal scores keep the order they were first seen in.
        let sorted = artists.sorted { a, b in a.1.score > b.1.score || (a.1.score == b.1.score && a.0 < b.0) }.map(\.1)
        return TasteProfile(artists: sorted, genres: allGenres)
    }

    private static let slash = Rx(#"\s*/\s*"#)
    private static let separators = Rx(#"[\s_-]+"#)
    private static let wordStart = Rx(#"\b[a-z]"#)

    /** "hip-hop/rap", "Hip Hop" and "HIP-HOP" are one genre. */
    public static func genreName(_ raw: String) -> String {
        var g = raw.trimmed().lowercased()
        g = slash.replace(g, with: "/")
        g = separators.replace(g, with: " ")
        g = wordStart.replace(g) { $0[0]?.uppercased() ?? "" }
        return g.replacingOccurrences(of: "Hip Hop", with: "Hip-Hop")
    }
}
