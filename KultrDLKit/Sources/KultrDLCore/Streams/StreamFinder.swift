import Foundation

/** Audio KultrDL can open: a file (possibly fetched in ranges) or an HLS stream. */
public struct MediaStream: Sendable {
    public enum Kind: String, Sendable { case file, hls }

    public let url: String
    public let headers: [String: String]
    public let kind: Kind
    /** "m4a", "webm", "mp3", "flac", "ogg", "opus", "wav", "aac"…; for HLS, what the segments hold when known. */
    public let container: String
    /** "aac", "opus", "mp3"… when known. */
    public let codec: String?
    /** Bits per second, when known. */
    public let bitrate: Int?
    public let contentLength: Int64?
    public let expiresAt: Date
    /** Don't ask for it before then (YouTube's pre-roll wait). */
    public let availableAt: Date?
    /** The YouTube client that gave it. */
    public let client: String?
    /** Only a short preview (SoundCloud Go+ tracks). */
    public let isPreview: Bool

    public init(
        url: String, headers: [String: String] = [:], kind: Kind, container: String, codec: String? = nil,
        bitrate: Int? = nil, contentLength: Int64? = nil, expiresAt: Date = Date().addingTimeInterval(1800),
        availableAt: Date? = nil, client: String? = nil, isPreview: Bool = false
    ) {
        self.url = url
        self.headers = headers
        self.kind = kind
        self.container = container
        self.codec = codec
        self.bitrate = bitrate
        self.contentLength = contentLength
        self.expiresAt = expiresAt
        self.availableAt = availableAt
        self.client = client
        self.isPreview = isPreview
    }

    public var label: String {
        let kbps = bitrate.map { " \($0 / 1000) kbps" } ?? ""
        return "\((codec ?? container).uppercased())\(kbps)"
    }
}

public enum StreamPurpose: Sendable {
    /** For AVPlayer: AAC, MP3 or HLS (no WebM). [saver] picks the smallest stream. */
    case playback(saver: Bool)
    /** For converting: the best audio, Opus or AAC as asked when both exist. */
    case download(prefer: PreferredCodec)
}

public enum PreferredCodec: Sendable { case best, opus, aac }

/**
 * Turns a track's page (its streamUrl, or the recording it was matched to)
 * into audio: YouTube through its player API, SoundCloud and Bandcamp
 * through their own pages, and links straight to a file as they are.
 */
public final class StreamFinder: @unchecked Sendable {
    public let catalog: Catalog
    public let youtube: YouTubePlayer

    public init(catalog: Catalog, youtube: YouTubePlayer) {
        self.catalog = catalog
        self.youtube = youtube
    }

    public static func isYouTube(_ url: String) -> Bool {
        guard let host = Links.host(url) else { return false }
        return host.hasSuffix("youtube.com") || host == "youtu.be" || host.hasSuffix("youtube-nocookie.com")
    }

    public static func youtubeId(_ url: String) -> String? {
        let t = Links.classify(url)
        guard t.source == .youtube || t.source == .youtubeMusic, t.kind == .track else { return nil }
        return t.id
    }

    /**
     * The stream for [pageUrl]. For YouTube, [client] starts the list of
     * clients to try (the one that worked last), or with [onlyClient] only
     * that one is asked.
     */
    public func find(_ pageUrl: String, purpose: StreamPurpose, client: String? = nil, onlyClient: String? = nil) async throws -> MediaStream {
        if let id = Self.youtubeId(pageUrl) {
            return try await youtubeStream(id, purpose: purpose, client: client, onlyClient: onlyClient)
        }
        let target = Links.classify(pageUrl)
        switch target.source {
        case .soundcloud:
            let s = try await catalog.soundCloud.stream(pageUrl)
            if s.preview, case .download = purpose {
                throw KultrError("SoundCloud only offers a 30-second preview of this track.")
            }
            return MediaStream(
                url: s.url,
                headers: ["User-Agent": Http.browserUserAgent],
                kind: s.hls ? .hls : .file,
                container: s.ext,
                codec: s.ext == "m4a" ? "aac" : s.ext,
                expiresAt: Date().addingTimeInterval(600),
                isPreview: s.preview
            )
        case .bandcamp:
            let url = try await catalog.bandcamp.stream(pageUrl)
            return MediaStream(url: url, headers: ["User-Agent": Http.browserUserAgent], kind: .file, container: "mp3", codec: "mp3", bitrate: 128_000, expiresAt: Date().addingTimeInterval(1800))
        default:
            var url = pageUrl
            if !Links.isAudioFile(url), case .single(let track) = try await catalog.extract(url), let stream = track.streamUrl {
                url = stream
            }
            let ext = ((URLComponents(string: url)?.path ?? url) as NSString).pathExtension.lowercased()
            if ext == "m3u8" {
                return MediaStream(url: url, headers: ["User-Agent": Http.browserUserAgent], kind: .hls, container: "ts", expiresAt: .distantFuture)
            }
            return MediaStream(url: url, headers: ["User-Agent": Http.browserUserAgent], kind: .file, container: ext.nonEmpty ?? "mp3", expiresAt: .distantFuture)
        }
    }

    private func youtubeStream(_ id: String, purpose: StreamPurpose, client: String?, onlyClient: String?) async throws -> MediaStream {
        let streams = try await youtube.streams(id, preferred: client, only: onlyClient)
        func file(_ f: YouTubeFormat) -> MediaStream {
            MediaStream(
                url: f.url,
                headers: streams.headers,
                kind: .file,
                container: f.container,
                codec: f.isOpus ? "opus" : f.isAAC ? "aac" : nil,
                bitrate: f.bitrate,
                contentLength: f.contentLength,
                expiresAt: streams.expiresAt,
                availableAt: streams.availableAt,
                client: streams.client.key
            )
        }
        func hls(_ url: String) -> MediaStream {
            MediaStream(
                url: url,
                headers: streams.headers,
                kind: .hls,
                container: "ts",
                codec: "aac",
                expiresAt: streams.expiresAt,
                availableAt: streams.availableAt,
                client: streams.client.key
            )
        }
        switch purpose {
        case .playback(let saver):
            if let f = saver ? (streams.smallestAAC ?? streams.bestAAC) : streams.bestAAC { return file(f) }
            if let url = streams.hlsManifestUrl { return hls(url) }
            throw YouTubeRefusal(client: streams.client.key, status: "NO_AAC", reason: "YouTube gave the \(streams.client.label) no stream this phone can play.", isFinal: false)
        case .download(let prefer):
            let pick: YouTubeFormat?
            switch prefer {
            case .aac: pick = streams.bestAAC ?? streams.bestOpus
            case .opus: pick = streams.bestOpus ?? streams.bestAAC
            case .best: pick = streams.bestOpus ?? streams.bestAAC
            }
            if let pick { return file(pick) }
            if let url = streams.hlsManifestUrl { return hls(url) }
            throw YouTubeRefusal(client: streams.client.key, status: "NO_AUDIO", reason: "YouTube gave no audio for this video.", isFinal: false)
        }
    }
}
