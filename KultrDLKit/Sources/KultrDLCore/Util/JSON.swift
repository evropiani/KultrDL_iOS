import Foundation

/**
 * JSON from services that change shape without notice, read forgivingly:
 * every step may be missing, and a missing step gives nil rather than an
 * error. Objects keep their keys in document order, because the YouTube
 * parsers look for "the first row" or "the first header" in the tree.
 */
public indirect enum JSON: Equatable, Sendable {
    case null
    case boolean(Bool)
    /** The number as written, so large ids keep every digit. */
    case number(String)
    case str(String)
    case arr([JSON])
    case obj(JSONObject)

    public static func parse(_ text: String) throws -> JSON {
        try parse(Data(text.utf8))
    }

    public static func parse(_ data: Data) throws -> JSON {
        var parser = JSONParser(bytes: [UInt8](data))
        return try parser.parseDocument()
    }

    /** Parsed, or nil when it isn't JSON. */
    public static func tryParse(_ text: String?) -> JSON? {
        guard let text else { return nil }
        return try? parse(text)
    }

    // ------------------------------------------------------------ access --

    public subscript(key: String) -> JSON? {
        if case .obj(let o) = self { return o[key] }
        return nil
    }

    public subscript(index: Int) -> JSON? {
        if case .arr(let a) = self, index >= 0, index < a.count { return a[index] }
        return nil
    }

    /** Follow keys (String) and indexes (Int). */
    public func path(_ steps: Any...) -> JSON? {
        var current: JSON? = self
        for step in steps {
            switch step {
            case let key as String: current = current?[key]
            case let index as Int: current = current?[index]
            default: return nil
            }
            if current == nil { return nil }
        }
        return current
    }

    /** Text of a string, number or boolean; nil when empty or not a value. */
    public var string: String? {
        switch self {
        case .str(let s): return s.isEmpty ? nil : s
        case .number(let n): return n
        case .boolean(let b): return b ? "true" : "false"
        default: return nil
        }
    }

    /** The raw string, even when empty. */
    public var rawString: String? {
        if case .str(let s) = self { return s }
        return nil
    }

    public var double: Double? {
        switch self {
        case .number(let n): return Double(n)
        case .str(let s): return Double(s.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }

    public var int64: Int64? {
        switch self {
        case .number(let n): return Int64(n) ?? Double(n).flatMap { $0.isFinite ? Int64($0) : nil }
        case .str(let s):
            let t = s.trimmingCharacters(in: .whitespaces)
            return Int64(t) ?? Double(t).flatMap { $0.isFinite ? Int64($0) : nil }
        default: return nil
        }
    }

    public var int: Int? { int64.map { Int(truncatingIfNeeded: $0) } }

    public var bool: Bool? {
        switch self {
        case .boolean(let b): return b
        case .str(let s): return s == "true" ? true : (s == "false" ? false : nil)
        default: return nil
        }
    }

    /** The elements of an array, or none. */
    public var array: [JSON] {
        if case .arr(let a) = self { return a }
        return []
    }

    public var object: JSONObject? {
        if case .obj(let o) = self { return o }
        return nil
    }

    public var isNull: Bool { self == .null }

    // ------------------------------------------------------------- trees --

    /** Every element in the tree, depth first in document order, this one included. */
    public func walk() -> JSONWalk { JSONWalk(root: self) }

    /** Objects stored under [key] anywhere in the tree, in document order. */
    public func objectsUnder(_ key: String) -> [JSON] {
        var out: [JSON] = []
        for node in walk() {
            if case .obj(let o) = node, let value = o[key], case .obj = value { out.append(value) }
        }
        return out
    }

    /** The first non-empty string stored under [key] anywhere in the tree. */
    public func firstString(_ key: String) -> String? {
        for node in walk() {
            if case .obj(let o) = node, let s = o[key]?.string { return s }
        }
        return nil
    }

    /** The first value stored under [key] anywhere in the tree. */
    public func first(_ key: String) -> JSON? {
        for node in walk() {
            if case .obj(let o) = node, let v = o[key] { return v }
        }
        return nil
    }

    // ------------------------------------------------------------ output --

    /** Compact JSON text. */
    public var compact: String {
        var out = ""
        write(to: &out)
        return out
    }

    private func write(to out: inout String) {
        switch self {
        case .null: out += "null"
        case .boolean(let b): out += b ? "true" : "false"
        case .number(let n): out += n
        case .str(let s): JSON.quote(s, into: &out)
        case .arr(let a):
            out += "["
            for (i, v) in a.enumerated() {
                if i > 0 { out += "," }
                v.write(to: &out)
            }
            out += "]"
        case .obj(let o):
            out += "{"
            for (i, key) in o.keys.enumerated() {
                if i > 0 { out += "," }
                JSON.quote(key, into: &out)
                out += ":"
                (o[key] ?? .null).write(to: &out)
            }
            out += "}"
        }
    }

    static func quote(_ s: String, into out: inout String) {
        out += "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
    }

    // ----------------------------------------------------------- building --

    /** A string value, or null for nil. */
    public static func of(_ value: String?) -> JSON { value.map { .str($0) } ?? .null }

    public static func of(_ value: Int?) -> JSON { value.map { .number(String($0)) } ?? .null }
}

extension JSON: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral,
    ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    public init(stringLiteral value: String) { self = .str(value) }
    public init(integerLiteral value: Int) { self = .number(String(value)) }
    public init(booleanLiteral value: Bool) { self = .boolean(value) }
    public init(arrayLiteral elements: JSON...) { self = .arr(elements) }

    /** Keys keep the order they are written in. */
    public init(dictionaryLiteral elements: (String, JSON)...) {
        var o = JSONObject()
        for (k, v) in elements { o[k] = v }
        self = .obj(o)
    }
}

/** An object that remembers the order of its keys. */
public struct JSONObject: Equatable, Sendable {
    public private(set) var keys: [String] = []
    private var values: [String: JSON] = [:]

    public init() {}

    public subscript(key: String) -> JSON? {
        get { values[key] }
        set {
            if let newValue {
                if values.updateValue(newValue, forKey: key) == nil { keys.append(key) }
            } else if values.removeValue(forKey: key) != nil {
                keys.removeAll { $0 == key }
            }
        }
    }

    public var entries: [(key: String, value: JSON)] { keys.compactMap { k in values[k].map { (k, $0) } } }

    public var count: Int { keys.count }
}

/** A depth-first walk that doesn't build the whole list first. */
public struct JSONWalk: Sequence {
    let root: JSON

    public func makeIterator() -> Iterator { Iterator(stack: [root]) }

    public struct Iterator: IteratorProtocol {
        var stack: [JSON]

        public mutating func next() -> JSON? {
            guard let node = stack.popLast() else { return nil }
            switch node {
            case .obj(let o):
                for key in o.keys.reversed() { if let v = o[key] { stack.append(v) } }
            case .arr(let a):
                stack.append(contentsOf: a.reversed())
            default:
                break
            }
            return node
        }
    }
}

public struct JSONError: Error, CustomStringConvertible {
    public let description: String
}

/** A small strict-enough parser over UTF-8 bytes. */
struct JSONParser {
    let bytes: [UInt8]
    var i = 0

    init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    mutating func parseDocument() throws -> JSON {
        // A BOM, or the ")]}'" guard some Google endpoints put first.
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { i = 3 }
        skipSpace()
        if i + 3 < bytes.count, bytes[i] == UInt8(ascii: ")"), bytes[i + 1] == UInt8(ascii: "]"), bytes[i + 2] == UInt8(ascii: "}") {
            while i < bytes.count, bytes[i] != UInt8(ascii: "\n") { i += 1 }
        }
        skipSpace()
        let value = try parseValue(depth: 0)
        skipSpace()
        return value
    }

    private mutating func skipSpace() {
        while i < bytes.count {
            switch bytes[i] {
            case 0x20, 0x09, 0x0A, 0x0D: i += 1
            default: return
            }
        }
    }

    private func fail(_ what: String) -> JSONError {
        JSONError(description: "Invalid JSON at byte \(i): \(what)")
    }

    private mutating func parseValue(depth: Int) throws -> JSON {
        guard depth < 512 else { throw fail("nested too deep") }
        guard i < bytes.count else { throw fail("unexpected end") }
        switch bytes[i] {
        case UInt8(ascii: "{"): return try parseObject(depth: depth)
        case UInt8(ascii: "["): return try parseArray(depth: depth)
        case UInt8(ascii: "\""): return .str(try parseString())
        case UInt8(ascii: "t"):
            try expect("true")
            return .boolean(true)
        case UInt8(ascii: "f"):
            try expect("false")
            return .boolean(false)
        case UInt8(ascii: "n"):
            try expect("null")
            return .null
        default:
            return .number(try parseNumber())
        }
    }

    private mutating func expect(_ word: String) throws {
        for byte in word.utf8 {
            guard i < bytes.count, bytes[i] == byte else { throw fail("expected \(word)") }
            i += 1
        }
    }

    private mutating func parseObject(depth: Int) throws -> JSON {
        i += 1
        var object = JSONObject()
        skipSpace()
        if i < bytes.count, bytes[i] == UInt8(ascii: "}") {
            i += 1
            return .obj(object)
        }
        while true {
            skipSpace()
            guard i < bytes.count, bytes[i] == UInt8(ascii: "\"") else { throw fail("expected a key") }
            let key = try parseString()
            skipSpace()
            guard i < bytes.count, bytes[i] == UInt8(ascii: ":") else { throw fail("expected :") }
            i += 1
            skipSpace()
            object[key] = try parseValue(depth: depth + 1)
            skipSpace()
            guard i < bytes.count else { throw fail("unterminated object") }
            if bytes[i] == UInt8(ascii: ",") {
                i += 1
                continue
            }
            if bytes[i] == UInt8(ascii: "}") {
                i += 1
                return .obj(object)
            }
            throw fail("expected , or }")
        }
    }

    private mutating func parseArray(depth: Int) throws -> JSON {
        i += 1
        var array: [JSON] = []
        skipSpace()
        if i < bytes.count, bytes[i] == UInt8(ascii: "]") {
            i += 1
            return .arr(array)
        }
        while true {
            skipSpace()
            array.append(try parseValue(depth: depth + 1))
            skipSpace()
            guard i < bytes.count else { throw fail("unterminated array") }
            if bytes[i] == UInt8(ascii: ",") {
                i += 1
                continue
            }
            if bytes[i] == UInt8(ascii: "]") {
                i += 1
                return .arr(array)
            }
            throw fail("expected , or ]")
        }
    }

    private mutating func parseNumber() throws -> String {
        let start = i
        while i < bytes.count {
            let b = bytes[i]
            if (b >= UInt8(ascii: "0") && b <= UInt8(ascii: "9")) || b == UInt8(ascii: "-") || b == UInt8(ascii: "+")
                || b == UInt8(ascii: ".") || b == UInt8(ascii: "e") || b == UInt8(ascii: "E") {
                i += 1
            } else {
                break
            }
        }
        guard i > start else { throw fail("unexpected character") }
        return String(decoding: bytes[start..<i], as: UTF8.self)
    }

    private mutating func parseString() throws -> String {
        i += 1
        var out = [UInt8]()
        var runStart = i
        while i < bytes.count {
            let b = bytes[i]
            if b == UInt8(ascii: "\"") {
                out.append(contentsOf: bytes[runStart..<i])
                i += 1
                return String(decoding: out, as: UTF8.self)
            }
            if b == UInt8(ascii: "\\") {
                out.append(contentsOf: bytes[runStart..<i])
                i += 1
                guard i < bytes.count else { break }
                let e = bytes[i]
                i += 1
                switch e {
                case UInt8(ascii: "\""): out.append(0x22)
                case UInt8(ascii: "\\"): out.append(0x5C)
                case UInt8(ascii: "/"): out.append(0x2F)
                case UInt8(ascii: "b"): out.append(0x08)
                case UInt8(ascii: "f"): out.append(0x0C)
                case UInt8(ascii: "n"): out.append(0x0A)
                case UInt8(ascii: "r"): out.append(0x0D)
                case UInt8(ascii: "t"): out.append(0x09)
                case UInt8(ascii: "u"):
                    var code = try hex4()
                    if code >= 0xD800 && code < 0xDC00, i + 1 < bytes.count, bytes[i] == UInt8(ascii: "\\"), bytes[i + 1] == UInt8(ascii: "u") {
                        let save = i
                        i += 2
                        let low = try hex4()
                        if low >= 0xDC00 && low < 0xE000 {
                            code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                        } else {
                            i = save
                        }
                    }
                    let scalar = Unicode.Scalar(code) ?? "\u{FFFD}"
                    out.append(contentsOf: Array(String(Character(scalar)).utf8))
                default:
                    out.append(e)
                }
                runStart = i
                continue
            }
            i += 1
        }
        throw fail("unterminated string")
    }

    private mutating func hex4() throws -> UInt32 {
        guard i + 4 <= bytes.count else { throw fail("bad \\u escape") }
        var value: UInt32 = 0
        for _ in 0..<4 {
            let b = bytes[i]
            let digit: UInt32
            switch b {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): digit = UInt32(b - UInt8(ascii: "0"))
            case UInt8(ascii: "a")...UInt8(ascii: "f"): digit = UInt32(b - UInt8(ascii: "a") + 10)
            case UInt8(ascii: "A")...UInt8(ascii: "F"): digit = UInt32(b - UInt8(ascii: "A") + 10)
            default: throw fail("bad hex digit")
            }
            value = value * 16 + digit
            i += 1
        }
        return value
    }
}

extension Optional where Wrapped == JSON {
    /** Chained access on an optional, as `json?["a"]` would be. */
    public subscript(key: String) -> JSON? { self?[key] }
    public subscript(index: Int) -> JSON? { self?[index] }
    public var string: String? { self?.string }
    public var int: Int? { self?.int }
    public var int64: Int64? { self?.int64 }
    public var double: Double? { self?.double }
    public var bool: Bool? { self?.bool }
    public var array: [JSON] { self?.array ?? [] }
    public var object: JSONObject? { self?.object }
}
