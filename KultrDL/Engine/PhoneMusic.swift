import Foundation
import MediaPlayer
import UIKit

/**
 * The music already on the phone, read from the Music app's library (with
 * the user's permission): what they own, and how often they play it, tells
 * the recommendations who they like, and the songs that are files on the
 * phone play in mixes without a connection.
 */
enum PhoneMusic {
    static var authorized: Bool { MPMediaLibrary.authorizationStatus() == .authorized }

    /** Asks once; afterwards only the Settings app can change the answer. */
    static func requestAccess() async -> Bool {
        if authorized { return true }
        return await withCheckedContinuation { continuation in
            MPMediaLibrary.requestAuthorization { status in continuation.resume(returning: status == .authorized) }
        }
    }

    static var denied: Bool {
        let status = MPMediaLibrary.authorizationStatus()
        return status == .denied || status == .restricted
    }

    /** Every song in the library, at least 30 seconds long. Slow for large libraries: call it off the main thread. */
    static func scan() -> [OwnedSong] {
        guard authorized, let items = MPMediaQuery.songs().items else { return [] }
        let artFolder = Storage.caches.appendingPathComponent("phone-art", isDirectory: true)
        try? FileManager.default.createDirectory(at: artFolder, withIntermediateDirectories: true)
        var artwork: [UInt64: String?] = [:]
        var out: [OwnedSong] = []
        out.reserveCapacity(items.count)
        for item in items {
            guard item.mediaType.contains(.music), item.playbackDuration >= 30 else { continue }
            guard let title = clean(item.title) else { continue }
            let artist = clean(item.artist) ?? clean(item.albumArtist) ?? "Unknown artist"
            let albumId = item.albumPersistentID
            if artwork[albumId] == nil {
                artwork[albumId] = .some(saveArtwork(item, albumId, artFolder))
            }
            out.append(OwnedSong(
                id: "phone:\(item.persistentID)",
                owner: .phone,
                title: title,
                artist: artist,
                album: clean(item.albumTitle),
                albumArtist: clean(item.albumArtist),
                genre: clean(item.genre),
                year: item.releaseDate.map { Calendar.current.component(.year, from: $0) },
                trackNumber: item.albumTrackNumber > 0 ? item.albumTrackNumber : nil,
                durationMs: Int64(item.playbackDuration * 1000),
                playCount: item.playCount,
                lastPlayedAt: item.lastPlayedDate.map { Int64($0.timeIntervalSince1970 * 1000) },
                starred: item.rating >= 4,
                rating: item.rating,
                artworkUrl: artwork[albumId] ?? nil,
                // Songs streamed from Apple Music or kept in iCloud have no file here; they are matched like catalogue songs.
                streamUrl: item.hasProtectedAsset ? nil : item.assetURL?.absoluteString,
                artistId: nil,
                addedAt: Int64(item.dateAdded.timeIntervalSince1970 * 1000)
            ))
        }
        return out
    }

    private static func clean(_ text: String?) -> String? {
        guard let t = text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }

    /** The album's cover as a small file, so it shows like any other artwork. */
    private static func saveArtwork(_ item: MPMediaItem, _ albumId: UInt64, _ folder: URL) -> String? {
        let file = folder.appendingPathComponent("\(albumId).jpg")
        if FileManager.default.fileExists(atPath: file.path) { return file.absoluteString }
        guard let image = item.artwork?.image(at: CGSize(width: 400, height: 400)),
              let data = image.jpegData(compressionQuality: 0.85),
              (try? data.write(to: file, options: .atomic)) != nil
        else { return nil }
        return file.absoluteString
    }
}
