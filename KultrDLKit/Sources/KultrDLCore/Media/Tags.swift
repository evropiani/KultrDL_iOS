import Foundation

/** What goes into a downloaded file's tags. */
public struct TrackTags: Sendable, Equatable {
    public var title: String
    public var artist: String
    public var album: String?
    public var albumArtist: String?
    public var year: Int?
    public var trackNumber: Int?
    public var discNumber: Int?
    public var genre: String?
    public var isrc: String?
    /** JPEG. */
    public var cover: Data?

    public init(
        title: String, artist: String, album: String? = nil, albumArtist: String? = nil, year: Int? = nil,
        trackNumber: Int? = nil, discNumber: Int? = nil, genre: String? = nil, isrc: String? = nil, cover: Data? = nil
    ) {
        self.title = title
        self.artist = artist
        self.album = album
        self.albumArtist = albumArtist
        self.year = year
        self.trackNumber = trackNumber
        self.discNumber = discNumber
        self.genre = genre
        self.isrc = isrc
        self.cover = cover
    }

    public init(_ track: Track, cover: Data? = nil) {
        self.init(
            title: track.title, artist: track.artist, album: track.album, albumArtist: track.albumArtist,
            year: track.year, trackNumber: track.trackNumber, discNumber: track.discNumber,
            genre: track.genre, isrc: track.isrc, cover: cover
        )
    }

    /** Vorbis comment fields (FLAC, Ogg Opus, Ogg Vorbis), in the usual order. */
    public var vorbisComments: [(String, String)] {
        var out: [(String, String)] = [("TITLE", title), ("ARTIST", artist)]
        if let album, !album.isEmpty { out.append(("ALBUM", album)) }
        if let albumArtist, !albumArtist.isEmpty { out.append(("ALBUMARTIST", albumArtist)) }
        if let year { out.append(("DATE", String(year))) }
        if let trackNumber { out.append(("TRACKNUMBER", String(trackNumber))) }
        if let discNumber { out.append(("DISCNUMBER", String(discNumber))) }
        if let genre, !genre.isEmpty { out.append(("GENRE", genre)) }
        if let isrc, !isrc.isEmpty { out.append(("ISRC", isrc)) }
        return out
    }
}

/** Byte writing helpers. */
struct ByteWriter {
    var bytes: [UInt8] = []

    mutating func u8(_ v: UInt8) { bytes.append(v) }
    mutating func u16le(_ v: UInt16) { bytes += [UInt8(v & 0xff), UInt8(v >> 8)] }
    mutating func u32le(_ v: UInt32) { bytes += [UInt8(v & 0xff), UInt8((v >> 8) & 0xff), UInt8((v >> 16) & 0xff), UInt8(v >> 24)] }
    mutating func u32be(_ v: UInt32) { bytes += [UInt8(v >> 24), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)] }
    mutating func ascii(_ s: String) { bytes += Array(s.utf8) }
    mutating func data(_ d: Data) { bytes += [UInt8](d) }
    mutating func append(_ b: [UInt8]) { bytes += b }
}

/**
 * ID3v2.3 tags, for MP3 (in front of the audio) and WAV (in an "id3 "
 * chunk). v2.3 rather than v2.4: it is the version every player reads,
 * AVFoundation, the Music app and Windows Explorer included.
 */
public enum ID3 {
    public static func tag(_ tags: TrackTags) -> Data {
        var frames = ByteWriter()
        func text(_ id: String, _ value: String?) {
            guard let value, !value.isEmpty else { return }
            frame(&frames, id, encoded(value))
        }
        text("TIT2", tags.title)
        text("TPE1", tags.artist)
        text("TALB", tags.album)
        text("TPE2", tags.albumArtist)
        text("TYER", tags.year.map(String.init))
        text("TRCK", tags.trackNumber.map(String.init))
        text("TPOS", tags.discNumber.map(String.init))
        text("TCON", tags.genre)
        text("TSRC", tags.isrc)
        if let cover = tags.cover {
            var apic = ByteWriter()
            apic.u8(0x00) // ISO-8859-1 description
            apic.ascii(mimeType(cover))
            apic.u8(0)
            apic.u8(0x03) // front cover
            apic.u8(0) // empty description
            apic.data(cover)
            frame(&frames, "APIC", apic.bytes)
        }
        // Some room to spare, so a tag editor can change it without rewriting the file.
        let padding = [UInt8](repeating: 0, count: 1024)
        var out = ByteWriter()
        out.ascii("ID3")
        out.append([0x03, 0x00, 0x00])
        out.append(syncsafe(frames.bytes.count + padding.count))
        out.append(frames.bytes)
        out.append(padding)
        return Data(out.bytes)
    }

    /** A text frame's body: ISO-8859-1 when the text fits it, UTF-16 with a byte order mark otherwise. */
    static func encoded(_ value: String) -> [UInt8] {
        if value.unicodeScalars.allSatisfy({ $0.value < 0x100 }) {
            return [0x00] + value.unicodeScalars.map { UInt8($0.value) }
        }
        var bytes: [UInt8] = [0x01, 0xFF, 0xFE]
        for unit in value.utf16 { bytes += [UInt8(unit & 0xff), UInt8(unit >> 8)] }
        return bytes
    }

    /** A v2.3 frame: plain 32-bit size (v2.4 would be syncsafe). */
    private static func frame(_ w: inout ByteWriter, _ id: String, _ body: [UInt8]) {
        w.ascii(id)
        w.u32be(UInt32(body.count))
        w.append([0, 0])
        w.append(body)
    }

    static func syncsafe(_ n: Int) -> [UInt8] {
        [UInt8((n >> 21) & 0x7f), UInt8((n >> 14) & 0x7f), UInt8((n >> 7) & 0x7f), UInt8(n & 0x7f)]
    }

    public static func mimeType(_ image: Data) -> String {
        image.starts(with: [0x89, 0x50, 0x4E, 0x47]) ? "image/png" : "image/jpeg"
    }

    /** The size of an ID3v2 tag at the start of [data], or 0. */
    public static func tagSize(_ head: [UInt8]) -> Int {
        guard head.count >= 10, head[0] == 0x49, head[1] == 0x44, head[2] == 0x33 else { return 0 }
        let size = (Int(head[6] & 0x7f) << 21) | (Int(head[7] & 0x7f) << 14) | (Int(head[8] & 0x7f) << 7) | Int(head[9] & 0x7f)
        return 10 + size + ((head[5] & 0x10) != 0 ? 10 : 0)
    }
}

/** Vorbis comments and the FLAC picture block they carry cover art in. */
public enum VorbisComment {
    /** A FLAC PICTURE block's body (also what METADATA_BLOCK_PICTURE holds, base64-encoded). */
    public static func pictureBlock(_ image: Data, width: Int = 0, height: Int = 0) -> Data {
        var w = ByteWriter()
        let mime = ID3.mimeType(image)
        w.u32be(3) // front cover
        w.u32be(UInt32(mime.utf8.count))
        w.ascii(mime)
        w.u32be(0) // description
        w.u32be(UInt32(width))
        w.u32be(UInt32(height))
        w.u32be(24)
        w.u32be(0)
        w.u32be(UInt32(image.count))
        w.data(image)
        return Data(w.bytes)
    }

    /** The comment fields, with the cover as METADATA_BLOCK_PICTURE when there is one. */
    public static func fields(_ tags: TrackTags) -> [String] {
        var out = tags.vorbisComments.map { "\($0.0)=\($0.1)" }
        if let cover = tags.cover {
            out.append("METADATA_BLOCK_PICTURE=" + pictureBlock(cover).base64EncodedString())
        }
        return out
    }

    /** A comment header body: vendor, count, fields (little-endian lengths). */
    public static func body(vendor: String, fields: [String]) -> Data {
        var w = ByteWriter()
        w.u32le(UInt32(vendor.utf8.count))
        w.ascii(vendor)
        w.u32le(UInt32(fields.count))
        for f in fields {
            w.u32le(UInt32(f.utf8.count))
            w.ascii(f)
        }
        return Data(w.bytes)
    }
}
