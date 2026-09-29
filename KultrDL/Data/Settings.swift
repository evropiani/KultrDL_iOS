import Foundation
import KultrDLCore
import Observation

enum ThemeMode: String, Codable, CaseIterable, Hashable {
    case system = "SYSTEM", dark = "DARK", light = "LIGHT"

    var label: String {
        switch self {
        case .system: return "System"
        case .dark: return "Dark"
        case .light: return "Light"
        }
    }

    init(from decoder: Decoder) throws {
        self = ThemeMode(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .system
    }
}

enum StreamQuality: String, Codable, CaseIterable, Hashable {
    case high = "HIGH", saver = "SAVER"

    var label: String { self == .high ? "Best" : "Data saver" }

    init(from decoder: Decoder) throws {
        self = StreamQuality(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .high
    }
}

/** A folder on a saved server that downloads are sent to. */
struct Destination: Codable, Hashable {
    var serverId: String
    var folder: String
    var keepOnPhone = false

    init(serverId: String, folder: String, keepOnPhone: Bool = false) {
        self.serverId = serverId
        self.folder = folder
        self.keepOnPhone = keepOnPhone
    }

    enum CodingKeys: String, CodingKey { case serverId, folder, keepOnPhone }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        serverId = try c.decode(String.self, forKey: .serverId)
        folder = c.value(.folder, "")
        keepOnPhone = c.value(.keepOnPhone, false)
    }
}

/**
 * Everything the user can set, as one JSON document so it backs up and
 * restores as a whole. The names match KultrDL for Android, so backups move
 * between the two.
 */
struct Settings: Codable, Equatable {
    var theme: ThemeMode = .system
    var accentFromArtwork = true
    var accent = "#7c8cff"
    var reduceMotion = false
    var backdropArtwork = true
    var searchSource: Source = .youtubeMusic
    var country = ""
    var spotifyClientId = ""
    var spotifyClientSecret = ""
    var download = DownloadPreset()
    var askEachTime = false
    /** Where downloads go; nil is this phone. */
    var destination: Destination?
    /** Downloads on the phone show in the Files app (Android's "Music folder"). */
    var saveToMusic = true
    var wifiOnly = false
    var embedArtwork = true
    var streamQuality: StreamQuality = .high
    /** The YouTube client tried first; empty picks automatically. */
    var youtubeClient = ""
    var autoUpdateEngine = true
    var lastEngineCheck: Int64 = 0

    init() {}

    enum CodingKeys: String, CodingKey {
        case theme, accentFromArtwork, accent, reduceMotion, backdropArtwork, searchSource, country
        case spotifyClientId, spotifyClientSecret, download, askEachTime, destination, saveToMusic
        case wifiOnly, embedArtwork, streamQuality, youtubeClient, autoUpdateEngine, lastEngineCheck
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings()
        theme = c.value(.theme, d.theme)
        accentFromArtwork = c.value(.accentFromArtwork, d.accentFromArtwork)
        accent = c.value(.accent, d.accent)
        reduceMotion = c.value(.reduceMotion, d.reduceMotion)
        backdropArtwork = c.value(.backdropArtwork, d.backdropArtwork)
        searchSource = c.value(.searchSource, d.searchSource)
        if !searchSource.searchable { searchSource = d.searchSource }
        country = c.value(.country, d.country)
        spotifyClientId = c.value(.spotifyClientId, d.spotifyClientId)
        spotifyClientSecret = c.value(.spotifyClientSecret, d.spotifyClientSecret)
        download = c.value(.download, d.download)
        askEachTime = c.value(.askEachTime, d.askEachTime)
        destination = c.optional(.destination)
        saveToMusic = c.value(.saveToMusic, d.saveToMusic)
        wifiOnly = c.value(.wifiOnly, d.wifiOnly)
        embedArtwork = c.value(.embedArtwork, d.embedArtwork)
        streamQuality = c.value(.streamQuality, d.streamQuality)
        youtubeClient = c.value(.youtubeClient, d.youtubeClient)
        autoUpdateEngine = c.value(.autoUpdateEngine, d.autoUpdateEngine)
        lastEngineCheck = c.value(.lastEngineCheck, d.lastEngineCheck)
    }
}

@MainActor
@Observable
final class SettingsStore {
    private(set) var settings: Settings
    /** The same settings for code off the main thread (the catalogue's country and Spotify keys). */
    @ObservationIgnored nonisolated let shared: Shared<Settings>

    init() {
        let loaded = Storage.load(Settings.self, "settings.json") ?? Settings()
        settings = loaded
        shared = Shared(loaded)
    }

    func update(_ change: (inout Settings) -> Void) {
        var next = settings
        change(&next)
        guard next != settings else { return }
        settings = next
        shared.value = next
        Storage.save(next, "settings.json")
    }

    func replace(_ settings: Settings) {
        update { $0 = settings }
    }
}
