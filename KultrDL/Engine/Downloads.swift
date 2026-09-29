import BackgroundTasks
import Foundation
import KultrDLCore
import KultrDLMedia
import KultrDLRemote
import Network
import Observation
import UIKit

enum DownloadState: String, Codable, Hashable {
    case queued = "QUEUED", running = "RUNNING", done = "DONE", failed = "FAILED", cancelled = "CANCELLED"

    init(from decoder: Decoder) throws {
        self = DownloadState(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .failed
    }
}

/**
 * A job in the download queue. With a [destination] the file goes to a
 * server; [upload] means the track is already on the phone and only needs
 * sending. When a job for a server is done, [message] says where it went.
 */
struct DownloadJob: Codable, Identifiable, Hashable {
    var trackId: String
    var state: DownloadState
    var format: AudioFormat
    var quality: Quality
    var progress: Double = 0
    var message: String?
    var createdAt: Int64
    var updatedAt: Int64
    var destination: Destination?
    var upload = false

    var id: String { trackId }
    var preset: DownloadPreset { DownloadPreset(format: format, quality: format.normalise(quality)) }
    var isActive: Bool { state == .queued || state == .running }

    init(trackId: String, preset: DownloadPreset, destination: Destination?, upload: Bool = false) {
        self.trackId = trackId
        state = .queued
        format = preset.format
        quality = preset.format.normalise(preset.quality)
        createdAt = nowMs()
        updatedAt = createdAt
        self.destination = destination
        self.upload = upload
    }
}

/** Live progress of the download that is running. */
struct DownloadProgress: Equatable {
    var trackId: String
    var fraction: Double
    var stage: String
}

/** Whether the phone is online, and on Wi-Fi or mobile data. */
@MainActor
@Observable
final class NetworkMonitor {
    private(set) var online = true
    private(set) var expensive = false
    @ObservationIgnored private let monitor = NWPathMonitor()
    @ObservationIgnored var onChange: (() -> Void)?

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self else { return }
                let online = path.status == .satisfied
                let expensive = path.isExpensive
                guard online != self.online || expensive != self.expensive else { return }
                self.online = online
                self.expensive = expensive
                self.onChange?()
            }
        }
        monitor.start(queue: DispatchQueue(label: "kultrdl.network"))
    }
}

/**
 * The download queue, worked through one job at a time: find the recording,
 * fetch the best audio, convert it to the chosen format and quality, write
 * the tags and cover, then keep it on the phone (in the Files app) or send
 * it to a folder on an FTP or SFTP server. It carries on in the background
 * for as long as iOS allows, and picks up where it stopped next time.
 */
@MainActor
@Observable
final class Downloads {
    static let backgroundTaskId = "app.kultr.dl.downloads"

    private(set) var jobs: [DownloadJob] = []
    private(set) var live: DownloadProgress?
    private(set) var waitingForNetwork = false

    @ObservationIgnored private unowned let graph: AppGraph
    @ObservationIgnored private var runner: Task<Void, Never>?
    @ObservationIgnored private var current: (trackId: String, task: Task<String?, Error>)?
    @ObservationIgnored private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    @ObservationIgnored private var processingTask: BGProcessingTask?
    @ObservationIgnored private let downloader = StreamDownloader()
    @ObservationIgnored private var lastLive = Date.distantPast

    init(graph: AppGraph) {
        self.graph = graph
        jobs = Storage.load([DownloadJob].self, "downloads.json") ?? []
    }

    private func save() {
        Storage.save(jobs, "downloads.json")
    }

    var active: [DownloadJob] { jobs.filter { $0.isActive } }
    var activeCount: Int { jobs.reduce(0) { $0 + ($1.isActive ? 1 : 0) } }

    func job(_ trackId: String) -> DownloadJob? { jobs.first { $0.trackId == trackId } }

    private func set(_ trackId: String, _ change: (inout DownloadJob) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.trackId == trackId }) else { return }
        change(&jobs[index])
        jobs[index].updatedAt = nowMs()
        save()
    }

    private func put(_ job: DownloadJob) {
        jobs.removeAll { $0.trackId == job.trackId }
        jobs.append(job)
        save()
    }

    // ------------------------------------------------------------ queueing --

    func enqueue(_ tracks: [Track], preset: DownloadPreset, destination: Destination?) {
        guard !tracks.isEmpty else { return }
        graph.library.remember(tracks)
        let target = destination.flatMap { graph.servers.get($0.serverId) != nil ? $0 : nil }
        var seen = Set<String>()
        for t in tracks where seen.insert(t.id).inserted {
            if job(t.id)?.isActive == true { continue }
            put(DownloadJob(trackId: t.id, preset: preset, destination: target))
        }
        start()
    }

    /** Sends tracks that are on the phone already to a server folder. Returns how many were queued. */
    func send(_ tracks: [Track], to destination: Destination) -> Int {
        var queued = 0
        var seen = Set<String>()
        for t in tracks where seen.insert(t.id).inserted {
            guard graph.library.stored(t.id)?.localPath != nil, job(t.id)?.isActive != true else { continue }
            var target = destination
            target.keepOnPhone = true
            put(DownloadJob(trackId: t.id, preset: graph.settings.settings.download, destination: target, upload: true))
            queued += 1
        }
        if queued > 0 { start() }
        return queued
    }

    func cancel(_ trackId: String) {
        set(trackId) {
            $0.state = .cancelled
            $0.progress = 0
            $0.message = nil
        }
        if current?.trackId == trackId { current?.task.cancel() }
    }

    func retry(_ trackId: String) {
        set(trackId) {
            $0.state = .queued
            $0.progress = 0
            $0.message = nil
        }
        start()
    }

    func retryFailed() {
        for job in jobs where job.state == .failed { retry(job.trackId) }
    }

    func remove(_ trackId: String) {
        if current?.trackId == trackId { current?.task.cancel() }
        jobs.removeAll { $0.trackId == trackId }
        save()
    }

    func clearFinished() {
        jobs.removeAll { $0.state == .done || $0.state == .cancelled }
        save()
    }

    /** Delete the downloaded file; the track stays in the library. */
    func deleteFile(_ trackId: String) {
        if let url = graph.library.stored(trackId)?.localURL { try? FileManager.default.removeItem(at: url) }
        graph.library.setLocal(trackId, file: nil, format: nil, size: nil)
        jobs.removeAll { $0.trackId == trackId && !$0.isActive }
        save()
    }

    /** At launch: a job cut off when the app stopped goes back in the queue. */
    func recover() {
        var changed = false
        for index in jobs.indices where jobs[index].state == .running {
            jobs[index].state = .queued
            jobs[index].message = nil
            changed = true
        }
        if changed { save() }
        if jobs.contains(where: { $0.state == .queued }) { start() }
    }

    // ------------------------------------------------------------- running --

    func start() {
        guard runner == nil else { return }
        guard jobs.contains(where: { $0.state == .queued }) else { return }
        runner = Task { [weak self] in
            await self?.runQueue()
            self?.runner = nil
        }
    }

    private func blocked() -> Bool {
        let network = graph.network
        return !network.online || (graph.settings.settings.wifiOnly && network.expensive)
    }

    var waitingForWifi: Bool { waitingForNetwork && graph.network.online }

    private func runQueue() async {
        beginBackground()
        defer { endBackground() }
        while let job = jobs.first(where: { $0.state == .queued }) {
            if blocked() {
                waitingForNetwork = true
                return
            }
            waitingForNetwork = false
            set(job.trackId) {
                $0.state = .running
                $0.progress = 0
                $0.message = "Starting…"
            }
            let work = Task { () throws -> String? in try await self.process(job) }
            current = (job.trackId, work)
            do {
                let note = try await work.value
                if self.job(job.trackId)?.state == .running {
                    set(job.trackId) {
                        $0.state = .done
                        $0.progress = 1
                        $0.message = note
                    }
                }
            } catch {
                let state = self.job(job.trackId)?.state
                if state == .running {
                    if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                        // The app is being stopped: this one starts again next time.
                        set(job.trackId) {
                            $0.state = .queued
                            $0.message = nil
                        }
                    } else {
                        let reason = error is UntrustedServerError
                            ? describe(error) + " Check the server in Settings → Servers."
                            : describe(error)
                        set(job.trackId) {
                            $0.state = .failed
                            $0.progress = 0
                            $0.message = reason
                        }
                    }
                }
            }
            current = nil
            if live?.trackId == job.trackId { live = nil }
            if Task.isCancelled { return }
        }
        finishedAll()
    }

    private func finishedAll() {
        processingTask?.setTaskCompleted(success: true)
        processingTask = nil
    }

    /** Progress from the work, thinned out to a few updates a second. */
    nonisolated private func report(_ trackId: String, _ fraction: Double, _ stage: String) {
        Task { @MainActor in
            let now = Date()
            if self.live?.stage == stage, now.timeIntervalSince(self.lastLive) < 0.25 { return }
            self.lastLive = now
            guard self.current?.trackId == trackId else { return }
            self.live = DownloadProgress(trackId: trackId, fraction: min(1, max(0, fraction)), stage: stage)
        }
    }

    /** Runs one job; for a server, returns where the file went. */
    private func process(_ job: DownloadJob) async throws -> String? {
        guard let track = graph.library.track(job.trackId) else { throw KultrError("The track is no longer in the library.") }
        let destination = job.destination
        let server = try destination.map { d -> SavedServer in
            guard let s = graph.servers.get(d.serverId) else { throw KultrError("The server it was going to has been removed.") }
            return s
        }
        let id = job.trackId
        if job.upload, let destination, let server {
            return try await sendFromPhone(track, destination, server)
        }
        let preset = job.preset
        let settings = graph.settings.settings
        report(id, 0, "Finding the recording…")
        let source = try await graph.resolver.sourceUrl(track)

        let dir = Storage.work.appendingPathComponent(TextTools.fileName(id, max: 60), isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // YouTube may refuse one client's stream (HTTP 403) and give another's.
        let preferred = settings.youtubeClient.isEmpty ? nil : settings.youtubeClient
        let order = graph.engine.config.order(startingWith: preferred).map { $0.key }
        var tried = Set<String>()
        var fetched: StreamDownloader.Result?
        while fetched == nil {
            var only: String?
            if !tried.isEmpty {
                guard let next = order.first(where: { !tried.contains($0) }) else {
                    throw KultrError("YouTube refused every way of downloading this on this network. Try Settings → Engine → Test YouTube.")
                }
                only = next
            }
            let stream = try await graph.finder.find(source, purpose: .download(prefer: preset.preferredCodec), client: preferred, onlyClient: only)
            if stream.isPreview {
                throw KultrError("Only a 30-second preview of this track is available.")
            }
            report(id, 0.02, "Downloading \(stream.label)…")
            do {
                let stage = "Downloading \(stream.label)…"
                fetched = try await downloader.download(stream, into: dir) { [weak self] fraction in
                    self?.report(id, 0.02 + fraction * 0.6, stage)
                }
                if let client = stream.client, !tried.isEmpty, client != graph.settings.settings.youtubeClient {
                    graph.settings.update { $0.youtubeClient = client }
                }
            } catch let refused as StreamForbidden {
                guard let client = stream.client else { throw refused }
                tried.insert(client)
                report(id, 0, "Trying another way…")
                for file in (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] {
                    try? FileManager.default.removeItem(at: file)
                }
            }
        }
        guard let fetched else { throw KultrError("Nothing was downloaded.") }

        var cover: Data?
        if settings.embedArtwork, let art = track.artworkUrl {
            report(id, 0.63, "Fetching the cover…")
            if let data = try? await graph.http.getData(art) { cover = CoverArt.squareJPEG(data) }
        }
        let stage = "Converting to \(preset.label)…"
        report(id, 0.64, stage)
        let output = try await Transcoder.convert(
            source: fetched.file, container: fetched.container, preset: preset,
            tags: TrackTags(track, cover: cover), directory: dir
        ) { [weak self] fraction in
            self?.report(id, 0.64 + fraction * 0.3, stage)
        }
        try Task.checkCancellation()

        let name = TextTools.fileName("\(track.artist) - \(track.title)") + "." + output.fileExtension
        var sent: String?
        if let destination, let server {
            sent = try await upload(output.file, name: name, track: track, destination: destination, server: server, from: 0.94, to: 0.99)
        }
        if sent == nil || destination?.keepOnPhone == true {
            report(id, 0.99, "Saving…")
            let folder = settings.saveToMusic ? Storage.visibleMusic : Storage.privateMusic
            let previous = graph.library.stored(id)?.localURL
            if let previous { try? FileManager.default.removeItem(at: previous) }
            let target = Storage.unique(folder, name)
            try FileManager.default.moveItem(at: output.file, to: target)
            graph.library.setLocal(id, file: target, format: preset.label, size: Storage.size(target))
        }
        return sent
    }

    /** A track that is on the phone already, sent as it is. */
    private func sendFromPhone(_ track: Track, _ destination: Destination, _ server: SavedServer) async throws -> String {
        guard let file = graph.library.stored(track.id)?.localURL, FileManager.default.fileExists(atPath: file.path) else {
            throw KultrError("“\(track.title)” isn't on this phone any more.")
        }
        let ext = file.pathExtension.isEmpty ? "mp3" : file.pathExtension.lowercased()
        let name = TextTools.fileName("\(track.artist) - \(track.title)") + "." + ext
        return try await upload(file, name: name, track: track, destination: destination, server: server, from: 0, to: 0.99)
    }

    /**
     * Uploads into the destination folder, under Artist or Artist/Album when
     * the server is set up that way. Trusts a server's key the first time it
     * is seen, and saves it.
     */
    private func upload(_ file: URL, name: String, track: Track, destination: Destination, server: SavedServer, from: Double, to: Double) async throws -> String {
        let id = track.id
        report(id, from, "Connecting to \(server.name)…")
        let size = Storage.size(file) ?? 0
        let session = try await Remote.open(server.connection)
        do {
            if let pin = session.newPin { graph.servers.setPin(server.id, pin) }
            let folder = RemotePath.resolve(session.home, destination.folder)
            let dir = RemotePath.join(folder, server.layout.folders(artist: track.artist, albumArtist: track.albumArtist, album: track.album))
            try await session.makeDirectories(dir)
            let path = RemotePath.join(dir, name)
            let stage = "Sending to \(server.name)…"
            report(id, from, stage)
            try await session.upload(file, to: path) { [weak self] sent in
                let fraction = size > 0 ? min(1, Double(sent) / Double(size)) : 0
                self?.report(id, from + (to - from) * fraction, stage)
            }
            await session.close()
            return "\(server.name): \(path)"
        } catch {
            await session.close()
            throw error
        }
    }

    // ---------------------------------------------------------- background --

    private func beginBackground() {
        guard backgroundTask == .invalid else { return }
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "KultrDL downloads") { [weak self] in
            Task { @MainActor in self?.expire() }
        }
    }

    private func endBackground() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    /** iOS is about to suspend the app: stop cleanly and ask to be woken later. */
    private func expire() {
        current?.task.cancel()
        runner?.cancel()
        scheduleProcessing()
        endBackground()
    }

    /** Asks iOS for time to carry on with the queue (on charge and Wi-Fi, when it decides). */
    func scheduleProcessing() {
        guard jobs.contains(where: { $0.isActive }) else { return }
        let request = BGProcessingTaskRequest(identifier: Self.backgroundTaskId)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        try? BGTaskScheduler.shared.submit(request)
    }

    /** iOS woke the app to work on the queue. */
    func run(_ task: BGProcessingTask) {
        processingTask = task
        task.expirationHandler = { [weak self] in
            Task { @MainActor in
                self?.current?.task.cancel()
                self?.runner?.cancel()
                self?.scheduleProcessing()
                task.setTaskCompleted(success: false)
                self?.processingTask = nil
            }
        }
        recover()
        if runner == nil { finishedAll() }
    }
}
