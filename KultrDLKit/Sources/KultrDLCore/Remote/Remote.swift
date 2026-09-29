import CryptoKit
import Foundation

/** The ways KultrDL can reach a server. */
public enum ServerProtocol: String, Codable, CaseIterable, Sendable, Hashable {
    case sftp = "SFTP"
    case ftps = "FTPS"
    case ftp = "FTP"
    case ftpsImplicit = "FTPS_IMPLICIT"

    public var label: String {
        switch self {
        case .sftp: return "SFTP"
        case .ftps: return "FTPS"
        case .ftp: return "FTP"
        case .ftpsImplicit: return "FTPS implicit"
        }
    }

    public var defaultPort: Int {
        switch self {
        case .sftp: return 22
        case .ftps, .ftp: return 21
        case .ftpsImplicit: return 990
        }
    }

    public var hint: String {
        switch self {
        case .sftp: return "Files over SSH. Most NAS boxes and Linux servers have it."
        case .ftps: return "FTP with encryption (explicit TLS)."
        case .ftp: return "Unencrypted: the password and music cross the network in the clear."
        case .ftpsImplicit: return "Older FTP encryption on its own port, usually 990."
        }
    }

    public init(from decoder: Decoder) throws {
        self = ServerProtocol(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .sftp
    }
}

/** Where on the server a track goes inside the chosen folder. */
public enum FolderLayout: String, Codable, CaseIterable, Sendable, Hashable {
    case flat = "FLAT"
    case artist = "ARTIST"
    case artistAlbum = "ARTIST_ALBUM"

    public var label: String {
        switch self {
        case .flat: return "Files only"
        case .artist: return "Artist"
        case .artistAlbum: return "Artist / Album"
        }
    }

    public var explanation: String {
        switch self {
        case .flat: return "Every file straight into the folder."
        case .artist: return "A folder per artist, as Plex, Jellyfin and Navidrome like it."
        case .artistAlbum: return "A folder per artist, and one per album inside it."
        }
    }

    /** The folders under the chosen one, e.g. ["Björk", "Homogenic"]. */
    public func folders(artist: String, albumArtist: String?, album: String?) -> [String] {
        let who = Text.fileName(albumArtist?.trimmed().nonEmpty ?? artist.trimmed().nonEmpty ?? "Unknown artist", max: 80)
        switch self {
        case .flat: return []
        case .artist: return [who]
        case .artistAlbum: return [who] + (album?.trimmed().nonEmpty.map { [Text.fileName($0, max: 80)] } ?? [])
        }
    }

    public init(from decoder: Decoder) throws {
        self = FolderLayout(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .flat
    }
}

/**
 * How to reach one server and sign in. Secrets are in the clear here and
 * only live as long as a connection is being made.
 *
 * `pin` is the fingerprint the user trusts: the SSH host key for SFTP, or a
 * self-signed certificate for FTPS. Without one, SFTP trusts the first key
 * it sees (and reports it in `RemoteSession.newPin`) and FTPS needs a
 * certificate the phone already trusts.
 */
public struct Connection: Sendable, CustomStringConvertible {
    public var serverProtocol: ServerProtocol
    public var host: String
    public var port: Int
    public var username: String
    public var password: String
    public var privateKey: String
    public var passphrase: String
    public var pin: String?
    public var passive: Bool
    public var timeout: TimeInterval

    public init(
        serverProtocol: ServerProtocol, host: String, port: Int? = nil, username: String = "", password: String = "",
        privateKey: String = "", passphrase: String = "", pin: String? = nil, passive: Bool = true, timeout: TimeInterval = 20
    ) {
        self.serverProtocol = serverProtocol
        self.host = host
        self.port = port ?? serverProtocol.defaultPort
        self.username = username
        self.password = password
        self.privateKey = privateKey
        self.passphrase = passphrase
        self.pin = pin
        self.passive = passive
        self.timeout = timeout
    }

    public var description: String { "\(serverProtocol.label) \(username)@\(host):\(port)" }
}

public struct RemoteEntry: Sendable, Hashable {
    public let name: String
    public let isDirectory: Bool
    public let size: Int64

    public init(name: String, isDirectory: Bool, size: Int64 = 0) {
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
    }
}

/** One signed-in connection. Use it from one task at a time. */
public protocol RemoteSession: AnyObject, Sendable {
    /** The folder the server starts in, as an absolute path. */
    var home: String { get }

    /** The server's fingerprint to remember, when there was no pin yet. */
    var newPin: String? { get }

    func list(_ path: String) async throws -> [RemoteEntry]

    func isDirectory(_ path: String) async throws -> Bool

    /** Creates the folder and any missing parents. */
    func makeDirectories(_ path: String) async throws

    /**
     * Stores [file] at [path]: first under a temporary name, then renamed,
     * so a music server never picks up half a file. Replaces what is there.
     */
    func upload(_ file: URL, to path: String, progress: @escaping @Sendable (Int64) -> Void) async throws

    func delete(_ path: String) async throws

    func close() async
}

/** A readable reason. */
public struct RemoteError: LocalizedError, Sendable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}

/**
 * The server identified itself with something the user hasn't trusted:
 * an SSH key that differs from the saved one, or a certificate the phone
 * doesn't trust (self-signed, as on most NAS boxes) or that changed.
 */
public struct UntrustedServerError: LocalizedError, Sendable {
    public enum Reason: Sendable {
        case keyChanged, certificateUntrusted, certificateChanged

        public var message: String {
            switch self {
            case .keyChanged: return "The server's SSH key has changed since it was saved. That happens after a reinstall — or when something is in the way."
            case .certificateUntrusted: return "The server's certificate isn't one this phone trusts (NAS boxes often make their own)."
            case .certificateChanged: return "The server's certificate has changed since it was trusted."
            }
        }

        public var title: String {
            switch self {
            case .keyChanged: return "The server's key changed"
            case .certificateUntrusted: return "Trust this certificate?"
            case .certificateChanged: return "The certificate changed"
            }
        }
    }

    public let reason: Reason
    public let fingerprint: String

    public init(_ reason: Reason, fingerprint: String) {
        self.reason = reason
        self.fingerprint = fingerprint
    }

    public var errorDescription: String? { reason.message }
}

public enum RemotePath {
    /** "/a//b/" → "/a/b"; "" stays "" (the start folder); "/" stays "/". */
    public static func normalise(_ path: String) -> String {
        let trimmed = path.trimmed().replacingOccurrences(of: "\\", with: "/")
        if trimmed.isEmpty { return "" }
        let absolute = trimmed.hasPrefix("/")
        var parts: [String] = []
        for part in trimmed.split(separator: "/", omittingEmptySubsequences: false).map(String.init) {
            switch part {
            case "", ".": continue
            case "..": if !parts.isEmpty { parts.removeLast() }
            default: parts.append(part)
            }
        }
        let joined = parts.joined(separator: "/")
        return absolute ? "/" + joined : joined
    }

    /** A folder relative to the start folder becomes absolute. */
    public static func resolve(_ home: String, _ path: String) -> String {
        let p = normalise(path)
        if p.hasPrefix("/") { return p }
        return normalise(p.isEmpty ? (home.isEmpty ? "/" : home) : "\(home.hasSuffix("/") ? String(home.dropLast()) : home)/\(p)")
    }

    public static func join(_ base: String, _ names: String...) -> String { join(base, names) }

    public static func join(_ base: String, _ names: [String]) -> String {
        normalise(([base] + names).filter { !$0.isEmpty }.joined(separator: "/"))
    }

    public static func parent(_ path: String) -> String {
        let p = normalise(path)
        if p == "/" || p.isEmpty { return p }
        guard let i = p.lastIndex(of: "/") else { return "" }
        if i == p.startIndex { return "/" }
        return String(p[..<i])
    }

    public static func name(_ path: String) -> String { normalise(path).afterLast("/") }

    /** Every folder from the top down to [path]: "/a/b" → ["/a", "/a/b"]. */
    public static func ancestors(_ path: String) -> [String] {
        var out: [String] = []
        var current = normalise(path)
        while !current.isEmpty && current != "/" {
            out.append(current)
            current = parent(current)
        }
        return out.reversed()
    }
}

/** "SHA256:…" as OpenSSH prints it (`ssh-keygen -lf`). */
public func sshFingerprint(_ bytes: Data) -> String {
    let digest = Data(SHA256.hash(data: bytes)).base64EncodedString()
    return "SHA256:" + digest.trimmingCharacters(in: CharacterSet(charactersIn: "="))
}

/** "" is the folder the server starts in. */
public func folderLabel(_ folder: String) -> String { folder.isEmpty ? "Start folder" : folder }
