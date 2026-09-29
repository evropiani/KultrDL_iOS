import Foundation

/**
 * Where KultrDL keeps things. The library, settings and queue are JSON
 * files in Application Support; downloads go to Documents (shown in the
 * Files app under On My iPhone › KultrDL) or, when asked, to a folder only
 * KultrDL sees.
 */
enum Storage {
    static let support: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("KultrDL", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    static let documents: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]

    /** Downloads the Files app shows. */
    static var visibleMusic: URL { folder(documents.appendingPathComponent("Music", isDirectory: true)) }

    /** Downloads only KultrDL sees. */
    static var privateMusic: URL { folder(support.appendingPathComponent("Music", isDirectory: true)) }

    /** Work space for downloads being fetched and converted. */
    static var work: URL { folder(FileManager.default.temporaryDirectory.appendingPathComponent("downloads", isDirectory: true)) }

    static var caches: URL { FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0] }

    private static func folder(_ url: URL) -> URL {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /** A file's path relative to the app's home, which stays valid when the container moves (updates, restores). */
    static func relative(_ url: URL) -> String {
        let home = URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL.path
        let path = url.standardizedFileURL.path
        // /private/var and /var are the same place on iOS.
        let trimmedHome = home.hasPrefix("/private") ? String(home.dropFirst(8)) : home
        let trimmedPath = path.hasPrefix("/private") ? String(path.dropFirst(8)) : path
        if trimmedPath.hasPrefix(trimmedHome + "/") { return String(trimmedPath.dropFirst(trimmedHome.count + 1)) }
        return path
    }

    static func absolute(_ relative: String) -> URL {
        if relative.hasPrefix("/") { return URL(fileURLWithPath: relative) }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(relative)
    }

    static func load<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
        let url = support.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    static func save<T: Encodable>(_ value: T, _ name: String) {
        let url = support.appendingPathComponent(name)
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /** A name in [folder] that isn't taken yet: "Artist - Title (2).flac". */
    static func unique(_ folder: URL, _ name: String) -> URL {
        var candidate = folder.appendingPathComponent(name)
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent(ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)")
            n += 1
        }
        return candidate
    }

    static func size(_ url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
    }
}

/** Milliseconds since 1970, as the Android app stores times (backups move between them). */
func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

extension KeyedDecodingContainer {
    /** The value, or [fallback] when it's missing or can't be read (an older or newer file). */
    func value<T: Decodable>(_ key: Key, _ fallback: T) -> T {
        (try? decodeIfPresent(T.self, forKey: key)) ?? fallback
    }

    func optional<T: Decodable>(_ key: Key) -> T? {
        (try? decodeIfPresent(T.self, forKey: key)) ?? nil
    }
}
