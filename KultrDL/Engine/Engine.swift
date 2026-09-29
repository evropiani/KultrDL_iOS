import Foundation
import KultrDLCore
import Observation
import UIKit

/** A value shared with the stream code, which reads it off the main thread. */
final class Shared<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T

    init(_ value: T) {
        stored = value
    }

    var value: T {
        get {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
        set {
            lock.lock()
            stored = newValue
            lock.unlock()
        }
    }
}

/**
 * What KultrDL uses in place of yt-dlp: YouTube's player API clients and
 * the challenge solver. YouTube changes often, so newer client versions and
 * solver scripts come from engine/youtube.json in this app's repository,
 * checked once a day (Settings → Engine).
 */
@MainActor
@Observable
final class Engine {
    let solver: JSChallengeSolver
    let youtube: YouTubePlayer
    @ObservationIgnored let configBox: Shared<EngineConfig>
    private(set) var config: EngineConfig
    private(set) var solverVersion: String
    private(set) var checking = false

    private static let solverLibFile = "solver-lib.js"
    private static let solverCoreFile = "solver-core.js"

    init(http: Http) {
        var config = EngineConfig.builtIn
        if let saved = Storage.load(EngineConfig.self, "engine.json"), saved.version > config.version, !saved.clients.isEmpty {
            config = saved
        }
        let box = Shared(config)
        configBox = box
        self.config = config
        solver = JSChallengeSolver(http: http, cacheDir: Storage.caches)
        youtube = YouTubePlayer(http: http, solver: solver, config: { box.value })
        solverVersion = JSChallengeSolver.bundledVersion
        if let version = UserDefaults.standard.string(forKey: "solverVersion"),
           let lib = try? String(contentsOf: Storage.support.appendingPathComponent(Self.solverLibFile), encoding: .utf8),
           let core = try? String(contentsOf: Storage.support.appendingPathComponent(Self.solverCoreFile), encoding: .utf8),
           Self.newer(version, than: JSChallengeSolver.bundledVersion) {
            solver.scriptsOverride = (lib, core)
            solverVersion = version
        }
    }

    var summary: String {
        "Engine \(config.version) (\(config.updated)) · solver \(solverVersion) · \(config.clients.count) clients"
    }

    private static func newer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }
        let y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0
            let r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    /** Fetches engine/youtube.json; returns what changed, for a message. */
    @discardableResult
    func update(http: Http) async throws -> String {
        checking = true
        defer { checking = false }
        let text = try await http.get(EngineConfig.updateUrl + "?t=\(Int(Date().timeIntervalSince1970))")
        let remote = try JSONDecoder().decode(EngineConfig.self, from: Data(text.utf8))
        var notes: [String] = []
        if remote.version > config.version, !remote.clients.isEmpty {
            config = remote
            configBox.value = remote
            Storage.save(remote, "engine.json")
            youtube.resetSession()
            notes.append("clients \(remote.version) (\(remote.updated))")
        }
        if let version = remote.solverVersion, Self.newer(version, than: solverVersion),
           let libUrl = remote.solverLibUrl, let coreUrl = remote.solverCoreUrl {
            let lib = try await http.get(libUrl)
            let core = try await http.get(coreUrl)
            guard lib.count > 1000, core.count > 1000 else { throw KultrError("The new solver scripts look broken.") }
            try lib.write(to: Storage.support.appendingPathComponent(Self.solverLibFile), atomically: true, encoding: .utf8)
            try core.write(to: Storage.support.appendingPathComponent(Self.solverCoreFile), atomically: true, encoding: .utf8)
            UserDefaults.standard.set(version, forKey: "solverVersion")
            solver.scriptsOverride = (lib, core)
            solverVersion = version
            notes.append("solver \(version)")
        }
        return notes.isEmpty ? "The engine is up to date." : "Updated: " + notes.joined(separator: ", ") + "."
    }

    /** Goes back to what came with the app. */
    func reset() {
        config = EngineConfig.builtIn
        configBox.value = config
        try? FileManager.default.removeItem(at: Storage.support.appendingPathComponent("engine.json"))
        try? FileManager.default.removeItem(at: Storage.support.appendingPathComponent(Self.solverLibFile))
        try? FileManager.default.removeItem(at: Storage.support.appendingPathComponent(Self.solverCoreFile))
        UserDefaults.standard.removeObject(forKey: "solverVersion")
        solver.scriptsOverride = nil
        solverVersion = JSChallengeSolver.bundledVersion
        youtube.resetSession()
    }
}

/**
 * Settings → Engine → Test YouTube: asks YouTube for one video with each
 * client, fetches the start of the audio, switches to the first client that
 * works, and writes a report the user can copy. Stream links and the
 * phone's address are left out.
 */
@MainActor
enum YouTubeCheck {
    static let testVideo = "jNQXAC9IVRw"

    static func run(_ graph: AppGraph, onStep: @escaping (String) -> Void) async -> String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let device = UIDevice.current
        var lines = [
            "KultrDL \(version) · \(device.systemName) \(device.systemVersion) · \(deviceModel())",
            graph.engine.summary,
            "Test video: https://www.youtube.com/watch?v=\(testVideo)",
            "",
        ]
        var working: InnerTubeClient?
        for client in graph.engine.config.clients {
            onStep("Trying the \(client.label)…")
            do {
                let streams = try await graph.engine.youtube.streams(testVideo, client: client)
                guard let format = streams.bestAAC ?? streams.bestOpus else {
                    lines.append("\(client.label): no audio format")
                    continue
                }
                let wait = streams.availableAt.timeIntervalSinceNow
                if wait > 0 {
                    try await Task.sleep(nanoseconds: UInt64(min(wait, 10) * 1_000_000_000))
                }
                guard let url = URL(string: format.url) else { continue }
                var request = URLRequest(url: url)
                request.setValue(Http.browserUserAgent, forHTTPHeaderField: "User-Agent")
                for (key, value) in streams.headers { request.setValue(value, forHTTPHeaderField: key) }
                request.setValue("bytes=0-65535", forHTTPHeaderField: "Range")
                let (_, response) = try await URLSession.shared.data(for: request)
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                let family = URLComponents(string: format.url)?.queryItems?.first { $0.name == "ip" }?.value.map { $0.contains(":") ? "IPv6" : "IPv4" } ?? "no ip"
                let ok = (200..<300).contains(code)
                lines.append("\(client.label): \(ok ? "works" : "refused")")
                lines.append("  itag \(format.itag) \(format.mimeType) \(format.codecs), link bound to \(family), HTTP \(code)")
                if ok && working == nil { working = client }
            } catch is CancellationError {
                break
            } catch {
                lines.append("\(client.label): refused")
                lines.append("  " + scrub(describe(error)))
            }
        }
        lines.append("")
        if let working {
            graph.settings.update { $0.youtubeClient = working.key }
            lines.append("Using: \(working.label)")
        } else {
            lines.append("No client worked on this network.")
        }
        return lines.joined(separator: "\n")
    }

    private static func deviceModel() -> String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    private static func scrub(_ line: String) -> String {
        var text = line
        for (pattern, replacement) in [
            (#"https?://[^\s]*googlevideo\.com[^\s]*"#, "<stream link>"),
            (#"\bip=[^&\s]+"#, "ip=…"),
            (#"\b\d{1,3}(\.\d{1,3}){3}\b"#, "<ip>"),
        ] {
            text = text.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        return text
    }
}
