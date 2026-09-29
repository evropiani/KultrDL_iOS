import Foundation
import KultrDLCore
import UniformTypeIdentifiers
import SwiftUI

/**
 * The library and settings as one JSON file: favourites, saved tracks,
 * listening history, playlists and saved servers (without their secrets).
 * The same format as KultrDL for Android, so a backup moves between them.
 * Downloaded files are not part of it.
 */
struct BackupFile: Codable {
    var app = "KultrDL"
    var version = 1
    var exportedAt: Int64 = nowMs()
    var settings: Settings?
    var tracks: [BackupTrack] = []
    var playlists: [BackupPlaylist] = []
    /** Saved servers, without passwords or keys. */
    var servers: [SavedServer] = []

    init() {}

    enum CodingKeys: String, CodingKey { case app, version, exportedAt, settings, tracks, playlists, servers }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        app = c.value(.app, "KultrDL")
        version = c.value(.version, 1)
        exportedAt = c.value(.exportedAt, nowMs())
        settings = c.optional(.settings)
        tracks = c.value(.tracks, [])
        playlists = c.value(.playlists, [])
        servers = c.value(.servers, [])
    }

    func encode() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }

    static func decode(_ data: Data) throws -> BackupFile {
        do {
            let file = try JSONDecoder().decode(BackupFile.self, from: data)
            guard file.app.lowercased().contains("kultrdl") else { throw KultrError("That isn't a KultrDL backup.") }
            return file
        } catch let error as KultrError {
            throw error
        } catch {
            throw KultrError("That file isn't a KultrDL backup.")
        }
    }
}

struct BackupTrack: Codable {
    var track: Track
    var favorite = false
    var favoritedAt: Int64?
    var saved = false
    var savedAt: Int64?
    var playCount = 0
    var lastPlayedAt: Int64?
    var matchedUrl: String?

    init(track: Track, favorite: Bool, favoritedAt: Int64?, saved: Bool, savedAt: Int64?, playCount: Int, lastPlayedAt: Int64?, matchedUrl: String?) {
        self.track = track
        self.favorite = favorite
        self.favoritedAt = favoritedAt
        self.saved = saved
        self.savedAt = savedAt
        self.playCount = playCount
        self.lastPlayedAt = lastPlayedAt
        self.matchedUrl = matchedUrl
    }

    enum CodingKeys: String, CodingKey { case track, favorite, favoritedAt, saved, savedAt, playCount, lastPlayedAt, matchedUrl }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        track = try c.decode(Track.self, forKey: .track)
        favorite = c.value(.favorite, false)
        favoritedAt = c.optional(.favoritedAt)
        saved = c.value(.saved, false)
        savedAt = c.optional(.savedAt)
        playCount = c.value(.playCount, 0)
        lastPlayedAt = c.optional(.lastPlayedAt)
        matchedUrl = c.optional(.matchedUrl)
    }
}

struct BackupPlaylist: Codable {
    var name: String
    var trackIds: [String]
    var sourceUrl: String?
    var artworkUrl: String?

    init(name: String, trackIds: [String], sourceUrl: String?, artworkUrl: String?) {
        self.name = name
        self.trackIds = trackIds
        self.sourceUrl = sourceUrl
        self.artworkUrl = artworkUrl
    }

    enum CodingKeys: String, CodingKey { case name, trackIds, sourceUrl, artworkUrl }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = c.value(.name, "Playlist")
        trackIds = c.value(.trackIds, [])
        sourceUrl = c.optional(.sourceUrl)
        artworkUrl = c.optional(.artworkUrl)
    }
}

/** A backup as a document for the share sheet and the Files export. */
struct BackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    var data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
