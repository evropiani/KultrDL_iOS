import Foundation

/** A bitrate or bit depth to download at. */
public enum Quality: String, Codable, CaseIterable, Sendable, Hashable {
    case original = "ORIGINAL"
    case k320 = "K320"
    case k256 = "K256"
    case k192 = "K192"
    case k160 = "K160"
    case k128 = "K128"
    case k96 = "K96"
    case v0 = "V0"
    case bit16 = "BIT16"
    case bit24 = "BIT24"

    public var label: String {
        switch self {
        case .original: return "Original, no re-encode"
        case .k320: return "320 kbps"
        case .k256: return "256 kbps"
        case .k192: return "192 kbps"
        case .k160: return "160 kbps"
        case .k128: return "128 kbps"
        case .k96: return "96 kbps"
        case .v0: return "VBR V0 (~245 kbps)"
        case .bit16: return "16-bit"
        case .bit24: return "24-bit"
        }
    }

    /** Kilobits per second for the fixed bitrates. */
    public var kbps: Int? {
        switch self {
        case .k320: return 320
        case .k256: return 256
        case .k192: return 192
        case .k160: return 160
        case .k128: return 128
        case .k96: return 96
        default: return nil
        }
    }

    public init(from decoder: Decoder) throws {
        self = Quality(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .k320
    }
}

/**
 * The file formats KultrDL writes. The best audio the source has is
 * fetched and converted; lossless formats keep that audio exactly (they
 * can't add detail the source never had).
 */
public enum AudioFormat: String, Codable, CaseIterable, Sendable, Hashable {
    case flac = "FLAC"
    case mp3 = "MP3"
    case aac = "AAC"
    case opus = "OPUS"
    case alac = "ALAC"
    case wav = "WAV"
    case vorbis = "VORBIS"
    case original = "ORIGINAL"

    public var label: String {
        switch self {
        case .flac: return "FLAC"
        case .mp3: return "MP3"
        case .aac: return "AAC (M4A)"
        case .opus: return "Opus"
        case .alac: return "ALAC (M4A)"
        case .wav: return "WAV"
        case .vorbis: return "Ogg Vorbis"
        case .original: return "Original file"
        }
    }

    public var fileExtension: String {
        switch self {
        case .flac: return "flac"
        case .mp3: return "mp3"
        case .aac, .alac: return "m4a"
        case .opus: return "opus"
        case .wav: return "wav"
        case .vorbis: return "ogg"
        case .original: return ""
        }
    }

    public var lossless: Bool { self == .flac || self == .alac || self == .wav }

    public var qualities: [Quality] {
        switch self {
        case .flac, .alac, .wav: return [.bit16, .bit24]
        case .mp3: return [.k320, .v0, .k256, .k192, .k128]
        case .aac: return [.original, .k256, .k192, .k128]
        case .opus: return [.original, .k160, .k128, .k96]
        case .vorbis: return [.k320, .k256, .k192, .k128]
        case .original: return [.original]
        }
    }

    public func normalise(_ quality: Quality) -> Quality { qualities.contains(quality) ? quality : qualities[0] }

    public static func mimeType(_ ext: String) -> String {
        switch ext.lowercased() {
        case "flac": return "audio/flac"
        case "mp3": return "audio/mpeg"
        case "m4a", "mp4", "aac", "alac": return "audio/mp4"
        case "opus", "ogg", "oga": return "audio/ogg"
        case "wav": return "audio/wav"
        case "webm", "weba": return "audio/webm"
        default: return "audio/*"
        }
    }

    public init(from decoder: Decoder) throws {
        self = AudioFormat(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .mp3
    }
}

public struct DownloadPreset: Codable, Hashable, Sendable {
    public var format: AudioFormat
    public var quality: Quality

    public init(format: AudioFormat = .mp3, quality: Quality = .k320) {
        self.format = format
        self.quality = quality
    }

    public var label: String {
        format == .original ? format.label : "\(format.label) · \(format.normalise(quality).label)"
    }

    /** Which source stream suits this preset best. */
    public var preferredCodec: PreferredCodec {
        let q = format.normalise(quality)
        switch format {
        case .aac where q == .original: return .aac
        case .opus where q == .original: return .opus
        default: return .best
        }
    }
}
