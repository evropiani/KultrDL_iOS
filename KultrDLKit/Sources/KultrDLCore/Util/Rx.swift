import Foundation

/**
 * A regular expression, compiled once. A thin layer over
 * NSRegularExpression that speaks Swift strings, so the patterns can be
 * the same as on Android.
 */
public struct Rx: @unchecked Sendable {
    let regex: NSRegularExpression

    public init(_ pattern: String, _ options: NSRegularExpression.Options = []) {
        // The patterns are constants; a bad one is a programming error.
        regex = try! NSRegularExpression(pattern: pattern, options: options)
    }

    /** Case-insensitive. */
    public static func i(_ pattern: String) -> Rx { Rx(pattern, [.caseInsensitive]) }

    /** "." matches newlines too. */
    public static func s(_ pattern: String) -> Rx { Rx(pattern, [.dotMatchesLineSeparators]) }

    /** Case-insensitive and "." matches newlines. */
    public static func si(_ pattern: String) -> Rx { Rx(pattern, [.caseInsensitive, .dotMatchesLineSeparators]) }

    private static func range(_ s: String) -> NSRange { NSRange(s.startIndex..<s.endIndex, in: s) }

    /** The first match's groups: [0] is the whole match; nil for a group that didn't take part. */
    public func find(_ s: String) -> [String?]? {
        guard let m = regex.firstMatch(in: s, range: Self.range(s)) else { return nil }
        return Self.groups(m, in: s)
    }

    /** Group [group] of the first match. */
    public func group(_ s: String, _ group: Int = 1) -> String? {
        guard let groups = find(s), group < groups.count else { return nil }
        return groups[group]
    }

    public func findAll(_ s: String) -> [[String?]] {
        regex.matches(in: s, range: Self.range(s)).map { Self.groups($0, in: s) }
    }

    /** Where the first match is, as a range of the string. */
    public func firstRange(_ s: String) -> Range<String.Index>? {
        guard let m = regex.firstMatch(in: s, range: Self.range(s)) else { return nil }
        return Range(m.range, in: s)
    }

    public func contains(_ s: String) -> Bool {
        regex.firstMatch(in: s, range: Self.range(s)) != nil
    }

    /** The whole string matches. */
    public func matches(_ s: String) -> Bool {
        guard let m = regex.firstMatch(in: s, options: [.anchored], range: Self.range(s)) else { return false }
        return m.range.location == 0 && m.range.length == (s as NSString).length
    }

    /** Groups of a match of the whole string. */
    public func matchEntire(_ s: String) -> [String?]? {
        guard matches(s) else { return nil }
        return find(s)
    }

    /** Replaces every match with a template ("$1" for groups). */
    public func replace(_ s: String, with template: String) -> String {
        regex.stringByReplacingMatches(in: s, range: Self.range(s), withTemplate: template)
    }

    /** Replaces every match with what [transform] makes of its groups. */
    public func replace(_ s: String, _ transform: ([String?]) -> String) -> String {
        let matches = regex.matches(in: s, range: Self.range(s))
        guard !matches.isEmpty else { return s }
        var out = ""
        var last = s.startIndex
        for m in matches {
            guard let r = Range(m.range, in: s) else { continue }
            out += s[last..<r.lowerBound]
            out += transform(Self.groups(m, in: s))
            last = r.upperBound
        }
        out += s[last...]
        return out
    }

    public func split(_ s: String) -> [String] {
        var parts: [String] = []
        var last = s.startIndex
        for m in regex.matches(in: s, range: Self.range(s)) {
            guard let r = Range(m.range, in: s) else { continue }
            parts.append(String(s[last..<r.lowerBound]))
            last = r.upperBound
        }
        parts.append(String(s[last...]))
        return parts
    }

    private static func groups(_ m: NSTextCheckingResult, in s: String) -> [String?] {
        (0..<m.numberOfRanges).map { i in
            let r = m.range(at: i)
            guard r.location != NSNotFound, let range = Range(r, in: s) else { return nil }
            return String(s[range])
        }
    }

    /** A literal string, escaped for use inside a pattern. */
    public static func escape(_ s: String) -> String { NSRegularExpression.escapedPattern(for: s) }
}

extension StringProtocol {
    public func trimmed() -> String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

extension String {
    /** Nil when empty. */
    public var nonEmpty: String? { isEmpty ? nil : self }

    /** The part before the first [separator], or all of it. */
    public func before(_ separator: String) -> String {
        guard let r = range(of: separator) else { return self }
        return String(self[..<r.lowerBound])
    }

    /** The part after the first [separator], or [missing] (all of it by default). */
    public func after(_ separator: String, missing: String? = nil) -> String {
        guard let r = range(of: separator) else { return missing ?? self }
        return String(self[r.upperBound...])
    }

    /** The part after the last [separator], or all of it. */
    public func afterLast(_ separator: String) -> String {
        guard let r = range(of: separator, options: .backwards) else { return self }
        return String(self[r.upperBound...])
    }

    /** The part before the last [separator], or all of it. */
    public func beforeLast(_ separator: String) -> String {
        guard let r = range(of: separator, options: .backwards) else { return self }
        return String(self[..<r.lowerBound])
    }

    public func removingPrefix(_ prefix: String) -> String {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : self
    }

    public func removingSuffix(_ suffix: String) -> String {
        hasSuffix(suffix) ? String(dropLast(suffix.count)) : self
    }

    /** Percent-encoded for a query value. */
    public var urlQueryEncoded: String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return addingPercentEncoding(withAllowedCharacters: allowed) ?? self
    }
}
