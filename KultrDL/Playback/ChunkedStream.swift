import AVFoundation
import Foundation
import KultrDLCore
import UniformTypeIdentifiers

/**
 * Feeds a remote audio file to AVPlayer through a resource loader, fetching
 * it in ranges of at most a megabyte with the headers its site wants.
 * YouTube cuts off long single requests from some clients and wants its own
 * User-Agent, which AVPlayer on its own can't do; a refusal (403) is
 * reported so the player can try another way of asking.
 */
final class ChunkedStream: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    static let scheme = "kultrdl-stream"

    let asset: AVURLAsset
    private let stream: MediaStream
    private let remote: URL
    private let session: URLSession
    private let queue = DispatchQueue(label: "kultrdl.stream")
    private let onRefused: @Sendable (Int) -> Void
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    private var totalLength: Int64?
    private var invalidated = false

    private static let chunk: Int64 = 1 << 20

    init?(stream: MediaStream, onRefused: @escaping @Sendable (Int) -> Void) {
        guard let remote = URL(string: stream.url), var components = URLComponents(url: remote, resolvingAgainstBaseURL: false) else { return nil }
        components.scheme = Self.scheme
        guard let custom = components.url else { return nil }
        self.stream = stream
        self.remote = remote
        self.onRefused = onRefused
        totalLength = stream.contentLength
        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.timeoutIntervalForRequest = 20
        session = URLSession(configuration: config)
        asset = AVURLAsset(url: custom)
        super.init()
        asset.resourceLoader.setDelegate(self, queue: queue)
    }

    func invalidate() {
        queue.async { [self] in
            invalidated = true
            for task in tasks.values { task.cancel() }
            tasks = [:]
            session.invalidateAndCancel()
        }
    }

    /** The type AVFoundation needs for the container. */
    static func typeIdentifier(_ container: String) -> String {
        switch container.lowercased() {
        case "mp3": return UTType.mp3.identifier
        case "m4a", "mp4", "alac": return UTType.mpeg4Audio.identifier
        case "aac": return "public.aac-audio"
        case "flac": return "org.xiph.flac"
        case "wav": return UTType.wav.identifier
        case "aif", "aiff": return UTType.aiff.identifier
        default: return UTType(filenameExtension: container)?.identifier ?? UTType.mpeg4Audio.identifier
        }
    }

    // ------------------------------------------------------------ loader --

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        guard !invalidated else { return false }
        let id = ObjectIdentifier(loadingRequest)
        let task = Task { [weak self] in
            guard let self else { return }
            await self.serve(loadingRequest)
            self.queue.async { self.tasks[id] = nil }
        }
        tasks[id] = task
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        let id = ObjectIdentifier(loadingRequest)
        tasks[id]?.cancel()
        tasks[id] = nil
    }

    private func request(from: Int64, to: Int64) -> URLRequest {
        var req = URLRequest(url: remote)
        req.setValue(Http.browserUserAgent, forHTTPHeaderField: "User-Agent")
        for (key, value) in stream.headers { req.setValue(value, forHTTPHeaderField: key) }
        req.setValue("bytes=\(from)-\(to)", forHTTPHeaderField: "Range")
        return req
    }

    /** One range from the site; learns the file's length from the reply. */
    private func fetch(from: Int64, to: Int64) async throws -> Data {
        let (data, response) = try await session.data(for: request(from: from, to: to))
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        if http.statusCode == 403 || http.statusCode == 401 || http.statusCode == 410 {
            onRefused(http.statusCode)
            throw StreamForbidden(code: http.statusCode)
        }
        guard (200..<300).contains(http.statusCode) else { throw URLError(.badServerResponse) }
        if let range = http.value(forHTTPHeaderField: "Content-Range"), let total = Int64(range.split(separator: "/").last ?? "") {
            queue.sync { totalLength = total }
        } else if http.statusCode == 200 {
            // No ranges on this server: the whole file came back.
            queue.sync { totalLength = Int64(data.count) }
            return from == 0 ? data : data.dropFirst(Int(from))
        }
        return data
    }

    private func currentLength() -> Int64? { queue.sync { totalLength } }

    private func serve(_ loading: AVAssetResourceLoadingRequest) async {
        do {
            // A song got ready ahead starts from the bytes already here.
            let head = StreamHeads.shared.head(stream.url)
            if head == nil, let wait = stream.availableAt?.timeIntervalSinceNow, wait > 0 {
                try await Task.sleep(nanoseconds: UInt64(min(wait, 15) * 1_000_000_000))
            }
            if let info = loading.contentInformationRequest {
                if currentLength() == nil, let total = head?.total { queue.sync { totalLength = total } }
                if currentLength() == nil { _ = try await fetch(from: 0, to: 1) }
                info.contentType = Self.typeIdentifier(stream.container)
                info.contentLength = currentLength() ?? 0
                info.isByteRangeAccessSupported = true
            }
            if let data = loading.dataRequest {
                var offset = data.currentOffset > 0 ? data.currentOffset : data.requestedOffset
                let total = currentLength() ?? Int64.max
                let end: Int64 = data.requestsAllDataToEndOfResource
                    ? total
                    : min(total, data.requestedOffset + Int64(data.requestedLength))
                if let head, offset < Int64(head.data.count) {
                    let upTo = min(end, Int64(head.data.count))
                    if upTo > offset {
                        data.respond(with: head.data.subdata(in: Int(offset)..<Int(upTo)))
                        offset = upTo
                    }
                }
                // The first piece small, so playback starts at once.
                var size: Int64 = 256 * 1024
                while offset < end {
                    try Task.checkCancellation()
                    let last = min(end, offset + size) - 1
                    let bytes = try await fetch(from: offset, to: last)
                    if bytes.isEmpty { break }
                    try Task.checkCancellation()
                    data.respond(with: bytes)
                    offset += Int64(bytes.count)
                    size = Self.chunk
                }
            }
            if !loading.isCancelled && !loading.isFinished { loading.finishLoading() }
        } catch is CancellationError {
            if !loading.isCancelled && !loading.isFinished { loading.finishLoading(with: URLError(.cancelled)) }
        } catch {
            if !loading.isCancelled && !loading.isFinished { loading.finishLoading(with: error) }
        }
    }
}

/**
 * The first bytes of streams that are coming up, fetched while the song
 * before them plays (see StreamResolver.prefetch): a song then starts the
 * moment it's due, and a stream that would be refused is known about early.
 */
final class StreamHeads: @unchecked Sendable {
    static let shared = StreamHeads()

    struct Head {
        let data: Data
        /** The whole file's length, when the site said. */
        let total: Int64?
    }

    /** How much of each stream is fetched ahead. */
    static let size = 256 * 1024
    private static let kept = 4

    private let lock = NSLock()
    private var heads: [String: Head] = [:]
    private var order: [String] = []
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.timeoutIntervalForRequest = 20
        return URLSession(configuration: config)
    }()

    func head(_ url: String) -> Head? {
        lock.lock()
        defer { lock.unlock() }
        return heads[url]
    }

    private func store(_ url: String, _ head: Head) {
        lock.lock()
        defer { lock.unlock() }
        heads[url] = head
        order.removeAll { $0 == url }
        order.append(url)
        while order.count > Self.kept { heads[order.removeFirst()] = nil }
    }

    /** Fetches the start of [stream] and keeps it; returns the site's HTTP status. */
    func fetch(_ stream: MediaStream) async throws -> Int {
        if head(stream.url) != nil { return 206 }
        guard let url = URL(string: stream.url) else { throw URLError(.badURL) }
        if let wait = stream.availableAt?.timeIntervalSinceNow, wait > 0 {
            try await Task.sleep(nanoseconds: UInt64(min(wait, 15) * 1_000_000_000))
        }
        var request = URLRequest(url: url)
        request.setValue(Http.browserUserAgent, forHTTPHeaderField: "User-Agent")
        for (key, value) in stream.headers { request.setValue(value, forHTTPHeaderField: key) }
        request.setValue("bytes=0-\(Self.size - 1)", forHTTPHeaderField: "Range")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(http.statusCode), !data.isEmpty else { return http.statusCode }
        if let range = http.value(forHTTPHeaderField: "Content-Range"), let total = Int64(range.split(separator: "/").last ?? "") {
            store(stream.url, Head(data: data, total: total))
        } else if http.statusCode == 200 {
            // No ranges on this server: the whole file came back.
            store(stream.url, Head(data: data.prefix(Self.size), total: Int64(data.count)))
        }
        return http.statusCode
    }
}
