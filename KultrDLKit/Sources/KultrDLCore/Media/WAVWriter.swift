import Foundation

/**
 * Writes 16- or 24-bit PCM WAV with the track's details in a LIST/INFO
 * chunk (what Windows shows) and an "id3 " chunk (what music players read,
 * cover included).
 */
public final class WAVWriter {
    private let handle: FileHandle
    private let url: URL
    private let channels: Int
    private let sampleRate: Int
    private let bits: Int
    private var dataBytes: UInt64 = 0
    private var dataSizeOffset: UInt64 = 0

    public init(url: URL, sampleRate: Int, channels: Int, bits: Int, tags: TrackTags) throws {
        self.url = url
        self.channels = channels
        self.sampleRate = sampleRate
        self.bits = bits
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)

        var w = ByteWriter()
        w.ascii("RIFF")
        w.u32le(0) // patched in finish()
        w.ascii("WAVE")
        w.ascii("fmt ")
        w.u32le(16)
        w.u16le(1) // PCM
        w.u16le(UInt16(channels))
        w.u32le(UInt32(sampleRate))
        let blockAlign = channels * bits / 8
        w.u32le(UInt32(sampleRate * blockAlign))
        w.u16le(UInt16(blockAlign))
        w.u16le(UInt16(bits))

        var info = ByteWriter()
        func infoItem(_ id: String, _ value: String?) {
            guard let value, !value.isEmpty else { return }
            var text = Array(value.utf8) + [0]
            if text.count % 2 == 1 { text.append(0) }
            info.ascii(id)
            info.u32le(UInt32(text.count))
            info.append(text)
        }
        infoItem("INAM", tags.title)
        infoItem("IART", tags.artist)
        infoItem("IPRD", tags.album)
        infoItem("ICRD", tags.year.map(String.init))
        infoItem("IGNR", tags.genre)
        infoItem("ITRK", tags.trackNumber.map(String.init))
        if !info.bytes.isEmpty {
            w.ascii("LIST")
            w.u32le(UInt32(4 + info.bytes.count))
            w.ascii("INFO")
            w.append(info.bytes)
        }
        var id3 = [UInt8](ID3.tag(tags))
        if id3.count % 2 == 1 { id3.append(0) }
        w.ascii("id3 ")
        w.u32le(UInt32(id3.count))
        w.append(id3)

        w.ascii("data")
        dataSizeOffset = UInt64(w.bytes.count)
        w.u32le(0)
        try handle.write(contentsOf: w.bytes)
    }

    /** Interleaved float samples in -1…1. */
    public func write(_ samples: UnsafeBufferPointer<Float>) throws {
        var out = [UInt8]()
        out.reserveCapacity(samples.count * bits / 8)
        if bits == 24 {
            for s in samples {
                let v = Int32((max(-1, min(1, s)) * 8_388_607).rounded())
                out.append(UInt8(truncatingIfNeeded: v))
                out.append(UInt8(truncatingIfNeeded: v >> 8))
                out.append(UInt8(truncatingIfNeeded: v >> 16))
            }
        } else {
            for s in samples {
                let v = Int16((max(-1, min(1, s)) * 32767).rounded())
                out.append(UInt8(truncatingIfNeeded: v))
                out.append(UInt8(truncatingIfNeeded: v >> 8))
            }
        }
        try handle.write(contentsOf: out)
        dataBytes += UInt64(out.count)
    }

    public func finish() throws {
        if dataBytes % 2 == 1 { try handle.write(contentsOf: [UInt8(0)]) }
        let end = try handle.offset()
        try handle.seek(toOffset: 4)
        var riff = ByteWriter()
        riff.u32le(UInt32(clamping: end - 8))
        try handle.write(contentsOf: riff.bytes)
        try handle.seek(toOffset: dataSizeOffset)
        var size = ByteWriter()
        size.u32le(UInt32(clamping: dataBytes))
        try handle.write(contentsOf: size.bytes)
        try handle.close()
    }
}
