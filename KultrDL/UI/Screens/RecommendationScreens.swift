import KultrDLCore
import SwiftUI
import UIKit
import UserNotifications

private let GENRES = [
    "Pop", "Rock", "Rap/Hip-Hop", "Electro", "Dance", "R&B", "Alternative", "Metal", "Jazz", "Classical",
    "Country", "Reggae", "Latin Music", "Folk", "Soul & Funk", "Blues", "Kids", "Films/Games", "Schlager",
]

@MainActor
private func change(_ edit: (inout Settings) -> Void) {
    AppGraph.shared.settings.update(edit)
}

@MainActor
private func binding<T>(_ read: @escaping (Settings) -> T, _ write: @escaping (inout Settings, T) -> Void) -> Binding<T> {
    Binding(
        get: { read(AppGraph.shared.settings.settings) },
        set: { value in change { write(&$0, value) } }
    )
}

/** Settings → Recommendations: what suggestions learn from, how adventurous they are, and new-release alerts. */
struct RecommendationSettings: View {
    @Environment(\.kultr) private var theme
    @State private var level = 0.5
    @State private var lastFmUser = ""
    @State private var lastFmKey = ""
    @State private var listenBrainzUser = ""
    @State private var ready = false
    @State private var updating = false

    var body: some View {
        let graph = AppGraph.shared
        let s = graph.settings.settings
        let recommender = graph.recommender
        let navidrome = graph.navidrome.config
        Form {
            Section {
                SettingToggle(
                    "Suggestions",
                    isOn: Binding(get: { s.suggestions }, set: { on in
                        change { $0.suggestions = on }
                        recommender.schedule()
                    }),
                    hint: "“For you” on Home: new releases, mixes and albums, worked out on this phone once a day."
                )
            }
            if s.suggestions {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Slider(value: $level, in: 0...1, step: 0.25, onEditingChanged: { editing in
                            if !editing { change { $0.discoverLevel = level } }
                        })
                        HStack {
                            Text("Familiar")
                            Spacer()
                            Text("Discover")
                        }
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("Familiar or new")
                } footer: {
                    Text("How much of each mix is music you know, and how much is new to you.")
                }

                Section {
                    Picker("Alerts", selection: Binding(get: { s.releaseAlerts }, set: { value in
                        change { $0.releaseAlerts = value }
                        if value != .off { askForNotifications() }
                    })) {
                        ForEach(ReleaseAlerts.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    Picker("Counts as new for", selection: binding({ $0.releaseWindowDays }, { $0.releaseWindowDays = $1 })) {
                        Text("2 weeks").tag(14)
                        Text("1 month").tag(30)
                        Text("3 months").tag(90)
                    }
                } header: {
                    Text("New releases")
                } footer: {
                    Text("A notification when artists you play release something new.")
                }

                Section {
                    SettingToggle(
                        "Music on this phone",
                        isOn: Binding(get: { s.usePhoneMusic && PhoneMusic.authorized }, set: { on in setPhoneMusic(on) }),
                        hint: s.usePhoneMusic && recommender.phoneSongs > 0
                            ? "\(Format.count(recommender.phoneSongs, "song")) in the Music app; the ones stored on the phone also play in your mixes, offline."
                            : "The songs in the Music app, with how often you play them."
                    )
                    NavigationLink {
                        NavidromeScreen()
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Navidrome")
                            Text(navidrome.configured
                                 ? "\(navidrome.username) at \(navidrome.url)" + (navidrome.lastSync.map { " · \($0)" } ?? "")
                                 : "Your plays, stars, ratings and collection there.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                } header: {
                    Text("Learn from")
                } footer: {
                    Text("Always: what you play, skip, heart, save, download and put in playlists here.")
                }

                Section {
                    TextField("Last.fm username", text: $lastFmUser)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onChange(of: lastFmUser) { _, value in change { $0.lastFmUser = value.trimmingCharacters(in: .whitespaces) } }
                    SecureField("Last.fm API key", text: $lastFmKey)
                        .onChange(of: lastFmKey) { _, value in change { $0.lastFmApiKey = value.trimmingCharacters(in: .whitespaces) } }
                } header: {
                    Text("Last.fm")
                } footer: {
                    Text("Your top artists there, and its similar artists. Needs your username and a free API key from last.fm/api/account/create.")
                }

                Section {
                    TextField("ListenBrainz username", text: $listenBrainzUser)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onChange(of: listenBrainzUser) { _, value in change { $0.listenBrainzUser = value.trimmingCharacters(in: .whitespaces) } }
                } header: {
                    Text("ListenBrainz")
                } footer: {
                    Text("Your top artists there, and the Weekly Exploration and Weekly Jams playlists it makes for you. Just your username; no password.")
                }

                Section {
                    SettingToggle(
                        "Deezer",
                        isOn: binding({ $0.useDeezer }, { $0.useDeezer = $1 }),
                        hint: "Discographies with release dates, related artists and top songs. Apple Music is used when this is off."
                    )
                    SettingToggle(
                        "YouTube Music radio",
                        isOn: binding({ $0.useYouTubeRadio }, { $0.useYouTubeRadio = $1 }),
                        hint: "Songs YouTube Music plays after your favourites."
                    )
                } header: {
                    Text("Find new music on")
                }

                Section {
                    GenreChips(excluded: s.excludedGenres)
                        .padding(.vertical, 4)
                } header: {
                    Text("Leave out genres")
                } footer: {
                    Text("Never suggest artists whose music is mainly these.")
                }

                Section {
                    NavigationLink {
                        BlockedArtistsScreen()
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Blocked artists")
                            let blocked = graph.taste.data.blocked
                            Text(blocked.isEmpty ? "No one. Block an artist from any song's menu." : blocked.map(\.name).joined(separator: ", "))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                }

                Section {
                    SettingToggle(
                        "Update on Wi-Fi only",
                        isOn: Binding(get: { s.suggestionsOnWifiOnly }, set: { on in
                            change { $0.suggestionsOnWifiOnly = on }
                            recommender.schedule()
                        })
                    )
                    SettingToggle(
                        "Update only while charging",
                        isOn: Binding(get: { s.suggestionsWhileCharging }, set: { on in
                            change { $0.suggestionsWhileCharging = on }
                            recommender.schedule()
                        })
                    )
                    Button {
                        updateNow()
                    } label: {
                        HStack {
                            Text("Update suggestions now")
                            Spacer()
                            if updating || recommender.status.isWorking { ProgressView() }
                        }
                    }
                    .disabled(updating)
                } footer: {
                    Text("iOS decides when background updates run; suggestions also update when you open Home and they're a day old.")
                }
            }
        }
        .navigationTitle("Recommendations")
        .navigationBarTitleDisplayMode(.inline)
        .settingsPage()
        .onAppear {
            guard !ready else { return }
            ready = true
            level = s.discoverLevel
            lastFmUser = s.lastFmUser
            lastFmKey = s.lastFmApiKey
            listenBrainzUser = s.listenBrainzUser
        }
    }

    private func setPhoneMusic(_ on: Bool) {
        let graph = AppGraph.shared
        guard on else {
            change { $0.usePhoneMusic = false }
            Task { await graph.recommender.forgetPhone() }
            return
        }
        Task { @MainActor in
            guard await PhoneMusic.requestAccess() else {
                graph.messages.error("KultrDL can't see the Music app's library. Allow it in the Settings app › KultrDL › Media & Apple Music.")
                return
            }
            change { $0.usePhoneMusic = true }
            let n = await graph.recommender.scanPhone()
            graph.messages.success("Found \(Format.count(n, "song")) on this phone")
            graph.recommender.refreshInBackground()
        }
    }

    private func updateNow() {
        let graph = AppGraph.shared
        updating = true
        Task { @MainActor in
            defer { updating = false }
            do {
                let feed = try await graph.recommender.refresh()
                let mixes = feed.mixes.count == 1 ? "1 mix" : "\(feed.mixes.count) mixes"
                graph.messages.success("Suggestions updated: \(Format.count(feed.releases.count, "new release")), \(mixes)")
            } catch is CancellationError {
            } catch {
                graph.messages.error("Couldn't update suggestions: \(describe(error))")
            }
        }
    }

    private func askForNotifications() {
        Task {
            _ = try? await UNUserNotificationCenterBridge.request()
        }
    }
}

/** Notifications for new releases, asked for when alerts are switched on. */
enum UNUserNotificationCenterBridge {
    static func request() async throws -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        if settings.authorizationStatus == .notDetermined {
            return try await center.requestAuthorization(options: [.alert, .sound, .badge])
        }
        return settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
    }
}

/** Genres to leave out, as chips that wrap. */
private struct GenreChips: View {
    @Environment(\.kultr) private var theme
    let excluded: [String]

    var body: some View {
        let c = theme.colors
        let off = Set(excluded.map { Taste.genreName($0).lowercased() })
        FlowLayout(spacing: 6) {
            ForEach(GENRES, id: \.self) { genre in
                let on = off.contains(Taste.genreName(genre).lowercased())
                Button {
                    Haptics.select()
                    change { s in
                        let key = Taste.genreName(genre).lowercased()
                        var list = s.excludedGenres.filter { Taste.genreName($0).lowercased() != key }
                        if !on { list.append(genre) }
                        s.excludedGenres = list
                    }
                } label: {
                    Text(genre)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(on ? Color.white : c.ink2)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(on ? c.danger : c.glass))
                        .overlay(Capsule().strokeBorder(on ? Color.clear : c.edge, lineWidth: 1))
                }
                .buttonStyle(PressScaleStyle())
                .accessibilityAddTraits(on ? .isSelected : [])
                .accessibilityHint(on ? "Left out of suggestions" : "")
            }
        }
    }
}

/** Lays its children out in rows, wrapping to the next row when one is full. */
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width {
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            x += size.width + spacing
            widest = max(widest, x - spacing)
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: proposal.width ?? widest, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX {
                y += rowHeight + spacing
                x = bounds.minX
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// ------------------------------------------------------------ Navidrome --

/**
 * The user's Navidrome: sign in, let its history (plays, stars, ratings)
 * and collection feed the recommendations, and choose the SFTP/FTP folder
 * it reads music from, for "Download to Navidrome".
 */
struct NavidromeScreen: View {
    @Environment(\.kultr) private var theme
    @State private var url = ""
    @State private var username = ""
    @State private var password = ""
    @State private var ready = false
    @State private var testing = false
    @State private var syncing = false
    @State private var report: String?

    var body: some View {
        let graph = AppGraph.shared
        let config = graph.navidrome.config
        let valid = !url.trimmingCharacters(in: .whitespaces).isEmpty && !username.trimmingCharacters(in: .whitespaces).isEmpty && !password.isEmpty
        let changed = Subsonic.baseUrl(url) != config.url || username.trimmingCharacters(in: .whitespaces) != config.username || password != graph.navidrome.password
        Form {
            Section {
                TextField("Server address", text: $url, prompt: Text("http://192.168.1.20:4533"))
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Username", text: $username)
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Password", text: $password)
                    .textContentType(.password)
            } header: {
                Text("Your server")
            } footer: {
                Text("Connect your Navidrome (or any Subsonic server). KultrDL reads what you own and what you play there — play counts, stars and ratings — to suggest music, never suggests what you already have, and plays your songs from it in mixes. It never changes anything on the server. Use a local Navidrome account (LDAP accounts can't sign in from apps); the password is kept in the iOS Keychain.")
            }
            Section {
                Button {
                    test()
                } label: {
                    HStack {
                        Text(testing ? "Testing…" : "Test connection")
                        Spacer()
                        if testing { ProgressView() }
                    }
                }
                .disabled(!valid || testing)
                Button("Save") { save() }
                    .disabled(!valid || !changed)
            }

            if config.configured {
                Section {
                    SettingToggle(
                        "Use my Navidrome for suggestions",
                        isOn: Binding(get: { config.useHistory }, set: { on in graph.navidrome.update { $0.useHistory = on } }),
                        hint: "Its plays, stars and ratings tell KultrDL what you like; what's on it is never suggested."
                    )
                    Button {
                        sync()
                    } label: {
                        HStack {
                            Text(syncing ? "Reading…" : "Read it again now")
                            Spacer()
                            if syncing { ProgressView() }
                        }
                    }
                    .disabled(syncing)
                } header: {
                    Text("Suggestions")
                } footer: {
                    let read = graph.recommender.navidromeSongs > 0 ? "\(Format.count(graph.recommender.navidromeSongs, "song")) read" : nil
                    Text([read, config.lastSync].compactMap { $0 }.joined(separator: " · ").nonEmpty ?? "Not read yet")
                }

                Section {
                    DestinationPicker(selected: config.destination, allowPhone: false) { picked in
                        let folder = picked.map { p in Destination(serverId: p.serverId, folder: p.folder) }
                        graph.navidrome.update { c in c.destination = folder }
                    }
                    .padding(.vertical, 4)
                    SettingToggle(
                        "Rescan after downloads",
                        isOn: Binding(get: { config.rescan }, set: { on in graph.navidrome.update { $0.rescan = on } }),
                        hint: "Ask Navidrome to look for new files as soon as downloads arrive (needs an admin account)."
                    )
                } header: {
                    Text("Download to Navidrome")
                } footer: {
                    Text("Choose the folder Navidrome reads music from, on one of your SFTP or FTP servers. “Download to Navidrome” then puts songs and albums straight there, in the format you download in." + (config.lastScan.map { "\n\n\($0)." } ?? ""))
                }

                Section {
                    Button("Remove Navidrome", role: .destructive) {
                        graph.navidrome.clear()
                        Task { await graph.recommender.forgetNavidrome() }
                        url = ""
                        username = ""
                        password = ""
                        graph.messages.show("Navidrome removed")
                    }
                }
            }
        }
        .navigationTitle("Navidrome")
        .navigationBarTitleDisplayMode(.inline)
        .settingsPage()
        .onAppear {
            guard !ready else { return }
            ready = true
            url = config.url
            username = config.username
            password = graph.navidrome.password
        }
        .alert("Test connection", isPresented: Binding(get: { report != nil }, set: { if !$0 { report = nil } })) {
            Button("OK") { report = nil }
        } message: {
            Text(report ?? "")
        }
    }

    private func test() {
        let graph = AppGraph.shared
        testing = true
        let client = NavidromeStore.clientFor(graph.http, url: url, username: username, password: password)
        Task { @MainActor in
            defer { testing = false }
            do {
                let info = try await client.ping()
                report = "Signed in to \(info) at \(Subsonic.baseUrl(url))."
                    + (info.openSubsonic ? "" : "\n\nIt doesn't say when songs were last played (that needs OpenSubsonic), so older plays count as much as recent ones.")
            } catch {
                report = "Couldn't connect: \(describe(error))"
            }
        }
    }

    private func save() {
        let graph = AppGraph.shared
        graph.navidrome.setLogin(url: url, username: username, password: password)
        url = graph.navidrome.config.url
        graph.messages.success("Navidrome saved; reading your music in the background")
        sync()
    }

    private func sync() {
        let graph = AppGraph.shared
        syncing = true
        Task { @MainActor in
            defer { syncing = false }
            do {
                try await graph.recommender.syncNavidrome()
                graph.recommender.refreshInBackground()
            } catch {
                graph.messages.error("Navidrome: \(describe(error))")
            }
        }
    }
}

// ------------------------------------------------------- blocked artists --

/** Artists the user never wants to hear: add one by name, or unblock. */
struct BlockedArtistsScreen: View {
    @Environment(\.kultr) private var theme
    @State private var adding = false
    @State private var name = ""

    var body: some View {
        let graph = AppGraph.shared
        let blocked = graph.taste.data.blocked.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        Form {
            Section {
                Button {
                    name = ""
                    adding = true
                } label: {
                    Label("Block an artist", systemImage: "plus")
                }
            } footer: {
                Text("Their songs, and every song they're on (“feat.”, “with”, shared credits), are hidden in search, albums, playlists, your library and suggestions, and skipped if they come up in the queue. Your downloads stay where they are.")
            }
            if blocked.isEmpty {
                Section {
                    Text("No one blocked. Choose “Block artist…” in any song's menu, or add a name here.")
                        .foregroundStyle(.secondary)
                }
            } else {
                Section {
                    ForEach(blocked, id: \.name) { artist in
                        HStack(spacing: 12) {
                            Image(systemName: "nosign").foregroundStyle(theme.colors.danger)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(artist.name).lineLimit(1)
                                Text("Blocked \(Format.ago(artist.at))").font(.footnote).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Unblock") { graph.actions.unblock(artist.name) }
                                .buttonStyle(.borderless)
                        }
                    }
                }
            }
        }
        .navigationTitle("Blocked artists")
        .navigationBarTitleDisplayMode(.inline)
        .settingsPage()
        .alert("Block an artist", isPresented: $adding) {
            TextField("Artist name, as it's written", text: $name)
                .textInputAutocapitalization(.words)
            Button("Cancel", role: .cancel) {}
            Button("Block", role: .destructive) {
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { graph.actions.block([trimmed]) }
            }
        }
    }
}
