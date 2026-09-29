import AVFoundation
import COpusShim
import FLAC
import Foundation
import KultrDLCore
import lame
import ogg
import opus
import opus.enc
import vorbis

/** Takes interleaved float samples and writes a finished, tagged file. */
protocol PCMEncoder: AnyObject {
    func write(_ samples: [Float]) throws
    func finish() async throws
}

// ------------------------------------------------------------------ MP3 --

/** MP3 through LAME, with an ID3v2.4 tag in front and a LAME/Xing header so players see the right length. */
final class MP3Encoder: PCMEncoder {
    private let lame: OpaquePointer
    private let handle: FileHandle
    private let channels: Int
    private let tagEnd: UInt64
    private var buffer: [UInt8]

    init(url: URL, sampleRate: Double, channels: Int, quality: Quality, tags: TrackTags) throws {
        guard let gf = lame_init() else { throw KultrError("The MP3 encoder couldn't start.") }
        lame = gf
        self.channels = channels
        lame_set_in_samplerate(gf, Int32(sampleRate))
        lame_set_num_channels(gf, Int32(channels))
        lame_set_mode(gf, channels == 1 ? MONO : JOINT_STEREO)
        lame_set_quality(gf, 2)
        lame_set_write_id3tag_automatic(gf, 0)
        lame_set_bWriteVbrTag(gf, 1)
        if quality == .v0 {
            lame_set_VBR(gf, vbr_mtrh)
            lame_set_VBR_quality(gf, 0)
        } else {
            lame_set_VBR(gf, vbr_off)
            lame_set_brate(gf, Int32(quality.kbps ?? 320))
        }
        guard lame_init_params(gf) >= 0 else {
            lame_close(gf)
            throw KultrError("The MP3 encoder refused these settings.")
        }
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
        let tag = ID3.tag(tags)
        try handle.write(contentsOf: tag)
        tagEnd = UInt64(tag.count)
        buffer = [UInt8](repeating: 0, count: 1 << 16)
    }

    deinit {
        lame_close(lame)
    }

    func write(_ samples: [Float]) throws {
        let frames = samples.count / channels
        guard frames > 0 else { return }
        let needed = frames * 5 / 4 + 7200
        if buffer.count < needed { buffer = [UInt8](repeating: 0, count: needed) }
        let size = buffer.count
        let written: Int32 = samples.withUnsafeBufferPointer { pcm in
            buffer.withUnsafeMutableBufferPointer { out in
                if channels == 1 {
                    return lame_encode_buffer_ieee_float(lame, pcm.baseAddress, nil, Int32(frames), out.baseAddress, Int32(size))
                }
                return lame_encode_buffer_interleaved_ieee_float(lame, pcm.baseAddress, Int32(frames), out.baseAddress, Int32(size))
            }
        }
        guard written >= 0 else { throw KultrError("MP3 encoding failed (\(written)).") }
        if written > 0 { try handle.write(contentsOf: buffer[0..<Int(written)]) }
    }

    func finish() async throws {
        let size = buffer.count
        let flushed = buffer.withUnsafeMutableBufferPointer { lame_encode_flush(lame, $0.baseAddress, Int32(size)) }
        if flushed > 0 { try handle.write(contentsOf: buffer[0..<Int(flushed)]) }
        // The first frame was a placeholder for the LAME/Xing header, which only now knows the length.
        var tagFrame = [UInt8](repeating: 0, count: 2880)
        let tagSize = tagFrame.withUnsafeMutableBufferPointer { lame_get_lametag_frame(lame, $0.baseAddress, $0.count) }
        if tagSize > 0 && tagSize <= tagFrame.count {
            try handle.seek(toOffset: tagEnd)
            try handle.write(contentsOf: tagFrame[0..<tagSize])
        }
        try handle.close()
    }
}

// ----------------------------------------------------------------- FLAC --

/** FLAC through libFLAC, with Vorbis comments and the cover as a PICTURE block. */
final class FLACEncoder: PCMEncoder {
    private let encoder: UnsafeMutablePointer<FLAC__StreamEncoder>
    private var blocks: [UnsafeMutablePointer<FLAC__StreamMetadata>?] = []
    private let channels: Int
    private let bits: Int
    private var ints: [Int32] = []

    init(url: URL, sampleRate: Double, channels: Int, bits: Int, tags: TrackTags) throws {
        guard let enc = FLAC__stream_encoder_new() else { throw KultrError("The FLAC encoder couldn't start.") }
        encoder = enc
        self.channels = channels
        self.bits = bits
        FLAC__stream_encoder_set_verify(enc, 0)
        FLAC__stream_encoder_set_compression_level(enc, 5)
        FLAC__stream_encoder_set_channels(enc, UInt32(channels))
        FLAC__stream_encoder_set_bits_per_sample(enc, UInt32(bits))
        FLAC__stream_encoder_set_sample_rate(enc, UInt32(sampleRate))

        if let comments = FLAC__metadata_object_new(FLAC__METADATA_TYPE_VORBIS_COMMENT) {
            for (name, value) in tags.vorbisComments {
                var entry = FLAC__StreamMetadata_VorbisComment_Entry()
                if FLAC__metadata_object_vorbiscomment_entry_from_name_value_pair(&entry, name, value) != 0 {
                    _ = FLAC__metadata_object_vorbiscomment_append_comment(comments, entry, 0)
                }
            }
            blocks.append(comments)
        }
        if let cover = tags.cover, let picture = FLAC__metadata_object_new(FLAC__METADATA_TYPE_PICTURE) {
            let size = CoverArt.size(cover)
            picture.pointee.data.picture.type = FLAC__STREAM_METADATA_PICTURE_TYPE_FRONT_COVER
            picture.pointee.data.picture.width = UInt32(size.width)
            picture.pointee.data.picture.height = UInt32(size.height)
            picture.pointee.data.picture.depth = 24
            var mime = Array(ID3.mimeType(cover).utf8CString)
            _ = mime.withUnsafeMutableBufferPointer { FLAC__metadata_object_picture_set_mime_type(picture, $0.baseAddress, 1) }
            var bytes = [UInt8](cover)
            _ = bytes.withUnsafeMutableBufferPointer { FLAC__metadata_object_picture_set_data(picture, $0.baseAddress, UInt32($0.count), 1) }
            blocks.append(picture)
        }
        if let padding = FLAC__metadata_object_new(FLAC__METADATA_TYPE_PADDING) {
            padding.pointee.length = 1024
            blocks.append(padding)
        }
        if !blocks.isEmpty {
            _ = blocks.withUnsafeMutableBufferPointer { FLAC__stream_encoder_set_metadata(enc, $0.baseAddress, UInt32($0.count)) }
        }
        let status = FLAC__stream_encoder_init_file(enc, url.path, nil, nil)
        guard status == FLAC__STREAM_ENCODER_INIT_STATUS_OK else {
            FLAC__stream_encoder_delete(enc)
            for b in blocks { FLAC__metadata_object_delete(b) }
            throw KultrError("The FLAC encoder couldn't open its file (\(status.rawValue)).")
        }
    }

    func write(_ samples: [Float]) throws {
        let frames = samples.count / channels
        guard frames > 0 else { return }
        let scale: Float = bits == 24 ? 8_388_607 : 32767
        if ints.count < samples.count { ints = [Int32](repeating: 0, count: samples.count) }
        for i in 0..<samples.count {
            ints[i] = Int32((max(-1, min(1, samples[i])) * scale).rounded())
        }
        let ok = ints.withUnsafeBufferPointer { FLAC__stream_encoder_process_interleaved(encoder, $0.baseAddress, UInt32(frames)) }
        guard ok != 0 else { throw KultrError("FLAC encoding failed.") }
    }

    func finish() async throws {
        let ok = FLAC__stream_encoder_finish(encoder)
        FLAC__stream_encoder_delete(encoder)
        for b in blocks { FLAC__metadata_object_delete(b) }
        blocks = []
        guard ok != 0 else { throw KultrError("The FLAC file couldn't be finished.") }
    }
}

// ----------------------------------------------------------------- Opus --

/** Ogg Opus through libopusenc (which resamples to 48 kHz itself), tags and cover included. */
final class OpusFileEncoder: PCMEncoder {
    private let encoder: OpaquePointer
    private let comments: OpaquePointer
    private let channels: Int

    init(url: URL, sampleRate: Double, channels: Int, kbps: Int, tags: TrackTags) throws {
        guard let c = ope_comments_create() else { throw KultrError("The Opus encoder couldn't start.") }
        comments = c
        for (name, value) in tags.vorbisComments { ope_comments_add(c, name, value) }
        if let cover = tags.cover {
            _ = cover.withUnsafeBytes { raw in
                ope_comments_add_picture_from_memory(c, raw.bindMemory(to: CChar.self).baseAddress, raw.count, 3, nil)
            }
        }
        var error: Int32 = 0
        guard let e = ope_encoder_create_file(url.path, c, Int32(sampleRate), Int32(channels), 0, &error), error == 0 else {
            ope_comments_destroy(c)
            throw KultrError("The Opus encoder couldn't open its file (\(error)).")
        }
        encoder = e
        self.channels = channels
        let raw = UnsafeMutableRawPointer(e)
        _ = kdl_ope_set_bitrate(raw, Int32(kbps * 1000))
        _ = kdl_ope_set_vbr(raw, 1)
        _ = kdl_ope_set_complexity(raw, 10)
        _ = kdl_ope_set_music(raw)
    }

    func write(_ samples: [Float]) throws {
        let frames = samples.count / channels
        guard frames > 0 else { return }
        let result = samples.withUnsafeBufferPointer { ope_encoder_write_float(encoder, $0.baseAddress, Int32(frames)) }
        guard result == 0 else { throw KultrError("Opus encoding failed (\(result)).") }
    }

    func finish() async throws {
        let result = ope_encoder_drain(encoder)
        ope_encoder_destroy(encoder)
        ope_comments_destroy(comments)
        guard result == 0 else { throw KultrError("The Opus file couldn't be finished (\(result)).") }
    }
}

// --------------------------------------------------------------- Vorbis --

/** Ogg Vorbis through libvorbis and libogg. */
final class VorbisEncoder: PCMEncoder {
    private let info = UnsafeMutablePointer<vorbis_info>.allocate(capacity: 1)
    private let comment = UnsafeMutablePointer<vorbis_comment>.allocate(capacity: 1)
    private let dsp = UnsafeMutablePointer<vorbis_dsp_state>.allocate(capacity: 1)
    private let block = UnsafeMutablePointer<vorbis_block>.allocate(capacity: 1)
    private let stream = UnsafeMutablePointer<ogg_stream_state>.allocate(capacity: 1)
    private let page = UnsafeMutablePointer<ogg_page>.allocate(capacity: 1)
    private let packet = UnsafeMutablePointer<ogg_packet>.allocate(capacity: 1)
    private let handle: FileHandle
    private let channels: Int
    private var finished = false

    init(url: URL, sampleRate: Double, channels: Int, kbps: Int, tags: TrackTags) throws {
        self.channels = channels
        vorbis_info_init(info)
        // Managed average bitrate, as ffmpeg's -b:a gives.
        guard vorbis_encode_init(info, channels, Int(sampleRate), -1, kbps * 1000, -1) == 0 else {
            vorbis_info_clear(info)
            Self.release([UnsafeMutableRawPointer(info), UnsafeMutableRawPointer(comment), UnsafeMutableRawPointer(dsp), UnsafeMutableRawPointer(block), UnsafeMutableRawPointer(stream), UnsafeMutableRawPointer(page), UnsafeMutableRawPointer(packet)])
            throw KultrError("The Vorbis encoder refused \(kbps) kbps at this sample rate.")
        }
        vorbis_comment_init(comment)
        for field in VorbisComment.fields(tags) {
            let (name, value) = (field.before("="), field.after("="))
            name.withCString { n in
                value.withCString { v in
                    vorbis_comment_add_tag(comment, UnsafeMutablePointer(mutating: n), UnsafeMutablePointer(mutating: v))
                }
            }
        }
        vorbis_analysis_init(dsp, info)
        vorbis_block_init(dsp, block)
        ogg_stream_init(stream, Int32.random(in: 1...Int32.max))

        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)

        var header = ogg_packet()
        var headerComment = ogg_packet()
        var headerCode = ogg_packet()
        vorbis_analysis_headerout(dsp, comment, &header, &headerComment, &headerCode)
        ogg_stream_packetin(stream, &header)
        ogg_stream_packetin(stream, &headerComment)
        ogg_stream_packetin(stream, &headerCode)
        // The audio starts on a fresh page.
        while ogg_stream_flush(stream, page) != 0 { try writePage() }
    }

    private static func release(_ pointers: [UnsafeMutableRawPointer]) {
        for p in pointers { p.deallocate() }
    }

    private func writePage() throws {
        let p = page.pointee
        try handle.write(contentsOf: UnsafeBufferPointer(start: p.header, count: p.header_len))
        try handle.write(contentsOf: UnsafeBufferPointer(start: p.body, count: p.body_len))
    }

    private func drain() throws {
        while vorbis_analysis_blockout(dsp, block) == 1 {
            vorbis_analysis(block, nil)
            vorbis_bitrate_addblock(block)
            while vorbis_bitrate_flushpacket(dsp, packet) != 0 {
                ogg_stream_packetin(stream, packet)
                while ogg_stream_pageout(stream, page) != 0 {
                    try writePage()
                    if ogg_page_eos(page) != 0 { break }
                }
            }
        }
    }

    func write(_ samples: [Float]) throws {
        let frames = samples.count / channels
        guard frames > 0 else { return }
        guard let buffers = vorbis_analysis_buffer(dsp, Int32(frames)) else { throw KultrError("Vorbis encoding failed.") }
        for c in 0..<channels {
            guard let out = buffers[c] else { continue }
            for i in 0..<frames { out[i] = samples[i * channels + c] }
        }
        vorbis_analysis_wrote(dsp, Int32(frames))
        try drain()
    }

    func finish() async throws {
        vorbis_analysis_wrote(dsp, 0)
        try drain()
        while ogg_stream_flush(stream, page) != 0 { try writePage() }
        try handle.close()
        cleanUp()
    }

    private func cleanUp() {
        guard !finished else { return }
        finished = true
        ogg_stream_clear(stream)
        vorbis_block_clear(block)
        vorbis_dsp_clear(dsp)
        vorbis_comment_clear(comment)
        vorbis_info_clear(info)
        Self.release([UnsafeMutableRawPointer(info), UnsafeMutableRawPointer(comment), UnsafeMutableRawPointer(dsp), UnsafeMutableRawPointer(block), UnsafeMutableRawPointer(stream), UnsafeMutableRawPointer(page), UnsafeMutableRawPointer(packet)])
    }

    deinit {
        cleanUp()
    }
}

// ------------------------------------------------------- AAC and ALAC --

/** AAC or ALAC in an M4A file through AVAssetWriter, with iTunes-style tags. */
final class M4AEncoder: PCMEncoder {
    enum Codec {
        case aac(kbps: Int)
        case alac(bits: Int)
    }

    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let format: CMAudioFormatDescription
    private let channels: Int
    private let sampleRate: Double
    private var position: Int64 = 0

    init(url: URL, codec: Codec, sampleRate: Double, channels: Int, tags: TrackTags) throws {
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
        writer.metadata = MP4Tags.items(tags)
        var settings: [String: Any] = [
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
        ]
        switch codec {
        case .aac(let kbps):
            settings[AVFormatIDKey] = kAudioFormatMPEG4AAC
            settings[AVEncoderBitRateKey] = (channels == 1 ? min(kbps, 192) : kbps) * 1000
        case .alac(let bits):
            settings[AVFormatIDKey] = kAudioFormatAppleLossless
            settings[AVEncoderBitDepthHintKey] = bits
        }
        var layout = AudioChannelLayout()
        layout.mChannelLayoutTag = channels == 1 ? kAudioChannelLayoutTag_Mono : kAudioChannelLayoutTag_Stereo
        settings[AVChannelLayoutKey] = Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)
        input = AVAssetWriterInput(mediaType: .audio, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        guard writer.canAdd(input) else { throw KultrError("M4A can't hold this audio.") }
        writer.add(input)

        var asbd = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(4 * channels),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(4 * channels),
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var description: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &description
        )
        guard status == noErr, let description else { throw KultrError("The M4A writer couldn't describe the audio (\(status)).") }
        format = description
        self.channels = channels
        self.sampleRate = sampleRate
        guard writer.startWriting() else { throw writer.error ?? KultrError("The M4A writer couldn't start.") }
        writer.startSession(atSourceTime: .zero)
    }

    func write(_ samples: [Float]) throws {
        let frames = samples.count / channels
        guard frames > 0 else { return }
        let bytes = frames * channels * 4
        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes, blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil, offsetToData: 0, dataLength: bytes, flags: 0, blockBufferOut: &block
        )
        guard status == kCMBlockBufferNoErr, let block else { throw KultrError("Out of memory while writing M4A.") }
        status = samples.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes)
        }
        guard status == kCMBlockBufferNoErr else { throw KultrError("Writing M4A failed (\(status)).") }
        var sample: CMSampleBuffer?
        status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: frames,
            presentationTimeStamp: CMTime(value: position, timescale: CMTimeScale(sampleRate)),
            packetDescriptions: nil, sampleBufferOut: &sample
        )
        guard status == noErr, let sample else { throw KultrError("Writing M4A failed (\(status)).") }
        while !input.isReadyForMoreMediaData {
            if writer.status == .failed { throw writer.error ?? KultrError("The M4A writer stopped.") }
            Thread.sleep(forTimeInterval: 0.005)
        }
        guard input.append(sample) else { throw writer.error ?? KultrError("The M4A writer refused the audio.") }
        position += Int64(frames)
    }

    func finish() async throws {
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? KultrError("The M4A file couldn't be finished.") }
    }
}

/** WAV, through the writer in the core package. */
final class WAVEncoder: PCMEncoder {
    private let writer: WAVWriter

    init(url: URL, sampleRate: Double, channels: Int, bits: Int, tags: TrackTags) throws {
        writer = try WAVWriter(url: url, sampleRate: Int(sampleRate), channels: channels, bits: bits, tags: tags)
    }

    func write(_ samples: [Float]) throws {
        try samples.withUnsafeBufferPointer { try writer.write($0) }
    }

    func finish() async throws {
        try writer.finish()
    }
}
