import Foundation

/** Text helpers for comparing titles and names across services. */
public enum TextTools {
    private static let marks = Rx(#"\p{M}+"#)
    private static let nonWord = Rx(#"[^\p{L}\p{N}]+"#)
    private static let feat = Rx(#"(?i)[(\[]\s*(feat\.?|ft\.?|featuring|with)\s[^)\]]*[)\]]"#)
    private static let featTail = Rx(#"(?i)\s+(feat\.?|ft\.?|featuring)\s.*$"#)
    private static let dashVersion = Rx(#"(?i)\s+-\s+(\d{4}\s+)?(remaster(ed)?|mono|stereo|single version|album version|original mix|bonus track).*$"#)
    private static let bracketVersion = Rx(#"(?i)[(\[][^)\]]*(remaster(ed)?|mono|stereo|single version|album version|explicit|clean)[^)\]]*[)\]]"#)
    private static let videoNoise = Rx(#"(?i)[(\[][^)\]]*(official|video|audio|lyrics?|visuali[sz]er|hd|4k|mv|m/v|clip)[^)\]]*[)\]]"#)
    private static let spaces = Rx(#"\s{2,}"#)
    private static let artistSeparators = Rx(#"(?i)\s*(,|&|\bx\b|\band\b|\bfeat\.?|\bft\.?|\bfeaturing\b|/|;)\s*"#)
    private static let dash = Rx(#"\s[-–—]\s"#)
    private static let isoDuration = Rx(#"^P(?:T)?(?:(\d+)H)?(?:(\d+)M)?(?:(\d+(?:\.\d+)?)S)?$"#)
    private static let yearStart = Rx(#"^(\d{4})"#)
    private static let decimalEntity = Rx(#"&#(\d+);"#)
    private static let hexEntity = Rx(#"&#x([0-9a-fA-F]+);"#)
    private static let unsafeFileChars = Rx(#"[\\/:*?"<>|\p{Cc}]"#)
    private static let whitespace = Rx(#"\s+"#)

    /** Lower case, no accents, "&" as "and", words separated by single spaces. */
    public static func normalize(_ text: String) -> String {
        let stripped = marks.replace(text.decomposedStringWithCanonicalMapping, with: "")
        let lowered = stripped.lowercased().replacingOccurrences(of: "&", with: " and ")
        return nonWord.replace(lowered, with: " ").trimmed()
    }

    /** A title without featured artists and remaster notes, for comparing recordings. */
    public static func coreTitle(_ title: String) -> String {
        var t = feat.replace(title, with: "")
        t = featTail.replace(t, with: "")
        t = dashVersion.replace(t, with: "")
        t = bracketVersion.replace(t, with: "")
        return normalize(t)
    }

    /** "Song (Official Music Video) [HD]" → "Song". */
    public static func stripVideoNoise(_ title: String) -> String {
        let cleaned = spaces.replace(videoNoise.replace(title, with: ""), with: " ").trimmed()
        return cleaned.isEmpty ? title : cleaned
    }

    public static func tokens(_ text: String) -> Set<String> {
        Set(normalize(text).split(separator: " ").map(String.init))
    }

    /** Dice coefficient of the word sets, falling back on letter pairs for one-word titles. */
    public static func similarity(_ a: String, _ b: String) -> Double {
        let na = normalize(a)
        let nb = normalize(b)
        if na.isEmpty || nb.isEmpty { return 0 }
        if na == nb { return 1 }
        let ta = Set(na.split(separator: " ").map(String.init))
        let tb = Set(nb.split(separator: " ").map(String.init))
        let words = 2.0 * Double(ta.intersection(tb).count) / Double(ta.count + tb.count)
        return max(words, bigramSimilarity(na, nb))
    }

    private static func pairs(_ s: String) -> [String] {
        let chars = Array(s.replacingOccurrences(of: " ", with: ""))
        guard chars.count >= 2 else { return [] }
        return (0..<(chars.count - 1)).map { String(chars[$0]) + String(chars[$0 + 1]) }
    }

    private static func bigramSimilarity(_ a: String, _ b: String) -> Double {
        let pa = pairs(a)
        var pb = pairs(b)
        let total = pa.count + pb.count
        if pa.isEmpty || pb.isEmpty { return 0 }
        var hits = 0
        for p in pa {
            if let i = pb.firstIndex(of: p) {
                hits += 1
                pb.remove(at: i)
            }
        }
        return 2.0 * Double(hits) / Double(total)
    }

    /** Artist credits split on the usual separators: "A, B & C feat. D". */
    public static func splitArtists(_ artist: String) -> [String] {
        artistSeparators.split(artist).map { $0.trimmed() }.filter { !$0.isEmpty }
    }

    /**
     * A YouTube upload's artist and title. "Artist - Title (Official Video)"
     * on an artist's own channel splits on the dash; auto-generated "Topic"
     * channels are named after the artist.
     */
    public static func artistAndTitle(_ rawTitle: String, channel: String?) -> (artist: String, title: String) {
        let cleanChannel = (channel ?? "").removingSuffix(" - Topic").removingSuffix("VEVO").trimmed()
        let title = stripVideoNoise(rawTitle)
        if let r = dash.firstRange(title), channel?.hasSuffix(" - Topic") != true {
            let left = String(title[..<r.lowerBound]).trimmed()
            let right = String(title[r.upperBound...]).trimmed()
            if !left.isEmpty && !right.isEmpty { return (left, right) }
        }
        return (cleanChannel, title)
    }

    /** "3:45" or "1:02:03" → milliseconds. */
    public static func parseClock(_ text: String?) -> Int64? {
        guard let text else { return nil }
        let parts = text.trimmed().split(separator: ":", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCIIDigitChar) }) else { return nil }
        return parts.reduce(Int64(0)) { $0 * 60 + (Int64($1) ?? 0) } * 1000
    }

    /** ISO 8601 durations as used by JSON-LD: "PT3M45S" → milliseconds. */
    public static func parseIsoDuration(_ text: String?) -> Int64? {
        guard let t = text?.trimmed(), let g = isoDuration.matchEntire(t) else { return nil }
        let h = g[1] ?? "", m = g[2] ?? "", s = g[3] ?? ""
        if h.isEmpty && m.isEmpty && s.isEmpty { return nil }
        return (Int64(h) ?? 0) * 3_600_000 + (Int64(m) ?? 0) * 60_000 + Int64((Double(s) ?? 0) * 1000)
    }

    /** The year at the start of a date such as "2019-05-17". */
    public static func year(_ date: String?) -> Int? {
        guard let date else { return nil }
        return yearStart.group(date.trimmed()).flatMap { Int($0) }
    }

    /** Unescape the few HTML entities that turn up in meta tags. */
    public static func unescapeHtml(_ text: String) -> String {
        var t = decimalEntity.replace(text) { g in
            g[1].flatMap { UInt32($0) }.flatMap { Unicode.Scalar($0) }.map { String(Character($0)) } ?? (g[0] ?? "")
        }
        t = hexEntity.replace(t) { g in
            g[1].flatMap { UInt32($0, radix: 16) }.flatMap { Unicode.Scalar($0) }.map { String(Character($0)) } ?? (g[0] ?? "")
        }
        return t
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    /** A name safe for a file on any file system. */
    public static func fileName(_ text: String, max: Int = 120) -> String {
        var cleaned = unsafeFileChars.replace(text, with: "_")
        cleaned = whitespace.replace(cleaned, with: " ").trimmed()
        cleaned = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let cut = String(cleaned.prefix(max))
        return cut.isEmpty ? "track" : cut
    }
}

extension Character {
    var isASCIIDigitChar: Bool { ("0"..."9").contains(self) }
}
