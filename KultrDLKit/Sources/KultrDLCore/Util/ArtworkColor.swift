import Foundation

/**
 * The colour the interface takes from whatever is playing.
 *
 * Works on packed ARGB pixels from a small downscaled copy of the artwork:
 * bucket colours coarsely and pick the most common one that is neither
 * near-black, near-white nor fully desaturated, then lift it into a range
 * that reads as an accent.
 */
public enum ArtworkColor {
    public static func dominant(_ pixels: [UInt32]) -> UInt32? {
        var counts: [UInt32: (n: Int, r: Int, g: Int, b: Int)] = [:]
        for argb in pixels {
            let alpha = (argb >> 24) & 0xff
            if alpha < 200 { continue }
            let r = Int((argb >> 16) & 0xff)
            let g = Int((argb >> 8) & 0xff)
            let b = Int(argb & 0xff)
            let hi = max(r, g, b)
            let lo = min(r, g, b)
            let luma = 0.2126 * Double(r) + 0.7152 * Double(g) + 0.0722 * Double(b)
            if luma < 28 || luma > 235 { continue }
            let saturation = hi == 0 ? 0 : Double(hi - lo) / Double(hi)
            if saturation < 0.12 { continue }
            let key = UInt32((r >> 4) << 8 | (g >> 4) << 4 | (b >> 4))
            var bucket = counts[key] ?? (0, 0, 0, 0)
            bucket.n += 1
            bucket.r += r
            bucket.g += g
            bucket.b += b
            counts[key] = bucket
        }
        guard let best = counts.values.max(by: { $0.n < $1.n }) else { return nil }
        return lift(best.r / best.n, best.g / best.n, best.b / best.n)
    }

    /** Nudge a sampled colour into a range that still reads as an accent. */
    public static func lift(_ r: Int, _ g: Int, _ b: Int) -> UInt32 {
        let luma = 0.2126 * Double(r) + 0.7152 * Double(g) + 0.0722 * Double(b)
        var scale = 1.0
        if luma < 90 { scale = 90 / max(luma, 1) }
        if luma > 200 { scale = 200 / luma }
        return rgb(
            min(255, Int((Double(r) * scale).rounded())),
            min(255, Int((Double(g) * scale).rounded())),
            min(255, Int((Double(b) * scale).rounded()))
        )
    }

    public static func rgb(_ r: Int, _ g: Int, _ b: Int) -> UInt32 {
        0xFF00_0000 | UInt32(r & 0xff) << 16 | UInt32(g & 0xff) << 8 | UInt32(b & 0xff)
    }

    /** "#7c8cff" → ARGB, or nil. */
    public static func parseHex(_ hex: String) -> UInt32? {
        var t = hex.trimmed()
        if t.hasPrefix("#") { t.removeFirst() }
        guard t.count == 6, let v = UInt32(t, radix: 16) else { return nil }
        return 0xFF00_0000 | v
    }

    public static func toHex(_ argb: UInt32) -> String { String(format: "#%06x", argb & 0xffffff) }

    /** Relative luminance (as WCAG defines it): 0 for black, 1 for white. */
    public static func luminance(_ argb: UInt32) -> Double {
        func linear(_ c: UInt32) -> Double {
            let v = Double(c & 0xff) / 255
            return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(argb >> 16) + 0.7152 * linear(argb >> 8) + 0.0722 * linear(argb)
    }

    /**
     * [argb] darkened until it reads as text on a light background (luminance
     * at most 0.22). The hue stays, and pale colours gain a little saturation
     * so they turn deeper rather than grey. Dark enough colours are unchanged.
     */
    public static func readableOnLight(_ argb: UInt32) -> UInt32 {
        let target = 0.22
        if luminance(argb) <= target { return argb }
        let r = Double((argb >> 16) & 0xff) / 255
        let g = Double((argb >> 8) & 0xff) / 255
        let b = Double(argb & 0xff) / 255
        let hi = max(r, g, b)
        let lo = min(r, g, b)
        var hue: Double
        if hi == lo {
            hue = 0
        } else if hi == r {
            hue = 60 * ((g - b) / (hi - lo)).truncatingRemainder(dividingBy: 6)
            if hue < 0 { hue += 360 }
        } else if hi == g {
            hue = 60 * ((b - r) / (hi - lo) + 2)
        } else {
            hue = 60 * ((r - g) / (hi - lo) + 4)
        }
        var saturation = hi == 0 ? 0 : (hi - lo) / hi
        if saturation > 0.05 { saturation = min(1, max(saturation, 0.45) * 1.1) }
        var value = hi
        var color = argb
        while value > 0.3 {
            color = fromHsv(hue, saturation, value)
            if luminance(color) <= target { break }
            value -= 0.02
        }
        return color
    }

    private static func fromHsv(_ hue: Double, _ saturation: Double, _ value: Double) -> UInt32 {
        let c = value * saturation
        let x = c * (1 - abs((hue / 60).truncatingRemainder(dividingBy: 2) - 1))
        let m = value - c
        let (r, g, b): (Double, Double, Double)
        switch hue {
        case ..<60: (r, g, b) = (c, x, 0)
        case ..<120: (r, g, b) = (x, c, 0)
        case ..<180: (r, g, b) = (0, c, x)
        case ..<240: (r, g, b) = (0, x, c)
        case ..<300: (r, g, b) = (x, 0, c)
        default: (r, g, b) = (c, 0, x)
        }
        func ch(_ v: Double) -> Int { min(255, max(0, Int(((v + m) * 255).rounded()))) }
        return rgb(ch(r), ch(g), ch(b))
    }

    /** Mix [b] into [a] by [amount] (0...1). */
    public static func mix(_ a: UInt32, _ b: UInt32, _ amount: Double) -> UInt32 {
        let t = min(1, max(0, amount))
        func ch(_ shift: UInt32) -> Int {
            Int((Double((a >> shift) & 0xff) * (1 - t) + Double((b >> shift) & 0xff) * t).rounded())
        }
        return rgb(ch(16), ch(8), ch(0))
    }
}
