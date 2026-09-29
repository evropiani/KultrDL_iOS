import Foundation
import KultrDLCore
import KultrDLMedia
import KultrDLRemote

/**
 * Checks KultrDL's engine against the real sites and against local test
 * servers, the way the app uses it. CI runs it after the unit tests; it
 * prints a report and never fails the build (sites refuse datacenter
 * addresses now and then).
 *
 *   swift run kultrdl-probe             everything
 *   swift run kultrdl-probe youtube     just the parts named
 */
@main
struct Probe {
    static var passed = 0
    static var failed: [String] = []

    static func check(_ name: String, _ body: () async throws -> String) async {
        let start = Date()
        do {
            let detail = try await body()
            passed += 1
            print("  ok    \(pad(name)) \(seconds(start))  \(detail)")
        } catch {
            failed.append(name)
            let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            print("  FAIL  \(pad(name)) \(seconds(start))  \(message.prefix(300))")
        }
    }

    static func pad(_ s: String) -> String { s.count >= 44 ? s : s + String(repeating: " ", count: 44 - s.count) }

    static func seconds(_ start: Date) -> String { String(format: "%5.1fs", Date().timeIntervalSince(start)) }

    static func section(_ title: String) {
        print("\n== \(title)")
    }

    static let work = FileManager.default.temporaryDirectory.appendingPathComponent("kultrdl-probe", isDirectory: true)

    static func main() async {
        let only = Set(CommandLine.arguments.dropFirst().map { $0.lowercased() })
        func wanted(_ part: String) -> Bool { only.isEmpty || only.contains(part) }
        try? FileManager.default.removeItem(at: work)
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

        let http = Http()
        let catalog = Catalog(http: http, country: { "US" }, spotifyCredentials: { nil })
        let solver = JSChallengeSolver(http: http, cacheDir: work)
        let youtube = YouTubePlayer(http: http, solver: solver, config: { EngineConfig.builtIn })
        let finder = StreamFinder(catalog: catalog, youtube: youtube)

        if wanted("search") { await search(catalog) }
        if wanted("links") { await links(catalog) }
        if wanted("youtube") { await youTube(youtube) }
        if wanted("streams") { await streams(catalog, finder) }
        if wanted("remote") { await remote() }

        print("\n\(passed) passed, \(failed.count) failed")
        if !failed.isEmpty { print("failed: " + failed.joined(separator: ", ")) }
    }

    // ------------------------------------------------------------ search --

    static func search(_ catalog: Catalog) async {
        section("Search")
        let sources: [Source] = [.youtubeMusic, .youtube, .appleMusic, .deezer, .soundcloud, .bandcamp]
        for source in sources {
            await check("search \(source.label)") {
                let r = try await catalog.search(source, "Daft Punk Get Lucky")
                guard let first = r.tracks.first ?? r.collections.first.map({ Track(id: $0.id, source: $0.source, title: $0.title, artist: $0.subtitle ?? "") }) else {
                    throw KultrError("no results")
                }
                return "\(r.tracks.count) tracks, \(r.collections.count) albums; \(first.artist) – \(first.title)"
            }
        }
        await check("album from YouTube Music search") {
            let r = try await catalog.search(.youtubeMusic, "Random Access Memories")
            guard let album = r.collections.first else { throw KultrError("no albums") }
            let loaded = try await catalog.load(album)
            return "\(loaded.title): \(loaded.tracks.count) tracks"
        }
        await check("album from Deezer search") {
            let r = try await catalog.search(.deezer, "Discovery Daft Punk")
            guard let album = r.collections.first else { throw KultrError("no albums") }
            let loaded = try await catalog.load(album)
            return "\(loaded.title): \(loaded.tracks.count) tracks"
        }
        await check("match an Apple Music track") {
            let r = try await catalog.search(.appleMusic, "Get Lucky Daft Punk")
            guard let track = r.tracks.first else { throw KultrError("no results") }
            guard let matched = try await catalog.match(track) else { throw KultrError("no match") }
            return "\(matched.title) → \(matched.streamUrl ?? "-")"
        }
    }

    // ------------------------------------------------------------- links --

    static func links(_ catalog: Catalog) async {
        section("Links")
        let samples: [(String, String)] = [
            ("YouTube video", "https://www.youtube.com/watch?v=5NV6Rdv1a3I"),
            ("YouTube Music", "https://music.youtube.com/watch?v=5NV6Rdv1a3I"),
            ("youtu.be", "https://youtu.be/5NV6Rdv1a3I"),
            ("YouTube playlist", "https://www.youtube.com/playlist?list=PLFgquLnL59alCl_2TQvOiD5Vgm1hCaGSI"),
            ("Spotify track", "https://open.spotify.com/track/69kOkLUCkxIZYexIgSG8rq"),
            ("Spotify album", "https://open.spotify.com/album/4m2880jivSbbyEGAKfITCa"),
            ("Apple Music album", "https://music.apple.com/us/album/random-access-memories/617154241"),
            ("Apple Music song", "https://music.apple.com/us/album/get-lucky-feat-pharrell-williams-nile-rodgers/617154241?i=617154366"),
            ("Deezer track", "https://www.deezer.com/track/67238735"),
            ("Deezer album", "https://www.deezer.com/album/6575789"),
            ("SoundCloud track", "https://soundcloud.com/forss/flickermood"),
            ("Bandcamp album", "https://c418.bandcamp.com/album/minecraft-volume-alpha"),
            ("Bandcamp track", "https://c418.bandcamp.com/track/sweden"),
            ("Tidal track", "https://tidal.com/browse/track/19542458"),
        ]
        for (name, url) in samples {
            await check(name) {
                switch try await catalog.resolve(url) {
                case .single(let t): return "track: \(t.artist) – \(t.title)\(t.streamUrl == nil ? "" : " [playable]")"
                case .many(let c): return "\(c.kind.label): \(c.title), \(c.tracks.count) tracks"
                }
            }
        }
    }

    // ----------------------------------------------------------- YouTube --

    static func youTube(_ youtube: YouTubePlayer) async {
        section("YouTube challenge solver")
        // The player script is static, so this works even where YouTube's pages turn the runner away.
        var playerUrl: String?
        await check("find the current player") {
            let api = try await Http().get("https://www.youtube.com/iframe_api")
            guard let id = Rx(#"player\\?/([0-9a-fA-F]{8,})\\?/"#).group(api) else { throw KultrError("no player id in iframe_api") }
            let url = JSChallengeSolver.canonicalPlayerUrl("/s/player/\(id)/player_ias.vflset/en_US/base.js")
            playerUrl = url
            return url
        }
        if let playerUrl {
            await check("signature timestamp") {
                guard let sts = try await youtube.solver.signatureTimestamp(playerUrl) else { throw KultrError("none found") }
                return "\(sts)"
            }
            await check("solve an n challenge") {
                let challenge = "gB7bY8xwQZ3kE5p1"
                let answers = try await youtube.solver.solveN([challenge], playerUrl: playerUrl)
                guard let answer = answers[challenge], !answer.isEmpty, answer != challenge else { throw KultrError("no answer (\(answers))") }
                return "\(challenge) → \(answer)"
            }
            await check("solve a signature") {
                let scrambled = String((0..<104).map { i in Character(UnicodeScalar(UInt8(65 + i % 26))) })
                let answers = try await youtube.solver.solveSignatures([scrambled], playerUrl: playerUrl)
                guard let answer = answers[scrambled], !answer.isEmpty, answer != scrambled else { throw KultrError("no answer") }
                return "\(scrambled.count) → \(answer.count) characters"
            }
        }

        section("YouTube player clients")
        let id = "5NV6Rdv1a3I"
        for client in EngineConfig.builtIn.clients {
            await check("client \(client.key)") {
                let s = try await youtube.streams(id, client: client)
                let aac = s.bestAAC.map { "AAC \($0.bitrate / 1000)k" } ?? "no AAC"
                let opus = s.bestOpus.map { "Opus \($0.bitrate / 1000)k" } ?? "no Opus"
                return "\(s.formats.count) audio formats; \(aac), \(opus)\(s.hlsManifestUrl == nil ? "" : ", HLS")"
            }
        }
        await check("fallback order") {
            let s = try await youtube.streams(id)
            return "served by \(s.client.key)"
        }
    }

    // ----------------------------------------------- download + convert --

    static func streams(_ catalog: Catalog, _ finder: StreamFinder) async {
        section("Streams, downloads and conversion")
        let downloader = StreamDownloader()
        var sourceFile: StreamDownloader.Result?
        var sourceTags = TrackTags(title: "Probe", artist: "KultrDL")

        await check("YouTube playback stream") {
            let s = try await finder.find("https://music.youtube.com/watch?v=5NV6Rdv1a3I", purpose: .playback(saver: false))
            return "\(s.label) via \(s.client ?? "-"), \(s.kind)"
        }
        await check("YouTube download (Opus)") {
            let s = try await finder.find("https://music.youtube.com/watch?v=5NV6Rdv1a3I", purpose: .download(prefer: .opus))
            let dir = work.appendingPathComponent("yt-opus", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let r = try await downloader.download(s, into: dir) { _ in }
            sourceFile = r
            let size = (try? FileManager.default.attributesOfItem(atPath: r.file.path)[.size] as? Int64) ?? 0
            return "\(s.label) via \(s.client ?? "-"): \(r.container), \(size / 1024) KB"
        }
        await check("YouTube download (AAC)") {
            let s = try await finder.find("https://www.youtube.com/watch?v=5NV6Rdv1a3I", purpose: .download(prefer: .aac))
            let dir = work.appendingPathComponent("yt-aac", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let r = try await downloader.download(s, into: dir) { _ in }
            if sourceFile == nil { sourceFile = r }
            let size = (try? FileManager.default.attributesOfItem(atPath: r.file.path)[.size] as? Int64) ?? 0
            return "\(s.label) via \(s.client ?? "-"): \(r.container), \(size / 1024) KB"
        }
        await check("SoundCloud stream") {
            let s = try await finder.find("https://soundcloud.com/forss/flickermood", purpose: .download(prefer: .best))
            return "\(s.label), \(s.kind)\(s.isPreview ? " (preview)" : "")"
        }
        await check("Bandcamp stream") {
            let s = try await finder.find("https://c418.bandcamp.com/track/sweden", purpose: .download(prefer: .best))
            return "\(s.label), \(s.kind)"
        }
        await check("cover art") {
            let data = try await catalog.http.getData("https://i.ytimg.com/vi/5NV6Rdv1a3I/hqdefault.jpg")
            let square = CoverArt.squareJPEG(data)
            sourceTags.cover = square
            return "\(data.count / 1024) KB → \((square?.count ?? 0) / 1024) KB square"
        }

        if sourceFile == nil {
            // YouTube turns datacenter addresses away now and then; Bandcamp's MP3 still exercises the converters.
            await check("Bandcamp download (for conversion)") {
                let s = try await finder.find("https://c418.bandcamp.com/track/sweden", purpose: .download(prefer: .best))
                let dir = work.appendingPathComponent("bandcamp", isDirectory: true)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let r = try await downloader.download(s, into: dir) { _ in }
                sourceFile = r
                let size = (try? FileManager.default.attributesOfItem(atPath: r.file.path)[.size] as? Int64) ?? 0
                return "\(r.container), \(size / 1024) KB"
            }
        }
        guard let source = sourceFile else {
            print("  (no download to convert)")
            return
        }
        let presets: [DownloadPreset] = [
            DownloadPreset(format: .mp3, quality: .k320),
            DownloadPreset(format: .flac, quality: .bit16),
            DownloadPreset(format: .aac, quality: .k256),
            DownloadPreset(format: .alac, quality: .bit16),
            DownloadPreset(format: .opus, quality: .original),
            DownloadPreset(format: .opus, quality: .k160),
            DownloadPreset(format: .vorbis, quality: .k256),
            DownloadPreset(format: .wav, quality: .bit16),
            DownloadPreset(format: .original, quality: .original),
        ]
        for preset in presets {
            await check("convert \(source.container) → \(preset.label)") {
                let dir = work.appendingPathComponent("out-\(preset.format.rawValue)-\(preset.quality.rawValue)", isDirectory: true)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let out = try await Transcoder.convert(source: source.file, container: source.container, preset: preset, tags: sourceTags, directory: dir) { _ in }
                let size = (try? FileManager.default.attributesOfItem(atPath: out.file.path)[.size] as? Int64) ?? 0
                return "\(out.fileExtension), \(size / 1024) KB"
            }
        }
    }

    // ------------------------------------------------------------ remote --

    /** The servers .github/scripts/test-servers.py starts (user "kultr", password "secret"). */
    static func remote() async {
        section("Servers")
        let keysDir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["KULTRDL_TEST_KEYS"] ?? "/tmp/kultrdl-test-keys")
        let file = work.appendingPathComponent("upload.bin")
        try? Data((0..<700_000).map { UInt8($0 % 251) }).write(to: file)

        func roundTrip(_ name: String, _ connection: Connection) async {
            await check(name) {
                var c = connection
                // First contact: trust on first use, as the app asks.
                var pin: String?
                do {
                    let session = try await Remote.open(c)
                    pin = session.newPin
                    await session.close()
                } catch let untrusted as UntrustedServerError {
                    pin = untrusted.fingerprint
                }
                c.pin = pin
                var step = "sign in"
                do {
                    return try await Remote.use(c) { session in
                        let folder = "KultrDL probe/Artist ü/Album"
                        step = "make folders"
                        try await session.makeDirectories(folder)
                        step = "upload"
                        try await session.upload(file, to: folder + "/Track 1.bin") { _ in }
                        step = "list"
                        let entries = try await session.list(folder)
                        guard let entry = entries.first(where: { $0.name == "Track 1.bin" }) else { throw KultrError("the upload isn't listed") }
                        guard entry.size == 700_000 else { throw KultrError("size \(entry.size) instead of 700000") }
                        step = "delete"
                        try await session.delete(folder + "/Track 1.bin")
                        step = "folder check"
                        let dirOK = try await session.isDirectory("KultrDL probe")
                        return "home \(session.home), pin \(pin?.prefix(20) ?? "-")…, folder \(dirOK)"
                    }
                } catch {
                    throw KultrError("\(step): \((error as? LocalizedError)?.errorDescription ?? String(describing: error))")
                }
            }
        }

        await roundTrip("FTP", Connection(serverProtocol: .ftp, host: "127.0.0.1", port: 2121, username: "kultr", password: "secret"))
        await roundTrip("FTPS explicit", Connection(serverProtocol: .ftps, host: "127.0.0.1", port: 2122, username: "kultr", password: "secret"))
        await roundTrip("FTPS implicit", Connection(serverProtocol: .ftpsImplicit, host: "127.0.0.1", port: 2123, username: "kultr", password: "secret"))
        await roundTrip("SFTP password", Connection(serverProtocol: .sftp, host: "127.0.0.1", port: 2222, username: "kultr", password: "secret"))
        for key in ["ed25519", "ecdsa", "rsa", "ed25519-pass", "rsa-pass", "rsa-pem", "ecdsa-pem", "pkcs8-ed25519"] {
            let path = keysDir.appendingPathComponent(key)
            guard let text = try? String(contentsOf: path, encoding: .utf8) else {
                print("  skip  SFTP key \(key) (no \(path.path))")
                continue
            }
            let passphrase = key.hasSuffix("-pass") ? "keypass" : ""
            await check("read key \(key)") { try Remote.checkKey(text, passphrase: passphrase) }
            await roundTrip("SFTP key \(key)", Connection(serverProtocol: .sftp, host: "127.0.0.1", port: 2222, username: "kultr", privateKey: text, passphrase: passphrase))
        }
        await check("SFTP wrong password is refused") {
            do {
                _ = try await Remote.open(Connection(serverProtocol: .sftp, host: "127.0.0.1", port: 2222, username: "kultr", password: "wrong"))
            } catch {
                return (error as? LocalizedError)?.errorDescription ?? "\(error)"
            }
            throw KultrError("signed in with the wrong password")
        }
        await check("SFTP changed key is refused") {
            do {
                _ = try await Remote.open(Connection(serverProtocol: .sftp, host: "127.0.0.1", port: 2222, username: "kultr", password: "secret", pin: "SHA256:AAAA"))
            } catch let untrusted as UntrustedServerError {
                return untrusted.reason.title
            }
            throw KultrError("connected despite the wrong pin")
        }
        await check("FTPS untrusted certificate is reported") {
            do {
                _ = try await Remote.open(Connection(serverProtocol: .ftps, host: "127.0.0.1", port: 2122, username: "kultr", password: "secret"))
            } catch let untrusted as UntrustedServerError {
                return "\(untrusted.reason.title) \(untrusted.fingerprint.prefix(24))…"
            }
            throw KultrError("a self-signed certificate was accepted without a pin")
        }
    }
}
