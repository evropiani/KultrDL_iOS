import Foundation

/**
 * Artists through Deezer's public API (discographies with dates and
 * genres, related artists, top songs), with Apple Music as a second
 * source for artists Deezer doesn't know or when Deezer is switched off.
 */
public final class CatalogDirectory: ArtistDirectory, @unchecked Sendable {
    private let deezer: Deezer
    private let apple: AppleMusic
    private let useDeezer: @Sendable () -> Bool

    public init(deezer: Deezer, apple: AppleMusic, useDeezer: @escaping @Sendable () -> Bool = { true }) {
        self.deezer = deezer
        self.apple = apple
        self.useDeezer = useDeezer
    }

    public func find(_ name: String) async throws -> ArtistRef? {
        let key = Credits.key(name)
        if key.isEmpty { return nil }
        if useDeezer() {
            // The same name, and the best-known artist of that name.
            let same = try await deezer.searchArtists(name).filter { Credits.key($0.name) == key }
            if let best = same.max(by: { $0.fans < $1.fans }) { return best }
        }
        return try await apple.searchArtists(name).first { Credits.key($0.name) == key }
    }

    public func releases(_ artist: ArtistRef) async throws -> [TrackCollection] {
        if let id = artist.id.dropPrefix("deezer:") { return try await deezer.artistAlbums(id, artistName: artist.name) }
        if let id = artist.id.dropPrefix("apple:") { return try await apple.artistAlbums(id) }
        return []
    }

    public func bestAlbums(_ artist: ArtistRef, limit: Int) async throws -> [TrackCollection] {
        if let id = artist.id.dropPrefix("deezer:") { return Array(try await deezer.popularAlbums(id, artistName: artist.name).prefix(limit)) }
        if let id = artist.id.dropPrefix("apple:") { return Array(try await apple.artistAlbums(id).filter { $0.recordType == "album" }.prefix(limit)) }
        return []
    }

    public func similar(_ artist: ArtistRef) async throws -> [ArtistRef] {
        guard let id = artist.id.dropPrefix("deezer:") else { return [] }
        return try await deezer.related(id)
    }

    public func topTracks(_ artist: ArtistRef, limit: Int) async throws -> [Track] {
        guard let id = artist.id.dropPrefix("deezer:") else { return [] }
        return try await deezer.top(id, limit: limit)
    }

    public func tracks(_ release: TrackCollection) async throws -> [Track] {
        if let id = release.id.dropPrefix("deezer:album:") { return try await deezer.album(id)?.tracks ?? [] }
        if let id = release.id.dropPrefix("apple:album:") { return try await apple.album(id)?.tracks ?? [] }
        return []
    }
}

extension String {
    /** The rest of the string after [prefix], or nil when it doesn't start with it. */
    func dropPrefix(_ prefix: String) -> String? { hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil }
}
