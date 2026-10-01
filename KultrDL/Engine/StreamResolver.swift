import Foundation
import KultrDLCore

/**
 * Turns a track into something the player can open: its downloaded file
 * when AVPlayer can play it, otherwise the audio stream of its recording —
 * found by matching for catalogue tracks (Spotify, Apple Music…). Streams
 * are cached until shortly before their links expire. When YouTube refuses
 * a stream (403), the next client is tried, and the one that works is kept.
 */
@MainActor
final class StreamResolver {
    enum Resolved {
        case local(URL)
        case remote(MediaStream)
        /** Played as it is: a song in the phone's Music library, or one streamed from the user's Navidrome. */
        case direct(URL)
    }

    private unowned let graph: AppGraph
    private var cache: [String: MediaStream] = [:]
    private var refused: [String: Set<String>] = [:]
    private var inFlight: [String: Task<Resolved, Error>] = [:]

    /** What AVPlayer plays from a file (not Ogg, Opus or WebM). */
    static let playable: Set<String> = ["mp3", "m4a", "aac", "flac", "wav", "aif", "aiff", "caf", "mp4", "alac"]

    init(graph: AppGraph) {
        self.graph = graph
    }

    func local(_ trackId: String) -> URL? {
        guard let url = graph.library.stored(trackId)?.localURL,
              Self.playable.contains(url.pathExtension.lowercased()),
              FileManager.default.fileExists(atPath: url.path)
        else { return nil }
        return url
    }

    func resolve(_ track: Track) async throws -> Resolved {
        if let url = local(track.id) { return .local(url) }
        if let mine = try own(track) { return mine }
        if let hit = cache[track.id], hit.expiresAt > Date().addingTimeInterval(90) { return .remote(hit) }
        if let running = inFlight[track.id] { return try await running.value }
        let task = Task { () throws -> Resolved in try await self.fetch(track) }
        inFlight[track.id] = task
        defer { inFlight[track.id] = nil }
        return try await task.value
    }

    /** Start resolving in the background, so the next track starts at once. */
    func prefetch(_ track: Track) {
        guard local(track.id) == nil, track.source != .phone, track.source != .navidrome, cache[track.id] == nil, inFlight[track.id] == nil else { return }
        Task { _ = try? await resolve(track) }
    }

    func invalidate(_ trackId: String) {
        cache[trackId] = nil
    }

    /**
     * The user's own songs play from where they are: a file in the phone's
     * Music library, or a stream from their Navidrome with the login added.
     * Music-library songs without a file (streamed from Apple Music, or in
     * iCloud) are matched like catalogue songs instead.
     */
    private func own(_ track: Track) throws -> Resolved? {
        switch track.source {
        case .phone:
            guard let url = track.streamUrl.flatMap(URL.init(string:)) else { return nil }
            return .direct(url)
        case .navidrome:
            guard let stream = track.streamUrl else { throw KultrError("Unknown Navidrome song.") }
            guard let client = graph.navidrome.client(graph.http) else {
                throw KultrError("Navidrome isn't connected any more (Settings → Recommendations → Navidrome).")
            }
            guard let url = URL(string: client.authenticate(stream)) else { throw KultrError("The Navidrome address is broken.") }
            return .direct(url)
        default:
            return nil
        }
    }

    private var preferredClient: String? {
        let key = graph.settings.settings.youtubeClient
        return key.isEmpty ? nil : key
    }

    private func fetch(_ track: Track) async throws -> Resolved {
        let source = try await sourceUrl(track)
        let saver = graph.settings.settings.streamQuality == .saver
        let skip = refused[track.id] ?? []
        var only: String?
        if !skip.isEmpty, StreamFinder.isYouTube(source) {
            guard let next = graph.engine.config.order(startingWith: preferredClient).first(where: { !skip.contains($0.key) }) else {
                throw KultrError("YouTube refused every way of playing “\(track.title)” on this network. Try Settings → Engine → Test YouTube.")
            }
            only = next.key
        }
        let stream = try await graph.finder.find(source, purpose: .playback(saver: saver), client: preferredClient, onlyClient: only)
        cache[track.id] = stream
        return .remote(stream)
    }

    /**
     * YouTube refused [trackId]'s stream: the next attempt asks another
     * client. False when it wasn't a YouTube stream or every client failed.
     */
    func refuse(_ trackId: String) -> Bool {
        guard let client = cache[trackId]?.client else { return false }
        var set = refused[trackId] ?? []
        set.insert(client)
        refused[trackId] = set
        cache[trackId] = nil
        return graph.engine.config.clients.contains { !set.contains($0.key) }
    }

    /** [trackId] plays: when it took a different client, start with that one from now on. */
    func playing(_ trackId: String) {
        defer { refused[trackId] = nil }
        guard refused[trackId]?.isEmpty == false, let client = cache[trackId]?.client else { return }
        if client != graph.settings.settings.youtubeClient {
            graph.settings.update { $0.youtubeClient = client }
        }
    }

    /**
     * The page to read for [track]: its own stream, or for a catalogue track
     * the recording it was matched to (found once, then remembered).
     */
    func sourceUrl(_ track: Track) async throws -> String {
        switch track.source {
        case .navidrome:
            // The original file, with the login.
            guard let client = graph.navidrome.client(graph.http) else {
                throw KultrError("Navidrome isn't connected any more (Settings → Recommendations → Navidrome).")
            }
            guard let stream = track.streamUrl else { throw KultrError("Unknown Navidrome song.") }
            return client.authenticate(stream.replacingOccurrences(of: "/rest/stream?", with: "/rest/download?"))
        case .phone where track.streamUrl != nil:
            throw KultrError("“\(track.title)” is already on this phone.")
        case .phone:
            break
        default:
            if let url = track.streamUrl { return url }
        }
        if let url = graph.library.stored(track.id)?.matchedUrl { return url }
        if let url = track.matchUrl {
            graph.library.remember([track])
            graph.library.setMatchedUrl(track.id, url)
            return url
        }
        guard let url = try await graph.catalog.match(track)?.streamUrl else {
            throw KultrError("Couldn't find “\(track.title)” by \(track.artist) on YouTube Music.")
        }
        graph.library.remember([track])
        graph.library.setMatchedUrl(track.id, url)
        return url
    }

    /** Forget the recording a catalogue track was matched to, to search again. */
    func rematch(_ trackId: String) {
        graph.library.setMatchedUrl(trackId, nil)
        cache[trackId] = nil
        refused[trackId] = nil
    }
}
