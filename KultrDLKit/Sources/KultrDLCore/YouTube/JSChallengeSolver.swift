import Foundation
import JavaScriptCore

/**
 * Solves YouTube's stream-link challenges ("n" and signatures) the way
 * yt-dlp does: its challenge solver scripts (yt-dlp/ejs, bundled) read the
 * player's own JavaScript and run the relevant functions. Here they run in
 * JavaScriptCore instead of Deno or QuickJS.
 *
 * The player is several megabytes, so it is fetched once per player
 * version and kept on disk, together with the solver's much smaller
 * preprocessed form of it; answers are kept too.
 */
public final class JSChallengeSolver: @unchecked Sendable {
    private let http: Http
    private let cacheDir: URL
    private let queue = DispatchQueue(label: "kultrdl.js-challenges")
    private var context: JSContext?
    private var lastException: String?
    private let lock = NSLock()
    private var nCache: [String: String] = [:]
    private var sigSpecs: [String: [Int]] = [:]
    /** Overrides for the bundled scripts (newer ones from the engine update). */
    public var scriptsOverride: (lib: String, core: String)?

    public init(http: Http, cacheDir: URL) {
        self.http = http
        self.cacheDir = cacheDir.appendingPathComponent("youtube-player", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.cacheDir, withIntermediateDirectories: true)
    }

    /** The version of the bundled solver scripts. */
    public static let bundledVersion = "0.8.0"

    static func bundledScripts() -> (lib: String, core: String)? {
        guard
            let lib = Bundle.module.url(forResource: "yt.solver.lib.min", withExtension: "js", subdirectory: "ejs")
                ?? Bundle.module.url(forResource: "yt.solver.lib.min", withExtension: "js"),
            let core = Bundle.module.url(forResource: "yt.solver.core.min", withExtension: "js", subdirectory: "ejs")
                ?? Bundle.module.url(forResource: "yt.solver.core.min", withExtension: "js"),
            let libText = try? String(contentsOf: lib, encoding: .utf8),
            let coreText = try? String(contentsOf: core, encoding: .utf8)
        else { return nil }
        return (libText, coreText)
    }

    // --------------------------------------------------------- player --

    private static let playerIdPattern = Rx(#"/s/player/([a-fA-F0-9]{8,})/"#)
    private static let stsPattern = Rx(#"(?:signatureTimestamp|sts)\s*:\s*([0-9]{5})"#)

    public static func playerId(_ playerUrl: String) -> String? { playerIdPattern.group(playerUrl) }

    /** The main variant of the player, as yt-dlp uses. */
    public static func canonicalPlayerUrl(_ playerUrl: String) -> String {
        guard let id = playerId(playerUrl) else {
            return playerUrl.hasPrefix("http") ? playerUrl : "https://www.youtube.com" + playerUrl
        }
        return "https://www.youtube.com/s/player/\(id)/player_ias.vflset/en_US/base.js"
    }

    private func file(_ playerId: String, _ kind: String) -> URL {
        cacheDir.appendingPathComponent("\(playerId).\(kind)")
    }

    /** The player's JavaScript, from disk when this version was seen before. */
    public func playerCode(_ playerUrl: String) async throws -> String {
        let url = Self.canonicalPlayerUrl(playerUrl)
        let id = Self.playerId(url) ?? Catalog.hash(url)
        let path = file(id, "js")
        if let cached = try? String(contentsOf: path, encoding: .utf8), !cached.isEmpty { return cached }
        let code = try await http.get(url)
        try? code.write(to: path, atomically: true, encoding: .utf8)
        prune(keep: id)
        return code
    }

    /** The signature timestamp YouTube wants back with player requests for this player. */
    public func signatureTimestamp(_ playerUrl: String) async throws -> Int? {
        let id = Self.playerId(playerUrl) ?? Catalog.hash(playerUrl)
        let path = file(id, "sts")
        if let text = try? String(contentsOf: path, encoding: .utf8), let sts = Int(text) { return sts }
        let code = try await playerCode(playerUrl)
        guard let sts = Self.stsPattern.group(code).flatMap({ Int($0) }) else { return nil }
        try? String(sts).write(to: path, atomically: true, encoding: .utf8)
        return sts
    }

    /** Keeps the newest few players on disk. */
    private func prune(keep: String) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let players = Set(files.map { $0.deletingPathExtension().lastPathComponent })
        guard players.count > 3 else { return }
        let dated = players.filter { $0 != keep }.map { id -> (String, Date) in
            let date = (try? file(id, "js").resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return (id, date)
        }.sorted { $0.1 < $1.1 }
        for (id, _) in dated.prefix(players.count - 3) {
            for f in files where f.deletingPathExtension().lastPathComponent == id { try? fm.removeItem(at: f) }
        }
    }

    // -------------------------------------------------------- solving --

    /** Answers for "n" values: the value to put back in each link. */
    public func solveN(_ challenges: [String], playerUrl: String) async throws -> [String: String] {
        let id = Self.playerId(playerUrl) ?? Catalog.hash(playerUrl)
        var answers: [String: String] = [:]
        var missing: [String] = []
        lock.lock()
        for c in Set(challenges) {
            if let a = nCache["\(id)|\(c)"] { answers[c] = a } else { missing.append(c) }
        }
        lock.unlock()
        guard !missing.isEmpty else { return answers }
        let solved = try await run(playerUrl: playerUrl, requests: [("n", missing)])
        lock.lock()
        for (c, a) in solved["n"] ?? [:] {
            answers[c] = a
            nCache["\(id)|\(c)"] = a
        }
        lock.unlock()
        return answers
    }

    /** Deciphers signatures: each scrambled value to what the link needs. */
    public func solveSignatures(_ scrambled: [String], playerUrl: String) async throws -> [String: String] {
        let id = Self.playerId(playerUrl) ?? Catalog.hash(playerUrl)
        // The scrambling only depends on the length, so solve "0, 1, 2, …" once per length (as yt-dlp does).
        var specs: [Int: [Int]] = [:]
        var missingLengths: [Int] = []
        lock.lock()
        for s in Set(scrambled) {
            let n = s.unicodeScalars.count
            if let spec = sigSpecs["\(id)|\(n)"] { specs[n] = spec } else if !missingLengths.contains(n) { missingLengths.append(n) }
        }
        lock.unlock()
        if !missingLengths.isEmpty {
            let challenges = missingLengths.map { n in String(String.UnicodeScalarView((0..<n).compactMap { Unicode.Scalar(UInt32($0)) })) }
            let solved = try await run(playerUrl: playerUrl, requests: [("sig", challenges)])
            lock.lock()
            for (challenge, answer) in solved["sig"] ?? [:] {
                let spec = answer.unicodeScalars.map { Int($0.value) }
                let n = challenge.unicodeScalars.count
                specs[n] = spec
                sigSpecs["\(id)|\(n)"] = spec
            }
            lock.unlock()
        }
        var out: [String: String] = [:]
        for s in Set(scrambled) {
            let chars = Array(s.unicodeScalars)
            guard let spec = specs[chars.count], spec.allSatisfy({ $0 >= 0 && $0 < chars.count }) else { continue }
            out[s] = String(String.UnicodeScalarView(spec.map { chars[$0] }))
        }
        return out
    }

    /** Runs the solver on the player for these requests: type → (challenge → answer). */
    private func run(playerUrl: String, requests: [(String, [String])]) async throws -> [String: [String: String]] {
        let id = Self.playerId(playerUrl) ?? Catalog.hash(playerUrl)
        let preprocessedPath = file(id, "pre.js")
        let preprocessed = try? String(contentsOf: preprocessedPath, encoding: .utf8)
        let player = preprocessed == nil ? try await playerCode(playerUrl) : nil
        guard let scripts = scriptsOverride ?? Self.bundledScripts() else {
            throw KultrError("The YouTube challenge solver is missing from the app.")
        }
        let output: String = try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    continuation.resume(returning: try self.evaluate(scripts: scripts, player: player, preprocessed: preprocessed, requests: requests))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        let json = try JSON.parse(output)
        if json["type"].string == "error" {
            // A stale preprocessed copy is the likeliest cause; drop it so the next try starts from the player.
            try? FileManager.default.removeItem(at: preprocessedPath)
            throw KultrError("YouTube's player changed in a way the challenge solver doesn't know yet: \(json["error"].string ?? "unknown error")")
        }
        if preprocessed == nil, let pre = json["preprocessed_player"]?.rawString, !pre.isEmpty {
            try? pre.write(to: preprocessedPath, atomically: true, encoding: .utf8)
        }
        var result: [String: [String: String]] = [:]
        for (i, response) in json["responses"].array.enumerated() where i < requests.count {
            guard response["type"].string == "result", let data = response["data"]?.object else { continue }
            var answers: [String: String] = [:]
            for (challenge, answer) in data.entries {
                if let a = answer.rawString { answers[challenge] = a }
            }
            result[requests[i].0] = answers
        }
        return result
    }

    /** On [queue] only. */
    private func evaluate(scripts: (lib: String, core: String), player: String?, preprocessed: String?, requests: [(String, [String])]) throws -> String {
        let ctx: JSContext
        if let existing = context {
            ctx = existing
        } else {
            guard let fresh = JSContext() else { throw KultrError("JavaScript isn't available.") }
            fresh.exceptionHandler = { [weak self] _, exception in
                self?.lastException = exception?.toString()
            }
            lastException = nil
            fresh.evaluateScript(scripts.lib + "\n;Object.assign(globalThis, lib);\n")
            fresh.evaluateScript(scripts.core)
            if let e = lastException {
                throw KultrError("The YouTube challenge solver didn't load: \(e)")
            }
            context = fresh
            ctx = fresh
        }
        lastException = nil
        var input = JSONObject()
        if let preprocessed {
            input["type"] = "preprocessed"
            ctx.setObject(preprocessed, forKeyedSubscript: "__kdlPlayer" as NSString)
        } else {
            input["type"] = "player"
            input["output_preprocessed"] = true
            ctx.setObject(player ?? "", forKeyedSubscript: "__kdlPlayer" as NSString)
        }
        input["requests"] = .arr(requests.map { type, challenges in
            ["type": .str(type), "challenges": .arr(challenges.map { .str($0) })]
        })
        let field = preprocessed != nil ? "preprocessed_player" : "player"
        let call = "(function(){ var input = \(JSON.obj(input).compact); input['\(field)'] = globalThis.__kdlPlayer; " +
            "try { return JSON.stringify(jsc(input)); } finally { globalThis.__kdlPlayer = undefined; } })()"
        let value = ctx.evaluateScript(call)
        if let e = lastException { throw KultrError("The YouTube challenge solver failed: \(e)") }
        guard let text = value?.toString(), text != "undefined" else { throw KultrError("The YouTube challenge solver gave no answer.") }
        return text
    }
}
