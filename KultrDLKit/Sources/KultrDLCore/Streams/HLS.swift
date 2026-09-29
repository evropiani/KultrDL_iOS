import Foundation

/** Just enough of HLS to fetch an audio stream as one file. */
public enum HLS {
    public struct Variant: Sendable {
        public let url: String
        public let bandwidth: Int
        public let codecs: String
        public let audioOnly: Bool
    }

    public struct Media: Sendable {
        /** The initialisation segment of fragmented MP4 streams. */
        public let initSegment: String?
        public let segments: [String]
        public let encrypted: Bool
        public let durationSeconds: Double
    }

    private static let bandwidthPattern = Rx(#"BANDWIDTH=(\d+)"#)
    private static let codecsPattern = Rx(#"CODECS="([^"]+)""#)
    private static let uriPattern = Rx(#"URI="([^"]+)""#)
    private static let typePattern = Rx(#"TYPE=([A-Z-]+)"#)
    private static let extinf = Rx(#"#EXTINF:([\d.]+)"#)

    public static func isMaster(_ text: String) -> Bool { text.contains("#EXT-X-STREAM-INF") }

    static func resolve(_ ref: String, base: String) -> String {
        let r = ref.trimmed()
        if r.hasPrefix("http://") || r.hasPrefix("https://") { return r }
        return URL(string: r, relativeTo: URL(string: base))?.absoluteURL.absoluteString ?? r
    }

    private static func lines(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).map { String($0).trimmed() }.filter { !$0.isEmpty }
    }

    /** The variants of a master playlist; audio-only renditions are listed too. */
    public static func variants(_ text: String, base: String) -> [Variant] {
        let all = lines(text)
        var out: [Variant] = []
        for (i, line) in all.enumerated() {
            if line.hasPrefix("#EXT-X-MEDIA"), typePattern.group(line) == "AUDIO", let uri = uriPattern.group(line) {
                // Renditions carry no bandwidth; the group's variants say what they are.
                let group = Rx(#"GROUP-ID="([^"]+)""#).group(line) ?? ""
                let related = all.filter { $0.hasPrefix("#EXT-X-STREAM-INF") && $0.contains("AUDIO=\"\(group)\"") }
                let bandwidth = related.compactMap { bandwidthPattern.group($0).flatMap { Int($0) } }.min() ?? 0
                out.append(Variant(url: resolve(uri, base: base), bandwidth: bandwidth, codecs: "mp4a", audioOnly: true))
            }
            if line.hasPrefix("#EXT-X-STREAM-INF") {
                guard let next = all[(i + 1)...].first(where: { !$0.hasPrefix("#") }) else { continue }
                let codecs = codecsPattern.group(line) ?? ""
                let audioOnly = !codecs.isEmpty && codecs.split(separator: ",").allSatisfy { c in
                    let t = String(c).trimmed()
                    return t.hasPrefix("mp4a") || t.hasPrefix("opus") || t.hasPrefix("mp3") || t.hasPrefix("ac-3") || t.hasPrefix("ec-3") || t.hasPrefix("flac")
                }
                out.append(Variant(
                    url: resolve(next, base: base),
                    bandwidth: bandwidthPattern.group(line).flatMap { Int($0) } ?? 0,
                    codecs: codecs,
                    audioOnly: audioOnly
                ))
            }
        }
        return out
    }

    /** The best audio of a master playlist: an audio-only rendition if there is one, else the smallest variant with sound. */
    public static func bestAudio(_ text: String, base: String) -> Variant? {
        let all = variants(text, base: base)
        if let audio = all.filter(\.audioOnly).max(by: { $0.bandwidth < $1.bandwidth }) { return audio }
        return all.min { $0.bandwidth < $1.bandwidth }
    }

    public static func media(_ text: String, base: String) -> Media {
        let all = lines(text)
        let encrypted = all.contains { $0.hasPrefix("#EXT-X-KEY") && !$0.contains("METHOD=NONE") }
        let map = all.first { $0.hasPrefix("#EXT-X-MAP") }.flatMap { uriPattern.group($0) }.map { resolve($0, base: base) }
        let segments = all.filter { !$0.hasPrefix("#") }.map { resolve($0, base: base) }
        let duration = all.compactMap { extinf.group($0).flatMap { Double($0) } }.reduce(0, +)
        return Media(initSegment: map, segments: segments, encrypted: encrypted, durationSeconds: duration)
    }
}
