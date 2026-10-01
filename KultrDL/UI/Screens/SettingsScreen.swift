import KultrDLCore
import SwiftUI
import UniformTypeIdentifiers

private let ACCENTS = ["#7c8cff", "#ff6b9a", "#ff9f43", "#ffd166", "#45d67a", "#2ec4b6", "#4cc9f0", "#b388ff", "#f5f5f7"]
private let SOURCE_CODE = "https://github.com/evropiani/KultrDL_iOS"

@MainActor
private func update(_ change: (inout Settings) -> Void) {
    AppGraph.shared.settings.update(change)
}

@MainActor
private func setting<T>(_ read: @escaping (Settings) -> T, _ write: @escaping (inout Settings, T) -> Void) -> Binding<T> {
    Binding(
        get: { read(AppGraph.shared.settings.settings) },
        set: { value in update { write(&$0, value) } }
    )
}

var appVersion: String {
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    return "\(version) (\(build))"
}

/**
 * Settings, the iOS way: a list of sections, each opening its own page of
 * switches and pickers.
 */
struct SettingsScreen: View {
    @Environment(\.kultr) private var theme

    var body: some View {
        let graph = AppGraph.shared
        List {
            Section {
                HStack(spacing: 14) {
                    Image("KultrDLLogo")
                        .resizable()
                        .frame(width: 54, height: 54)
                        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("KultrDL").font(.system(size: 19, weight: .semibold))
                        Text("\(graph.settings.settings.download.label) · \(graph.servers.label(graph.settings.settings.destination))")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .padding(.vertical, 4)
            }
            Section {
                link("Downloads", "arrow.down.circle.fill", .green) { DownloadSettings() }
                link("Servers", "server.rack", .indigo) { ServersScreen() }
            }
            Section {
                link("Recommendations", "sparkles", .orange) { RecommendationSettings() }
                link("Search and sources", "magnifyingglass", .blue) { SourceSettings() }
                link("Playback", "play.fill", .red) { PlaybackSettings() }
                link("Appearance", "paintpalette.fill", .pink) { AppearanceSettings() }
            }
            Section {
                link("Engine", "cpu", .purple) { EngineSettings() }
                link("Backup and reset", "externaldrive.fill", .gray) { BackupSettings() }
            }
            Section {
                link("Open links from other apps", "square.and.arrow.down.on.square", .orange) { ShareHelp() }
                link("About", "info.circle.fill", .gray) { AboutSection() }
            }
        }
        .navigationTitle("Settings")
        .settingsPage()
    }

    private func link<Destination: View>(_ title: String, _ icon: String, _ color: Color, @ViewBuilder destination: @escaping () -> Destination) -> some View {
        NavigationLink(destination: destination) {
            SettingsIcon(title: title, icon: icon, color: color)
        }
    }
}

/** A row label in the style of the Settings app: a white symbol on a coloured tile. */
private struct SettingsIcon: View {
    let title: String
    let icon: String
    let color: Color

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 29, height: 29)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(color.gradient))
        }
    }
}

extension View {
    /** A settings list over KultrDL's background, tinted with the accent. */
    func settingsPage() -> some View {
        self
            .scrollContentBackground(.hidden)
            .kultrScreen()
    }
}

/** A switch with a line of explanation under its label. */
struct SettingToggle: View {
    let label: String
    let hint: String?
    let isOn: Binding<Bool>

    init(_ label: String, isOn: Binding<Bool>, hint: String? = nil) {
        self.label = label
        self.isOn = isOn
        self.hint = hint
    }

    var body: some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                if let hint {
                    Text(hint)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

// ------------------------------------------------------------- downloads --

private struct DownloadSettings: View {
    @Environment(\.kultr) private var theme
    @State private var choosing = false

    var body: some View {
        let graph = AppGraph.shared
        let s = theme.settings
        Form {
            Section {
                FormatPicker(preset: s.download) { preset in update { $0.download = preset } }
                    .padding(.vertical, 6)
            } header: {
                Text("Format")
            }
            Section {
                Button { choosing = true } label: {
                    HStack {
                        Text("Save to").foregroundStyle(Color.primary)
                        Spacer()
                        Text(graph.servers.label(s.destination)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                NavigationLink {
                    ServersScreen()
                } label: {
                    HStack {
                        Text("Servers")
                        Spacer()
                        Text(graph.servers.servers.isEmpty ? "None" : graph.servers.servers.map { $0.name }.joined(separator: ", "))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                SettingToggle(
                    "Ask every time",
                    isOn: setting({ $0.askEachTime }, { $0.askEachTime = $1 }),
                    hint: "Choose the format, quality and where it goes for each download."
                )
            } footer: {
                Text("Send downloads to a NAS or computer over SFTP, FTPS or FTP, into Artist or Artist/Album folders if you like.")
            }
            Section {
                SettingToggle(
                    "Show in the Files app",
                    isOn: setting({ $0.saveToMusic }, { $0.saveToMusic = $1 }),
                    hint: s.saveToMusic ? "Files › On My iPhone › KultrDL › Music, where other apps can open them." : "Kept inside KultrDL, hidden from other apps."
                )
                SettingToggle("Embed cover art", isOn: setting({ $0.embedArtwork }, { $0.embedArtwork = $1 }), hint: "Put the album artwork inside each file.")
                SettingToggle(
                    "Download on Wi-Fi only",
                    isOn: setting({ $0.wifiOnly }, { $0.wifiOnly = $1 }),
                    hint: "Downloads wait while the phone is on mobile data or a personal hotspot."
                )
            } footer: {
                Text("Downloads carry on for a while after you leave the app, and while music plays. When iOS stops them, they pick up where they were the next time KultrDL opens.")
            }
        }
        .navigationTitle("Downloads")
        .navigationBarTitleDisplayMode(.inline)
        .settingsPage()
        .sheet(isPresented: $choosing) {
            DestinationSheet { choosing = false }
                .environment(\.kultr, theme)
                .presentationDetents([.medium, .large])
                .presentationBackground(.regularMaterial)
        }
    }
}

// --------------------------------------------------------------- sources --

private struct SourceSettings: View {
    @Environment(\.kultr) private var theme
    @State private var country = ""
    @State private var clientId = ""
    @State private var clientSecret = ""
    @State private var ready = false

    var body: some View {
        Form {
            Section {
                Picker("Search first on", selection: setting({ $0.searchSource }, { $0.searchSource = $1 })) {
                    ForEach(Source.searchSources, id: \.self) { Text($0.label).tag($0) }
                }
            }
            Section {
                TextField("Automatic", text: $country)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .onChange(of: country) { _, value in
                        let cleaned = String(value.filter { $0.isLetter }.prefix(2)).uppercased()
                        if cleaned != value { country = cleaned }
                        update { $0.country = cleaned }
                    }
            } header: {
                Text("Country")
            } footer: {
                Text("Two letters, like US or DE: the Apple Music store searched and its charts. Empty uses the phone's region.")
            }
            Section {
                TextField("Client ID", text: $clientId)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onChange(of: clientId) { _, value in update { $0.spotifyClientId = value.trimmingCharacters(in: .whitespaces) } }
                SecureField("Client secret", text: $clientSecret)
                    .onChange(of: clientSecret) { _, value in update { $0.spotifyClientSecret = value.trimmingCharacters(in: .whitespaces) } }
            } header: {
                Text("Spotify search")
            } footer: {
                Text("Spotify links work as they are. To search Spotify too, create a free app at developer.spotify.com and enter its Client ID and secret.")
            }
        }
        .navigationTitle("Search and sources")
        .navigationBarTitleDisplayMode(.inline)
        .settingsPage()
        .onAppear {
            guard !ready else { return }
            ready = true
            let s = AppGraph.shared.settings.settings
            country = s.country
            clientId = s.spotifyClientId
            clientSecret = s.spotifyClientSecret
        }
    }
}

// -------------------------------------------------------------- playback --

private struct PlaybackSettings: View {
    var body: some View {
        Form {
            Section {
                Picker("Streaming quality", selection: setting({ $0.streamQuality }, { $0.streamQuality = $1 })) {
                    ForEach(StreamQuality.allCases, id: \.self) { Text($0.label).tag($0) }
                }
            } footer: {
                Text("Downloaded tracks play from the phone. Downloads always fetch the best audio and convert it to your format.")
            }
        }
        .navigationTitle("Playback")
        .navigationBarTitleDisplayMode(.inline)
        .settingsPage()
    }
}

// ------------------------------------------------------------ appearance --

private struct AppearanceSettings: View {
    @Environment(\.kultr) private var theme

    var body: some View {
        let s = theme.settings
        let c = theme.colors
        Form {
            Section {
                Picker("Theme", selection: setting({ $0.theme }, { $0.theme = $1 })) {
                    ForEach(ThemeMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
            Section {
                SettingToggle(
                    "Colour from artwork",
                    isOn: setting({ $0.accentFromArtwork }, { $0.accentFromArtwork = $1 }),
                    hint: "The interface takes its colour from whatever is playing."
                )
                VStack(alignment: .leading, spacing: 10) {
                    Text(s.accentFromArtwork ? "When nothing is playing" : "Accent colour")
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 12) {
                            ForEach(ACCENTS, id: \.self) { hex in
                                let selected = s.accent.lowercased() == hex
                                Button {
                                    Haptics.select()
                                    update { $0.accent = hex }
                                } label: {
                                    ZStack {
                                        Circle().fill(Color(argb: ArtworkColor.parseHex(hex) ?? 0))
                                        Circle().strokeBorder(selected ? c.ink : Color.primary.opacity(0.12), lineWidth: selected ? 3 : 1)
                                        if selected {
                                            Image(systemName: "checkmark")
                                                .font(.system(size: 13, weight: .bold))
                                                .foregroundStyle(.black.opacity(0.7))
                                        }
                                    }
                                    .frame(width: 34, height: 34)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Accent \(hex)")
                                .accessibilityAddTraits(selected ? .isSelected : [])
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            Section {
                SettingToggle(
                    "Artwork behind pages",
                    isOn: setting({ $0.backdropArtwork }, { $0.backdropArtwork = $1 }),
                    hint: "Blurred cover art of what's playing behind every page."
                )
                SettingToggle(
                    "Reduce motion",
                    isOn: setting({ $0.reduceMotion }, { $0.reduceMotion = $1 }),
                    hint: "Stops animated colour changes and sliding highlights. KultrDL also follows Reduce Motion in iOS's Accessibility settings."
                )
            }
        }
        .navigationTitle("Appearance")
        .navigationBarTitleDisplayMode(.inline)
        .settingsPage()
    }
}

// ---------------------------------------------------------------- engine --

private struct EngineSettings: View {
    @Environment(\.kultr) private var theme
    @State private var testing: String?
    @State private var report: String?
    @State private var updating = false

    var body: some View {
        let graph = AppGraph.shared
        let engine = graph.engine
        Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("YouTube player API and challenge solver")
                    Text(engine.summary).font(.footnote).foregroundStyle(.secondary)
                }
                Button(updating ? "Checking…" : "Check for updates now") {
                    updating = true
                    Task {
                        do {
                            let note = try await engine.update(http: graph.http)
                            graph.settings.update { $0.lastEngineCheck = nowMs() }
                            graph.messages.success(note)
                        } catch {
                            graph.messages.error("Update failed: \(describe(error))")
                        }
                        updating = false
                    }
                }
                .disabled(updating)
                SettingToggle(
                    "Update automatically",
                    isOn: setting({ $0.autoUpdateEngine }, { $0.autoUpdateEngine = $1 }),
                    hint: "YouTube changes often. KultrDL checks once a day for newer client versions and solver scripts."
                )
            } footer: {
                Text("What yt-dlp does on Android, done natively: KultrDL asks YouTube's own player API for the audio, and solves its JavaScript challenges with the same scripts yt-dlp uses.")
            }
            Section {
                Picker("Try first", selection: setting({ $0.youtubeClient }, { $0.youtubeClient = $1 })) {
                    Text("Automatic").tag("")
                    ForEach(engine.config.clients) { client in
                        Text(client.label).tag(client.key)
                    }
                }
                Button(testing ?? "Test YouTube") {
                    testing = "Starting…"
                    Task {
                        report = await YouTubeCheck.run(graph) { step in testing = step }
                        testing = nil
                    }
                }
                .disabled(testing != nil)
            } header: {
                Text("YouTube connection")
            } footer: {
                Text("If YouTube refuses a song (error 403), KultrDL tries the other clients and keeps the one that works. The test tries them all and writes a report you can copy.")
            }
            Section {
                Button("Use the engine that came with the app", role: .destructive) {
                    engine.reset()
                    graph.messages.show("Back to the built-in engine.")
                }
            }
        }
        .navigationTitle("Engine")
        .navigationBarTitleDisplayMode(.inline)
        .settingsPage()
        .sheet(isPresented: Binding(get: { report != nil }, set: { if !$0 { report = nil } })) {
            SheetScaffold(title: "YouTube test") {
                Text(report ?? "")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(theme.colors.ink2)
                    .textSelection(.enabled)
            } buttons: {
                TextButton("Copy report") {
                    UIPasteboard.general.string = report
                    graph.messages.show("Report copied")
                }
                TextButton("Close", color: theme.colors.ink2) { report = nil }
            }
            .environment(\.kultr, theme)
            .presentationDetents([.medium, .large])
            .presentationBackground(.regularMaterial)
        }
    }
}

// ---------------------------------------------------------------- backup --

private struct BackupSettings: View {
    @State private var exporting = false
    @State private var importing = false
    @State private var document: BackupDocument?
    @State private var confirmHistory = false

    var body: some View {
        let graph = AppGraph.shared
        Form {
            Section {
                Button("Back up library") {
                    var settings = graph.settings.settings
                    settings.spotifyClientSecret = ""
                    settings.lastFmApiKey = ""
                    var file = graph.library.snapshot(settings: settings, servers: graph.servers.servers)
                    file.taste = graph.taste.data
                    file.navidrome = graph.navidrome.config.configured ? graph.navidrome.config : nil
                    do {
                        document = BackupDocument(data: try file.encode())
                        exporting = true
                    } catch {
                        graph.messages.error(describe(error))
                    }
                }
                Button("Restore a backup") { importing = true }
            } footer: {
                Text("Favourites, saved tracks, playlists, history, settings, servers and Navidrome (without passwords), blocked artists and your answers to suggestions, as one file — the same format as KultrDL for Android. Restoring adds to what's here; nothing is removed.")
            }
            Section {
                Button("Clear listening history", role: .destructive) { confirmHistory = true }
                Button("Clear recent searches") {
                    graph.library.clearSearches()
                    graph.messages.show("Recent searches cleared")
                }
                Button("Clear the artwork cache") {
                    URLCache.shared.removeAllCachedResponses()
                    try? FileManager.default.removeItem(at: Storage.caches.appendingPathComponent("artwork"))
                    graph.messages.show("Artwork cache cleared")
                }
            }
        }
        .navigationTitle("Backup and reset")
        .navigationBarTitleDisplayMode(.inline)
        .settingsPage()
        .fileExporter(isPresented: $exporting, document: document, contentType: .json, defaultFilename: "KultrDL-backup.json") { result in
            if case .success = result {
                let file = document.flatMap { try? BackupFile.decode($0.data) }
                graph.messages.success("Backed up \(Format.count(file?.tracks.count ?? 0, "track")) and \(Format.count(file?.playlists.count ?? 0, "playlist"))")
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json, .plainText, .data]) { result in
            guard case .success(let url) = result else { return }
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            do {
                let file = try BackupFile.decode(try Data(contentsOf: url))
                let count = graph.library.restore(file)
                let servers = graph.servers.restore(file.servers)
                if let taste = file.taste { graph.taste.restore(taste) }
                if var navidrome = file.navidrome, !graph.navidrome.config.configured, navidrome.configured {
                    navidrome.lastSyncAt = 0
                    graph.navidrome.update { $0 = navidrome }
                }
                if var restored = file.settings {
                    restored.spotifyClientSecret = graph.settings.settings.spotifyClientSecret
                    restored.lastFmApiKey = graph.settings.settings.lastFmApiKey
                    graph.settings.replace(restored)
                }
                graph.messages.success(
                    "Restored \(Format.count(count, "track")) and \(Format.count(file.playlists.count, "playlist"))"
                        + (servers > 0 ? "; enter the passwords for \(Format.count(servers, "server")) again" : "")
                )
            } catch {
                graph.messages.error(describe(error))
            }
        }
        .confirmationDialog("Clear listening history?", isPresented: $confirmHistory, titleVisibility: .visible) {
            Button("Clear", role: .destructive) {
                graph.library.clearHistory()
                Task { await graph.listening.clearPlays() }
            }
        } message: {
            Text("Play counts and “Jump back in” start again. Favourites, playlists and downloads stay.")
        }
    }
}

// ----------------------------------------------------------------- share --

private struct ShareHelp: View {
    var body: some View {
        Form {
            Section {
                Text("Paste a link on the Home page, or in the search field. To send links straight from the share sheet of Spotify, Safari or any other app, make a Shortcut once:")
                VStack(alignment: .leading, spacing: 8) {
                    Text("1. Open Shortcuts and create a new shortcut.")
                    Text("2. In its settings (ⓘ), switch on “Show in Share Sheet” and let it receive URLs and text.")
                    Text("3. Add the action “Open URLs” with: kultrdl://open?url=, followed by the Shortcut Input variable.")
                    Text("4. Name it “KultrDL”. It now appears when you share a link.")
                }
                .font(.callout)
            } footer: {
                Text("kultrdl://open?url=… works from anywhere that opens links, too.")
            }
        }
        .navigationTitle("Open links from other apps")
        .navigationBarTitleDisplayMode(.inline)
        .settingsPage()
    }
}

// ----------------------------------------------------------------- about --

private struct AboutSection: View {
    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image("KultrDLLogo")
                        .resizable()
                        .frame(width: 56, height: 56)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("KultrDL \(appVersion)").font(.headline)
                        Text("Search, play, save and download music.").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
            Section {
                Text("Audio comes from YouTube Music, YouTube, SoundCloud and Bandcamp. Spotify, Apple Music, Deezer, Tidal, Qobuz and Amazon Music are used for search, links and track details; their tracks play and download from the matching recording on YouTube Music, with the catalogue's tags and cover. Only download music you have the right to keep.")
                    .font(.callout)
            }
            Section {
                Link("Source code", destination: URL(string: SOURCE_CODE)!)
                Link("Latest release", destination: URL(string: SOURCE_CODE + "/releases/latest")!)
                Link("KultrDL for Android", destination: URL(string: "https://github.com/evropiani/KultrDL")!)
            } footer: {
                Text("Free software under the GNU GPL v3. Built with LAME, libFLAC, libopus, libvorbis, SwiftNIO SSH, Citadel, yt-dlp's challenge solver and the Kultr design.")
            }
        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
        .settingsPage()
    }
}
