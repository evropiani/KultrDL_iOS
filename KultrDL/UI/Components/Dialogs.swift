import KultrDLCore
import SwiftUI

/** A sheet body in Kultr's style: a title, the content, and a row of text buttons. */
struct SheetScaffold<Content: View, Buttons: View>: View {
    @Environment(\.kultr) private var theme
    let title: String
    @ViewBuilder var content: Content
    @ViewBuilder var buttons: Buttons

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title)
                .font(KFont.headlineSmall.weight(.semibold))
                .foregroundStyle(theme.colors.ink)
                .lineLimit(2)
            ScrollView {
                content.frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
            HStack(spacing: 16) {
                Spacer()
                buttons
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.colors.elevated.ignoresSafeArea())
        .tint(theme.colors.accent)
    }
}

struct TextButton: View {
    @Environment(\.kultr) private var theme
    let text: String
    var color: Color?
    var enabled = true
    let action: () -> Void

    init(_ text: String, color: Color? = nil, enabled: Bool = true, action: @escaping () -> Void) {
        self.text = text
        self.color = color
        self.enabled = enabled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(text)
                .font(KFont.labelLarge)
                .foregroundStyle((color ?? theme.colors.accent).opacity(enabled ? 1 : 0.4))
                .padding(.vertical, 8)
                .padding(.horizontal, 4)
        }
        .buttonStyle(PressableStyle())
        .disabled(!enabled)
    }
}

private func tracksLabel(_ tracks: [Track]) -> String {
    tracks.count == 1 ? "“\(tracks[0].title)”" : "\(tracks.count) tracks"
}

/** Format chips, then the qualities that format offers, and what the choice means. */
struct FormatPicker: View {
    @Environment(\.kultr) private var theme
    let preset: DownloadPreset
    let onChange: (DownloadPreset) -> Void

    var body: some View {
        let c = theme.colors
        VStack(alignment: .leading, spacing: 10) {
            Text("Format").font(KFont.labelLarge).foregroundStyle(c.ink2)
            Chips(options: AudioFormat.allCases, selected: preset.format, label: { $0.shortLabel }) { format in
                onChange(DownloadPreset(format: format, quality: format.normalise(preset.quality)))
            }
            .padding(.horizontal, -16)
            if preset.format.qualities.count > 1 {
                Text(preset.format.lossless ? "Bit depth" : "Quality").font(KFont.labelLarge).foregroundStyle(c.ink2)
                Chips(options: preset.format.qualities, selected: preset.format.normalise(preset.quality), label: { $0.label }) { quality in
                    onChange(DownloadPreset(format: preset.format, quality: quality))
                }
                .padding(.horizontal, -16)
            }
            Text(preset.format.hint)
                .font(KFont.bodySmall)
                .foregroundStyle(c.ink3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

extension AudioFormat {
    /** "FLAC" rather than "FLAC (lossless)", for chips. */
    var shortLabel: String {
        if let cut = label.range(of: " (") { return String(label[..<cut.lowerBound]) }
        return label
    }

    var hint: String {
        switch self {
        case .flac: return "Lossless and widely supported. Keeps the source audio exactly; it can't add detail the source never had."
        case .mp3: return "Plays everywhere. 320 kbps is the highest MP3 quality."
        case .aac: return "Small and good quality. “Original” keeps YouTube's AAC stream without re-encoding."
        case .opus: return "The most efficient codec. “Original” keeps the source stream as it is. iPhone's Music app can't play it; VLC and most players can."
        case .alac: return "Apple's lossless format, for the Music app and Apple devices."
        case .wav: return "Uncompressed. Largest files."
        case .vorbis: return "Open format, good for older Ogg players."
        case .original: return "The file exactly as the source serves it, no conversion."
        }
    }
}

/** This phone, or one of the folders saved on a server; with a server, whether to keep a copy here too. */
struct DestinationPicker: View {
    @Environment(\.kultr) private var theme
    let selected: Destination?
    var allowPhone = true
    let onSelect: (Destination?) -> Void

    var body: some View {
        let graph = AppGraph.shared
        let c = theme.colors
        VStack(alignment: .leading, spacing: 2) {
            Text(allowPhone ? "Save to" : "Send to").font(KFont.labelLarge).foregroundStyle(c.ink2).padding(.bottom, 4)
            if allowPhone {
                row("This phone", graph.settings.settings.saveToMusic ? "Files app › KultrDL › Music" : "Inside KultrDL", selected == nil) { onSelect(nil) }
            }
            ForEach(graph.servers.servers) { server in
                ForEach(server.folders.isEmpty ? [""] : server.folders, id: \.self) { folder in
                    let on = selected?.serverId == server.id && selected?.folder == folder
                    row(server.name, "\(server.serverProtocol.label) · \(folderLabel(folder))", on) {
                        onSelect(Destination(serverId: server.id, folder: folder, keepOnPhone: selected?.keepOnPhone ?? false))
                    }
                }
            }
            if graph.servers.servers.isEmpty {
                Button {
                    graph.ui.downloadAs = nil
                    graph.ui.sendTo = nil
                    graph.actions.navigate(.server("new"))
                } label: {
                    Label("Add an FTP or SFTP server…", systemImage: "plus")
                        .font(KFont.bodyMedium)
                        .foregroundStyle(c.accent)
                        .padding(.vertical, 8)
                }
                .buttonStyle(PressableStyle())
            }
            if allowPhone, let selected {
                Toggle(isOn: Binding(get: { selected.keepOnPhone }, set: { value in
                    var next = selected
                    next.keepOnPhone = value
                    onSelect(next)
                })) {
                    Text("Keep a copy on this phone too").font(KFont.bodyMedium).foregroundStyle(c.ink)
                }
                .tint(c.accent)
                .padding(.top, 6)
            }
        }
    }

    private func row(_ title: String, _ hint: String, _ on: Bool, _ action: @escaping () -> Void) -> some View {
        let c = theme.colors
        return Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: on ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 20))
                    .foregroundStyle(on ? c.accent : c.ink3)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(KFont.bodyLarge).foregroundStyle(c.ink).lineLimit(1)
                    Text(hint).font(KFont.bodySmall).foregroundStyle(c.ink3).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/** Choose a format, quality and destination for a download. */
struct DownloadAsSheet: View {
    @Environment(\.kultr) private var theme
    let tracks: [Track]
    let onDismiss: () -> Void
    @State private var preset = DownloadPreset()
    @State private var destination: Destination?
    @State private var remember = false
    @State private var ready = false

    var body: some View {
        let graph = AppGraph.shared
        SheetScaffold(title: tracks.count == 1 ? "Download “\(tracks[0].title)”" : "Download \(tracks.count) tracks") {
            VStack(alignment: .leading, spacing: 18) {
                FormatPicker(preset: preset) { preset = $0 }
                DestinationPicker(selected: destination) { destination = $0 }
                Toggle(isOn: $remember) {
                    Text("Use for every download").font(KFont.bodyMedium).foregroundStyle(theme.colors.ink)
                }
                .tint(theme.colors.accent)
            }
        } buttons: {
            TextButton("Cancel", color: theme.colors.ink2, action: onDismiss)
            TextButton("Download") {
                if remember {
                    graph.settings.update {
                        $0.download = preset
                        $0.destination = destination
                        $0.askEachTime = false
                    }
                }
                graph.actions.download(tracks, preset: preset, destination: destination)
                onDismiss()
            }
        }
        .onAppear {
            guard !ready else { return }
            ready = true
            let s = graph.settings.settings
            preset = s.download
            destination = s.destination.flatMap { d in graph.servers.get(d.serverId) != nil ? d : nil }
        }
    }
}

/** Sends tracks that are on the phone to a server folder. */
struct SendToServerSheet: View {
    @Environment(\.kultr) private var theme
    let tracks: [Track]
    let onDismiss: () -> Void
    @State private var destination: Destination?
    @State private var ready = false

    var body: some View {
        let graph = AppGraph.shared
        SheetScaffold(title: "Send \(tracksLabel(tracks))") {
            DestinationPicker(selected: destination, allowPhone: false) { destination = $0 }
        } buttons: {
            TextButton("Cancel", color: theme.colors.ink2, action: onDismiss)
            TextButton("Send", enabled: destination != nil) {
                if let destination { graph.actions.send(tracks, to: destination) }
                onDismiss()
            }
        }
        .onAppear {
            guard !ready else { return }
            ready = true
            let servers = graph.servers.servers
            destination = graph.settings.settings.destination.flatMap { d in graph.servers.get(d.serverId) != nil ? d : nil }
                ?? servers.first.map { Destination(serverId: $0.id, folder: $0.folders.first ?? "") }
        }
    }
}

struct AddToPlaylistSheet: View {
    @Environment(\.kultr) private var theme
    let tracks: [Track]
    let onDismiss: () -> Void
    @State private var name = ""

    var body: some View {
        let library = AppGraph.shared.library
        let messages = AppGraph.shared.messages
        let c = theme.colors
        SheetScaffold(title: "Add \(tracksLabel(tracks)) to…") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    TextField("New playlist", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .submitLabel(.done)
                        .onSubmit(create)
                    IconButton(icon: "plus", tint: c.accent, label: "Create playlist", action: create)
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                ForEach(library.playlistsByDate) { playlist in
                    Button {
                        library.addToPlaylist(playlist.id, tracks)
                        messages.success("Added \(tracksLabel(tracks)) to “\(playlist.name)”")
                        onDismiss()
                    } label: {
                        HStack(spacing: 12) {
                            Artwork(url: playlist.artworkUrl ?? library.playlistTracks(playlist.id).first?.artworkUrl, size: 40, label: playlist.name)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(playlist.name).font(KFont.bodyLarge).foregroundStyle(c.ink)
                                Text(Format.count(playlist.trackIds.count, "track")).font(KFont.bodySmall).foregroundStyle(c.ink3)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PressableStyle())
                }
                if library.playlists.isEmpty {
                    Text("No playlists yet — name one above to create it.").font(KFont.bodyMedium).foregroundStyle(c.ink3)
                }
            }
        } buttons: {
            TextButton("Cancel", color: c.ink2, action: onDismiss)
        }
    }

    private func create() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        AppGraph.shared.library.createPlaylist(trimmed, tracks)
        AppGraph.shared.messages.success("Created “\(trimmed)”")
        onDismiss()
    }
}

/** A toast at the top of the screen, in the colour of its kind. */
struct ToastView: View {
    @Environment(\.kultr) private var theme
    let message: UiMessage

    var body: some View {
        let c = theme.colors
        let color: Color = {
            switch message.kind {
            case .error: return c.danger
            case .warning: return c.warning
            case .success, .info: return c.ink
            }
        }()
        HStack(spacing: 10) {
            Image(systemName: message.kind == .error ? "exclamationmark.triangle.fill" : message.kind == .success ? "checkmark.circle.fill" : "info.circle.fill")
                .foregroundStyle(message.kind == .success ? c.accent : color)
            Text(message.text)
                .font(KFont.bodyMedium)
                .foregroundStyle(color)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .kultrGlass(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding(.horizontal, 12)
        .onTapGesture { AppGraph.shared.messages.dismiss() }
        .accessibilityAddTraits(.isStaticText)
    }
}

/** A bold total for a list: "1 hr 12 min", "45 min". */
func totalDuration(_ tracks: [Track]) -> String? {
    let ms = tracks.compactMap { $0.durationMs }.reduce(0, +)
    guard ms > 0 else { return nil }
    let minutes = Int((Double(ms) / 60_000).rounded())
    if minutes >= 60 { return "\(minutes / 60) hr \(minutes % 60) min" }
    return "\(max(1, minutes)) min"
}
