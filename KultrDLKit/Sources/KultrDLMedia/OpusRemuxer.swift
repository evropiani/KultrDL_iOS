import Foundation
import KultrDLCore
import ogg
import opus

/**
 * Moves the Opus packets of a WebM file into an Ogg Opus file untouched
 * (Opus "original"): the same audio, bit for bit, in the container music
 * players expect, with tags and cover.
 */
enum OpusRemuxer {
    static func remux(_ source: URL, to output: URL, tags: TrackTags) throws {
        let audio = try WebMAudio.read(source)
        guard audio.isOpus else { throw KultrError("The source isn't Opus.") }
        var head = [UInt8](audio.codecPrivate)
        if head.count < 19 || !head.starts(with: Array("OpusHead".utf8)) {
            // Build the identification header from the WebM track.
            let preSkip = UInt16(clamping: audio.codecDelayNs * 48000 / 1_000_000_000)
            head = Array("OpusHead".utf8) + [1, UInt8(audio.channels), UInt8(preSkip & 0xff), UInt8(preSkip >> 8)]
            let rate = UInt32(audio.sampleRate)
            head += [UInt8(rate & 0xff), UInt8((rate >> 8) & 0xff), UInt8((rate >> 16) & 0xff), UInt8(rate >> 24), 0, 0, 0]
        }
        let preSkip = Int64(head[10]) | Int64(head[11]) << 8
        let tagsPacket = Array("OpusTags".utf8) + [UInt8](VorbisComment.body(vendor: "KultrDL", fields: VorbisComment.fields(tags)))

        let stream = UnsafeMutablePointer<ogg_stream_state>.allocate(capacity: 1)
        let page = UnsafeMutablePointer<ogg_page>.allocate(capacity: 1)
        defer {
            ogg_stream_clear(stream)
            stream.deallocate()
            page.deallocate()
        }
        ogg_stream_init(stream, Int32.random(in: 1...Int32.max))
        FileManager.default.createFile(atPath: output.path, contents: nil)
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }

        func writePages(flush: Bool) throws {
            while (flush ? ogg_stream_flush(stream, page) : ogg_stream_pageout(stream, page)) != 0 {
                let p = page.pointee
                try handle.write(contentsOf: UnsafeBufferPointer(start: p.header, count: p.header_len))
                try handle.write(contentsOf: UnsafeBufferPointer(start: p.body, count: p.body_len))
            }
        }

        func packetIn(_ bytes: [UInt8], number: Int64, granule: Int64, bos: Bool = false, eos: Bool = false) {
            var copy = bytes
            copy.withUnsafeMutableBufferPointer { buffer in
                var packet = ogg_packet()
                packet.packet = buffer.baseAddress
                packet.bytes = buffer.count
                packet.b_o_s = bos ? 1 : 0
                packet.e_o_s = eos ? 1 : 0
                packet.granulepos = granule
                packet.packetno = number
                ogg_stream_packetin(stream, &packet)
            }
        }

        // The identification header alone on the first page, the comment header ending its own.
        packetIn(head, number: 0, granule: 0, bos: true)
        try writePages(flush: true)
        packetIn(tagsPacket, number: 1, granule: 0)
        try writePages(flush: true)

        let padding = audio.discardPaddingNs * 48000 / 1_000_000_000
        var total: Int64 = 0
        let lengths: [Int64] = audio.packets.map { packet in
            packet.data.withUnsafeBytes { raw -> Int64 in
                guard let base = raw.bindMemory(to: UInt8.self).baseAddress, raw.count > 0 else { return 0 }
                return Int64(max(0, opus_packet_get_nb_samples(base, Int32(raw.count), 48000)))
            }
        }
        let end = max(preSkip, lengths.reduce(0, +) - padding)
        for (i, packet) in audio.packets.enumerated() {
            total += lengths[i]
            let last = i == audio.packets.count - 1
            packetIn([UInt8](packet.data), number: Int64(i + 2), granule: last ? end : total, eos: last)
            try writePages(flush: false)
        }
        try writePages(flush: true)
    }
}
