import AVFoundation
import Foundation
import KultrDLCore
import opus

/** Decoded audio, read in chunks of interleaved float samples (-1…1). */
protocol PCMSource: AnyObject {
    var sampleRate: Double { get }
    var channels: Int { get }
    /** Seconds, when known, for progress. */
    var duration: Double? { get }
    /** The next chunk, or nil at the end. */
    func next() throws -> [Float]?
}

/** Anything AVFoundation reads: MP4/M4A (AAC, ALAC), MP3, ADTS AAC, WAV, AIFF, CAF, FLAC. */
final class AssetPCMSource: PCMSource {
    let sampleRate: Double
    let channels: Int
    let duration: Double?
    private let reader: AVAssetReader
    private let output: AVAssetReaderTrackOutput

    private init(reader: AVAssetReader, output: AVAssetReaderTrackOutput, sampleRate: Double, channels: Int, duration: Double?) {
        self.reader = reader
        self.output = output
        self.sampleRate = sampleRate
        self.channels = channels
        self.duration = duration
    }

    static func open(_ url: URL) async throws -> AssetPCMSource {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
            throw KultrError("The downloaded file has no audio AVFoundation can read.")
        }
        let descriptions = try await track.load(.formatDescriptions)
        let asbd = descriptions.first.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
        let rate = (asbd?.mSampleRate ?? 0) > 0 ? asbd!.mSampleRate : 44100
        let sourceChannels = Int(asbd?.mChannelsPerFrame ?? 2)
        let channels = min(2, max(1, sourceChannels))
        var settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
            AVSampleRateKey: rate,
            AVNumberOfChannelsKey: channels,
        ]
        if sourceChannels > 2 {
            // Down to stereo: tell the reader which two channels it makes.
            var layout = AudioChannelLayout()
            layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo
            settings[AVChannelLayoutKey] = Data(bytes: &layout, count: MemoryLayout<AudioChannelLayout>.size)
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw KultrError("The downloaded audio can't be decoded.") }
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? KultrError("The downloaded audio can't be decoded.")
        }
        let seconds = try? await asset.load(.duration).seconds
        return AssetPCMSource(reader: reader, output: output, sampleRate: rate, channels: channels, duration: seconds.flatMap { $0.isFinite ? $0 : nil })
    }

    func next() throws -> [Float]? {
        while true {
            guard let buffer = output.copyNextSampleBuffer() else {
                if reader.status == .failed { throw reader.error ?? KultrError("Decoding the audio failed.") }
                return nil
            }
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            guard length > 0 else { continue }
            var samples = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
            let status = samples.withUnsafeMutableBytes { raw in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: raw.count, destination: raw.baseAddress!)
            }
            guard status == kCMBlockBufferNoErr else { throw KultrError("Decoding the audio failed (\(status)).") }
            return samples
        }
    }

    deinit {
        if reader.status == .reading { reader.cancelReading() }
    }
}

/** YouTube's Opus audio in WebM, decoded with libopus. */
final class WebMOpusSource: PCMSource {
    let sampleRate: Double = 48000
    let channels: Int
    let duration: Double?
    private let audio: WebMAudio
    private let decoder: OpaquePointer
    private var index = 0
    private var skip: Int
    private let padding: Int
    private var held: [Float]?
    private var output: [Float]

    init(url: URL) throws {
        audio = try WebMAudio.read(url)
        guard audio.isOpus else { throw KultrError("The WebM file isn't Opus audio (\(audio.codecId)).") }
        let head = [UInt8](audio.codecPrivate)
        let headChannels = head.count >= 10 ? Int(head[9]) : audio.channels
        guard (1...2).contains(headChannels) else { throw KultrError("Opus with \(headChannels) channels isn't supported.") }
        channels = headChannels
        if head.count >= 12 {
            skip = Int(head[10]) | Int(head[11]) << 8
        } else {
            skip = Int(audio.codecDelayNs * 48000 / 1_000_000_000)
        }
        padding = Int(audio.discardPaddingNs * 48000 / 1_000_000_000)
        duration = audio.durationNs.map { Double($0) / 1_000_000_000 }
        var error: Int32 = 0
        guard let d = opus_decoder_create(48000, Int32(headChannels), &error), error == OPUS_OK else {
            throw KultrError("The Opus decoder couldn't start (\(error)).")
        }
        decoder = d
        output = [Float](repeating: 0, count: 5760 * headChannels)
    }

    deinit {
        opus_decoder_destroy(decoder)
    }

    private func decodeNext() throws -> [Float]? {
        while index < audio.packets.count {
            let packet = audio.packets[index].data
            index += 1
            let count: Int32 = packet.withUnsafeBytes { raw in
                output.withUnsafeMutableBufferPointer { out in
                    opus_decode_float(decoder, raw.bindMemory(to: UInt8.self).baseAddress, Int32(raw.count), out.baseAddress!, 5760, 0)
                }
            }
            if count < 0 { continue } // A damaged packet: carry on, as players do.
            var frames = Int(count)
            var start = 0
            if skip > 0 {
                let dropped = min(skip, frames)
                skip -= dropped
                start = dropped
                frames -= dropped
            }
            if frames <= 0 { continue }
            return Array(output[(start * channels)..<((start + frames) * channels)])
        }
        return nil
    }

    func next() throws -> [Float]? {
        // One chunk is held back, so the padding at the very end can be cut from it.
        if held == nil { held = try decodeNext() }
        guard let current = held else { return nil }
        let following = try decodeNext()
        held = following
        if following == nil, padding > 0 {
            let keep = max(0, current.count / channels - padding)
            return Array(current.prefix(keep * channels))
        }
        return current
    }
}

enum Sources {
    /** A decoder for a downloaded file. */
    static func open(_ url: URL, container: String) async throws -> PCMSource {
        if container == "webm" {
            do {
                return try WebMOpusSource(url: url)
            } catch {
                // Not Opus after all: nothing else here reads WebM.
                throw error
            }
        }
        return try await AssetPCMSource.open(url)
    }
}
