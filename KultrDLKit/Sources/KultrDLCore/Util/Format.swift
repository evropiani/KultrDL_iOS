import Foundation

public enum Format {
    /** "3:45" or "1:02:03"; empty for an unknown length. */
    public static func duration(_ ms: Int64?) -> String {
        guard let ms, ms > 0 else { return "" }
        return clock(Int(ms / 1000))
    }

    /** "3:45" from seconds, "0:00" for nothing. */
    public static func time(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        return clock(Int(seconds))
    }

    public static func timeMs(_ ms: Int64) -> String { time(Double(ms) / 1000) }

    private static func clock(_ total: Int) -> String {
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    /** "1 track", "12 tracks". */
    public static func count(_ n: Int, _ word: String) -> String { n == 1 ? "1 \(word)" : "\(n) \(word)s" }

    public static func count(_ n: Int?, _ word: String) -> String { count(n ?? 0, word) }

    public static func bytes(_ n: Int64) -> String {
        let gb = Int64(1) << 30, mb = Int64(1) << 20, kb = Int64(1) << 10
        if n >= gb { return String(format: "%.1f GB", Double(n) / Double(gb)) }
        if n >= mb { return String(format: "%.1f MB", Double(n) / Double(mb)) }
        if n >= kb { return String(format: "%.0f KB", Double(n) / Double(kb)) }
        return "\(n) B"
    }

    public static func greeting(_ hour: Int) -> String {
        switch hour {
        case 5...11: return "Good morning"
        case 12...17: return "Good afternoon"
        case 18...22: return "Good evening"
        default: return "Up late"
        }
    }

    public static func initials(_ text: String) -> String {
        let words = text.split(whereSeparator: { $0.isWhitespace }).prefix(2)
        let letters = words.compactMap { $0.first.map { String($0).uppercased() } }.joined()
        return letters.isEmpty ? "♪" : letters
    }
}
