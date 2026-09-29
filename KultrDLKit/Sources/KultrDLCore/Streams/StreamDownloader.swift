import Foundation

/** The server refused the stream itself (YouTube's 403): another client may do better. */
public struct StreamForbidden: LocalizedError, Sendable {
    public let code: Int

    public init(code: Int) {
        self.code = code
    }

    public var errorDescription: String? { "The stream was refused (HTTP \(code))." }
}

/**
 * Fetches a stream to a file: a plain file in 10 MB ranges (as yt-dlp does,
 * so YouTube doesn't slow it down), or an HLS stream joined into one file.
 */
public final class StreamDownloader: @unchecked Sendable {
    public struct Result: Sendable {
        public let file: URL
        /** "m4a", "webm", "mp3", "aac" (ADTS), "flac", "ogg"… */
        public let container: String
    }

    private let session: URLSession
    private static let chunk: Int64 = 10 << 20

    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = 30
            config.timeoutIntervalForResource = 3600
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            config.urlCache = nil
            self.session = URLSession(configuration: config)
        }
    }

    /** Downloads [stream] into [directory] as "source.<ext>". [progress] gets 0…1. */
    public func download(_ stream: MediaStream, into directory: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> Result {
        if let wait = stream.availableAt?.timeIntervalSinceNow, wait > 0 {
            try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        switch stream.kind {
        case .file:
            let file = directory.appendingPathComponent("source.\(stream.container)")
            try await fetchFile(stream.url, headers: stream.headers, knownLength: stream.contentLength, to: file, progress: progress)
            return Result(file: file, container: Self.sniff(file) ?? stream.container)
        case .hls:
            return try await fetchHLS(stream, into: directory, progress: progress)
        }
    }

    // ----------------------------------------------------------- files --

    private func request(_ url: String, headers: [String: String], range: ClosedRange<Int64>? = nil) throws -> URLRequest {
        guard let u = URL(string: url) else { throw KultrError("Bad stream address.") }
        var req = URLRequest(url: u)
        req.setValue(Http.browserUserAgent, forHTTPHeaderField: "User-Agent")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        if let range { req.setValue("bytes=\(range.lowerBound)-\(range.upperBound)", forHTTPHeaderField: "Range") }
        return req
    }

    private func check(_ response: URLResponse) throws -> HTTPURLResponse {
        guard let http = response as? HTTPURLResponse else { throw KultrError("No answer from the stream's server.") }
        if http.statusCode == 403 || http.statusCode == 401 || http.statusCode == 410 { throw StreamForbidden(code: http.statusCode) }
        guard (200..<300).contains(http.statusCode) else {
            throw HttpError(code: http.statusCode, host: http.url?.host ?? "", body: nil)
        }
        return http
    }

    /** Appends everything [req] returns to [handle]; returns the bytes written. */
    private func stream(_ req: URLRequest, to handle: FileHandle, onBytes: (Int64) -> Void) async throws -> (Int64, HTTPURLResponse) {
        let (bytes, response) = try await session.bytes(for: req)
        let http = try check(response)
        var buffer = [UInt8]()
        buffer.reserveCapacity(1 << 16)
        var written: Int64 = 0
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 1 << 16 {
                try Task.checkCancellation()
                try handle.write(contentsOf: buffer)
                written += Int64(buffer.count)
                onBytes(written)
                buffer.removeAll(keepingCapacity: true)
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
            written += Int64(buffer.count)
            onBytes(written)
        }
        return (written, http)
    }

    func fetchFile(_ url: String, headers: [String: String], knownLength: Int64?, to file: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        var total = knownLength
        var offset: Int64 = 0
        while true {
            try Task.checkCancellation()
            let end = offset + Self.chunk - 1
            let base = offset
            let req = try request(url, headers: headers, range: offset...end)
            let (written, response) = try await stream(req, to: handle) { n in
                if let total, total > 0 { progress(min(1, Double(base + n) / Double(total))) }
            }
            offset += written
            if total == nil {
                // "bytes 0-1048575/4196711"
                if let range = response.value(forHTTPHeaderField: "Content-Range"), let size = Int64(range.afterLast("/")) {
                    total = size
                } else if response.statusCode == 200 {
                    // The server ignored the range and sent it all.
                    break
                }
            }
            if response.statusCode == 200 { break }
            guard let total else { break }
            if offset >= total || written == 0 { break }
        }
        progress(1)
        if offset == 0 { throw KultrError("The stream was empty.") }
    }

    // ------------------------------------------------------------- HLS --

    private func text(_ url: String, headers: [String: String]) async throws -> String {
        let (data, response) = try await session.data(for: try request(url, headers: headers))
        _ = try check(response)
        return String(decoding: data, as: UTF8.self)
    }

    private func fetchHLS(_ stream: MediaStream, into directory: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> Result {
        var playlistUrl = stream.url
        var playlist = try await text(playlistUrl, headers: stream.headers)
        if HLS.isMaster(playlist) {
            guard let variant = HLS.bestAudio(playlist, base: playlistUrl) else { throw KultrError("The stream has no audio.") }
            playlistUrl = variant.url
            playlist = try await text(playlistUrl, headers: stream.headers)
        }
        let media = HLS.media(playlist, base: playlistUrl)
        if media.encrypted { throw KultrError("This stream is encrypted and can't be downloaded.") }
        guard !media.segments.isEmpty else { throw KultrError("The stream has no segments.") }

        let joined = directory.appendingPathComponent("segments.bin")
        FileManager.default.createFile(atPath: joined.path, contents: nil)
        let handle = try FileHandle(forWritingTo: joined)
        var first: [UInt8]?
        let parts = [media.initSegment].compactMap { $0 } + media.segments
        for (i, part) in parts.enumerated() {
            try Task.checkCancellation()
            var attempt = 0
            while true {
                do {
                    let (data, response) = try await session.data(for: try request(part, headers: stream.headers))
                    _ = try check(response)
                    var bytes = [UInt8](data)
                    if first == nil { first = Array(bytes.prefix(1024)) }
                    // Packed audio (MP3 or AAC in HLS) starts each segment with an ID3 timestamp; drop it.
                    if media.initSegment == nil { bytes = Self.stripID3(bytes) }
                    try handle.write(contentsOf: bytes)
                    break
                } catch let error as StreamForbidden {
                    throw error
                } catch {
                    attempt += 1
                    if attempt >= 3 || error is CancellationError { throw error }
                    try await Task.sleep(nanoseconds: 800_000_000)
                }
            }
            progress(Double(i + 1) / Double(parts.count))
        }
        try handle.close()

        let head = first ?? []
        if media.initSegment != nil || Self.isMP4(head) {
            let out = directory.appendingPathComponent("source.m4a")
            try? FileManager.default.removeItem(at: out)
            try FileManager.default.moveItem(at: joined, to: out)
            return Result(file: out, container: "m4a")
        }
        if head.first == 0x47 {
            // MPEG-TS: take the audio out.
            let (payload, kind) = try TSDemuxer.extractAudio(from: joined)
            let out = directory.appendingPathComponent("source.\(kind)")
            try payload.write(to: out)
            try? FileManager.default.removeItem(at: joined)
            return Result(file: out, container: kind)
        }
        let ext = stream.container == "m4a" || stream.codec == "aac" ? "aac" : (stream.container == "ts" ? "mp3" : stream.container)
        let out = directory.appendingPathComponent("source.\(ext)")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.moveItem(at: joined, to: out)
        return Result(file: out, container: Self.sniff(out) ?? ext)
    }

    static func stripID3(_ bytes: [UInt8]) -> [UInt8] {
        guard bytes.count > 10, bytes[0] == 0x49, bytes[1] == 0x44, bytes[2] == 0x33 else { return bytes }
        let size = (Int(bytes[6] & 0x7f) << 21) | (Int(bytes[7] & 0x7f) << 14) | (Int(bytes[8] & 0x7f) << 7) | Int(bytes[9] & 0x7f)
        let footer = (bytes[5] & 0x10) != 0 ? 10 : 0
        let end = 10 + size + footer
        return end < bytes.count ? Array(bytes[end...]) : bytes
    }

    static func isMP4(_ head: [UInt8]) -> Bool {
        head.count >= 8 && [0x66, 0x74, 0x79, 0x70].elementsEqual(head[4..<8]) // "ftyp"
            || head.count >= 8 && [0x73, 0x74, 0x79, 0x70].elementsEqual(head[4..<8]) // "styp"
            || head.count >= 8 && [0x6D, 0x6F, 0x6F, 0x66].elementsEqual(head[4..<8]) // "moof"
    }

    /** What a file really is, from its first bytes. */
    public static func sniff(_ file: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        let head = [UInt8]((try? handle.read(upToCount: 64)) ?? Data())
        guard head.count >= 12 else { return nil }
        if isMP4(head) { return "m4a" }
        if head.starts(with: [0x1A, 0x45, 0xDF, 0xA3]) { return "webm" }
        if head.starts(with: [0x66, 0x4C, 0x61, 0x43]) { return "flac" }
        if head.starts(with: [0x4F, 0x67, 0x67, 0x53]) { return "ogg" }
        if head.starts(with: [0x52, 0x49, 0x46, 0x46]) { return "wav" }
        if head.starts(with: [0x49, 0x44, 0x33]) || (head[0] == 0xFF && (head[1] & 0xE6) == 0xE2) { return "mp3" }
        if head[0] == 0xFF && (head[1] & 0xF6) == 0xF0 { return "aac" }
        return nil
    }
}

/** Takes the audio track out of an MPEG transport stream (AAC as ADTS, or MP3). */
public enum TSDemuxer {
    public static func extractAudio(from file: URL) throws -> (Data, String) {
        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        let bytes = [UInt8](data)
        var pmtPid: Int?
        var audioPid: Int?
        var kind = "aac"
        var out = [UInt8]()
        out.reserveCapacity(bytes.count / 2)
        var i = 0
        // Find the first sync byte.
        while i < bytes.count, bytes[i] != 0x47 { i += 1 }
        while i + 188 <= bytes.count {
            guard bytes[i] == 0x47 else {
                i += 1
                continue
            }
            let packet = bytes[i..<(i + 188)]
            let p = packet.startIndex
            let unitStart = (bytes[p + 1] & 0x40) != 0
            let pid = (Int(bytes[p + 1] & 0x1F) << 8) | Int(bytes[p + 2])
            let adaptation = (bytes[p + 3] >> 4) & 0x3
            var offset = p + 4
            if adaptation == 2 || adaptation == 3 { offset += 1 + Int(bytes[p + 4]) }
            let hasPayload = adaptation == 1 || adaptation == 3
            if hasPayload, offset < p + 188 {
                if pid == 0, unitStart {
                    // PAT: the first program's PMT.
                    let start = offset + 1 + Int(bytes[offset])
                    if start + 12 <= p + 188 {
                        pmtPid = (Int(bytes[start + 10] & 0x1F) << 8) | Int(bytes[start + 11])
                    }
                } else if pid == pmtPid, unitStart, audioPid == nil {
                    let start = offset + 1 + Int(bytes[offset])
                    if start + 12 <= p + 188 {
                        let sectionLength = (Int(bytes[start + 1] & 0x0F) << 8) | Int(bytes[start + 2])
                        let programInfoLength = (Int(bytes[start + 10] & 0x0F) << 8) | Int(bytes[start + 11])
                        var e = start + 12 + programInfoLength
                        let end = min(start + 3 + sectionLength - 4, p + 188)
                        while e + 5 <= end {
                            let type = bytes[e]
                            let elementaryPid = (Int(bytes[e + 1] & 0x1F) << 8) | Int(bytes[e + 2])
                            let infoLength = (Int(bytes[e + 3] & 0x0F) << 8) | Int(bytes[e + 4])
                            if type == 0x0F || type == 0x11 {
                                audioPid = elementaryPid
                                kind = "aac"
                                break
                            }
                            if type == 0x03 || type == 0x04 {
                                audioPid = elementaryPid
                                kind = "mp3"
                                break
                            }
                            e += 5 + infoLength
                        }
                    }
                } else if pid == audioPid {
                    var payload = offset
                    if unitStart, payload + 9 <= p + 188, bytes[payload] == 0, bytes[payload + 1] == 0, bytes[payload + 2] == 1 {
                        payload += 9 + Int(bytes[payload + 8])
                    }
                    if payload < p + 188 { out.append(contentsOf: bytes[payload..<(p + 188)]) }
                }
            }
            i += 188
        }
        guard !out.isEmpty else { throw KultrError("The stream has no audio track KultrDL can read.") }
        return (Data(out), kind)
    }
}
