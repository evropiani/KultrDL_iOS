import Foundation
import KultrDLCore
import Observation
import Security

/**
 * Passwords, private keys and passphrases for servers, sealed by the
 * system's Keychain rather than kept in a settings file.
 */
enum Keychain {
    private static let service = "app.kultr.dl.servers"

    @discardableResult
    static func set(_ secret: String, for account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        guard !secret.isEmpty else { return true }
        var attributes = query
        attributes[kSecValueData as String] = Data(secret.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    static func get(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(_ account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

/**
 * An FTP, FTPS or SFTP server, with the folders on it downloads can go to.
 * Its secrets are in the Keychain; [pin] is the SSH host key or pinned
 * certificate it trusts. The JSON matches KultrDL for Android's backups
 * (their sealed secrets are dropped when restoring).
 */
struct SavedServer: Codable, Identifiable, Hashable {
    var id = UUID().uuidString
    var name: String
    var serverProtocol: ServerProtocol = .sftp
    var host: String
    var port: Int
    var username = ""
    var keyName: String?
    var pin: String?
    var folders: [String] = []
    var layout: FolderLayout = .flat
    var passive = true

    init(name: String, serverProtocol: ServerProtocol, host: String, port: Int) {
        self.name = name
        self.serverProtocol = serverProtocol
        self.host = host
        self.port = port
    }

    enum CodingKeys: String, CodingKey {
        case id, name, serverProtocol = "protocol", host, port, username, keyName, pin, folders, layout, passive
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, UUID().uuidString)
        host = try c.decode(String.self, forKey: .host)
        name = c.value(.name, host)
        serverProtocol = c.value(.serverProtocol, .sftp)
        port = c.value(.port, serverProtocol.defaultPort)
        username = c.value(.username, "")
        keyName = c.optional(.keyName)
        pin = c.optional(.pin)
        folders = c.value(.folders, [])
        layout = c.value(.layout, .flat)
        passive = c.value(.passive, true)
    }

    var address: String {
        (username.isEmpty ? "" : "\(username)@") + host + (port != serverProtocol.defaultPort ? ":\(port)" : "")
    }

    var password: String { Keychain.get("\(id).password") ?? "" }
    var privateKey: String { Keychain.get("\(id).key") ?? "" }
    var passphrase: String { Keychain.get("\(id).passphrase") ?? "" }

    func setSecrets(password: String, privateKey: String, passphrase: String) {
        Keychain.set(password, for: "\(id).password")
        Keychain.set(privateKey, for: "\(id).key")
        Keychain.set(passphrase, for: "\(id).passphrase")
    }

    func deleteSecrets() {
        for suffix in ["password", "key", "passphrase"] { Keychain.delete("\(id).\(suffix)") }
    }

    /** How to sign in, with the secrets from the Keychain. */
    var connection: Connection {
        Connection(
            serverProtocol: serverProtocol, host: host, port: port, username: username, password: password,
            privateKey: privateKey, passphrase: passphrase, pin: pin, passive: passive
        )
    }
}

@MainActor
@Observable
final class ServerStore {
    private(set) var servers: [SavedServer]

    init() {
        servers = Storage.load([SavedServer].self, "servers.json") ?? []
    }

    private func write() {
        Storage.save(servers, "servers.json")
    }

    func get(_ id: String) -> SavedServer? { servers.first { $0.id == id } }

    func save(_ server: SavedServer) {
        if let index = servers.firstIndex(where: { $0.id == server.id }) {
            servers[index] = server
        } else {
            servers.append(server)
        }
        write()
    }

    func remove(_ id: String) {
        get(id)?.deleteSecrets()
        servers.removeAll { $0.id == id }
        write()
    }

    /** The first key or certificate a server showed, trusted from then on. */
    func setPin(_ id: String, _ pin: String) {
        guard let index = servers.firstIndex(where: { $0.id == id }), servers[index].pin == nil else { return }
        servers[index].pin = pin
        write()
    }

    /** Servers from a backup that aren't here yet; they come without passwords. */
    func restore(_ list: [SavedServer]) -> Int {
        let known = Set(servers.map { $0.id })
        let added = list.filter { !known.contains($0.id) }
        guard !added.isEmpty else { return 0 }
        servers += added
        write()
        return added.count
    }

    func label(_ destination: Destination?) -> String {
        guard let destination else { return "This phone" }
        guard let server = get(destination.serverId) else { return "A removed server" }
        return "\(server.name) · \(folderLabel(destination.folder))"
    }
}
