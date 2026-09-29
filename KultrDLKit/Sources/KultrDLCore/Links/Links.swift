import Foundation

/** What a pasted link points at, before anything is fetched. */
public struct LinkTarget: Equatable, Sendable {
    public enum Kind: Sendable { case track, album, playlist, artist, unknown }

    public let source: Source
    public let kind: Kind
    public let id: String?
    public let url: String
}

public enum Links {
    private static let urlPattern = Rx.i(#"https?://[^\s<>"']+"#)
    private static let spotifyUri = Rx(#"^spotify:(track|album|playlist|artist):([A-Za-z0-9]+)$"#)

    /** The first link in shared text ("Listen to this: https://…"). */
    public static func find(_ text: String) -> String? {
        let t = text.trimmed()
        if spotifyUri.matches(t) { return t }
        guard let url = urlPattern.group(t, 0) else { return nil }
        return url.trimmingCharacters(in: CharacterSet(charactersIn: ".,)]!?"))
    }

    public static func isLink(_ text: String) -> Bool {
        let t = text.trimmed()
        return find(t) != nil && (t.lowercased().hasPrefix("http") || t.hasPrefix("spotify:"))
    }

    /** Links that must be followed to see where they lead. */
    public static func isShortLink(_ url: String) -> Bool {
        guard let host = host(url) else { return false }
        let short: Set<String> = ["spotify.link", "deezer.page.link", "link.deezer.com", "on.soundcloud.com", "tidal.link", "amzn.to", "qobuz.link"]
        return short.contains(host) || host.hasSuffix(".app.link")
    }

    public static func host(_ url: String) -> String? {
        guard let h = URLComponents(string: url.trimmed())?.host?.lowercased() else { return nil }
        return h.removingPrefix("www.").removingPrefix("m.")
    }

    static func query(_ url: String, _ name: String) -> String? {
        URLComponents(string: url)?.queryItems?.first { $0.name == name }?.value?.nonEmpty
    }

    static func segments(_ url: String) -> [String] {
        (URLComponents(string: url)?.path ?? "").split(separator: "/").map(String.init)
    }

    public static func classify(_ raw: String) -> LinkTarget {
        let url = raw.trimmed()
        if let g = spotifyUri.matchEntire(url), let kind = g[1], let id = g[2] {
            return LinkTarget(source: .spotify, kind: kindOf(kind), id: id, url: "https://open.spotify.com/\(kind)/\(id)")
        }
        guard let host = host(url) else { return LinkTarget(source: .web, kind: .unknown, id: nil, url: url) }
        let path = segments(url)
        func at(_ i: Int) -> String? { i >= 0 && i < path.count ? path[i] : nil }

        if host == "youtu.be" {
            return LinkTarget(source: .youtube, kind: .track, id: path.first, url: url)
        }
        if host == "music.youtube.com" || host.hasSuffix("youtube.com") || host == "youtube-nocookie.com" {
            let source: Source = host == "music.youtube.com" ? .youtubeMusic : .youtube
            let video = query(url, "v") ?? (["shorts", "live", "embed"].contains(path.first ?? "") ? at(1) : nil)
            if path.first == "browse", let id = at(1), id.hasPrefix("MPRE") {
                return LinkTarget(source: .youtubeMusic, kind: .album, id: id, url: url)
            }
            if path.first == "browse", let id = at(1), id.hasPrefix("VL") {
                return LinkTarget(source: source, kind: .playlist, id: String(id.dropFirst(2)), url: url)
            }
            if let video { return LinkTarget(source: source, kind: .track, id: video, url: url) }
            if let list = query(url, "list") { return LinkTarget(source: source, kind: .playlist, id: list, url: url) }
            if path.first == "channel" || path.first?.hasPrefix("@") == true {
                return LinkTarget(source: source, kind: .artist, id: at(1) ?? path.first, url: url)
            }
            return LinkTarget(source: source, kind: .unknown, id: nil, url: url)
        }
        if host == "open.spotify.com" || host == "play.spotify.com" {
            let p = Array(path.drop { $0.hasPrefix("intl-") || $0 == "embed" })
            return LinkTarget(source: .spotify, kind: kindOf(p.first), id: p.count > 1 ? p[1] : nil, url: url)
        }
        if host == "music.apple.com" || host == "itunes.apple.com" || host == "geo.music.apple.com" {
            let song = query(url, "i")
            let kindWord = path.first { ["album", "song", "playlist", "artist"].contains($0) }
            let last = path.last
            if let song { return LinkTarget(source: .appleMusic, kind: .track, id: song, url: url) }
            switch kindWord {
            case "song": return LinkTarget(source: .appleMusic, kind: .track, id: last?.removingPrefix("id"), url: url)
            case "album": return LinkTarget(source: .appleMusic, kind: .album, id: last?.removingPrefix("id"), url: url)
            case "playlist": return LinkTarget(source: .appleMusic, kind: .playlist, id: last, url: url)
            case "artist": return LinkTarget(source: .appleMusic, kind: .artist, id: last, url: url)
            default: return LinkTarget(source: .appleMusic, kind: .unknown, id: nil, url: url)
            }
        }
        if host.hasSuffix("deezer.com") {
            let i = path.firstIndex { ["track", "album", "playlist", "artist"].contains($0) } ?? -1
            return LinkTarget(source: .deezer, kind: kindOf(at(i)), id: at(i + 1), url: url)
        }
        if host.hasSuffix("tidal.com") {
            let i = path.firstIndex { ["track", "album", "playlist", "artist", "video"].contains($0) } ?? -1
            let word = at(i).map { $0 == "video" ? "track" : $0 }
            return LinkTarget(source: .tidal, kind: kindOf(word), id: at(i + 1), url: url)
        }
        if host.hasSuffix("qobuz.com") {
            let i = path.firstIndex { ["track", "album", "playlist", "artist", "interpreter"].contains($0) } ?? -1
            let word = at(i).map { $0 == "interpreter" ? "artist" : $0 }
            return LinkTarget(source: .qobuz, kind: kindOf(word), id: path.last, url: url)
        }
        if host.hasPrefix("music.amazon.") || (host.hasPrefix("amazon.") && path.first == "music") {
            let track = query(url, "trackAsin")
            let i = path.firstIndex { ["albums", "playlists", "user-playlists", "tracks", "artists"].contains($0) } ?? -1
            let kind: LinkTarget.Kind
            if track != nil {
                kind = .track
            } else {
                switch at(i) {
                case "albums": kind = .album
                case "playlists", "user-playlists": kind = .playlist
                case "tracks": kind = .track
                case "artists": kind = .artist
                default: kind = .unknown
                }
            }
            return LinkTarget(source: .amazonMusic, kind: kind, id: track ?? at(i + 1), url: url)
        }
        if host.hasSuffix("soundcloud.com") {
            let kind: LinkTarget.Kind
            if at(1) == "sets" {
                kind = .playlist
            } else if path.count >= 2 {
                kind = .track
            } else if path.count == 1 {
                kind = .artist
            } else {
                kind = .unknown
            }
            return LinkTarget(source: .soundcloud, kind: kind, id: nil, url: url)
        }
        if host.hasSuffix("bandcamp.com") {
            let kind: LinkTarget.Kind = path.first == "track" ? .track : path.first == "album" ? .album : .artist
            return LinkTarget(source: .bandcamp, kind: kind, id: nil, url: url)
        }
        return LinkTarget(source: .web, kind: .unknown, id: nil, url: url)
    }

    private static func kindOf(_ word: String?) -> LinkTarget.Kind {
        switch word {
        case "track", "song": return .track
        case "album": return .album
        case "playlist": return .playlist
        case "artist": return .artist
        default: return .unknown
        }
    }

    /** The file types that are audio, for links straight to a file. */
    public static let audioExtensions: Set<String> = ["mp3", "m4a", "aac", "flac", "wav", "ogg", "oga", "opus", "alac", "aif", "aiff", "caf", "mp4", "webm"]

    /** A link straight to an audio file. */
    public static func isAudioFile(_ url: String) -> Bool {
        guard let path = URLComponents(string: url)?.path else { return false }
        return audioExtensions.contains((path as NSString).pathExtension.lowercased())
    }
}
