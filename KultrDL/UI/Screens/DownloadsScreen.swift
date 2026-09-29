import KultrDLCore
import SwiftUI

/** Everything downloading, waiting, failed and done, and the format new downloads use. */
struct DownloadsScreen: View {
    @Environment(\.kultr) private var theme
    @State private var pickingFormat = false
    @State private var pickingDestination = false

    var body: some View {
        let graph = AppGraph.shared
        let downloads = graph.downloads
        let library = graph.library
        let settings = graph.settings.settings
        let servers = graph.servers.servers
        let c = theme.colors
        let jobs = downloads.jobs
        let active = jobs.filter { $0.isActive }.sorted { ($0.state == .running ? 0 : 1, $0.createdAt) < ($1.state == .running ? 0 : 1, $1.createdAt) }
        let failed = jobs.filter { $0.state == .failed }
        let sent = jobs.filter { $0.state == .done && $0.destination != nil && $0.message != nil }.sorted { $0.updatedAt > $1.updatedAt }
        let done = library.downloaded
        let destination = settings.destination.flatMap { d in graph.servers.get(d.serverId) != nil ? d : nil }
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                PillRow {
                    Pill(settings.download.label, icon: "slider.horizontal.3") { pickingFormat = true }
                    if !servers.isEmpty {
                        Pill(graph.servers.label(destination), icon: destination == nil ? "iphone" : "server.rack") { pickingDestination = true }
                    }
                    if !failed.isEmpty {
                        Pill("Retry failed", icon: "arrow.clockwise") { downloads.retryFailed() }
                    }
                    if jobs.contains(where: { $0.state == .done || $0.state == .cancelled }) {
                        Pill("Clear finished", icon: "xmark") { downloads.clearFinished() }
                    }
                }
                Text(whereTheyGo(destination, settings))
                    .font(KFont.bodySmall)
                    .foregroundStyle(c.ink3)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 6)
                if downloads.waitingForNetwork {
                    Label(
                        graph.network.online ? "Waiting for Wi-Fi (Settings → Downloads → Wi-Fi only)." : "Waiting for a connection.",
                        systemImage: graph.network.online ? "wifi" : "icloud.slash"
                    )
                    .font(KFont.bodyMedium)
                    .foregroundStyle(c.warning)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                }

                if !active.isEmpty {
                    SectionHeader("In progress", icon: "arrow.down.circle")
                    ForEach(active) { job in JobRow(job: job).id("active:\(job.trackId)") }
                }
                if !failed.isEmpty {
                    SectionHeader("Failed", icon: "exclamationmark.circle")
                    ForEach(failed) { job in JobRow(job: job).id("failed:\(job.trackId)") }
                }
                if !sent.isEmpty {
                    SectionHeader("Sent to servers", icon: "checkmark.icloud")
                    ForEach(sent) { job in SentRow(job: job).id("sent:\(job.trackId)") }
                }
                if !done.isEmpty {
                    let tracks = done.map { $0.track }
                    SectionHeader("On this phone", icon: "iphone") {
                        HStack(spacing: 12) {
                            if !servers.isEmpty {
                                textAction("Send all…") { graph.actions.sendToServer(tracks) }
                            }
                            textAction("Play all") { graph.actions.play(tracks) }
                        }
                    }
                    ForEach(Array(done.enumerated()), id: \.element.id) { index, stored in
                        DoneRow(stored: stored, canSend: !servers.isEmpty) { graph.actions.play(tracks, index) }
                            .id("done:\(stored.id)")
                    }
                }
                if active.isEmpty && failed.isEmpty && done.isEmpty && sent.isEmpty {
                    EmptyState(
                        icon: "arrow.down.circle",
                        title: "Nothing downloaded yet",
                        message: "Find a track, album or playlist and tap Download. Choose FLAC, MP3, AAC, Opus, ALAC, WAV or Ogg Vorbis above, and add an FTP or SFTP server in Settings to send music straight to it."
                    )
                }
            }
            .padding(.bottom, 24)
        }
        .navigationTitle("Downloads")
        .kultrScreen()
        .onAppear { downloads.start() }
        .onChange(of: settings.wifiOnly) { _, _ in downloads.start() }
        .sheet(isPresented: $pickingFormat) {
            FormatSheet { pickingFormat = false }
                .environment(\.kultr, theme)
                .presentationDetents([.medium, .large])
                .presentationBackground(.regularMaterial)
        }
        .sheet(isPresented: $pickingDestination) {
            DestinationSheet { pickingDestination = false }
                .environment(\.kultr, theme)
                .presentationDetents([.medium, .large])
                .presentationBackground(.regularMaterial)
        }
    }

    private func whereTheyGo(_ destination: Destination?, _ settings: Settings) -> String {
        let servers = AppGraph.shared.servers
        if let destination, destination.keepOnPhone { return "Sent to \(servers.label(destination)), with a copy on this phone." }
        if let destination { return "Sent to \(servers.label(destination))." }
        return settings.saveToMusic
            ? "Saved on this phone, in the Files app under KultrDL › Music."
            : "Saved inside KultrDL, hidden from other apps."
    }

    private func textAction(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(KFont.labelLarge).foregroundStyle(theme.colors.accent).frame(minHeight: 44)
        }
        .buttonStyle(PressScaleStyle())
    }
}

private func presetLabel(_ job: DownloadJob) -> String { job.preset.label }

@MainActor
private func serverName(_ job: DownloadJob) -> String? {
    job.destination.map { d in AppGraph.shared.servers.get(d.serverId)?.name ?? "a removed server" }
}

private struct JobRow: View {
    @Environment(\.kultr) private var theme
    let row: DownloadJob

    init(job: DownloadJob) {
        row = job
    }

    /** The job as it is now, not as it was when the row was made. */
    private var job: DownloadJob { AppGraph.shared.downloads.job(row.trackId) ?? row }

    var body: some View {
        let graph = AppGraph.shared
        let downloads = graph.downloads
        let job = self.job
        let c = theme.colors
        let track = graph.library.track(job.trackId)
        let live = downloads.live?.trackId == job.trackId ? downloads.live : nil
        let fraction = live?.fraction ?? job.progress
        HStack(spacing: 12) {
            Artwork(url: track?.artworkUrl, size: 48)
            VStack(alignment: .leading, spacing: 3) {
                Text(track?.title ?? job.trackId).font(KFont.bodyLarge).foregroundStyle(c.ink).lineLimit(1)
                Text(line(live))
                    .font(KFont.bodySmall)
                    .foregroundStyle(job.state == .failed ? c.danger : c.ink3)
                    .lineLimit(2)
                if job.state == .running {
                    ProgressBar(value: fraction, height: 3)
                        .padding(.top, 3)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if job.state == .failed {
                IconButton(icon: "arrow.clockwise", tint: c.ink2, size: 17, label: "Retry") { downloads.retry(job.trackId) }
                IconButton(icon: "xmark", tint: c.ink3, size: 15, label: "Remove") { downloads.remove(job.trackId) }
            } else {
                IconButton(icon: "xmark", tint: c.ink3, size: 15, label: "Cancel") { downloads.cancel(job.trackId) }
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 4)
        .padding(.vertical, 6)
        .contextMenu {
            if let track { TrackMenuItems(track: track) }
        }
    }

    private func line(_ live: DownloadProgress?) -> String {
        let server = serverName(job)
        switch job.state {
        case .queued:
            if job.upload { return "Waiting to send to \(server ?? "the server")" }
            if let server { return "Waiting · \(presetLabel(job)) → \(server)" }
            return "Waiting · \(presetLabel(job))"
        case .running:
            let fraction = live?.fraction ?? job.progress
            return [live?.stage ?? job.message, "\(Int(fraction * 100))%"].compactMap { $0 }.joined(separator: " · ")
        case .failed:
            return job.message ?? "Failed"
        default:
            return presetLabel(job)
        }
    }
}

/** A track that went to a server, and where it is there. */
private struct SentRow: View {
    @Environment(\.kultr) private var theme
    let job: DownloadJob

    var body: some View {
        let c = theme.colors
        let track = AppGraph.shared.library.track(job.trackId)
        HStack(spacing: 12) {
            Artwork(url: track?.artworkUrl, size: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(track?.title ?? job.trackId).font(KFont.bodyLarge).foregroundStyle(c.ink).lineLimit(1)
                Text(job.message ?? "").font(KFont.bodySmall).foregroundStyle(c.ink3).lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }
}

/** A download on the phone: play it, share or save the file, send it to a server, or delete it. */
private struct DoneRow: View {
    @Environment(\.kultr) private var theme
    let stored: StoredTrack
    let canSend: Bool
    let onPlay: () -> Void
    @State private var confirmDelete = false

    var body: some View {
        let graph = AppGraph.shared
        let c = theme.colors
        let track = stored.track
        HStack(spacing: 12) {
            Artwork(url: track.artworkUrl, size: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title).font(KFont.bodyLarge).foregroundStyle(c.ink).lineLimit(1)
                Text([track.artist, stored.localFormat, stored.localSize.map { Format.bytes($0) }].compactMap { $0 }.joined(separator: " · "))
                    .font(KFont.bodySmall)
                    .foregroundStyle(c.ink3)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let file = stored.localURL {
                ShareLink(item: file) {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(c.ink2)
                        .frame(width: 40, height: 44)
                }
                .accessibilityLabel("Share or save the file")
            }
            if canSend {
                IconButton(icon: "icloud.and.arrow.up", tint: c.ink2, size: 17, label: "Send to server") { graph.actions.sendToServer([track]) }
            }
            IconButton(icon: "trash", tint: c.ink3, size: 16, label: "Delete download") { confirmDelete = true }
        }
        .padding(.leading, 16)
        .padding(.trailing, 4)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture(perform: onPlay)
        .contextMenu { TrackMenuItems(track: track) }
        .confirmationDialog("Delete the download of “\(track.title)”?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { graph.actions.removeDownload(track) }
        } message: {
            Text("The track stays in your library and can be downloaded again.")
        }
    }
}

/** The format new downloads use. */
private struct FormatSheet: View {
    @Environment(\.kultr) private var theme
    let onDismiss: () -> Void
    @State private var preset = DownloadPreset()
    @State private var ready = false

    var body: some View {
        SheetScaffold(title: "Download format") {
            FormatPicker(preset: preset) { preset = $0 }
        } buttons: {
            TextButton("Cancel", color: theme.colors.ink2, action: onDismiss)
            TextButton("Save") {
                AppGraph.shared.settings.update { $0.download = preset }
                onDismiss()
            }
        }
        .onAppear {
            guard !ready else { return }
            ready = true
            preset = AppGraph.shared.settings.settings.download
        }
    }
}

/** Where downloads go: this phone or a folder on a saved server. */
struct DestinationSheet: View {
    @Environment(\.kultr) private var theme
    let onDismiss: () -> Void
    @State private var destination: Destination?
    @State private var ready = false

    var body: some View {
        SheetScaffold(title: "Where downloads go") {
            DestinationPicker(selected: destination) { destination = $0 }
        } buttons: {
            TextButton("Cancel", color: theme.colors.ink2, action: onDismiss)
            TextButton("Save") {
                AppGraph.shared.settings.update { $0.destination = destination }
                onDismiss()
            }
        }
        .onAppear {
            guard !ready else { return }
            ready = true
            let graph = AppGraph.shared
            destination = graph.settings.settings.destination.flatMap { d in graph.servers.get(d.serverId) != nil ? d : nil }
        }
    }
}

/** A glass strip over the page while anything is downloading; tap it for Downloads. */
struct DownloadIndicator: View {
    @Environment(\.kultr) private var theme
    var floating = false

    var body: some View {
        let graph = AppGraph.shared
        let downloads = graph.downloads
        let count = downloads.activeCount
        ZStack {
            if count > 0 {
                content(downloads, count)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .kultrGlass(RoundedRectangle(cornerRadius: 24, style: .continuous), interactive: true)
                    .contentShape(Rectangle())
                    .onTapGesture { graph.actions.openDownloads() }
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityHint("Opens Downloads")
            }
        }
        .animation(theme.spring, value: count > 0)
    }

    private func content(_ downloads: Downloads, _ count: Int) -> some View {
        let c = theme.colors
        let live = downloads.live
        let title = live.flatMap { AppGraph.shared.library.track($0.trackId)?.title }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: downloads.waitingForNetwork ? "wifi" : "arrow.down.circle.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(downloads.waitingForNetwork ? c.warning : c.accent)
                    .symbolEffect(.pulse, options: .repeating, isActive: !theme.reduceMotion && live != nil)
                Text(label(downloads, count, title))
                    .font(KFont.bodyMedium.weight(.medium))
                    .foregroundStyle(c.ink)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if count > 1 {
                    Text("\(count)").font(KFont.bodySmall.monospacedDigit()).foregroundStyle(c.ink3)
                }
                Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(c.ink3)
            }
            if let live {
                ProgressBar(value: live.fraction, height: 3)
            } else if !downloads.waitingForNetwork {
                ProgressBar(value: nil, height: 3)
            }
        }
    }

    private func label(_ downloads: Downloads, _ count: Int, _ title: String?) -> String {
        if downloads.waitingForNetwork {
            return AppGraph.shared.network.online ? "\(Format.count(count, "download")) waiting for Wi-Fi" : "\(Format.count(count, "download")) waiting for a connection"
        }
        if let title, let live = downloads.live { return "\(title) · \(live.stage)" }
        return "\(Format.count(count, "download")) waiting"
    }
}
