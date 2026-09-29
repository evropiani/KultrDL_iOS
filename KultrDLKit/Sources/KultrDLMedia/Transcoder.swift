import Foundation
import KultrDLCore

/**
 * Turns a downloaded stream into the format the user chose, with the
 * track's tags and cover inside — what ffmpeg and jaudiotagger do on
 * Android. Lossless formats keep the source audio exactly; they can't add
 * detail the source never had.
 */
public enum Transcoder {
    public struct Output: Sendable {
        public let file: URL
        public let fileExtension: String
    }

    /**
     * Converts [source] (whose [container] is "m4a", "webm", "mp3", "aac"…)
     * into [directory]/audio.<ext>. [progress] gets 0…1.
     */
    public static func convert(
        source: URL,
        container: String,
        preset: DownloadPreset,
        tags: TrackTags,
        directory: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> Output {
        let quality = preset.format.normalise(preset.quality)
        func out(_ ext: String) -> URL {
            let url = directory.appendingPathComponent("audio.\(ext)")
            try? FileManager.default.removeItem(at: url)
            return url
        }

        switch preset.format {
        case .original:
            return try await keepOriginal(source, container: container, tags: tags, out: out)
        case .aac where quality == .original && (container == "m4a" || container == "aac"):
            if let copied = try? await remuxM4A(source, tags: tags, out: out("m4a")) { return copied }
        case .opus where quality == .original && container == "webm":
            if let copied = try? remuxOpus(source, tags: tags, out: out("opus")) { return copied }
        default:
            break
        }

        let pcm = try await Sources.open(source, container: container)
        let ext = preset.format.fileExtension
        let target = out(ext)
        let rate = pcm.sampleRate
        let channels = pcm.channels
        let encoder: PCMEncoder
        switch preset.format {
        case .mp3:
            encoder = try MP3Encoder(url: target, sampleRate: rate, channels: channels, quality: quality, tags: tags)
        case .flac:
            encoder = try FLACEncoder(url: target, sampleRate: rate, channels: channels, bits: quality == .bit24 ? 24 : 16, tags: tags)
        case .aac:
            encoder = try M4AEncoder(url: target, codec: .aac(kbps: quality.kbps ?? 256), sampleRate: rate, channels: channels, tags: tags)
        case .alac:
            encoder = try M4AEncoder(url: target, codec: .alac(bits: quality == .bit24 ? 24 : 16), sampleRate: rate, channels: channels, tags: tags)
        case .wav:
            encoder = try WAVEncoder(url: target, sampleRate: rate, channels: channels, bits: quality == .bit24 ? 24 : 16, tags: tags)
        case .opus:
            encoder = try OpusFileEncoder(url: target, sampleRate: rate, channels: channels, kbps: quality.kbps ?? 160, tags: tags)
        case .vorbis:
            encoder = try VorbisEncoder(url: target, sampleRate: rate, channels: channels, kbps: quality.kbps ?? 256, tags: tags)
        case .original:
            throw KultrError("Unreachable")
        }

        let totalFrames = (pcm.duration ?? 0) * rate
        var frames = 0.0
        var lastReport = Date.distantPast
        while let chunk = try pcm.next() {
            try Task.checkCancellation()
            try encoder.write(chunk)
            frames += Double(chunk.count / max(1, channels))
            if totalFrames > 0, Date().timeIntervalSince(lastReport) > 0.2 {
                lastReport = Date()
                progress(min(0.99, frames / totalFrames))
            }
        }
        try await encoder.finish()
        progress(1)
        return Output(file: target, fileExtension: ext)
    }

    private static func remuxM4A(_ source: URL, tags: TrackTags, out: URL) async throws -> Output {
        try await MP4Tags.remux(source, to: out, tags: tags)
        return Output(file: out, fileExtension: "m4a")
    }

    private static func remuxOpus(_ source: URL, tags: TrackTags, out: URL) throws -> Output {
        try OpusRemuxer.remux(source, to: out, tags: tags)
        return Output(file: out, fileExtension: "opus")
    }

    /** "Original file": the stream as it came, in a container that can hold tags where there is one. */
    private static func keepOriginal(_ source: URL, container: String, tags: TrackTags, out: (String) -> URL) async throws -> Output {
        switch container {
        case "m4a", "aac":
            if let copied = try? await remuxM4A(source, tags: tags, out: out("m4a")) { return copied }
        case "webm":
            if let copied = try? remuxOpus(source, tags: tags, out: out("opus")) { return copied }
        case "mp3":
            let target = out("mp3")
            let bytes = try Data(contentsOf: source)
            let skip = ID3.tagSize([UInt8](bytes.prefix(10)))
            var data = ID3.tag(tags)
            data.append(bytes.dropFirst(skip))
            try data.write(to: target)
            return Output(file: target, fileExtension: "mp3")
        default:
            break
        }
        let ext = container.isEmpty ? "audio" : container
        let target = out(ext)
        try FileManager.default.copyItem(at: source, to: target)
        return Output(file: target, fileExtension: ext)
    }
}
