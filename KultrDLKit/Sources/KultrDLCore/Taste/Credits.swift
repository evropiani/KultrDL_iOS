import Foundation

/**
 * Who is on a track: the artists it is credited to, and anyone featured,
 * whether the feature is in the artist field ("A feat. B", "A, B & C") or
 * in the title ("Song (feat. B)", "Song ft. B", "Song (with B)").
 */
public enum Credits {
    private static let featBracket = Rx(#"(?i)[(\[]\s*(?:feat\.?|ft\.?|featuring|with)\s+([^)\]]+)[)\]]"#)
    private static let featTail = Rx(#"(?i)\s(?:feat\.?|ft\.?|featuring)\s+(.+)$"#)
    private static let channelNoise = Rx(#"(?i)(\s*-\s*topic|vevo)$"#)

    /** The key artists are compared by: lower case, no accents, no "- Topic"/"VEVO" channel suffixes. */
    public static func key(_ name: String) -> String {
        TextTools.normalize(channelNoise.replace(name.trimmed(), with: "").trimmed())
    }

    /** The artist field's names, main artist first. */
    public static func main(_ artist: String) -> [String] {
        let whole = artist.trimmed()
        if whole.isEmpty { return [] }
        return ([whole] + TextTools.splitArtists(whole)).distinct(by: key).filter { !key($0).isEmpty }
    }

    /** Names featured in the title. */
    public static func featured(_ title: String) -> [String] {
        var found = featBracket.findAll(title).compactMap { $0.count > 1 ? $0[1] : nil }
        if let tail = featTail.group(featBracket.replace(title, with: "")) { found.append(tail) }
        return found.flatMap { TextTools.splitArtists($0) }
            .map { $0.trimmed() }
            .filter { !key($0).isEmpty }
            .distinct(by: key)
    }

    /** Everyone credited, as display names: the artist field's names, then the title's features. */
    public static func everyone(_ artist: String, _ title: String, albumArtist: String? = nil) -> [String] {
        (main(artist) + featured(title) + main(albumArtist ?? "")).distinct(by: key)
    }

    public static func keys(_ artist: String, _ title: String, albumArtist: String? = nil) -> Set<String> {
        Set(everyone(artist, title, albumArtist: albumArtist).map(key).filter { !$0.isEmpty })
    }

    /**
     * The names to offer in "Block artist…": each credited artist once, then a
     * shared credit line as a whole, since that may be one band ("Mumford & Sons").
     */
    public static func people(_ artist: String, _ title: String) -> [String] {
        let split = TextTools.splitArtists(artist)
        var parts: [String] = split.isEmpty ? [artist] : split
        parts += featured(title)
        if split.count > 1 { parts.append(artist) }
        return parts.map { $0.trimmed() }.filter { !key($0).isEmpty }.distinct(by: key)
    }
}

/**
 * Artists the user never wants to hear: their own songs and every song
 * they are featured on are hidden and skipped.
 */
public struct ArtistBlocks: Sendable, Equatable {
    private let blocked: Set<String>

    public init<S: Sequence>(_ keys: S) where S.Element == String {
        blocked = Set(keys.map(Credits.key).filter { !$0.isEmpty })
    }

    public static let none = ArtistBlocks([String]())

    public var isEmpty: Bool { blocked.isEmpty }

    public func blocksArtist(_ name: String?) -> Bool {
        guard let name, !isEmpty else { return false }
        return !Credits.keys(name, "").isDisjoint(with: blocked)
    }

    public func blocks(_ artist: String, _ title: String, albumArtist: String? = nil) -> Bool {
        !isEmpty && !Credits.keys(artist, title, albumArtist: albumArtist).isDisjoint(with: blocked)
    }

    public func blocks(_ track: Track) -> Bool { blocks(track.artist, track.title, albumArtist: track.albumArtist) }

    /** An album or playlist by a blocked artist (its other songs are filtered one by one). */
    public func blocks(_ collection: TrackCollection) -> Bool { blocksArtist(collection.subtitle) }

    public func tracks(_ list: [Track]) -> [Track] { isEmpty ? list : list.filter { !blocks($0) } }
}
