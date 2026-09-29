import Foundation

/** One audio format YouTube offers for a video. */
public struct YouTubeFormat: Sendable, Hashable {
    public let itag: Int
    public let url: String
    public let mimeType: String
    public let codecs: String
    public let bitrate: Int
    public let contentLength: Int64?
    public let sampleRate: Int?
    public let channels: Int?
    public let isDrc: Bool
    /** False for dubbed tracks that aren't the original or default language. */
    public let isMainTrack: Bool

    /** "m4a" or "webm". */
    public var container: String { mimeType.contains("webm") ? "webm" : "m4a" }
    public var isOpus: Bool { codecs.contains("opus") }
    public var isAAC: Bool { codecs.hasPrefix("mp4a") }
}

/** What YouTube answered for a video with one client. */
public struct YouTubeStreams: Sendable {
    public let videoId: String
    public let client: InnerTubeClient
    /** Audio-only formats, best first. */
    public let formats: [YouTubeFormat]
    /** An HLS master playlist (the iOS client gives one); AVPlayer plays it directly. */
    public let hlsManifestUrl: String?
    /** Headers to send with requests for the streams. */
    public let headers: [String: String]
    /** When the links stop working. */
    public let expiresAt: Date
    /** YouTube sometimes holds the stream back for as long as an ad would have played. */
    public let availableAt: Date
    public let details: Track?

    public var bestAAC: YouTubeFormat? { formats.first { $0.isAAC && $0.isMainTrack && !$0.isDrc } ?? formats.first { $0.isAAC } }
    public var bestOpus: YouTubeFormat? { formats.first { $0.isOpus && $0.isMainTrack && !$0.isDrc } ?? formats.first { $0.isOpus } }
    /** The lowest-bitrate AAC stream, for data saving. */
    public var smallestAAC: YouTubeFormat? { formats.filter { $0.isAAC && $0.isMainTrack }.min { $0.bitrate < $1.bitrate } }
}

/** Why a client couldn't give streams: the video itself, or this way of asking. */
public struct YouTubeRefusal: LocalizedError, Sendable {
    public let client: String
    public let status: String
    public let reason: String
    /** Nothing another client can do: the video is private, removed or blocked. */
    public let isFinal: Bool

    public var errorDescription: String? { reason.isEmpty ? "YouTube refused (\(status))." : reason }
}

/**
 * YouTube's player API, asked the way yt-dlp asks it: the watch page for
 * the session's visitor data and the player's version, then a player
 * request per client until one gives audio links, with signatures and "n"
 * values solved through the player's own JavaScript where the client needs
 * it.
 */
public final class YouTubePlayer: @unchecked Sendable {
    private let http: Http
    public let solver: JSChallengeSolver
    private let config: @Sendable () -> EngineConfig
    private let lock = NSLock()
    private var session: (visitorData: String?, playerUrl: String?, fetched: Date)?

    public init(http: Http, solver: JSChallengeSolver, config: @escaping @Sendable () -> EngineConfig) {
        self.http = http
        self.solver = solver
        self.config = config
    }

    public static let browserHeaders = [
        "User-Agent": Http.browserUserAgent,
        "Accept-Language": "en-US,en;q=0.9",
        "Cookie": "SOCS=CAI; PREF=hl=en&tz=UTC",
    ]

    // -------------------------------------------------------- session --

    private static let ytcfgPattern = Rx.s(#"ytcfg\.set\s*\(\s*(\{.+?\})\s*\)\s*;"#)
    private static let iframePlayer = Rx(#"player\\?/([0-9a-fA-F]{8})\\?/"#)

    /** Visitor data and the player's address, from a watch page (kept for half an hour). */
    private func sessionInfo(_ videoId: String, fresh: Bool = false) async -> (visitorData: String?, playerUrl: String?) {
        lock.lock()
        let known = session
        lock.unlock()
        if !fresh, let known, Date().timeIntervalSince(known.fetched) < 1800, known.visitorData != nil {
            return (known.visitorData, known.playerUrl)
        }
        var visitor: String?
        var player: String?
        if let page = try? await http.get(
            "https://www.youtube.com/watch?v=\(videoId)&bpctr=9999999999&has_verified=1",
            headers: Self.browserHeaders
        ) {
            for groups in Self.ytcfgPattern.findAll(page) {
                guard let cfg = JSON.tryParse(groups[1]) else { continue }
                visitor = visitor ?? cfg["VISITOR_DATA"].string ?? cfg.path("INNERTUBE_CONTEXT", "client", "visitorData").string
                player = player ?? cfg["PLAYER_JS_URL"].string
                if player == nil, let configs = cfg["WEB_PLAYER_CONTEXT_CONFIGS"]?.object {
                    player = configs.entries.compactMap { $0.value["jsUrl"].string }.first
                }
            }
        }
        if visitor == nil {
            // Any InnerTube answer carries visitor data.
            let body: JSON = ["context": ["client": ["clientName": "WEB", "clientVersion": .str(config().webClientVersion), "hl": "en", "gl": "US"]]]
            visitor = (try? await http.postJSON(
                "https://www.youtube.com/youtubei/v1/visitor_id?prettyPrint=false",
                body: body,
                headers: ["X-YouTube-Client-Name": "1", "X-YouTube-Client-Version": config().webClientVersion, "Origin": "https://www.youtube.com"]
            ))?["responseContext"]?["visitorData"].string
        }
        if player == nil, let iframe = try? await http.get("https://www.youtube.com/iframe_api"), let id = Self.iframePlayer.group(iframe) {
            player = "/s/player/\(id)/player_ias.vflset/en_US/base.js"
        }
        let url = player.map { JSChallengeSolver.canonicalPlayerUrl($0) }
        lock.lock()
        session = (visitor, url, Date())
        lock.unlock()
        return (visitor, url)
    }

    /** Forget the session, so the next request starts a new one. */
    public func resetSession() {
        lock.lock()
        session = nil
        lock.unlock()
    }

    // --------------------------------------------------------- player --

    /**
     * The streams of [videoId], asking the clients in turn (starting with
     * [preferred]) until one answers with audio. Throws the most telling
     * refusal when none does.
     */
    public func streams(_ videoId: String, preferred: String? = nil, only: String? = nil) async throws -> YouTubeStreams {
        let clients = only.flatMap { key in config().client(key).map { [$0] } } ?? config().order(startingWith: preferred)
        var refusals: [Error] = []
        for client in clients {
            do {
                return try await streams(videoId, client: client)
            } catch let refusal as YouTubeRefusal where refusal.isFinal {
                throw refusal
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                refusals.append(error)
            }
        }
        if let refusal = refusals.compactMap({ $0 as? YouTubeRefusal }).first { throw refusal }
        throw refusals.first ?? KultrError("YouTube gave no audio for this video.")
    }

    public func streams(_ videoId: String, client: InnerTubeClient) async throws -> YouTubeStreams {
        let (visitor, playerUrl) = await sessionInfo(videoId)
        var sts: Int?
        if client.requiresJS {
            guard let playerUrl else { throw KultrError("Couldn't find YouTube's player for the \(client.label).") }
            sts = try? await solver.signatureTimestamp(playerUrl)
        }
        let response = try await playerRequest(videoId, client: client, visitorData: visitor, sts: sts)
        let status = response["playabilityStatus"]?["status"].string ?? "UNKNOWN"
        let reason = playabilityReason(response)
        if response.path("videoDetails", "videoId").string.map({ $0 != videoId }) == true {
            throw YouTubeRefusal(client: client.key, status: "WRONG_VIDEO", reason: "YouTube answered with another video.", isFinal: false)
        }
        guard status == "OK" else {
            // Private, removed or blocked is final; "sign in" and the like depend on how we asked.
            let lowered = reason.lowercased()
            let gone = ["private video", "been removed", "terminated", "copyright", "no longer available"].contains { lowered.contains($0) }
            throw YouTubeRefusal(client: client.key, status: status, reason: reason, isFinal: gone)
        }
        guard let streaming = response["streamingData"] else {
            throw YouTubeRefusal(client: client.key, status: "NO_STREAMS", reason: "YouTube gave the \(client.label) no streams.", isFinal: false)
        }

        // Collect the challenges first, to solve them in one go.
        struct Raw {
            let fmt: JSON
            var url: String
            let s: String?
            let sp: String
        }
        var raws: [Raw] = []
        for fmt in streaming["adaptiveFormats"].array + streaming["formats"].array {
            guard let mime = fmt["mimeType"].string, mime.hasPrefix("audio/") else { continue }
            if fmt["drmFamilies"] != nil || fmt["targetDurationSec"] != nil { continue }
            if fmt["type"].string == "FORMAT_STREAM_TYPE_OTF" { continue }
            if let url = fmt["url"].string {
                raws.append(Raw(fmt: fmt, url: url, s: nil, sp: "signature"))
            } else if let cipher = fmt["signatureCipher"].string ?? fmt["cipher"].string {
                let parts = Self.query(cipher)
                guard let url = parts["url"], let s = parts["s"] else { continue }
                raws.append(Raw(fmt: fmt, url: url, s: s, sp: parts["sp"] ?? "signature"))
            }
        }
        if raws.contains(where: { $0.s != nil }) || raws.contains(where: { Self.query($0.url)["n"] != nil && client.requiresJS }) {
            guard let playerUrl else { throw KultrError("Couldn't find YouTube's player to unlock the \(client.label)'s links.") }
            let sigs = try await solver.solveSignatures(raws.compactMap(\.s), playerUrl: playerUrl)
            let ns = try await solver.solveN(raws.compactMap { Self.query($0.url)["n"] }, playerUrl: playerUrl)
            raws = raws.compactMap { raw in
                var r = raw
                if let s = raw.s {
                    guard let solved = sigs[s] else { return nil }
                    r.url = Self.setQuery(r.url, raw.sp, solved)
                }
                if let n = Self.query(r.url)["n"] {
                    guard let solved = ns[n] else { return nil }
                    r.url = Self.setQuery(r.url, "n", solved)
                }
                return r
            }
        }

        let formats = raws.map { raw -> YouTubeFormat in
            let f = raw.fmt
            let mime = f["mimeType"].string ?? ""
            let track = f["audioTrack"]
            let name = track?["displayName"].string?.lowercased() ?? ""
            let main = track == nil || track?["audioIsDefault"].bool == true || name.contains("original")
            return YouTubeFormat(
                itag: f["itag"].int ?? 0,
                url: raw.url,
                mimeType: mime.before(";"),
                codecs: Rx(#"codecs="([^"]+)""#).group(mime) ?? "",
                bitrate: f["averageBitrate"].int ?? f["bitrate"].int ?? 0,
                contentLength: f["contentLength"].int64,
                sampleRate: f["audioSampleRate"].int,
                channels: f["audioChannels"].int,
                isDrc: f["isDrc"].bool == true,
                isMainTrack: main && !name.contains("descriptive")
            )
        }.sorted { a, b in
            if a.isMainTrack != b.isMainTrack { return a.isMainTrack }
            if a.isDrc != b.isDrc { return !a.isDrc }
            return a.bitrate > b.bitrate
        }
        let hls = streaming["hlsManifestUrl"].string
        guard !formats.isEmpty || hls != nil else {
            throw YouTubeRefusal(client: client.key, status: "NO_AUDIO", reason: "YouTube gave the \(client.label) no audio links.", isFinal: false)
        }
        let links = formats.map(\.url) + [hls].compactMap { $0 }
        let expires = links.compactMap(Self.expiry).min() ?? Date().addingTimeInterval(3 * 3600)
        return YouTubeStreams(
            videoId: videoId,
            client: client,
            formats: formats,
            hlsManifestUrl: hls,
            headers: ["User-Agent": client.userAgent ?? Http.browserUserAgent, "Origin": "https://www.youtube.com", "Referer": "https://www.youtube.com/"],
            expiresAt: expires,
            availableAt: Self.availableAt(response),
            details: YouTube.parseVideoDetails(response, source: .youtube)
        )
    }

    private func playerRequest(_ videoId: String, client: InnerTubeClient, visitorData: String?, sts: Int?) async throws -> JSON {
        var clientContext = JSONObject()
        clientContext["clientName"] = .str(client.clientName)
        clientContext["clientVersion"] = .str(client.clientVersion)
        if let v = client.deviceMake { clientContext["deviceMake"] = .str(v) }
        if let v = client.deviceModel { clientContext["deviceModel"] = .str(v) }
        if let v = client.androidSdkVersion { clientContext["androidSdkVersion"] = .of(v) }
        if let v = client.userAgent { clientContext["userAgent"] = .str(v) }
        if let v = client.osName { clientContext["osName"] = .str(v) }
        if let v = client.osVersion { clientContext["osVersion"] = .str(v) }
        clientContext["hl"] = "en"
        clientContext["gl"] = "US"
        clientContext["timeZone"] = "UTC"
        clientContext["utcOffsetMinutes"] = 0
        if let visitorData { clientContext["visitorData"] = .str(visitorData) }
        var context = JSONObject()
        context["client"] = .obj(clientContext)
        if client.embedded { context["thirdParty"] = ["embedUrl": "https://www.reddit.com/"] }

        var playback = JSONObject()
        playback["html5Preference"] = "HTML5_PREF_WANTS"
        if let sts { playback["signatureTimestamp"] = .of(sts) }
        var body = JSONObject()
        body["context"] = .obj(context)
        body["videoId"] = .str(videoId)
        body["playbackContext"] = ["contentPlaybackContext": .obj(playback)]
        body["contentCheckOk"] = true
        body["racyCheckOk"] = true

        var headers = [
            "X-YouTube-Client-Name": String(client.clientNameId),
            "X-YouTube-Client-Version": client.clientVersion,
            "Origin": "https://\(client.host)",
            "User-Agent": client.userAgent ?? Http.browserUserAgent,
            "Cookie": "SOCS=CAI; PREF=hl=en&tz=UTC",
        ]
        if let visitorData { headers["X-Goog-Visitor-Id"] = visitorData }
        return try await http.postJSON("https://\(client.host)/youtubei/v1/player?prettyPrint=false", body: .obj(body), headers: headers)
    }

    private func playabilityReason(_ response: JSON) -> String {
        let p = response["playabilityStatus"]
        if let reason = p?["reason"].string { return reason }
        if let messages = p?["messages"]?.array.compactMap({ $0.string }), !messages.isEmpty { return messages.joined(separator: " ") }
        if let subreason = p?["errorScreen"]?["playerErrorMessageRenderer"]?["subreason"] {
            return YouTube.text(subreason)
        }
        return ""
    }

    // ------------------------------------------------------------ links --

    static func query(_ urlOrQuery: String) -> [String: String] {
        let q = urlOrQuery.contains("?") ? urlOrQuery.after("?") : urlOrQuery
        var out: [String: String] = [:]
        for pair in q.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
            guard let key = kv.first else { continue }
            let value = kv.count > 1 ? kv[1] : ""
            out[key.removingPercentEncoding ?? key] = value.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? value
        }
        return out
    }

    static func setQuery(_ url: String, _ name: String, _ value: String) -> String {
        guard var comps = URLComponents(string: url) else { return url }
        var items = comps.percentEncodedQueryItems ?? []
        items.removeAll { $0.name == name }
        items.append(URLQueryItem(name: name, value: value.urlQueryEncoded))
        comps.percentEncodedQueryItems = items
        return comps.string ?? url
    }

    private static let expirePattern = Rx(#"[?&/]expire[=/](\d+)"#)

    /** Stream links carry their expiry. */
    public static func expiry(_ url: String) -> Date? {
        expirePattern.group(url).flatMap { Double($0) }.map { Date(timeIntervalSince1970: $0) }
    }

    /** How long a pre-roll ad would have played, as yt-dlp works it out. */
    static func availableAt(_ response: JSON) -> Date {
        var wait = 0.0
        for placement in response["adPlacements"].array {
            let renderer = placement["adPlacementRenderer"]
            guard renderer?.path("config", "adPlacementConfig", "kind").string == "AD_PLACEMENT_KIND_START" else { continue }
            for ad in renderer?.objectsUnder("instreamVideoAdRenderer") ?? [] { wait += adSeconds(ad) }
        }
        for slot in response["adSlots"].array {
            let renderer = slot["adSlotRenderer"]
            guard renderer?.path("adSlotMetadata", "triggerEvent").string == "SLOT_TRIGGER_EVENT_BEFORE_CONTENT" else { continue }
            for ad in renderer?.objectsUnder("instreamVideoAdRenderer") ?? [] { wait += adSeconds(ad) }
        }
        return Date().addingTimeInterval(min(wait, 120))
    }

    private static func adSeconds(_ ad: JSON) -> Double {
        if let skip = ad["skipOffsetMilliseconds"].double { return skip / 1000 }
        if let vars = ad["playerVars"].string, let length = query(vars)["length_seconds"].flatMap(Double.init) { return length }
        return 0
    }
}
