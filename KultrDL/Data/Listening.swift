import Foundation
import KultrDLCore
import Observation

/**
 * One listen, as the player saw it: how long it played and whether it was
 * finished or skipped. Skips tell the recommendations what not to suggest.
 */
struct PlayRecord: Codable, Hashable {
    var trackId: String
    var artist: String
    var title: String
    /** Milliseconds since 1970. */
    var startedAt: Int64
    var listenedMs: Int64
    var durationMs: Int64?
    var completed: Bool
    var skipped: Bool
}

/** Where a song the user owns lives. */
enum Owner: String, Codable, CaseIterable {
    case phone = "PHONE", navidrome = "NAVIDROME"

    var file: String { "owned-\(rawValue.lowercased()).json" }
}

/**
 * A song in the user's own collection: a music file in the phone's Music
 * library, or a song on their Navidrome server with its play count, star
 * and rating.
 */
struct OwnedSong: Codable, Hashable, Sendable {
    var id: String
    var owner: Owner
    var title: String
    var artist: String
    var album: String?
    var albumArtist: String?
    var genre: String?
    var year: Int?
    var trackNumber: Int?
    var durationMs: Int64?
    var playCount: Int
    /** Milliseconds since 1970. */
    var lastPlayedAt: Int64?
    var starred: Bool
    var rating: Int
    var artworkUrl: String?
    /** The Music library's "ipod-library://" address on the phone; the stream address (without login) on Navidrome. */
    var streamUrl: String?
    /** The server's id for the artist, to ask it for similar artists. */
    var artistId: String?
    var addedAt: Int64?

    func toTrack() -> Track {
        Track(
            id: id,
            source: owner == .navidrome ? .navidrome : .phone,
            title: title,
            artist: artist,
            album: album,
            albumArtist: albumArtist,
            durationMs: durationMs,
            artworkUrl: artworkUrl,
            streamUrl: streamUrl,
            year: year,
            trackNumber: trackNumber,
            genre: genre
        )
    }
}

/**
 * The listening log and the songs the user owns elsewhere (on the phone and
 * on Navidrome), for recommendations. The song lists can be large, so they
 * are read and written off the main thread.
 */
actor ListeningStore {
    private static let playsFile = "plays.json"
    private var plays: [PlayRecord]?
    private var owned: [Owner: [OwnedSong]] = [:]
    private var saveTask: Task<Void, Never>?

    private func loadedPlays() -> [PlayRecord] {
        if let plays { return plays }
        let loaded = Storage.load([PlayRecord].self, Self.playsFile) ?? []
        plays = loaded
        return loaded
    }

    func record(_ play: PlayRecord) {
        var list = loadedPlays()
        list.append(play)
        // A year of listens is plenty for taste; older ones go.
        let cutoff = nowMs() - 400 * 86_400_000
        if let first = list.first, first.startedAt < cutoff { list.removeAll { $0.startedAt < cutoff } }
        plays = list
        scheduleSave()
    }

    func plays(since: Int64) -> [PlayRecord] { loadedPlays().filter { $0.startedAt >= since } }

    func clearPlays() {
        plays = []
        Storage.save([PlayRecord](), Self.playsFile)
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            self.saveNow()
        }
    }

    func saveNow() {
        saveTask?.cancel()
        if let plays { Storage.save(plays, Self.playsFile) }
    }

    // ------------------------------------------------------------ owned --

    func songs(_ owner: Owner) -> [OwnedSong] {
        if let list = owned[owner] { return list }
        let loaded = Storage.load([OwnedSong].self, owner.file) ?? []
        owned[owner] = loaded
        return loaded
    }

    func allSongs() -> [OwnedSong] { Owner.allCases.flatMap { songs($0) } }

    func song(_ id: String) -> OwnedSong? {
        let owner: Owner = id.hasPrefix("navidrome:") ? .navidrome : .phone
        return songs(owner).first { $0.id == id }
    }

    /** Swap in a fresh list of the songs on the phone or on Navidrome. */
    func replace(_ owner: Owner, _ list: [OwnedSong]) {
        owned[owner] = list
        Storage.save(list, owner.file)
    }
}
