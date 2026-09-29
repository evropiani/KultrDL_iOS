import Citadel
import Crypto
import Foundation
import KultrDLCore
import NIOCore
import NIOSSH

/**
 * Trusts the pinned key, or — when nothing is pinned yet — the first key
 * the server shows, which the caller then saves (as OpenSSH's "accept-new"
 * does). A different key stops the connection before any password is sent.
 */
final class PinnedHostKey: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    let pin: String?
    private let lock = NSLock()
    private var _seen: String?

    init(pin: String?) {
        self.pin = pin
    }

    var seen: String? {
        lock.lock()
        defer { lock.unlock() }
        return _seen
    }

    static func fingerprint(_ key: NIOSSHPublicKey) -> String {
        let text = String(openSSHPublicKey: key)
        let base64 = text.split(separator: " ").dropFirst().first.map(String.init) ?? ""
        return sshFingerprint(Data(base64Encoded: base64) ?? Data(text.utf8))
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let fp = Self.fingerprint(hostKey)
        lock.lock()
        _seen = fp
        lock.unlock()
        if pin == nil || pin == fp {
            validationCompletePromise.succeed(())
        } else {
            validationCompletePromise.fail(UntrustedServerError(.keyChanged, fingerprint: fp))
        }
    }
}

/** Offers the key first (when there is one), then the password. */
final class Credentials: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
    private let username: String
    private var offers: [NIOSSHUserAuthenticationOffer.Offer]
    private let lock = NSLock()

    init(username: String, key: NIOSSHPrivateKey?, password: String) {
        self.username = username
        var list: [NIOSSHUserAuthenticationOffer.Offer] = []
        if let key { list.append(.privateKey(.init(privateKey: key))) }
        if !password.isEmpty { list.append(.password(.init(password: password))) }
        offers = list
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        lock.lock()
        defer { lock.unlock() }
        while !offers.isEmpty {
            let offer = offers.removeFirst()
            switch offer {
            case .privateKey where availableMethods.contains(.publicKey),
                 .password where availableMethods.contains(.password):
                nextChallengePromise.succeed(NIOSSHUserAuthenticationOffer(username: username, serviceName: "", offer: offer))
                return
            default:
                continue
            }
        }
        nextChallengePromise.fail(RemoteError("The server didn't accept the username, password or key."))
    }
}

/** SFTP through Citadel (SwiftNIO SSH). */
final class SFTPSession: RemoteSession, @unchecked Sendable {
    let home: String
    let newPin: String?
    private let client: SSHClient
    private let sftp: SFTPClient

    private init(client: SSHClient, sftp: SFTPClient, home: String, newPin: String?) {
        self.client = client
        self.sftp = sftp
        self.home = home
        self.newPin = newPin
    }

    static func open(_ c: Connection) async throws -> SFTPSession {
        let key: NIOSSHPrivateKey?
        if c.privateKey.trimmed().isEmpty {
            key = nil
        } else {
            do {
                key = try SSHKeys.parse(c.privateKey, passphrase: c.passphrase)
            } catch let error as RemoteError {
                throw error
            } catch {
                throw RemoteError("The private key couldn't be read\(c.passphrase.isEmpty ? " (does it need a passphrase?)" : " — check the passphrase") (\(error)).")
            }
        }
        let hostKeys = PinnedHostKey(pin: c.pin)
        let auth = SSHAuthenticationMethod.custom(Credentials(username: c.username, key: key, password: c.password))
        let client: SSHClient
        do {
            client = try await SSHClient.connect(
                host: c.host.trimmed(),
                port: c.port,
                authenticationMethod: auth,
                hostKeyValidator: .custom(hostKeys),
                reconnect: .never,
                algorithms: .all,
                connectTimeout: .seconds(Int64(max(5, c.timeout)))
            )
        } catch {
            throw explain(error, c, hostKeys)
        }
        let sftp: SFTPClient
        do {
            sftp = try await client.openSFTP()
        } catch {
            try? await client.close()
            throw RemoteError("Signed in, but the server has no SFTP. Is it an SSH server with file transfer switched on?")
        }
        let home = RemotePath.normalise((try? await sftp.getRealPath(atPath: ".")) ?? "/")
        return SFTPSession(client: client, sftp: sftp, home: home.isEmpty ? "/" : home, newPin: c.pin == nil ? hostKeys.seen : nil)
    }

    private static func explain(_ error: Error, _ c: Connection, _ keys: PinnedHostKey) -> Error {
        if let untrusted = error as? UntrustedServerError { return untrusted }
        if let pin = c.pin, let seen = keys.seen, seen != pin { return UntrustedServerError(.keyChanged, fingerprint: seen) }
        if error is RemoteError { return error }
        let text = String(describing: error)
        if let ssh = error as? SSHClientError {
            switch ssh {
            case .allAuthenticationOptionsFailed, .unsupportedPasswordAuthentication, .unsupportedPrivateKeyAuthentication:
                return RemoteError("The server didn't accept the username, password or key.")
            default:
                break
            }
        }
        if text.contains("NIOConnectionError") || text.contains("connectTimeout") || text.contains("connectionRefused") || text.contains("Connection refused") {
            return RemoteError("Nothing answered on \(c.host):\(c.port). Check the port, and that SSH is switched on.")
        }
        if text.contains("unknownHost") || text.contains("nodename nor servname") || text.contains("NXDOMAIN") {
            return RemoteError("Can't find “\(c.host)”. Check the address and that the phone is online.")
        }
        if text.contains("keyExchangeNegotiationFailure") || text.contains("NoCommonAlgorithm") || text.contains("negotiation") {
            return RemoteError("KultrDL and the server share no encryption method (\(text.prefix(120))).")
        }
        return RemoteError("SFTP: \(text.prefix(200))")
    }

    private func guarded<T>(_ action: String, _ path: String, _ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let SFTPError.errorStatus(status) {
            switch status.errorCode {
            case .noSuchFile: throw RemoteError("“\(path)” doesn't exist on the server.")
            case .permissionDenied: throw RemoteError("The server doesn't allow KultrDL to \(action) “\(path)”.")
            default: throw RemoteError("Couldn't \(action) “\(path)”: \(status.message.isEmpty ? "error \(status.errorCode.rawValue)" : status.message)")
            }
        }
    }

    private static func isDirectory(_ attributes: SFTPFileAttributes) -> Bool {
        guard let permissions = attributes.permissions else { return false }
        return (permissions & 0o170000) == 0o040000
    }

    func list(_ path: String) async throws -> [RemoteEntry] {
        let dir = RemotePath.resolve(home, path)
        let names = try await guarded("list", dir) { try await sftp.listDirectory(atPath: dir) }
        var out: [RemoteEntry] = []
        for name in names {
            for component in name.components {
                let entryName = component.filename
                if entryName == "." || entryName == ".." { continue }
                var directory = Self.isDirectory(component.attributes)
                if !directory, let permissions = component.attributes.permissions, (permissions & 0o170000) == 0o120000 {
                    // A link to a folder is a folder here.
                    directory = (try? await isDirectory(RemotePath.join(dir, entryName))) ?? false
                }
                out.append(RemoteEntry(name: entryName, isDirectory: directory, size: Int64(component.attributes.size ?? 0)))
            }
        }
        return out.sorted { a, b in a.isDirectory != b.isDirectory ? a.isDirectory : a.name.lowercased() < b.name.lowercased() }
    }

    func isDirectory(_ path: String) async throws -> Bool {
        do {
            return Self.isDirectory(try await sftp.getAttributes(at: RemotePath.resolve(home, path)))
        } catch let SFTPError.errorStatus(status) where status.errorCode == .noSuchFile {
            return false
        }
    }

    func makeDirectories(_ path: String) async throws {
        for dir in RemotePath.ancestors(RemotePath.resolve(home, path)) {
            if (try? await isDirectory(dir)) == true { continue }
            try await guarded("create", dir) { try await sftp.createDirectory(atPath: dir) }
        }
    }

    func upload(_ file: URL, to path: String, progress: @escaping @Sendable (Int64) -> Void) async throws {
        // Straight to the final name: Citadel's RENAME carries a field only SFTP v5 has, which
        // v3 servers (most of them) turn down, so there is no writing to ".part" and renaming.
        let target = RemotePath.resolve(home, path)
        let input = try FileHandle(forReadingFrom: file)
        defer { try? input.close() }
        let remote = try await guarded("write", target) {
            try await sftp.openFile(filePath: target, flags: [.write, .create, .truncate])
        }
        var offset: UInt64 = 0
        do {
            while true {
                try Task.checkCancellation()
                guard let chunk = try input.read(upToCount: 256 * 1024), !chunk.isEmpty else { break }
                try await remote.write(ByteBuffer(bytes: chunk), at: offset)
                offset += UInt64(chunk.count)
                progress(Int64(offset))
            }
            try await remote.close()
        } catch {
            try? await remote.close()
            // Don't leave half a file behind.
            try? await sftp.remove(at: target)
            throw error
        }
    }

    func delete(_ path: String) async throws {
        let target = RemotePath.resolve(home, path)
        try await guarded("delete", target) { try await sftp.remove(at: target) }
    }

    func close() async {
        try? await sftp.close()
        try? await client.close()
    }
}

/** Opens FTP, FTPS and SFTP connections. */
public enum Remote {
    /**
     * Reads a private key as sign-in would, and names its kind ("Ed25519",
     * "ECDSA", "RSA"). Throws with a message when it can't be read or the
     * passphrase is wrong.
     */
    public static func checkKey(_ text: String, passphrase: String) throws -> String {
        let key: NIOSSHPrivateKey
        do {
            key = try SSHKeys.parse(text, passphrase: passphrase)
        } catch let error as RemoteError {
            throw error
        } catch {
            throw RemoteError("The private key couldn't be read\(passphrase.isEmpty ? " (does it need a passphrase?)" : " — check the passphrase") (\(error)).")
        }
        let type = String(openSSHPublicKey: key.publicKey).before(" ")
        switch type {
        case "ssh-ed25519": return "Ed25519"
        case "ssh-rsa": return "RSA"
        default: return type.hasPrefix("ecdsa") ? "ECDSA " + type.afterLast("-").uppercased() : type
        }
    }

    public static func open(_ connection: Connection) async throws -> RemoteSession {
        guard !connection.host.trimmed().isEmpty else { throw RemoteError("Enter the server's address.") }
        switch connection.serverProtocol {
        case .sftp: return try await SFTPSession.open(connection)
        default: return try await FTPSession.open(connection)
        }
    }

    /** Opens, runs [body], closes. */
    public static func use<T>(_ connection: Connection, _ body: (RemoteSession) async throws -> T) async throws -> T {
        let session = try await open(connection)
        do {
            let result = try await body(session)
            await session.close()
            return result
        } catch {
            await session.close()
            throw error
        }
    }
}
