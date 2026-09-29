import KultrDLCore
import KultrDLRemote
import SwiftUI
import UniformTypeIdentifiers

/** The saved FTP and SFTP servers. */
struct ServersScreen: View {
    @Environment(\.kultr) private var theme

    var body: some View {
        let graph = AppGraph.shared
        let c = theme.colors
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                Text("Send downloads straight to a NAS, a seedbox or any computer that has SFTP or FTP. Save the folders you use, then choose one when you download.")
                    .font(KFont.bodyMedium)
                    .foregroundStyle(c.ink2)
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                HStack {
                    Pill("Add server", icon: "plus", accent: true) { graph.actions.navigate(.server("new")) }
                }
                .padding(.horizontal, 16)
                if graph.servers.servers.isEmpty {
                    EmptyState(
                        icon: "server.rack",
                        title: "No servers yet",
                        message: "Add one with its address, a username and password (or an SSH key), and the folders music should go to."
                    )
                }
                ForEach(graph.servers.servers) { server in
                    Button { graph.actions.navigate(.server(server.id)) } label: {
                        GlassPanel {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 12) {
                                    Image(systemName: "server.rack").foregroundStyle(c.accent)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(server.name).font(KFont.titleMedium).foregroundStyle(c.ink).lineLimit(1)
                                        Text("\(server.serverProtocol.label) · \(server.address)").font(KFont.bodySmall).foregroundStyle(c.ink3).lineLimit(1)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(c.ink3)
                                }
                                if !server.folders.isEmpty {
                                    ScrollView(.horizontal, showsIndicators: false) {
                                        HStack(spacing: 6) {
                                            ForEach(server.folders, id: \.self) { Tag(folderLabel($0)) }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .buttonStyle(PressScaleStyle())
                    .padding(.horizontal, 12)
                }
            }
            .padding(.bottom, 24)
        }
        .navigationTitle("Servers")
        .navigationBarTitleDisplayMode(.inline)
        .kultrScreen()
    }
}

/** What is being typed into the editor; secrets in the clear until saved (to the Keychain). */
@MainActor
@Observable
private final class ServerDraft {
    let original: SavedServer?
    var name = ""
    var serverProtocol: ServerProtocol = .sftp
    var host = ""
    var port = ""
    var username = ""
    var password = ""
    var privateKey = ""
    var keyName: String?
    var passphrase = ""
    var pin: String?
    var folders: [String] = []
    var layout: FolderLayout = .flat
    var passive = true

    init(_ original: SavedServer?) {
        self.original = original
        guard let o = original else { return }
        name = o.name
        serverProtocol = o.serverProtocol
        host = o.host
        port = o.port == o.serverProtocol.defaultPort ? "" : String(o.port)
        username = o.username
        password = o.password
        privateKey = o.privateKey
        keyName = privateKey.isEmpty ? nil : (o.keyName ?? "Private key")
        passphrase = o.passphrase
        pin = o.pin
        folders = o.folders
        layout = o.layout
        passive = o.passive
    }

    var portNumber: Int {
        if let n = Int(port), (1...65535).contains(n) { return n }
        return serverProtocol.defaultPort
    }

    var valid: Bool {
        !host.trimmingCharacters(in: .whitespaces).isEmpty && (port.isEmpty || Int(port).map { (1...65535).contains($0) } == true)
    }

    var connection: Connection {
        Connection(
            serverProtocol: serverProtocol, host: host.trimmingCharacters(in: .whitespaces), port: portNumber,
            username: username.trimmingCharacters(in: .whitespaces), password: password, privateKey: privateKey,
            passphrase: passphrase, pin: pin, passive: passive
        )
    }

    func save() -> SavedServer {
        let trimmedHost = host.trimmingCharacters(in: .whitespaces)
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        var server = original ?? SavedServer(name: trimmedName, serverProtocol: serverProtocol, host: trimmedHost, port: portNumber)
        server.name = trimmedName.isEmpty ? trimmedHost : trimmedName
        server.serverProtocol = serverProtocol
        server.host = trimmedHost
        server.port = portNumber
        server.username = username.trimmingCharacters(in: .whitespaces)
        server.keyName = privateKey.isEmpty ? nil : keyName
        server.pin = pin
        server.folders = folders.isEmpty ? [""] : folders
        server.layout = layout
        server.passive = passive
        server.setSecrets(password: password, privateKey: privateKey, passphrase: passphrase)
        return server
    }
}

/** Adds or edits a server: how to reach it, how to sign in, and its folders. */
struct ServerEditorScreen: View {
    @Environment(\.kultr) private var theme
    let id: String
    @State private var draft: ServerDraft?
    @State private var showPassword = false
    @State private var testing = false
    @State private var report: String?
    @State private var untrusted: UntrustedServerError?
    @State private var browsing = false
    @State private var typingFolder = false
    @State private var folderText = ""
    @State private var pickingKey = false
    @State private var confirmDelete = false

    var body: some View {
        let graph = AppGraph.shared
        ZStack {
            if let draft {
                form(draft)
            }
        }
        .navigationTitle(draft?.original?.name ?? "Add server")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if draft?.original != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Delete", role: .destructive) { confirmDelete = true }
                        .tint(theme.colors.danger)
                }
            }
        }
        .settingsPage()
        .onAppear {
            if draft == nil { draft = ServerDraft(id == "new" ? nil : graph.servers.get(id)) }
        }
        .alert("Test connection", isPresented: Binding(get: { report != nil }, set: { if !$0 { report = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(report ?? "")
        }
        .alert(untrusted?.reason.title ?? "", isPresented: Binding(get: { untrusted != nil }, set: { if !$0 { untrusted = nil } })) {
            Button("Cancel", role: .cancel) {}
            Button("Trust") {
                guard let e = untrusted else { return }
                draft?.pin = e.fingerprint
                untrusted = nil
                test()
            }
        } message: {
            if let e = untrusted {
                Text(e.reason.message + "\n\n" + e.fingerprint + "\n\n" + (e.reason == .keyChanged
                    ? "Compare it with what the server shows (ssh-keygen -lf on its host key). Trust it only if they match."
                    : "Compare it with the certificate in the server's settings. Trust it only if they match; KultrDL will then accept exactly this certificate."))
            }
        }
        .alert("Add a folder", isPresented: $typingFolder) {
            TextField("/music, or music in the start folder", text: $folderText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            Button("Cancel", role: .cancel) {}
            Button("Add") {
                let folder = RemotePath.normalise(folderText)
                if let draft, !draft.folders.contains(folder) { draft.folders.append(folder) }
            }
        }
        .confirmationDialog("Delete “\(draft?.original?.name ?? "")”?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                guard let original = draft?.original else { return }
                graph.servers.remove(original.id)
                graph.settings.update { if $0.destination?.serverId == original.id { $0.destination = nil } }
                graph.actions.back()
            }
        } message: {
            Text("Files already on the server stay there. Downloads waiting to go to it will fail.")
        }
        .fileImporter(isPresented: $pickingKey, allowedContentTypes: [.data, .plainText, .text, .item]) { result in
            guard case .success(let url) = result else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url), data.count < 64 * 1024, let text = String(data: data, encoding: .utf8) else {
                graph.messages.error("That file couldn't be read.")
                return
            }
            useKey(text, name: url.lastPathComponent)
        }
        .sheet(isPresented: $browsing) {
            if let draft {
                FolderBrowser(connection: draft.connection, start: draft.folders.last) { folder in
                    if !draft.folders.contains(folder) { draft.folders.append(folder) }
                    browsing = false
                } onPin: { pin in
                    draft.pin = pin
                } onUntrusted: { error in
                    browsing = false
                    untrusted = error
                } onDismiss: {
                    browsing = false
                }
                .environment(\.kultr, theme)
                .presentationDetents([.large])
                .presentationBackground(.regularMaterial)
            }
        }
    }

    private func useKey(_ text: String, name: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains("PRIVATE KEY") || trimmed.hasPrefix("PuTTY-User-Key-File") else {
            AppGraph.shared.messages.error("That doesn't look like a private key. Choose the key file without .pub.")
            return
        }
        draft?.privateKey = trimmed
        draft?.keyName = name
    }

    @ViewBuilder
    private func form(_ draft: ServerDraft) -> some View {
        @Bindable var d = draft
        let c = theme.colors
        Form {
            if draft.original != nil && draft.password.isEmpty && draft.privateKey.isEmpty && !draft.username.isEmpty {
                Section {
                    Text("No password or key is saved for this server on this phone (a restored backup has none). Enter it again.")
                        .font(.footnote)
                        .foregroundStyle(c.warning)
                }
            }
            Section {
                TextField("Name (My NAS)", text: $d.name)
                Picker("Protocol", selection: Binding(get: { d.serverProtocol }, set: { d.serverProtocol = $0; d.pin = nil })) {
                    ForEach(ServerProtocol.allCases, id: \.self) { Text($0.label).tag($0) }
                }
            } footer: {
                Text(d.serverProtocol.hint).foregroundStyle(d.serverProtocol == .ftp ? c.warning : Color.secondary)
            }
            Section("Address") {
                TextField("192.168.1.20 or nas.example.com", text: Binding(get: { d.host }, set: { d.host = $0.trimmingCharacters(in: .whitespaces); d.pin = nil }))
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Port (\(d.serverProtocol.defaultPort))", text: Binding(get: { d.port }, set: { d.port = String($0.filter { $0.isNumber }.prefix(5)); d.pin = nil }))
                    .keyboardType(.numberPad)
            }
            Section {
                TextField(d.serverProtocol == .sftp ? "Username" : "Username (anonymous)", text: $d.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                HStack {
                    Group {
                        if showPassword {
                            TextField(d.serverProtocol == .sftp && !d.privateKey.isEmpty ? "Password (if the key isn't enough)" : "Password", text: $d.password)
                        } else {
                            SecureField(d.serverProtocol == .sftp && !d.privateKey.isEmpty ? "Password (if the key isn't enough)" : "Password", text: $d.password)
                        }
                    }
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    Button { showPassword.toggle() } label: {
                        Image(systemName: showPassword ? "eye.slash" : "eye").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(showPassword ? "Hide password" : "Show password")
                }
                if d.serverProtocol == .sftp {
                    if d.privateKey.isEmpty {
                        Menu {
                            Button { pickingKey = true } label: { Label("Choose a key file…", systemImage: "doc") }
                            Button {
                                useKey(UIPasteboard.general.string ?? "", name: "Pasted key")
                            } label: { Label("Paste a copied key", systemImage: "doc.on.clipboard") }
                        } label: {
                            Label("Sign in with an SSH key…", systemImage: "key")
                        }
                    } else {
                        HStack {
                            Label(d.keyName ?? "Private key", systemImage: "key.fill")
                            Spacer()
                            Button("Remove", role: .destructive) {
                                d.privateKey = ""
                                d.keyName = nil
                                d.passphrase = ""
                            }
                            .buttonStyle(.borderless)
                        }
                        SecureField("Key passphrase (if it has one)", text: $d.passphrase)
                    }
                } else {
                    Toggle(isOn: $d.passive) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Passive mode")
                            Text("Works through routers and firewalls. Turn off only if the server asks for active mode.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Sign in")
            } footer: {
                if let pin = d.pin {
                    Text((d.serverProtocol == .sftp ? "Trusted server key: " : "Trusted certificate: ") + pin)
                        .font(.system(size: 11, design: .monospaced))
                } else if d.serverProtocol == .sftp {
                    Text("Keys: OpenSSH, PEM or PuTTY; Ed25519, ECDSA or RSA. Passwords and keys are kept in the iOS Keychain.")
                }
            }
            Section {
                ForEach(d.folders, id: \.self) { folder in
                    Label(folderLabel(folder), systemImage: "folder.fill")
                }
                .onDelete { d.folders.remove(atOffsets: $0) }
                Button { browsing = true } label: { Label("Browse the server…", systemImage: "folder.badge.gearshape") }
                    .disabled(!d.valid)
                Button {
                    folderText = ""
                    typingFolder = true
                } label: { Label("Type a path…", systemImage: "folder.badge.plus") }
                Picker("Inside the folder", selection: $d.layout) {
                    ForEach(FolderLayout.allCases, id: \.self) { Text($0.label).tag($0) }
                }
            } header: {
                Text("Folders")
            } footer: {
                Text("The places on the server music can go; you choose one when you download. \(d.layout.explanation)")
            }
            Section {
                Button(testing ? "Testing…" : "Test connection") { test() }
                    .disabled(!d.valid || testing)
                Button("Save") {
                    let server = draft.save()
                    AppGraph.shared.servers.save(server)
                    AppGraph.shared.messages.success("Saved “\(server.name)”")
                    AppGraph.shared.actions.back()
                }
                .disabled(!d.valid)
                .fontWeight(.semibold)
            }
        }
    }

    private func test() {
        guard let draft else { return }
        testing = true
        let connection = draft.connection
        let folders = draft.folders
        let host = draft.host
        let kind = draft.serverProtocol
        Task {
            defer { testing = false }
            do {
                let (home, newPin, found) = try await Remote.use(connection) { session -> (String, String?, [(String, Bool)]) in
                    var found: [(String, Bool)] = []
                    for folder in folders {
                        found.append((folder, (try? await session.isDirectory(RemotePath.resolve(session.home, folder))) ?? false))
                    }
                    return (session.home, session.newPin, found)
                }
                if let newPin { draft.pin = newPin }
                var lines = ["Signed in to \(host). It starts in \(home)."]
                if !found.isEmpty {
                    lines.append("")
                    for (folder, exists) in found { lines.append("\(folderLabel(folder)): \(exists ? "found" : "will be created")") }
                }
                if kind == .sftp, let pin = draft.pin {
                    lines.append("")
                    lines.append("Server key: \(pin)")
                    if newPin != nil { lines.append("It will be trusted from now on; if it ever changes, KultrDL stops and asks.") }
                }
                if kind == .ftp { lines.append("\nPlain FTP isn't encrypted. Use SFTP or FTPS if the server has them.") }
                report = lines.joined(separator: "\n")
            } catch let error as UntrustedServerError {
                untrusted = error
            } catch {
                report = "Couldn't connect: \(describe(error))"
            }
        }
    }
}

/** Walks the server's folders and picks one, over one connection kept open. */
private struct FolderBrowser: View {
    @Environment(\.kultr) private var theme
    let connection: Connection
    let start: String?
    let onPick: (String) -> Void
    let onPin: (String) -> Void
    let onUntrusted: (UntrustedServerError) -> Void
    let onDismiss: () -> Void

    @State private var session: RemoteSession?
    @State private var path: String?
    @State private var entries: [RemoteEntry]?
    @State private var error: String?
    @State private var creating = false
    @State private var newName = ""

    var body: some View {
        let c = theme.colors
        SheetScaffold(title: "Choose a folder") {
            VStack(alignment: .leading, spacing: 8) {
                Text(path ?? "Connecting…")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(c.ink2)
                if let error {
                    Text(error).font(KFont.bodyMedium).foregroundStyle(c.danger)
                    TextButton("Try again") { open(path ?? start) }
                } else if let entries {
                    if let current = path, current != "/" {
                        row("..", "Up one folder") { open(RemotePath.parent(current)) }
                    }
                    if entries.isEmpty {
                        Text("No folders in here.").font(KFont.bodySmall).foregroundStyle(c.ink3).padding(8)
                    }
                    ForEach(entries, id: \.name) { entry in
                        row(entry.name, nil) { open(RemotePath.join(path ?? "/", entry.name)) }
                    }
                    Button {
                        newName = ""
                        creating = true
                    } label: {
                        Label("New folder", systemImage: "folder.badge.plus").font(KFont.bodyMedium).foregroundStyle(c.accent)
                    }
                    .buttonStyle(PressableStyle())
                    .padding(.top, 6)
                } else {
                    LoadingView()
                }
            }
        } buttons: {
            TextButton("Cancel", color: c.ink2) { close(); onDismiss() }
            TextButton("Use this folder", enabled: path != nil) {
                if let path { close(); onPick(path) }
            }
        }
        .task { open(start) }
        .alert("New folder", isPresented: $creating) {
            TextField("Name", text: $newName)
            Button("Cancel", role: .cancel) {}
            Button("Create") {
                let target = RemotePath.join(path ?? "/", newName.replacingOccurrences(of: "/", with: "_"))
                Task {
                    do {
                        try await ensureSession().makeDirectories(target)
                        open(target)
                    } catch {
                        self.error = describe(error)
                    }
                }
            }
        }
    }

    private func row(_ name: String, _ hint: String?, _ action: @escaping () -> Void) -> some View {
        let c = theme.colors
        return Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: "folder.fill").foregroundStyle(c.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text(name).font(KFont.bodyLarge).foregroundStyle(c.ink).lineLimit(1)
                    if let hint { Text(hint).font(KFont.bodySmall).foregroundStyle(c.ink3) }
                }
                Spacer()
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
    }

    private func ensureSession() async throws -> RemoteSession {
        if let session { return session }
        let opened = try await Remote.open(connection)
        session = opened
        if let pin = opened.newPin { onPin(pin) }
        return opened
    }

    private func open(_ target: String?) {
        entries = nil
        error = nil
        Task {
            do {
                let s = try await ensureSession()
                var wanted = s.home
                if let target {
                    let resolved = RemotePath.resolve(s.home, target)
                    if (try? await s.isDirectory(resolved)) == true { wanted = resolved }
                }
                let listing = try await s.list(wanted)
                path = wanted
                entries = listing.filter { $0.isDirectory }
            } catch let untrusted as UntrustedServerError {
                close()
                onUntrusted(untrusted)
            } catch {
                self.error = describe(error)
            }
        }
    }

    private func close() {
        guard let s = session else { return }
        session = nil
        Task { await s.close() }
    }
}
