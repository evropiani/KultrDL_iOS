import Foundation
import KultrDLCore
import Security

/**
 * Checks FTPS certificates: what the phone trusts, or exactly the one the
 * user pinned. Remembers the fingerprint of a certificate it turned down,
 * so the user can be asked whether to trust it.
 */
final class CertificateTrust: NSObject, URLSessionTaskDelegate, URLSessionStreamDelegate, @unchecked Sendable {
    let pin: String?
    private let lock = NSLock()
    private var _rejected: String?

    init(pin: String?) {
        self.pin = pin
    }

    var rejected: String? {
        lock.lock()
        defer { lock.unlock() }
        return _rejected
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        handle(challenge, completionHandler)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        handle(challenge, completionHandler)
    }

    private func handle(_ challenge: URLAuthenticationChallenge, _ completion: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust
        else {
            completion(.performDefaultHandling, nil)
            return
        }
        let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first
        let fingerprint = leaf.map { sshFingerprint(SecCertificateCopyData($0) as Data) } ?? ""
        if let pin {
            if fingerprint == pin {
                completion(.useCredential, URLCredential(trust: trust))
            } else {
                reject(fingerprint)
                completion(.cancelAuthenticationChallenge, nil)
            }
            return
        }
        var error: CFError?
        if SecTrustEvaluateWithError(trust, &error) {
            completion(.useCredential, URLCredential(trust: trust))
        } else {
            reject(fingerprint)
            completion(.cancelAuthenticationChallenge, nil)
        }
    }

    private func reject(_ fingerprint: String) {
        lock.lock()
        _rejected = fingerprint
        lock.unlock()
    }
}

/** A byte stream over one TCP connection, read line by line or to the end. */
final class FTPStream: @unchecked Sendable {
    let task: URLSessionStreamTask
    private var buffer: [UInt8] = []
    private var eof = false
    private let timeout: TimeInterval

    init(session: URLSession, host: String, port: Int, timeout: TimeInterval) {
        task = session.streamTask(withHostName: host, port: port)
        self.timeout = timeout
        task.resume()
    }

    func secure() { task.startSecureConnection() }

    private func fill() async throws {
        let (data, atEnd) = try await task.readData(ofMinLength: 1, maxLength: 65536, timeout: timeout)
        if let data { buffer += data }
        if atEnd { eof = true }
    }

    func readLine() async throws -> String {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                var line = Array(buffer[..<newline])
                buffer.removeSubrange(...newline)
                if line.last == 0x0D { line.removeLast() }
                return String(decoding: line, as: UTF8.self)
            }
            if eof {
                guard !buffer.isEmpty else { throw RemoteError("The server closed the connection.") }
                let rest = buffer
                buffer = []
                return String(decoding: rest, as: UTF8.self)
            }
            try await fill()
        }
    }

    func readAll() async throws -> [UInt8] {
        while !eof { try await fill() }
        let all = buffer
        buffer = []
        return all
    }

    func write(_ data: Data) async throws {
        try await task.write(data, timeout: timeout)
    }

    func send(_ line: String) async throws {
        try await write(Data((line + "\r\n").utf8))
    }

    func close() {
        task.closeWrite()
        task.cancel()
    }
}

/** FTP and FTPS (explicit and implicit TLS), passive mode. */
final class FTPSession: RemoteSession, @unchecked Sendable {
    let home: String
    let newPin: String? = nil
    private let session: URLSession
    private let control: FTPStream
    private let connection: Connection
    private let tls: Bool
    private let features: Set<String>
    private var closed = false

    private init(session: URLSession, control: FTPStream, connection: Connection, tls: Bool, features: Set<String>, home: String) {
        self.session = session
        self.control = control
        self.connection = connection
        self.tls = tls
        self.features = features
        self.home = home
    }

    struct Reply {
        let code: Int
        let text: String

        var positive: Bool { (200..<400).contains(code) }
        var message: String { text.split(separator: "\n").last.map { String($0.dropFirst(min(4, $0.count))) } ?? text }
    }

    private static func reply(_ stream: FTPStream) async throws -> Reply {
        var line = try await stream.readLine()
        // Some servers send a blank line or two first.
        while line.count < 3 { line = try await stream.readLine() }
        guard let code = Int(line.prefix(3)) else { throw RemoteError("The server's answer doesn't look like FTP: \(line.prefix(80))") }
        var lines = [line]
        if line.count > 3, line[line.index(line.startIndex, offsetBy: 3)] == "-" {
            repeat {
                line = try await stream.readLine()
                lines.append(line)
            } while !line.hasPrefix("\(code) ")
        }
        return Reply(code: code, text: lines.joined(separator: "\n"))
    }

    private func command(_ line: String) async throws -> Reply {
        try await control.send(line)
        return try await Self.reply(control)
    }

    static func open(_ c: Connection) async throws -> FTPSession {
        let trust = CertificateTrust(pin: c.pin)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = c.timeout
        let session = URLSession(configuration: config, delegate: trust, delegateQueue: nil)
        let tls = c.serverProtocol != .ftp
        let control = FTPStream(session: session, host: c.host.trimmed(), port: c.port, timeout: c.timeout)
        do {
            if c.serverProtocol == .ftpsImplicit { control.secure() }
            let greeting = try await reply(control)
            guard greeting.positive else { throw RemoteError("The server turned the connection away: \(greeting.message)") }
            if c.serverProtocol == .ftps {
                try await control.send("AUTH TLS")
                let auth = try await reply(control)
                guard auth.code == 234 else {
                    throw RemoteError("The server doesn't offer FTPS (it answered: \(auth.message)). Choose FTP, or switch TLS on at the server.")
                }
                control.secure()
            }
            try await control.send("USER \(c.username.isEmpty ? "anonymous" : c.username)")
            var login = try await reply(control)
            if login.code == 331 || login.code == 332 {
                try await control.send("PASS \(c.password)")
                login = try await reply(control)
            }
            guard login.code == 230 || login.code == 202 else { throw RemoteError("The server didn't accept the username or password.") }
            if tls {
                try await control.send("PBSZ 0")
                _ = try await reply(control)
                try await control.send("PROT P")
                let prot = try await reply(control)
                guard prot.positive else { throw RemoteError("The server refused encrypted transfers: \(prot.message)") }
            }
            try await control.send("FEAT")
            let feat = try await reply(control)
            let features = feat.positive
                ? Set(feat.text.split(separator: "\n").dropFirst().map { $0.trimmed().uppercased().before(" ") })
                : []
            if features.contains("UTF8") {
                try await control.send("OPTS UTF8 ON")
                _ = try await reply(control)
            }
            try await control.send("TYPE I")
            let type = try await reply(control)
            guard type.positive else { throw RemoteError("The server refused binary transfers: \(type.message)") }
            try await control.send("PWD")
            let pwd = try await reply(control)
            let quoted = Rx(#""((?:[^"]|"")*)""#).group(pwd.text)?.replacingOccurrences(of: "\"\"", with: "\"")
            var home = RemotePath.normalise(quoted ?? "/")
            if home.isEmpty { home = "/" }
            if !home.hasPrefix("/") { home = "/" + home }
            return FTPSession(session: session, control: control, connection: c, tls: tls, features: features, home: home)
        } catch {
            control.close()
            session.invalidateAndCancel()
            if let fingerprint = trust.rejected {
                throw UntrustedServerError(c.pin == nil ? .certificateUntrusted : .certificateChanged, fingerprint: fingerprint)
            }
            throw explain(error, c)
        }
    }

    static func explain(_ error: Error, _ c: Connection) -> Error {
        if error is RemoteError || error is UntrustedServerError { return error }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
                return RemoteError("Can't find “\(c.host)”. Check the address and that the phone is online.")
            case NSURLErrorCannotConnectToHost:
                return RemoteError("Nothing answered on \(c.host):\(c.port). Check the port and the protocol.")
            case NSURLErrorTimedOut:
                return RemoteError("\(c.host) didn't answer in time.")
            case NSURLErrorNotConnectedToInternet:
                return RemoteError("The phone is offline.")
            case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasBadDate,
                 NSURLErrorServerCertificateNotYetValid, NSURLErrorServerCertificateHasUnknownRoot:
                return RemoteError("The encrypted connection failed: \(ns.localizedDescription) Is it the right port for \(c.serverProtocol.label)?")
            default:
                break
            }
        }
        return RemoteError("\(c.serverProtocol.label): \(error.localizedDescription)")
    }

    private func fail(_ action: String, _ path: String, _ reply: Reply) -> RemoteError {
        switch reply.code {
        case 550 where action == "open": return RemoteError("“\(path)” doesn't exist on the server, or can't be opened.")
        case 550, 553, 532: return RemoteError("The server doesn't allow KultrDL to \(action) “\(path)” (\(reply.message)).")
        case 552: return RemoteError("The server is out of space (\(reply.message)).")
        case 522: return RemoteError("The server wants TLS session reuse on data connections, which KultrDL can't do. Switch that off on the server (vsftpd: require_ssl_reuse=NO) or use SFTP.")
        default: return RemoteError("Couldn't \(action) “\(path)”: \(reply.message.isEmpty ? "no answer" : reply.message)")
        }
    }

    // ------------------------------------------------------ data links --

    private static func isPrivate(_ ip: String) -> Bool {
        let parts = ip.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        return parts[0] == 10 || parts[0] == 127 || (parts[0] == 172 && (16...31).contains(parts[1]))
            || (parts[0] == 192 && parts[1] == 168) || (parts[0] == 169 && parts[1] == 254)
    }

    /** A passive data connection: EPSV (same host, new port), or PASV. */
    private func openData() async throws -> FTPStream {
        let host = connection.host.trimmed()
        let epsv = try await command("EPSV")
        if epsv.code == 229, let port = Rx(#"\(\|\|\|(\d+)\|\)"#).group(epsv.text).flatMap({ Int($0) }) {
            return FTPStream(session: session, host: host, port: port, timeout: connection.timeout)
        }
        let pasv = try await command("PASV")
        guard pasv.code == 227, let g = Rx(#"(\d+),(\d+),(\d+),(\d+),(\d+),(\d+)"#).find(pasv.text) else {
            throw RemoteError("The server has no passive mode: \(pasv.message)")
        }
        let numbers = g.dropFirst().compactMap { $0.flatMap { Int($0) } }
        guard numbers.count == 6 else { throw RemoteError("The server's passive address can't be read.") }
        let ip = numbers[0..<4].map(String.init).joined(separator: ".")
        // A server behind NAT may name an address only it can reach; use the one we already talk to (as FileZilla does).
        let target = Self.isPrivate(ip) && ip != host ? host : ip
        return FTPStream(session: session, host: target, port: numbers[4] * 256 + numbers[5], timeout: connection.timeout)
    }

    /** Runs a transfer command on a fresh data connection. */
    private func transfer(_ line: String, action: String, path: String, body: (FTPStream) async throws -> Void) async throws {
        let data = try await openData()
        defer { data.close() }
        let start = try await command(line)
        guard (100..<200).contains(start.code) else { throw fail(action, path, start) }
        if tls { data.secure() }
        try await body(data)
        data.task.closeWrite()
        let done = try await Self.reply(control)
        guard done.positive else { throw fail(action, path, done) }
    }

    // --------------------------------------------------------- session --

    func list(_ path: String) async throws -> [RemoteEntry] {
        let dir = RemotePath.resolve(home, path)
        // Change into the folder first: LIST with a path containing spaces confuses some servers.
        let cwd = try await command("CWD \(dir)")
        guard cwd.positive else { throw fail("open", dir, cwd) }
        var raw: [UInt8] = []
        let machine = features.contains("MLST") || features.contains("MLSD")
        try await transfer(machine ? "MLSD" : "LIST", action: "list", path: dir) { data in
            raw = try await data.readAll()
        }
        let lines = String(decoding: raw, as: UTF8.self).split(whereSeparator: \.isNewline).map(String.init)
        let entries = lines.compactMap { machine ? Self.parseMLSD($0) : Self.parseLIST($0) }
            .filter { $0.name != "." && $0.name != ".." }
        return entries.sorted { a, b in a.isDirectory != b.isDirectory ? a.isDirectory : a.name.lowercased() < b.name.lowercased() }
    }

    static func parseMLSD(_ line: String) -> RemoteEntry? {
        guard let space = line.firstIndex(of: " ") else { return nil }
        let facts = line[..<space].lowercased()
        let name = String(line[line.index(after: space)...])
        var type = ""
        var size: Int64 = 0
        for fact in facts.split(separator: ";") {
            let kv = fact.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { continue }
            if kv[0] == "type" { type = String(kv[1]) }
            if kv[0] == "size" { size = Int64(kv[1]) ?? 0 }
        }
        if type == "cdir" || type == "pdir" { return nil }
        return RemoteEntry(name: name, isDirectory: type == "dir" || type.hasPrefix("os.unix=symlink"), size: size)
    }

    static func parseLIST(_ line: String) -> RemoteEntry? {
        // Unix: "drwxr-xr-x 2 user group 4096 Jan 1 12:00 name"
        if let first = line.first, "dl-".contains(first) {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 9 else { return nil }
            var name = fields[8...].joined(separator: " ")
            if first == "l", let arrow = name.range(of: " -> ") { name = String(name[..<arrow.lowerBound]) }
            return RemoteEntry(name: name, isDirectory: first == "d" || first == "l", size: Int64(fields[4]) ?? 0)
        }
        // Windows: "01-01-24  12:00PM       <DIR>          name"
        let fields = line.split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count >= 4 else { return nil }
        let name = fields[3...].joined(separator: " ")
        return RemoteEntry(name: name, isDirectory: fields[2] == "<DIR>", size: Int64(fields[2]) ?? 0)
    }

    func isDirectory(_ path: String) async throws -> Bool {
        try await command("CWD \(RemotePath.resolve(home, path))").positive
    }

    func makeDirectories(_ path: String) async throws {
        for dir in RemotePath.ancestors(RemotePath.resolve(home, path)) {
            if try await isDirectory(dir) { continue }
            let made = try await command("MKD \(dir)")
            if !made.positive, !(try await isDirectory(dir)) { throw fail("create", dir, made) }
        }
    }

    func upload(_ file: URL, to path: String, progress: @escaping @Sendable (Int64) -> Void) async throws {
        let target = RemotePath.resolve(home, path)
        let partial = target + ".part"
        let input = try FileHandle(forReadingFrom: file)
        defer { try? input.close() }
        var sent: Int64 = 0
        try await transfer("STOR \(partial)", action: "write", path: target) { data in
            while true {
                try Task.checkCancellation()
                guard let chunk = try input.read(upToCount: 256 * 1024), !chunk.isEmpty else { break }
                try await data.write(chunk)
                sent += Int64(chunk.count)
                progress(sent)
            }
        }
        _ = try await command("DELE \(target)")
        let from = try await command("RNFR \(partial)")
        guard from.code == 350 else { throw fail("rename", target, from) }
        let to = try await command("RNTO \(target)")
        guard to.positive else { throw fail("rename", target, to) }
    }

    func delete(_ path: String) async throws {
        let target = RemotePath.resolve(home, path)
        let reply = try await command("DELE \(target)")
        guard reply.positive else { throw fail("delete", target, reply) }
    }

    func close() async {
        guard !closed else { return }
        closed = true
        _ = try? await command("QUIT")
        control.close()
        session.invalidateAndCancel()
    }
}
