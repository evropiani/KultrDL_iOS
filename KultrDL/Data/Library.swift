import Foundation
import KultrDLCore
import Observation

/**
 * A track the app has touched — saved, favourited, downloaded, played or
 * just queued — with what the user did with it, and the recording it was
 * matched to.
 */
struct StoredTrack: Codable, Identifiable, Hashable {
    var track: Track
    var matchedUrl: String?
    var favorite = false
    var favoritedAt: Int64?
    var saved = false
    var savedAt: Int64?
    var playCount = 0
    var lastPlayedAt: Int64?
    /** The downloaded file, relative to the app's home (see Storage.relative). */
    var localPath: String?
    var localFormat: String?
    var localSize: Int64?
    var downloadedAt: Int64?
    var addedAt: Int64

    var id: String { track.id }

    init(_ track: Track) {
        self.track = track
        addedAt = nowMs()
    }

    enum CodingKeys: String, CodingKey {
        case track, matchedUrl, favorite, favoritedAt, saved, savedAt, playCount, lastPlayedAt
        case localPath, localFormat, localSize, downloadedAt, addedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        track = try c.decode(Track.self, forKey: .track)
        matchedUrl = c.optional(.matchedUrl)
        favorite = c.value(.favorite, false)
        favoritedAt = c.optional(.favoritedAt)
        saved = c.value(.saved, false)
        savedAt = c.optional(.savedAt)
        playCount = c.value(.playCount, 0)
        lastPlayedAt = c.optional(.lastPlayedAt)
        localPath = c.optional(.localPath)
        localFormat = c.optional(.localFormat)
        localSize = c.optional(.localSize)
        downloadedAt = c.optional(.downloadedAt)
        addedAt = c.value(.addedAt, nowMs())
    }

    var localURL: URL? { localPath.map(Storage.absolute) }

    /** New catalogue details over what is stored, keeping what the user did with it. */
    mutating func refresh(_ t: Track) {
        var merged = t
        merged.album = t.album ?? track.album
        merged.albumArtist = t.albumArtist ?? track.albumArtist
        merged.durationMs = t.durationMs ?? track.durationMs
        merged.artworkUrl = t.artworkUrl ?? track.artworkUrl
        merged.pageUrl = t.pageUrl ?? track.pageUrl
        merged.streamUrl = t.streamUrl ?? track.streamUrl
        merged.matchUrl = t.matchUrl ?? track.matchUrl
        merged.isrc = t.isrc ?? track.isrc
        merged.year = t.year ?? track.year
        merged.trackNumber = t.trackNumber ?? track.trackNumber
        merged.discNumber = t.discNumber ?? track.discNumber
        merged.genre = t.genre ?? track.genre
        merged.explicit = t.explicit || track.explicit
        track = merged
    }
}

/** One of the user's own playlists. */
struct Playlist: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var createdAt: Int64
    var updatedAt: Int64
    /** The page it was imported from, if it was. */
    var sourceUrl: String?
    var artworkUrl: String?
    var trackIds: [String]

    init(name: String, trackIds: [String] = [], sourceUrl: String? = nil, artworkUrl: String? = nil) {
        id = UUID().uuidString
        self.name = name
        createdAt = nowMs()
        updatedAt = createdAt
        self.sourceUrl = sourceUrl
        self.artworkUrl = artworkUrl
        self.trackIds = trackIds
    }
}

private struct LibraryFile: Codable {
    var tracks: [StoredTrack] = []
    var playlists: [Playlist] = []
    var searches: [String] = []

    init() {}

    enum CodingKeys: String, CodingKey { case tracks, playlists, searches }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tracks = c.value(.tracks, [])
        playlists = c.value(.playlists, [])
        searches = c.value(.searches, [])
    }
}

/**
 * The user's library, all on the phone: favourites, saved tracks,
 * playlists, downloads, listening history and recent searches.
 */
@MainActor
@Observable
final class LibraryStore {
    private(set) var tracks: [String: StoredTrack] = [:]
    private(set) var playlists: [Playlist] = []
    private(set) var recentSearches: [String] = []
    /** Bumped on every change, for views that reload from the library. */
    private(set) var version = 0

    @ObservationIgnored private var saveTask: Task<Void, Never>?

    init() {
        if let file = Storage.load(LibraryFile.self, "library.json") {
            let kept = Set(file.playlists.flatMap { $0.trackIds })
            for stored in file.tracks where Self.worthKeeping(stored) || kept.contains(stored.id) {
                tracks[stored.id] = stored
            }
            playlists = file.playlists
            recentSearches = file.searches
        }
    }

    private static func worthKeeping(_ t: StoredTrack) -> Bool {
        t.favorite || t.saved || t.playCount > 0 || t.localPath != nil || t.matchedUrl != nil
    }

    private func changed() {
        version += 1
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled, let self else { return }
            self.saveNow()
        }
    }

    func saveNow() {
        saveTask?.cancel()
        var file = LibraryFile()
        file.tracks = Array(tracks.values)
        file.playlists = playlists
        file.searches = recentSearches
        Storage.save(file, "library.json")
    }

    // ------------------------------------------------------------ reading --

    func stored(_ id: String) -> StoredTrack? { tracks[id] }

    func track(_ id: String) -> Track? { tracks[id]?.track }

    func isFavorite(_ id: String) -> Bool { tracks[id]?.favorite == true }

    func isSaved(_ id: String) -> Bool { tracks[id]?.saved == true }

    func isDownloaded(_ id: String) -> Bool { tracks[id]?.localPath != nil }

    var favorites: [Track] {
        tracks.values.filter { $0.favorite }.sorted { ($0.favoritedAt ?? 0) > ($1.favoritedAt ?? 0) }.map { $0.track }
    }

    var saved: [Track] {
        tracks.values.filter { $0.saved }.sorted { ($0.savedAt ?? 0) > ($1.savedAt ?? 0) }.map { $0.track }
    }

    var downloaded: [StoredTrack] {
        tracks.values.filter { $0.localPath != nil }.sorted { ($0.downloadedAt ?? 0) > ($1.downloadedAt ?? 0) }
    }

    func history(_ limit: Int = 100) -> [Track] {
        Array(tracks.values.filter { $0.lastPlayedAt != nil }.sorted { ($0.lastPlayedAt ?? 0) > ($1.lastPlayedAt ?? 0) }.prefix(limit)).map { $0.track }
    }

    func mostPlayed(_ limit: Int = 20) -> [Track] {
        Array(tracks.values.filter { $0.playCount > 0 }.sorted { $0.playCount > $1.playCount }.prefix(limit)).map { $0.track }
    }

    // ------------------------------------------------------------ writing --

    /** Store (or refresh) tracks without touching what the user did with them. */
    func remember(_ list: [Track]) {
        guard !list.isEmpty else { return }
        for t in list {
            if var existing = tracks[t.id] {
                existing.refresh(t)
                tracks[t.id] = existing
            } else {
                tracks[t.id] = StoredTrack(t)
            }
        }
        changed()
    }

    private func edit(_ id: String, _ change: (inout StoredTrack) -> Void) {
        guard var t = tracks[id] else { return }
        change(&t)
        tracks[id] = t
        changed()
    }

    func setFavorite(_ list: [Track], _ on: Bool) {
        remember(list)
        let now = nowMs()
        for t in list { edit(t.id) { $0.favorite = on; $0.favoritedAt = on ? now : nil } }
    }

    func setSaved(_ list: [Track], _ on: Bool) {
        remember(list)
        let now = nowMs()
        for t in list { edit(t.id) { $0.saved = on; $0.savedAt = on ? now : nil } }
    }

    func markPlayed(_ id: String) {
        edit(id) {
            $0.playCount += 1
            $0.lastPlayedAt = nowMs()
        }
    }

    func clearHistory() {
        for id in Array(tracks.keys) {
            tracks[id]?.playCount = 0
            tracks[id]?.lastPlayedAt = nil
        }
        changed()
    }

    func setMatchedUrl(_ id: String, _ url: String?) {
        edit(id) { $0.matchedUrl = url }
    }

    func setLocal(_ id: String, file: URL?, format: String?, size: Int64?) {
        edit(id) {
            $0.localPath = file.map(Storage.relative)
            $0.localFormat = file == nil ? nil : format
            $0.localSize = file == nil ? nil : size
            $0.downloadedAt = file == nil ? nil : nowMs()
        }
    }

    /** Downloads whose file was deleted outside the app (in the Files app) are forgotten. */
    func checkFiles() {
        var gone = false
        for (id, t) in tracks {
            if let url = t.localURL, !FileManager.default.fileExists(atPath: url.path) {
                tracks[id]?.localPath = nil
                tracks[id]?.localFormat = nil
                tracks[id]?.localSize = nil
                gone = true
            }
        }
        if gone { changed() }
    }

    // ---------------------------------------------------------- playlists --

    func playlist(_ id: String) -> Playlist? { playlists.first { $0.id == id } }

    func playlistTracks(_ id: String) -> [Track] {
        playlist(id)?.trackIds.compactMap { tracks[$0]?.track } ?? []
    }

    @discardableResult
    func createPlaylist(_ name: String, _ list: [Track] = [], sourceUrl: String? = nil, artworkUrl: String? = nil) -> String {
        remember(list)
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let playlist = Playlist(name: trimmed.isEmpty ? "New playlist" : trimmed, trackIds: list.map { $0.id }, sourceUrl: sourceUrl, artworkUrl: artworkUrl)
        playlists.insert(playlist, at: 0)
        changed()
        return playlist.id
    }

    private func editPlaylist(_ id: String, _ change: (inout Playlist) -> Void) {
        guard let index = playlists.firstIndex(where: { $0.id == id }) else { return }
        change(&playlists[index])
        playlists[index].updatedAt = nowMs()
        changed()
    }

    func renamePlaylist(_ id: String, _ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        editPlaylist(id) { $0.name = trimmed }
    }

    func deletePlaylist(_ id: String) {
        playlists.removeAll { $0.id == id }
        changed()
    }

    func addToPlaylist(_ id: String, _ list: [Track]) {
        remember(list)
        editPlaylist(id) { $0.trackIds += list.map { $0.id } }
    }

    func removeFromPlaylist(_ id: String, at position: Int) {
        editPlaylist(id) { p in
            if p.trackIds.indices.contains(position) { p.trackIds.remove(at: position) }
        }
    }

    func movePlaylistTrack(_ id: String, from: Int, to: Int) {
        editPlaylist(id) { p in
            guard p.trackIds.indices.contains(from), p.trackIds.indices.contains(to) else { return }
            p.trackIds.insert(p.trackIds.remove(at: from), at: to)
        }
    }

    /** Replace a playlist's tracks (a followed mix gets today's songs). */
    func replacePlaylistTracks(_ id: String, _ list: [Track]) {
        remember(list)
        let ids = list.map(\.id)
        guard playlist(id)?.trackIds != ids else { return }
        editPlaylist(id) { $0.trackIds = ids }
    }

    /** The playlist saved from a source (a mix followed with "Keep updated"). */
    func playlist(source: String) -> Playlist? { playlists.first { $0.sourceUrl == source } }

    /** Playlists by when they were last changed, newest first. */
    var playlistsByDate: [Playlist] { playlists.sorted { $0.updatedAt > $1.updatedAt } }

    // ----------------------------------------------------------- searches --

    func rememberSearch(_ query: String) {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard q.count >= 2 else { return }
        recentSearches.removeAll { $0.caseInsensitiveCompare(q) == .orderedSame }
        recentSearches.insert(q, at: 0)
        if recentSearches.count > 12 { recentSearches.removeLast(recentSearches.count - 12) }
        changed()
    }

    func forgetSearch(_ query: String) {
        recentSearches.removeAll { $0 == query }
        changed()
    }

    func clearSearches() {
        recentSearches = []
        changed()
    }

    // ------------------------------------------------------------- backup --

    func snapshot(settings: Settings?, servers: [SavedServer]) -> BackupFile {
        let inPlaylists = Set(playlists.flatMap { $0.trackIds })
        let keep = tracks.values.filter { $0.favorite || $0.saved || $0.playCount > 0 || $0.matchedUrl != nil || inPlaylists.contains($0.id) }
        var file = BackupFile()
        file.settings = settings
        file.tracks = keep.map {
            BackupTrack(track: $0.track, favorite: $0.favorite, favoritedAt: $0.favoritedAt, saved: $0.saved, savedAt: $0.savedAt, playCount: $0.playCount, lastPlayedAt: $0.lastPlayedAt, matchedUrl: $0.matchedUrl)
        }
        file.playlists = playlists.map { BackupPlaylist(name: $0.name, trackIds: $0.trackIds, sourceUrl: $0.sourceUrl, artworkUrl: $0.artworkUrl) }
        file.servers = servers
        return file
    }

    /** Merge a backup in: nothing already here is lost, and playlists are added alongside. */
    func restore(_ file: BackupFile) -> Int {
        for b in file.tracks {
            var t = tracks[b.track.id] ?? StoredTrack(b.track)
            t.refresh(b.track)
            t.favorite = t.favorite || b.favorite
            t.favoritedAt = t.favoritedAt ?? b.favoritedAt
            t.saved = t.saved || b.saved
            t.savedAt = t.savedAt ?? b.savedAt
            t.playCount = max(t.playCount, b.playCount)
            t.lastPlayedAt = [t.lastPlayedAt, b.lastPlayedAt].compactMap { $0 }.max()
            t.matchedUrl = t.matchedUrl ?? b.matchedUrl
            tracks[b.track.id] = t
        }
        let known = Set(tracks.keys)
        for p in file.playlists {
            playlists.append(Playlist(name: p.name, trackIds: p.trackIds.filter { known.contains($0) }, sourceUrl: p.sourceUrl, artworkUrl: p.artworkUrl))
        }
        changed()
        return file.tracks.count
    }
}
