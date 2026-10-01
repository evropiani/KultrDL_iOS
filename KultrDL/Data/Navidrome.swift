import Foundation
import KultrDLCore
import Observation

/**
 * The user's Navidrome server: how to sign in (the password is in the
 * Keychain, never in this file or a backup), whether its history feeds the
 * recommendations, and which saved FTP/SFTP folder is its music folder, for
 * "Download to Navidrome". The JSON matches KultrDL for Android's backups.
 */
struct NavidromeConfig: Codable, Hashable {
    var url = ""
    var username = ""
    var useHistory = true
    /** The SFTP/FTP folder Navidrome reads its music from. */
    var destination: Destination?
    /** Ask Navidrome to rescan after downloads reach that folder. */
    var rescan = true
    var lastSyncAt: Int64 = 0
    var lastSync: String?
    var songCount = 0
    var lastScan: String?

    init() {}

    var configured: Bool {
        !url.trimmingCharacters(in: .whitespaces).isEmpty && !username.trimmingCharacters(in: .whitespaces).isEmpty
    }

    enum CodingKeys: String, CodingKey {
        case url, username, password, useHistory, destination, rescan, lastSyncAt, lastSync, songCount, lastScan
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        url = c.value(.url, "")
        username = c.value(.username, "")
        useHistory = c.value(.useHistory, true)
        destination = c.optional(.destination)
        rescan = c.value(.rescan, true)
        lastSyncAt = c.value(.lastSyncAt, 0)
        lastSync = c.optional(.lastSync)
        songCount = c.value(.songCount, 0)
        lastScan = c.optional(.lastScan)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(url, forKey: .url)
        try c.encode(username, forKey: .username)
        // Android keeps its sealed password here; this app keeps it in the Keychain.
        try c.encode("", forKey: .password)
        try c.encode(useHistory, forKey: .useHistory)
        try c.encodeIfPresent(destination, forKey: .destination)
        try c.encode(rescan, forKey: .rescan)
        try c.encode(lastSyncAt, forKey: .lastSyncAt)
        try c.encodeIfPresent(lastSync, forKey: .lastSync)
        try c.encode(songCount, forKey: .songCount)
        try c.encodeIfPresent(lastScan, forKey: .lastScan)
    }
}

@MainActor
@Observable
final class NavidromeStore {
    private static let file = "navidrome.json"
    private static let account = "navidrome.password"

    private(set) var config: NavidromeConfig
    @ObservationIgnored private var cached: (NavidromeConfig, String, Subsonic?)?
    /** The client for code off the main thread (artwork requests), nil without a login. */
    @ObservationIgnored nonisolated let shared = Shared<Subsonic?>(nil)

    init() {
        config = Storage.load(NavidromeConfig.self, Self.file) ?? NavidromeConfig()
        shared.value = makeClient()
    }

    func update(_ change: (inout NavidromeConfig) -> Void) {
        var next = config
        change(&next)
        guard next != config else { return }
        config = next
        Storage.save(next, Self.file)
        shared.value = makeClient()
    }

    private func makeClient() -> Subsonic? {
        guard config.configured else { return nil }
        let secret = password
        return secret.isEmpty ? nil : Subsonic(http: Http(), server: .init(url: config.url, username: config.username, password: secret))
    }

    var password: String { Keychain.get(Self.account) ?? "" }

    func setLogin(url: String, username: String, password: String) {
        Keychain.set(password, for: Self.account)
        cached = nil
        update {
            $0.url = Subsonic.baseUrl(url)
            $0.username = username.trimmingCharacters(in: .whitespaces)
            $0.lastSyncAt = 0
        }
        shared.value = makeClient()
    }

    func clear() {
        Keychain.delete(Self.account)
        cached = nil
        update { $0 = NavidromeConfig() }
        shared.value = nil
    }

    /** A client for the saved server, or nil when there is none (or no password on this phone). */
    func client(_ http: Http) -> Subsonic? {
        let c = config
        guard c.configured else { return nil }
        let secret = password
        if let hit = cached, hit.0.url == c.url, hit.0.username == c.username, hit.1 == secret { return hit.2 }
        let client = secret.isEmpty ? nil : Subsonic(http: http, server: .init(url: c.url, username: c.username, password: secret))
        cached = (c, secret, client)
        return client
    }

    /** Download straight into Navidrome's music folder needs that folder, on a server that still exists. */
    func destination(_ servers: ServerStore) -> Destination? {
        guard var d = config.destination, servers.get(d.serverId) != nil else { return nil }
        d.keepOnPhone = false
        return d
    }

    static func clientFor(_ http: Http, url: String, username: String, password: String) -> Subsonic {
        Subsonic(http: http, server: .init(url: url, username: username.trimmingCharacters(in: .whitespaces), password: password))
    }
}
