import Citadel
import CommonCrypto
import Crypto
import Foundation
import KultrDLCore
import NIOSSH

/**
 * Private keys as people have them: OpenSSH ("BEGIN OPENSSH PRIVATE KEY",
 * with or without a passphrase for Ed25519 and RSA), PEM (PKCS#1, SEC1 and
 * PKCS#8, including the older passphrase-protected PEM), and unencrypted
 * PuTTY files. Ed25519, ECDSA (P-256, P-384, P-521) and RSA.
 */
enum SSHKeys {
    static func parse(_ raw: String, passphrase: String) throws -> NIOSSHPrivateKey {
        let text = raw.replacingOccurrences(of: "\r", with: "").trimmed()
        if text.hasPrefix("PuTTY-User-Key-File-") { return try putty(text) }
        if text.contains("BEGIN OPENSSH PRIVATE KEY") { return try openSSH(text, passphrase: passphrase) }
        if text.contains("BEGIN ENCRYPTED PRIVATE KEY") {
            throw RemoteError("Encrypted PKCS#8 keys aren't supported. Convert it with “ssh-keygen -p -f key” or use an OpenSSH key.")
        }
        guard let pem = PEM(text) else { throw RemoteError("That doesn't look like a private key.") }
        var der = pem.der
        if let info = pem.headers["DEK-Info"] {
            guard !passphrase.isEmpty else { throw RemoteError("The key needs its passphrase.") }
            der = try decryptLegacyPEM(der, dekInfo: info, passphrase: passphrase)
        }
        switch pem.label {
        case "RSA PRIVATE KEY": return try rsa(pkcs1: der)
        case "EC PRIVATE KEY": return try ecdsa(der: der)
        case "PRIVATE KEY": return try pkcs8(der)
        default: throw RemoteError("Keys of the kind “\(pem.label)” aren't supported.")
        }
    }

    // ---------------------------------------------------------- OpenSSH --

    private static func openSSH(_ text: String, passphrase: String) throws -> NIOSSHPrivateKey {
        guard let pem = PEM(text) else { throw RemoteError("The OpenSSH key couldn't be read.") }
        var r = SSHReader(pem.der)
        guard r.take(15) == Array("openssh-key-v1\0".utf8) else { throw RemoteError("The OpenSSH key couldn't be read.") }
        let cipher = String(decoding: r.string() ?? [], as: UTF8.self)
        _ = r.string() // kdf
        _ = r.string() // kdf options
        _ = r.uint32() // number of keys
        var pub = SSHReader(r.string() ?? [])
        let type = String(decoding: pub.string() ?? [], as: UTF8.self)
        let decryption = passphrase.isEmpty ? nil : Data(passphrase.utf8)
        let normalised = "-----BEGIN OPENSSH PRIVATE KEY-----\n" + pem.der.base64EncodedString() + "\n-----END OPENSSH PRIVATE KEY-----"
        switch type {
        case "ssh-ed25519":
            return NIOSSHPrivateKey(ed25519Key: try Curve25519.Signing.PrivateKey(sshEd25519: normalised, decryptionKey: decryption))
        case "ssh-rsa":
            return NIOSSHPrivateKey(custom: try Insecure.RSA.PrivateKey(sshRsa: normalised, decryptionKey: decryption))
        case "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521":
            guard cipher == "none" else {
                throw RemoteError("Passphrase-protected ECDSA keys in OpenSSH format aren't supported. Remove the passphrase (ssh-keygen -p) or use an Ed25519 key.")
            }
            var priv = SSHReader(r.string() ?? [])
            _ = priv.uint32()
            _ = priv.uint32()
            _ = priv.string() // type
            _ = priv.string() // curve
            _ = priv.string() // public point
            guard let d = priv.string() else { throw RemoteError("The ECDSA key couldn't be read.") }
            return try ecdsa(scalar: d, curve: type)
        default:
            throw RemoteError("Keys of the type “\(type)” aren't supported. Use Ed25519, ECDSA or RSA.")
        }
    }

    // -------------------------------------------------------------- PEM --

    struct PEM {
        let label: String
        let headers: [String: String]
        let der: Data

        init?(_ text: String) {
            let lines = text.split(separator: "\n").map { String($0).trimmed() }
            guard let begin = lines.firstIndex(where: { $0.hasPrefix("-----BEGIN ") }),
                  let end = lines.lastIndex(where: { $0.hasPrefix("-----END ") }), end > begin
            else { return nil }
            label = lines[begin].removingPrefix("-----BEGIN ").removingSuffix("-----")
            var headers: [String: String] = [:]
            var body = ""
            for line in lines[(begin + 1)..<end] {
                if line.contains(":"), body.isEmpty {
                    headers[line.before(":").trimmed()] = line.after(":").trimmed()
                } else {
                    body += line
                }
            }
            guard let der = Data(base64Encoded: body) else { return nil }
            self.headers = headers
            self.der = der
        }
    }

    /** The PEM encryption OpenSSL used before PKCS#8: MD5-based key derivation, AES or 3DES in CBC mode. */
    private static func decryptLegacyPEM(_ data: Data, dekInfo: String, passphrase: String) throws -> Data {
        let parts = dekInfo.split(separator: ",").map { String($0).trimmed() }
        guard parts.count == 2, let iv = hexBytes(parts[1]) else { throw RemoteError("The key's encryption header can't be read.") }
        let (algorithm, keyLength): (CCAlgorithm, Int)
        switch parts[0].uppercased() {
        case "AES-128-CBC": (algorithm, keyLength) = (CCAlgorithm(kCCAlgorithmAES), 16)
        case "AES-192-CBC": (algorithm, keyLength) = (CCAlgorithm(kCCAlgorithmAES), 24)
        case "AES-256-CBC": (algorithm, keyLength) = (CCAlgorithm(kCCAlgorithmAES), 32)
        case "DES-EDE3-CBC": (algorithm, keyLength) = (CCAlgorithm(kCCAlgorithm3DES), 24)
        default: throw RemoteError("Keys encrypted with \(parts[0]) aren't supported.")
        }
        // EVP_BytesToKey with MD5, one iteration, the first 8 bytes of the IV as salt.
        var key = Data()
        var previous = Data()
        let salt = Data(iv.prefix(8))
        while key.count < keyLength {
            previous = Data(Insecure.MD5.hash(data: previous + Data(passphrase.utf8) + salt))
            key += previous
        }
        key = key.prefix(keyLength)
        var out = Data(count: data.count + 32)
        var moved = 0
        let status = out.withUnsafeMutableBytes { outRaw in
            data.withUnsafeBytes { inRaw in
                key.withUnsafeBytes { keyRaw in
                    Data(iv).withUnsafeBytes { ivRaw in
                        CCCrypt(
                            CCOperation(kCCDecrypt), algorithm, CCOptions(kCCOptionPKCS7Padding),
                            keyRaw.baseAddress, keyLength, ivRaw.baseAddress,
                            inRaw.baseAddress, data.count, outRaw.baseAddress, outRaw.count, &moved
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw RemoteError("The passphrase doesn't open the key.") }
        return out.prefix(moved)
    }

    private static func hexBytes(_ hex: String) -> [UInt8]? {
        var out: [UInt8] = []
        var chars = Array(hex)
        guard chars.count % 2 == 0 else { return nil }
        while !chars.isEmpty {
            guard let b = UInt8(String(chars.prefix(2)), radix: 16) else { return nil }
            out.append(b)
            chars.removeFirst(2)
        }
        return out
    }

    private static func pkcs8(_ der: Data) throws -> NIOSSHPrivateKey {
        var top = DER(der)
        guard var seq = top.sequence() else { throw RemoteError("The key couldn't be read.") }
        _ = seq.integer() // version
        guard var algorithm = seq.sequence(), let oid = algorithm.oid(), let inner = seq.octetString() else {
            throw RemoteError("The key couldn't be read.")
        }
        switch oid {
        case [0x2B, 0x65, 0x70]: // Ed25519
            var o = DER(Data(inner))
            guard let raw = o.octetString(), raw.count == 32 else { throw RemoteError("The Ed25519 key couldn't be read.") }
            return NIOSSHPrivateKey(ed25519Key: try Curve25519.Signing.PrivateKey(rawRepresentation: raw))
        case [0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x01, 0x01]: // RSA
            return try rsa(pkcs1: Data(inner))
        case [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01]: // EC
            return try ecdsa(der: der)
        default:
            throw RemoteError("This kind of key isn't supported. Use Ed25519, ECDSA or RSA.")
        }
    }

    private static func ecdsa(der: Data) throws -> NIOSSHPrivateKey {
        if let k = try? P256.Signing.PrivateKey(derRepresentation: der) { return NIOSSHPrivateKey(p256Key: k) }
        if let k = try? P384.Signing.PrivateKey(derRepresentation: der) { return NIOSSHPrivateKey(p384Key: k) }
        if let k = try? P521.Signing.PrivateKey(derRepresentation: der) { return NIOSSHPrivateKey(p521Key: k) }
        throw RemoteError("The ECDSA key couldn't be read.")
    }

    private static func ecdsa(scalar: [UInt8], curve: String) throws -> NIOSSHPrivateKey {
        var d = Array(scalar.drop { $0 == 0 })
        switch curve {
        case "ecdsa-sha2-nistp256":
            d = [UInt8](repeating: 0, count: max(0, 32 - d.count)) + d
            return NIOSSHPrivateKey(p256Key: try P256.Signing.PrivateKey(rawRepresentation: d))
        case "ecdsa-sha2-nistp384":
            d = [UInt8](repeating: 0, count: max(0, 48 - d.count)) + d
            return NIOSSHPrivateKey(p384Key: try P384.Signing.PrivateKey(rawRepresentation: d))
        default:
            d = [UInt8](repeating: 0, count: max(0, 66 - d.count)) + d
            return NIOSSHPrivateKey(p521Key: try P521.Signing.PrivateKey(rawRepresentation: d))
        }
    }

    /** RSA from PKCS#1, through an OpenSSH-format copy that Citadel reads. */
    private static func rsa(pkcs1: Data) throws -> NIOSSHPrivateKey {
        var top = DER(pkcs1)
        guard var seq = top.sequence() else { throw RemoteError("The RSA key couldn't be read.") }
        _ = seq.integer()
        guard let n = seq.integer(), let e = seq.integer(), let d = seq.integer(), let p = seq.integer(), let q = seq.integer() else {
            throw RemoteError("The RSA key couldn't be read.")
        }
        _ = seq.integer() // dp
        _ = seq.integer() // dq
        guard let iqmp = seq.integer() else { throw RemoteError("The RSA key couldn't be read.") }
        return try rsa(n: n, e: e, d: d, iqmp: iqmp, p: p, q: q)
    }

    private static func rsa(n: [UInt8], e: [UInt8], d: [UInt8], iqmp: [UInt8], p: [UInt8], q: [UInt8]) throws -> NIOSSHPrivateKey {
        var pub = SSHWriter()
        pub.string(Array("ssh-rsa".utf8))
        pub.mpint(e)
        pub.mpint(n)
        var priv = SSHWriter()
        let check = UInt32.random(in: 0...UInt32.max)
        priv.uint32(check)
        priv.uint32(check)
        priv.string(Array("ssh-rsa".utf8))
        for value in [n, e, d, iqmp, p, q] { priv.mpint(value) }
        priv.string([])
        var pad: UInt8 = 1
        while priv.bytes.count % 8 != 0 {
            priv.bytes.append(pad)
            pad += 1
        }
        var blob = SSHWriter()
        blob.bytes += Array("openssh-key-v1\0".utf8)
        blob.string(Array("none".utf8))
        blob.string(Array("none".utf8))
        blob.string([])
        blob.uint32(1)
        blob.string(pub.bytes)
        blob.string(priv.bytes)
        let text = "-----BEGIN OPENSSH PRIVATE KEY-----\n" + Data(blob.bytes).base64EncodedString() + "\n-----END OPENSSH PRIVATE KEY-----"
        return NIOSSHPrivateKey(custom: try Insecure.RSA.PrivateKey(sshRsa: text))
    }

    // ------------------------------------------------------------ PuTTY --

    private static func putty(_ text: String) throws -> NIOSSHPrivateKey {
        let lines = text.split(separator: "\n").map(String.init)
        func field(_ name: String) -> String? { lines.first { $0.hasPrefix(name + ":") }?.after(":").trimmed() }
        guard let type = lines.first?.after(":").trimmed(), !type.isEmpty else {
            throw RemoteError("The PuTTY key couldn't be read.")
        }
        if let encryption = field("Encryption"), encryption != "none" {
            throw RemoteError("Passphrase-protected PuTTY keys aren't supported. In PuTTYgen, export it with Conversions → Export OpenSSH key.")
        }
        func block(_ name: String) -> [UInt8]? {
            guard let start = lines.firstIndex(where: { $0.hasPrefix(name + ":") }), let count = Int(lines[start].after(":").trimmed()) else { return nil }
            let body = lines[(start + 1)..<min(lines.count, start + 1 + count)].joined()
            return Data(base64Encoded: body).map { [UInt8]($0) }
        }
        guard let publicBlob = block("Public-Lines"), let privateBlob = block("Private-Lines") else {
            throw RemoteError("The PuTTY key couldn't be read.")
        }
        var pub = SSHReader(publicBlob)
        var priv = SSHReader(privateBlob)
        _ = pub.string()
        switch type {
        case "ssh-ed25519":
            guard let raw = priv.string(), raw.count == 32 else { throw RemoteError("The PuTTY key couldn't be read.") }
            return NIOSSHPrivateKey(ed25519Key: try Curve25519.Signing.PrivateKey(rawRepresentation: raw))
        case "ssh-rsa":
            guard let e = pub.string(), let n = pub.string(), let d = priv.string(), let p = priv.string(), let q = priv.string(), let iqmp = priv.string() else {
                throw RemoteError("The PuTTY key couldn't be read.")
            }
            return try rsa(n: n, e: e, d: d, iqmp: iqmp, p: p, q: q)
        case "ecdsa-sha2-nistp256", "ecdsa-sha2-nistp384", "ecdsa-sha2-nistp521":
            guard let d = priv.string() else { throw RemoteError("The PuTTY key couldn't be read.") }
            return try ecdsa(scalar: d, curve: type)
        default:
            throw RemoteError("PuTTY keys of the type “\(type)” aren't supported.")
        }
    }
}

// ------------------------------------------------------ byte helpers --

struct SSHReader {
    let bytes: [UInt8]
    var pos = 0

    init(_ bytes: [UInt8]) { self.bytes = bytes }
    init(_ data: Data) { self.bytes = [UInt8](data) }

    mutating func take(_ n: Int) -> [UInt8]? {
        guard n >= 0, pos + n <= bytes.count else { return nil }
        defer { pos += n }
        return Array(bytes[pos..<(pos + n)])
    }

    mutating func uint32() -> UInt32? {
        guard let b = take(4) else { return nil }
        return UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3])
    }

    mutating func string() -> [UInt8]? {
        guard let n = uint32() else { return nil }
        return take(Int(n))
    }
}

struct SSHWriter {
    var bytes: [UInt8] = []

    mutating func uint32(_ v: UInt32) { bytes += [UInt8(v >> 24), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)] }

    mutating func string(_ s: [UInt8]) {
        uint32(UInt32(s.count))
        bytes += s
    }

    /** An unsigned big integer as an SSH mpint: no extra leading zeros, one added when the top bit is set. */
    mutating func mpint(_ value: [UInt8]) {
        var v = Array(value.drop { $0 == 0 })
        if let first = v.first, first & 0x80 != 0 { v.insert(0, at: 0) }
        string(v)
    }
}

/** Just enough DER for private keys. */
struct DER {
    let bytes: [UInt8]
    var pos = 0

    init(_ data: Data) { bytes = [UInt8](data) }
    init(_ bytes: [UInt8]) { self.bytes = bytes }

    private mutating func element(_ tag: UInt8) -> [UInt8]? {
        guard pos + 2 <= bytes.count, bytes[pos] == tag else { return nil }
        var length = Int(bytes[pos + 1])
        var start = pos + 2
        if length & 0x80 != 0 {
            let count = length & 0x7f
            guard count <= 4, start + count <= bytes.count else { return nil }
            length = bytes[start..<(start + count)].reduce(0) { $0 << 8 | Int($1) }
            start += count
        }
        guard start + length <= bytes.count else { return nil }
        pos = start + length
        return Array(bytes[start..<(start + length)])
    }

    mutating func sequence() -> DER? { element(0x30).map { DER($0) } }
    mutating func integer() -> [UInt8]? { element(0x02) }
    mutating func octetString() -> [UInt8]? { element(0x04) }

    mutating func oid() -> [UInt8]? {
        let found = element(0x06)
        // Parameters, if any, follow; they aren't needed.
        return found
    }
}
