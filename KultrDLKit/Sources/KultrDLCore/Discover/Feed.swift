import Foundation

/** An album or single suggested, and why. */
public struct Pick: Codable, Hashable, Sendable, Identifiable {
    public var collection: TrackCollection
    public var artist: String
    public var reason: String
    public var key: String

    public var id: String { key }

    public init(_ collection: TrackCollection, artist: String, reason: String, key: String) {
        self.collection = collection
        self.artist = artist
        self.reason = reason
        self.key = key
    }
}

/** A playlist made for the user; [id] stays the same from day to day, so it can be followed. */
public struct Mix: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var subtitle: String
    public var tracks: [Track]

    public init(id: String, title: String, subtitle: String, tracks: [Track]) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.tracks = tracks
    }

    public var artworkUrls: [String] { Array(tracks.compactMap(\.artworkUrl).distinct { $0 }.prefix(4)) }

    public func asCollection() -> TrackCollection {
        TrackCollection(
            id: "mix:\(id)",
            source: .web,
            kind: .playlist,
            title: title,
            subtitle: subtitle,
            artworkUrl: artworkUrls.first,
            trackCount: tracks.count,
            tracks: tracks
        )
    }
}

/** Everything on the "For you" page, as last worked out. */
public struct Feed: Codable, Hashable, Sendable {
    /** Milliseconds since 1970. */
    public var builtAt: Int64
    public var releases: [Pick]
    public var mixes: [Mix]
    public var albums: [Pick]
    public var missing: [Pick]
    public var rediscover: [Track]
    /** The artists the suggestions grew from, most liked first. */
    public var seeds: [String]
    /** Nothing could be fetched; only suggestions from what is on the phone. */
    public var offline: Bool

    public init(
        builtAt: Int64 = 0,
        releases: [Pick] = [],
        mixes: [Mix] = [],
        albums: [Pick] = [],
        missing: [Pick] = [],
        rediscover: [Track] = [],
        seeds: [String] = [],
        offline: Bool = false
    ) {
        self.builtAt = builtAt
        self.releases = releases
        self.mixes = mixes
        self.albums = albums
        self.missing = missing
        self.rediscover = rediscover
        self.seeds = seeds
        self.offline = offline
    }

    public var isEmpty: Bool { releases.isEmpty && mixes.isEmpty && albums.isEmpty && missing.isEmpty && rediscover.isEmpty }

    /** The same feed with anything now blocked or dismissed left out. */
    public func filtered(_ rules: Rules) -> Feed {
        var f = self
        f.releases = releases.filter { rules.allows($0) }
        f.albums = albums.filter { rules.allows($0) }
        f.missing = missing.filter { rules.allows($0) }
        f.mixes = mixes.map { m in
            var m = m
            m.tracks = m.tracks.filter { rules.allows($0) }
            return m
        }.filter { !$0.tracks.isEmpty }
        f.rediscover = rediscover.filter { rules.allows($0) }
        return f
    }
}

/** Stable keys for "not interested": the same song or album from any source gets the same key. */
public enum Keys {
    private static let edition = Rx(#"(?i)\s*[(\[][^)\]]*(deluxe|edition|expanded|anniversary|bonus|explicit|clean|version|remaster)[^)\]]*[)\]]"#)

    public static func primary(_ artist: String?) -> String {
        let a = artist ?? ""
        return TextTools.splitArtists(a).first ?? a
    }

    public static func albumTitle(_ title: String) -> String { TextTools.coreTitle(edition.replace(title, with: "")) }

    public static func artist(_ name: String) -> String { "artist:" + Credits.key(name) }

    public static func album(_ artist: String?, _ title: String) -> String {
        "album:" + Credits.key(primary(artist)) + "|" + albumTitle(title)
    }

    public static func track(_ artist: String, _ title: String) -> String {
        "track:" + Credits.key(primary(artist)) + "|" + TextTools.coreTitle(title)
    }
}

/** What the user already has: files on the phone, Navidrome, and the KultrDL library. */
public struct Owned: Sendable {
    private let albums: Set<String>
    private let songs: Set<String>
    private let artists: Set<String>

    public static let none = Builder().build()

    public var isEmpty: Bool { songs.isEmpty && albums.isEmpty }

    public func hasAlbum(_ artist: String?, _ title: String) -> Bool { albums.contains(Keys.album(artist, title)) }

    public func hasSong(_ artist: String, _ title: String) -> Bool { songs.contains(Keys.track(artist, title)) }

    public func hasArtist(_ name: String) -> Bool {
        artists.contains(Credits.key(name)) || artists.contains(Credits.key(Keys.primary(name)))
    }

    public var songCount: Int { songs.count }

    public final class Builder {
        private var albums = Set<String>()
        private var songs = Set<String>()
        private var artists = Set<String>()

        public init() {}

        @discardableResult
        public func add(_ artist: String, _ title: String, album: String? = nil, albumArtist: String? = nil) -> Builder {
            if !title.trimmed().isEmpty { songs.insert(Keys.track(artist, title)) }
            if let album, !album.trimmed().isEmpty {
                let by = albumArtist.flatMap { $0.trimmed().isEmpty ? nil : $0 } ?? artist
                albums.insert(Keys.album(by, album))
            }
            Credits.main(artist).forEach { artists.insert(Credits.key($0)) }
            if let albumArtist { Credits.main(albumArtist).forEach { artists.insert(Credits.key($0)) } }
            return self
        }

        public func build() -> Owned { Owned(albums: albums, songs: songs, artists: artists) }
    }
}

/**
 * What must never be suggested: blocked artists (and songs they are on),
 * anything marked "not interested", and genres left out.
 */
public struct Rules: Sendable {
    public let blocks: ArtistBlocks
    public let dismissed: Set<String>
    /** Each artist's genres (by [Credits.key]), as far as they are known. */
    public let artistGenres: [String: [String]]
    private let excluded: Set<String>

    public init(
        blocks: ArtistBlocks = .none,
        dismissed: Set<String> = [],
        excludedGenres: [String] = [],
        artistGenres: [String: [String]] = [:]
    ) {
        self.blocks = blocks
        self.dismissed = dismissed
        self.artistGenres = artistGenres
        excluded = Set(excludedGenres.map { Taste.genreName($0).lowercased() })
    }

    private init(blocks: ArtistBlocks, dismissed: Set<String>, excluded: Set<String>, artistGenres: [String: [String]]) {
        self.blocks = blocks
        self.dismissed = dismissed
        self.excluded = excluded
        self.artistGenres = artistGenres
    }

    public func withGenres(_ more: [String: [String]]) -> Rules {
        Rules(blocks: blocks, dismissed: dismissed, excluded: excluded, artistGenres: artistGenres.merging(more) { _, new in new })
    }

    private func excludedGenre(_ genre: String?) -> Bool {
        guard let genre else { return false }
        return excluded.contains(Taste.genreName(genre).lowercased())
    }

    private func excludedArtist(_ name: String) -> Bool {
        if excluded.isEmpty { return false }
        guard let genres = artistGenres[Credits.key(name)] ?? artistGenres[Credits.key(Keys.primary(name))] else { return false }
        return genres.first.map(excludedGenre) == true
    }

    public func allowsArtist(_ name: String) -> Bool {
        !blocks.blocksArtist(name) && !dismissed.contains(Keys.artist(name)) && !excludedArtist(name)
    }

    public func allows(_ track: Track) -> Bool {
        !blocks.blocks(track) &&
            !dismissed.contains(Keys.track(track.artist, track.title)) &&
            !dismissed.contains(Keys.artist(Keys.primary(track.artist))) &&
            !excludedGenre(track.genre) && !excludedArtist(track.artist)
    }

    public func allows(_ collection: TrackCollection) -> Bool {
        let artist = collection.subtitle ?? ""
        return !blocks.blocks(collection) &&
            !dismissed.contains(Keys.album(artist, collection.title)) &&
            (artist.isEmpty || allowsArtist(artist)) &&
            !excludedGenre(collection.genre)
    }

    public func allows(_ pick: Pick) -> Bool { !dismissed.contains(pick.key) && allows(pick.collection) }
}
