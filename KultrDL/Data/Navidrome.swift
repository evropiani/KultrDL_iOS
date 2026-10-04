import Foundation
import KultrDLCore
import Observation

/**
 * The user's Navidrome server: how to sign in (passwords are in the
 * Keychain, never in this file or a backup), whether its history feeds the
 * recommendations, and which saved FTP/SFTP folder is its music folder, for
 * "Download to Navidrome". The JSON matches KultrDL for Android's backups.
 *
 * [username] is the account the user listens with: Navidrome keeps plays,
 * stars and ratings per account. Only admins may start a scan, so an admin
 * login can be kept beside it, used for nothing else.
 */
struct NavidromeConfig: Codable, Hashable {
    var url = ""
    var username = ""
    /** Whether [username] is an admin, as the server said at the last sync (nil: not known). */
    var isAdmin: Bool?
    /** An admin login for starting scans, when [username] isn't one (its password is in the Keychain). */
    var adminUsername = ""
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
        case url, username, password, isAdmin, adminUsername, adminPassword, useHistory, destination, rescan, lastSyncAt, lastSync, songCount, lastScan
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        url = c.value(.url, "")
        username = c.value(.username, "")
        isAdmin = c.optional(.isAdmin)
        adminUsername = c.value(.adminUsername, "")
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
        // Android keeps its sealed passwords here; this app keeps them in the Keychain.
        try c.encode("", forKey: .password)
        try c.encodeIfPresent(isAdmin, forKey: .isAdmin)
        try c.encode(adminUsername, forKey: .adminUsername)
        try c.encode("", forKey: .adminPassword)
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
    private static let adminAccount = "navidrome.admin-password"

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
    var adminPassword: String { Keychain.get(Self.adminAccount) ?? "" }
    /** An admin login is kept for starting scans. */
    var hasAdmin: Bool { !config.adminUsername.isEmpty && !adminPassword.isEmpty }

    /**
     * Saves the login the user listens with. Moving from an admin to another
     * account on the same server keeps the admin login for rescans, so
     * switching to one's own account doesn't stop them. Returns that admin's
     * name when it was kept. An admin login for another server is dropped.
     */
    @discardableResult
    func signIn(_ http: Http, url: String, username: String, password newPassword: String) async -> String? {
        let before = config
        let oldPassword = password
        let base = Subsonic.baseUrl(url)
        let user = username.trimmingCharacters(in: .whitespaces)
        let sameServer = before.configured && before.url == base
        let another = sameServer && before.username.lowercased() != user.lowercased()
        var keep = another && !hasAdmin && before.isAdmin != false && !oldPassword.isEmpty
        if keep, before.isAdmin != true {
            let old = Self.clientFor(http, url: before.url, username: before.username, password: oldPassword)
            keep = (try? await old.isAdmin()) == true
        }
        if keep {
            Keychain.set(oldPassword, for: Self.adminAccount)
        } else if !sameServer {
            Keychain.delete(Self.adminAccount)
        }
        Keychain.set(newPassword, for: Self.account)
        cached = nil
        update {
            $0.url = base
            $0.username = user
            $0.isAdmin = nil
            if keep {
                $0.adminUsername = before.username
            } else if !sameServer {
                $0.adminUsername = ""
            }
            $0.lastSyncAt = 0
        }
        shared.value = makeClient()
        return keep ? before.username : nil
    }

    /** Keeps [username] as the login for rescans, if the server says it's an admin. Throws when it can't sign in. */
    func keepAdmin(_ http: Http, username: String, password: String) async throws -> Bool {
        let name = username.trimmingCharacters(in: .whitespaces)
        let admin = try await Self.clientFor(http, url: config.url, username: name, password: password).isAdmin()
        if admin == false { return false }
        Keychain.set(password, for: Self.adminAccount)
        update { $0.adminUsername = name }
        return true
    }

    func forgetAdmin() {
        Keychain.delete(Self.adminAccount)
        update { $0.adminUsername = "" }
    }

    func clear() {
        Keychain.delete(Self.account)
        Keychain.delete(Self.adminAccount)
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

    /** The client for starting scans: the admin login when one is kept, otherwise [client]. */
    func scanClient(_ http: Http) -> Subsonic? {
        let c = config
        guard c.configured, !c.adminUsername.isEmpty else { return client(http) }
        let secret = adminPassword
        guard !secret.isEmpty else { return client(http) }
        return Subsonic(http: http, server: .init(url: c.url, username: c.adminUsername, password: secret))
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
