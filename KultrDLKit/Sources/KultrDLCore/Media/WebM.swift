import Foundation

/**
 * Reads the audio track of a WebM (Matroska) file: its codec, codec
 * private data and packets with their times. YouTube's Opus streams come
 * this way; KultrDL decodes them with libopus, or moves the packets into
 * an Ogg file untouched.
 */
public struct WebMAudio: Sendable {
    public struct Packet: Sendable {
        public let data: Data
        /** From the start of the file, in nanoseconds. */
        public let timeNs: Int64
    }

    public var codecId: String = ""
    public var codecPrivate = Data()
    public var sampleRate: Double = 48000
    public var channels: Int = 2
    /** Nanoseconds of priming (Opus pre-skip) to drop. */
    public var codecDelayNs: Int64 = 0
    /** Nanoseconds of padding at the end to drop. */
    public var discardPaddingNs: Int64 = 0
    public var durationNs: Int64?
    public var packets: [Packet] = []

    public var isOpus: Bool { codecId == "A_OPUS" }

    public static func read(_ url: URL) throws -> WebMAudio {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        var reader = EBMLReader(bytes: [UInt8](data))
        return try reader.readAudio()
    }
}

struct EBMLReader {
    let bytes: [UInt8]
    var pos = 0

    init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    struct Element {
        let id: UInt32
        let start: Int
        /** nil: unknown size (to the end of the parent). */
        let size: Int?
    }

    private mutating func vint(keepMarker: Bool) -> (UInt64, Int)? {
        guard pos < bytes.count else { return nil }
        let first = bytes[pos]
        var length = 1
        var mask: UInt8 = 0x80
        while length <= 8 && (first & mask) == 0 {
            length += 1
            mask >>= 1
        }
        guard length <= 8, pos + length <= bytes.count else { return nil }
        var value = UInt64(keepMarker ? first : first & (mask &- 1))
        for i in 1..<length { value = (value << 8) | UInt64(bytes[pos + i]) }
        pos += length
        return (value, length)
    }

    private mutating func element() -> Element? {
        guard let (id, _) = vint(keepMarker: true), let (size, length) = vint(keepMarker: false) else { return nil }
        let unknown = size == (UInt64(1) << (7 * UInt64(length))) - 1
        return Element(id: UInt32(truncatingIfNeeded: id), start: pos, size: unknown ? nil : Int(clamping: size))
    }

    private func uint(_ e: Element) -> UInt64 {
        var v: UInt64 = 0
        for i in 0..<(e.size ?? 0) where e.start + i < bytes.count { v = (v << 8) | UInt64(bytes[e.start + i]) }
        return v
    }

    private func sint(_ e: Element) -> Int64 {
        let n = e.size ?? 0
        guard n > 0 else { return 0 }
        let u = uint(e)
        let shift = UInt64(64 - 8 * n)
        return Int64(bitPattern: u << shift) >> Int64(shift)
    }

    private func float(_ e: Element) -> Double {
        let u = uint(e)
        if e.size == 4 { return Double(Float(bitPattern: UInt32(truncatingIfNeeded: u))) }
        return Double(bitPattern: u)
    }

    private func string(_ e: Element) -> String {
        let end = min(bytes.count, e.start + (e.size ?? 0))
        return String(decoding: bytes[e.start..<end].prefix { $0 != 0 }, as: UTF8.self)
    }

    private func slice(_ e: Element) -> [UInt8] {
        Array(bytes[e.start..<min(bytes.count, e.start + (e.size ?? 0))])
    }

    // Element ids.
    static let segment: UInt32 = 0x1853_8067
    static let info: UInt32 = 0x1549_A966
    static let timecodeScale: UInt32 = 0x2A_D7B1
    static let duration: UInt32 = 0x4489
    static let tracks: UInt32 = 0x1654_AE6B
    static let trackEntry: UInt32 = 0xAE
    static let trackNumber: UInt32 = 0xD7
    static let trackType: UInt32 = 0x83
    static let codecId: UInt32 = 0x86
    static let codecPrivate: UInt32 = 0x63A2
    static let codecDelay: UInt32 = 0x56AA
    static let audio: UInt32 = 0xE1
    static let samplingFrequency: UInt32 = 0xB5
    static let channels: UInt32 = 0x9F
    static let cluster: UInt32 = 0x1F43_B675
    static let timecode: UInt32 = 0xE7
    static let simpleBlock: UInt32 = 0xA3
    static let blockGroup: UInt32 = 0xA0
    static let block: UInt32 = 0xA1
    static let discardPadding: UInt32 = 0x75A2

    mutating func readAudio() throws -> WebMAudio {
        var out = WebMAudio()
        var scale: Int64 = 1_000_000
        var audioTrack: UInt64?
        var clusterTime: Int64 = 0
        // Walk down into containers, over everything else.
        let containers: Set<UInt32> = [Self.segment, Self.info, Self.tracks, Self.trackEntry, Self.audio, Self.cluster, Self.blockGroup]
        var pendingTrack: (number: UInt64, type: UInt64, codec: String, priv: [UInt8], delay: Int64, rate: Double, channels: Int)?
        var trackEnds: [Int] = []
        var groupBlock: (track: UInt64, time: Int64, frames: [[UInt8]])?

        func flushTrack() {
            guard let t = pendingTrack else { return }
            if audioTrack == nil && (t.type == 2 || t.codec.hasPrefix("A_")) {
                audioTrack = t.number
                out.codecId = t.codec
                out.codecPrivate = Data(t.priv)
                out.codecDelayNs = t.delay
                out.sampleRate = t.rate
                out.channels = t.channels
            }
            pendingTrack = nil
        }

        while pos < bytes.count {
            while let end = trackEnds.last, pos >= end {
                trackEnds.removeLast()
                flushTrack()
            }
            guard let e = element() else { break }
            if e.id == Self.trackEntry {
                pendingTrack = (0, 0, "", [], 0, 48000, 2)
                if let size = e.size { trackEnds.append(e.start + size) }
                continue
            }
            if containers.contains(e.id) {
                if e.id == Self.blockGroup, let g = groupBlock {
                    appendFrames(g, to: &out, audioTrack: audioTrack)
                    groupBlock = nil
                }
                continue
            }
            let next = e.size.map { e.start + $0 } ?? bytes.count
            switch e.id {
            case Self.timecodeScale: scale = Int64(uint(e))
            case Self.duration: out.durationNs = Int64(float(e) * Double(scale))
            case Self.trackNumber: pendingTrack?.number = uint(e)
            case Self.trackType: pendingTrack?.type = uint(e)
            case Self.codecId: pendingTrack?.codec = string(e)
            case Self.codecPrivate: pendingTrack?.priv = slice(e)
            case Self.codecDelay: pendingTrack?.delay = Int64(uint(e))
            case Self.samplingFrequency: pendingTrack?.rate = float(e)
            case Self.channels: pendingTrack?.channels = Int(uint(e))
            case Self.timecode: clusterTime = Int64(uint(e))
            case Self.discardPadding: out.discardPaddingNs = max(out.discardPaddingNs, sint(e))
            case Self.simpleBlock, Self.block:
                flushTrack()
                if let parsed = parseBlock(slice(e), clusterTime: clusterTime, scale: scale) {
                    if e.id == Self.block {
                        if let g = groupBlock { appendFrames(g, to: &out, audioTrack: audioTrack) }
                        groupBlock = parsed
                    } else {
                        appendFrames(parsed, to: &out, audioTrack: audioTrack)
                    }
                }
            default:
                break
            }
            pos = next
        }
        flushTrack()
        if let g = groupBlock { appendFrames(g, to: &out, audioTrack: audioTrack) }
        guard audioTrack != nil, !out.packets.isEmpty else { throw KultrError("The WebM file has no audio.") }
        return out
    }

    private func appendFrames(_ block: (track: UInt64, time: Int64, frames: [[UInt8]]), to out: inout WebMAudio, audioTrack: UInt64?) {
        guard let audioTrack, block.track == audioTrack else { return }
        for (i, frame) in block.frames.enumerated() {
            // Laced frames share the block's time; spread them evenly is not needed for Opus (each packet knows its length).
            out.packets.append(WebMAudio.Packet(data: Data(frame), timeNs: block.time + Int64(i)))
        }
    }

    private func parseBlock(_ b: [UInt8], clusterTime: Int64, scale: Int64) -> (track: UInt64, time: Int64, frames: [[UInt8]])? {
        var r = EBMLReader(bytes: b)
        guard let (track, _) = r.vint(keepMarker: false), r.pos + 3 <= b.count else { return nil }
        let relative = Int64(Int16(bitPattern: UInt16(b[r.pos]) << 8 | UInt16(b[r.pos + 1])))
        let flags = b[r.pos + 2]
        r.pos += 3
        let time = (clusterTime + relative) * scale
        let lacing = (flags >> 1) & 0x03
        if lacing == 0 { return (track, time, [Array(b[r.pos...])]) }
        guard r.pos < b.count else { return nil }
        let count = Int(b[r.pos]) + 1
        r.pos += 1
        var sizes: [Int] = []
        switch lacing {
        case 1: // Xiph
            for _ in 0..<(count - 1) {
                var size = 0
                while r.pos < b.count {
                    let v = Int(b[r.pos])
                    r.pos += 1
                    size += v
                    if v != 255 { break }
                }
                sizes.append(size)
            }
        case 3: // EBML
            guard let (first, _) = r.vint(keepMarker: false) else { return nil }
            var last = Int(first)
            sizes.append(last)
            for _ in 1..<max(1, count - 1) where count > 2 {
                guard let (raw, length) = r.vint(keepMarker: false) else { return nil }
                let bias = (Int64(1) << (7 * Int64(length) - 1)) - 1
                last += Int(Int64(raw) - bias)
                sizes.append(last)
            }
        default: // fixed
            let each = (b.count - r.pos) / count
            sizes = Array(repeating: each, count: count - 1)
        }
        let used = sizes.reduce(0, +)
        sizes.append(b.count - r.pos - used)
        var frames: [[UInt8]] = []
        var p = r.pos
        for s in sizes {
            guard s >= 0, p + s <= b.count else { return nil }
            frames.append(Array(b[p..<(p + s)]))
            p += s
        }
        return (track, time, frames)
    }
}
