import Foundation

/**
 * Where a track or collection was found.
 *
 * Streaming sources (`streams`) carry audio KultrDL can fetch directly. The
 * others are catalogues: their tracks are played and downloaded from the
 * matching recording on YouTube Music, with the catalogue's own title,
 * artist, album and artwork kept for tags.
 */
public enum Source: String, Codable, CaseIterable, Sendable, Hashable {
    case youtubeMusic = "YOUTUBE_MUSIC"
    case youtube = "YOUTUBE"
    case spotify = "SPOTIFY"
    case appleMusic = "APPLE_MUSIC"
    case deezer = "DEEZER"
    case soundcloud = "SOUNDCLOUD"
    case bandcamp = "BANDCAMP"
    case tidal = "TIDAL"
    case qobuz = "QOBUZ"
    case amazonMusic = "AMAZON_MUSIC"
    case web = "WEB"
    /** Songs on the user's Navidrome (Subsonic) server, streamed from it. */
    case navidrome = "NAVIDROME"
    /** Music files already on the phone (the Music app's library). */
    case phone = "PHONE"
    /** Tracks from ListenBrainz's weekly playlists: names only, matched like a catalogue. */
    case listenbrainz = "LISTENBRAINZ"

    public var label: String {
        switch self {
        case .youtubeMusic: return "YouTube Music"
        case .youtube: return "YouTube"
        case .spotify: return "Spotify"
        case .appleMusic: return "Apple Music"
        case .deezer: return "Deezer"
        case .soundcloud: return "SoundCloud"
        case .bandcamp: return "Bandcamp"
        case .tidal: return "Tidal"
        case .qobuz: return "Qobuz"
        case .amazonMusic: return "Amazon Music"
        case .web: return "Web"
        case .navidrome: return "Navidrome"
        case .phone: return "This phone"
        case .listenbrainz: return "ListenBrainz"
        }
    }

    public var streams: Bool {
        switch self {
        case .youtubeMusic, .youtube, .soundcloud, .bandcamp, .web, .navidrome, .phone: return true
        default: return false
        }
    }

    public var searchable: Bool {
        switch self {
        case .youtubeMusic, .youtube, .spotify, .appleMusic, .deezer, .soundcloud, .bandcamp: return true
        default: return false
        }
    }

    public static let searchSources: [Source] = allCases.filter { $0.searchable }

    /** The lower-case prefix of ids from this source ("tidal:…"). */
    public var key: String { rawValue.lowercased() }

    /** Unknown names (a newer backup) fall back to Web rather than failing. */
    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = Source(rawValue: raw) ?? .web
    }
}

public struct Track: Codable, Hashable, Identifiable, Sendable {
    /** Stable across searches: "<source>:<id on that source>". */
    public var id: String
    public var source: Source
    public var title: String
    public var artist: String
    public var album: String?
    public var albumArtist: String?
    public var durationMs: Int64?
    public var artworkUrl: String?
    /** The track's page on its source, for sharing and "open in". */
    public var pageUrl: String?
    /** A page KultrDL can play and download directly; nil for catalogue tracks. */
    public var streamUrl: String?
    /** A recording known to be this track (from a link service), tried before searching. */
    public var matchUrl: String?
    public var isrc: String?
    public var year: Int?
    public var trackNumber: Int?
    public var discNumber: Int?
    public var genre: String?
    public var explicit: Bool

    public init(
        id: String,
        source: Source,
        title: String,
        artist: String,
        album: String? = nil,
        albumArtist: String? = nil,
        durationMs: Int64? = nil,
        artworkUrl: String? = nil,
        pageUrl: String? = nil,
        streamUrl: String? = nil,
        matchUrl: String? = nil,
        isrc: String? = nil,
        year: Int? = nil,
        trackNumber: Int? = nil,
        discNumber: Int? = nil,
        genre: String? = nil,
        explicit: Bool = false
    ) {
        self.id = id
        self.source = source
        self.title = title
        self.artist = artist
        self.album = album
        self.albumArtist = albumArtist
        self.durationMs = durationMs
        self.artworkUrl = artworkUrl
        self.pageUrl = pageUrl
        self.streamUrl = streamUrl
        self.matchUrl = matchUrl
        self.isrc = isrc
        self.year = year
        self.trackNumber = trackNumber
        self.discNumber = discNumber
        self.genre = genre
        self.explicit = explicit
    }

    public var needsMatch: Bool { streamUrl == nil }

    enum CodingKeys: String, CodingKey {
        case id, source, title, artist, album, albumArtist, durationMs, artworkUrl, pageUrl, streamUrl, matchUrl
        case isrc, year, trackNumber, discNumber, genre, explicit
    }

    /** Lenient, so backups from the Android app (and older versions) open. */
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        source = (try? c.decode(Source.self, forKey: .source)) ?? .web
        title = (try? c.decode(String.self, forKey: .title)) ?? "Untitled"
        artist = (try? c.decode(String.self, forKey: .artist)) ?? "Unknown artist"
        album = try? c.decodeIfPresent(String.self, forKey: .album)
        albumArtist = try? c.decodeIfPresent(String.self, forKey: .albumArtist)
        durationMs = try? c.decodeIfPresent(Int64.self, forKey: .durationMs)
        artworkUrl = try? c.decodeIfPresent(String.self, forKey: .artworkUrl)
        pageUrl = try? c.decodeIfPresent(String.self, forKey: .pageUrl)
        streamUrl = try? c.decodeIfPresent(String.self, forKey: .streamUrl)
        matchUrl = try? c.decodeIfPresent(String.self, forKey: .matchUrl)
        isrc = try? c.decodeIfPresent(String.self, forKey: .isrc)
        year = try? c.decodeIfPresent(Int.self, forKey: .year)
        trackNumber = try? c.decodeIfPresent(Int.self, forKey: .trackNumber)
        discNumber = try? c.decodeIfPresent(Int.self, forKey: .discNumber)
        genre = try? c.decodeIfPresent(String.self, forKey: .genre)
        explicit = (try? c.decodeIfPresent(Bool.self, forKey: .explicit)) ?? false
    }
}

public enum CollectionKind: String, Codable, Sendable, Hashable {
    case album = "ALBUM"
    case playlist = "PLAYLIST"

    public var label: String { self == .album ? "Album" : "Playlist" }
}

/** An album or playlist, from any source. */
public struct TrackCollection: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var source: Source
    public var kind: CollectionKind
    public var title: String
    public var subtitle: String?
    public var artworkUrl: String?
    public var pageUrl: String?
    public var year: Int?
    public var trackCount: Int?
    /** "2026-09-26", when the source gives the full date. */
    public var releaseDate: String?
    /** "album", "single", "ep" or "compile", when the source says. */
    public var recordType: String?
    public var genre: String?
    /** Empty until loaded (search results list albums without their tracks). */
    public var tracks: [Track]

    public init(
        id: String,
        source: Source,
        kind: CollectionKind,
        title: String,
        subtitle: String? = nil,
        artworkUrl: String? = nil,
        pageUrl: String? = nil,
        year: Int? = nil,
        trackCount: Int? = nil,
        releaseDate: String? = nil,
        recordType: String? = nil,
        genre: String? = nil,
        tracks: [Track] = []
    ) {
        self.id = id
        self.source = source
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.artworkUrl = artworkUrl
        self.pageUrl = pageUrl
        self.year = year
        self.trackCount = trackCount
        self.releaseDate = releaseDate
        self.recordType = recordType
        self.genre = genre
        self.tracks = tracks
    }
}

public struct SearchResults: Sendable, Equatable {
    public var tracks: [Track]
    public var collections: [TrackCollection]

    public init(tracks: [Track] = [], collections: [TrackCollection] = []) {
        self.tracks = tracks
        self.collections = collections
    }

    public var isEmpty: Bool { tracks.isEmpty && collections.isEmpty }
}

/** What a pasted link turned out to be. */
public enum LinkResult: Sendable, Equatable {
    case single(Track)
    case many(TrackCollection)
}

/** An error with a message meant for people. */
public struct KultrError: LocalizedError, CustomStringConvertible, Sendable {
    public let message: String
    /** The source can't do this at all (rather than failing this time). */
    public let notSupported: Bool

    public init(_ message: String, notSupported: Bool = false) {
        self.message = message
        self.notSupported = notSupported
    }

    public var errorDescription: String? { message }
    public var description: String { message }
}

extension Array {
    /** Keeps the first element for each key. */
    public func distinct<K: Hashable>(by key: (Element) -> K) -> [Element] {
        var seen = Set<K>()
        return filter { seen.insert(key($0)).inserted }
    }
}
