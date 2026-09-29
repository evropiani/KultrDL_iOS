import AVFoundation
import Foundation
import KultrDLCore
import MediaPlayer
import Observation
import UIKit

enum RepeatMode: String, Codable {
    case off, all, one
}

struct QueueEntry: Identifiable, Equatable {
    let index: Int
    let track: Track
    var id: String { "\(index):\(track.id)" }
}

struct PlayerUiState: Equatable {
    var current: Track?
    var index = -1
    var queue: [Track] = []
    var playWhenReady = false
    var isPlaying = false
    var buffering = false
    var ended = false
    var durationMs: Int64 = 0
    var shuffle = false
    var repeatMode: RepeatMode = .off

    var upNext: [QueueEntry] {
        guard index >= 0 else { return [] }
        return queue.enumerated().dropFirst(index + 1).map { QueueEntry(index: $0.offset, track: $0.element) }
    }
}

/** What is saved so the queue is there again next time. */
private struct SavedQueue: Codable {
    var queue: [Track]
    var original: [Track]?
    var index: Int
    var positionMs: Int64
    var shuffle: Bool
    var repeatMode: RepeatMode
}

/**
 * Playback: a queue of tracks played one after the other with AVPlayer,
 * each resolved when its turn comes (its downloaded file, or its stream),
 * with Control Center, the lock screen, AirPlay and headphone buttons.
 */
@MainActor
@Observable
final class PlayerController {
    private(set) var state = PlayerUiState()

    @ObservationIgnored private unowned let graph: AppGraph
    @ObservationIgnored private let player = AVPlayer()
    @ObservationIgnored private var loader: ChunkedStream?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var loadToken = UUID()
    @ObservationIgnored private var timeObserver: NSKeyValueObservation?
    @ObservationIgnored private var statusObserver: NSKeyValueObservation?
    @ObservationIgnored private var itemObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var original: [Track]?
    @ObservationIgnored private var loaded = false
    @ObservationIgnored private var pendingPositionMs: Int64 = 0
    @ObservationIgnored private var refused = false
    @ObservationIgnored private var countedPlay = false
    @ObservationIgnored private var failuresInARow = 0
    @ObservationIgnored private var artworkFor: String?
    @ObservationIgnored private var artwork: MPMediaItemArtwork?
    @ObservationIgnored private var saveTask: Task<Void, Never>?

    init(graph: AppGraph) {
        self.graph = graph
    }

    func start() {
        player.automaticallyWaitsToMinimizeStalling = true
        timeObserver = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            let status = player.timeControlStatus
            Task { @MainActor in self?.timeControlChanged(status) }
        }
        setUpRemoteCommands()
        let center = NotificationCenter.default
        center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let info = note.userInfo
            MainActor.assumeIsolated { self?.interrupted(info) }
        }
        center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap(AVAudioSession.RouteChangeReason.init)
            MainActor.assumeIsolated {
                if reason == .oldDeviceUnavailable { self?.pause() }
            }
        }
        center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.saveNow() }
        }
        restore()
    }

    // ------------------------------------------------------------- queue --

    func play(_ tracks: [Track], startIndex: Int = 0, shuffle: Bool = false) {
        guard !tracks.isEmpty else { return }
        graph.library.remember(tracks)
        if shuffle {
            original = tracks
            state.queue = tracks.shuffled()
            state.index = 0
        } else {
            original = nil
            state.queue = tracks
            state.index = min(max(0, startIndex), tracks.count - 1)
        }
        state.shuffle = shuffle
        state.current = state.queue[state.index]
        failuresInARow = 0
        load(autoplay: true)
        queueChanged()
    }

    func playNext(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        if state.queue.isEmpty {
            play(tracks)
            return
        }
        graph.library.remember(tracks)
        state.queue.insert(contentsOf: tracks, at: state.index + 1)
        original?.append(contentsOf: tracks)
        queueChanged()
    }

    func enqueue(_ tracks: [Track]) {
        guard !tracks.isEmpty else { return }
        if state.queue.isEmpty {
            play(tracks)
            return
        }
        graph.library.remember(tracks)
        state.queue.append(contentsOf: tracks)
        original?.append(contentsOf: tracks)
        queueChanged()
    }

    func jumpTo(_ index: Int) {
        guard state.queue.indices.contains(index) else { return }
        state.index = index
        state.current = state.queue[index]
        failuresInARow = 0
        load(autoplay: true)
        queueChanged()
    }

    func remove(_ index: Int) {
        guard state.queue.indices.contains(index), index != state.index else { return }
        let removed = state.queue.remove(at: index)
        if let at = original?.firstIndex(where: { $0.id == removed.id }) { original?.remove(at: at) }
        if index < state.index { state.index -= 1 }
        queueChanged()
    }

    func move(_ from: Int, _ to: Int) {
        guard state.queue.indices.contains(from), state.queue.indices.contains(to), from != to else { return }
        let track = state.queue.remove(at: from)
        state.queue.insert(track, at: to)
        if from == state.index {
            state.index = to
        } else if from < state.index && to >= state.index {
            state.index -= 1
        } else if from > state.index && to <= state.index {
            state.index += 1
        }
        queueChanged()
    }

    func clearUpcoming() {
        guard state.index >= 0, state.index + 1 < state.queue.count else { return }
        state.queue.removeSubrange((state.index + 1)...)
        original = nil
        queueChanged()
    }

    func setShuffle(_ on: Bool) {
        guard on != state.shuffle else { return }
        if on {
            original = state.queue
            if state.index >= 0 {
                let head = Array(state.queue.prefix(state.index + 1))
                state.queue = head + state.queue.dropFirst(state.index + 1).shuffled()
            }
        } else if let original {
            let currentId = state.current?.id
            state.queue = original
            state.index = original.firstIndex { $0.id == currentId } ?? 0
            self.original = nil
        }
        state.shuffle = on
        queueChanged()
    }

    func cycleRepeat() {
        switch state.repeatMode {
        case .off: state.repeatMode = .all
        case .all: state.repeatMode = .one
        case .one: state.repeatMode = .off
        }
        queueChanged()
    }

    func stop() {
        teardown()
        state = PlayerUiState()
        original = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        queueChanged()
    }

    // ---------------------------------------------------------- transport --

    func toggle() {
        if state.playWhenReady && !state.ended { pause() } else { resume() }
    }

    /** Play, picking up a restored queue where it was left. */
    func resume() {
        guard state.current != nil else { return }
        if state.ended {
            state.ended = false
            seekTo(0)
        }
        if !loaded {
            load(autoplay: true, at: pendingPositionMs)
            return
        }
        activateSession()
        state.playWhenReady = true
        player.play()
        updateNowPlaying()
    }

    func pause() {
        state.playWhenReady = false
        player.pause()
        updateNowPlaying()
        scheduleSave()
    }

    func next() {
        guard !state.queue.isEmpty else { return }
        if state.index + 1 < state.queue.count {
            jumpTo(state.index + 1)
        } else if state.repeatMode == .all {
            jumpTo(0)
        }
    }

    func previous() {
        if positionMs() > 4000 || state.index <= 0 {
            seekTo(0)
        } else {
            jumpTo(state.index - 1)
        }
    }

    func seekTo(_ ms: Int64) {
        let target = max(0, ms)
        if !loaded {
            pendingPositionMs = target
            return
        }
        player.seek(to: CMTime(value: target, timescale: 1000), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in self?.updateNowPlaying() }
        }
    }

    func positionMs() -> Int64 {
        guard loaded else { return pendingPositionMs }
        let seconds = player.currentTime().seconds
        return seconds.isFinite ? Int64(seconds * 1000) : 0
    }

    // ------------------------------------------------------------ loading --

    private func teardown() {
        loadTask?.cancel()
        loadTask = nil
        loadToken = UUID()
        for token in itemObservers { NotificationCenter.default.removeObserver(token) }
        itemObservers = []
        statusObserver?.invalidate()
        statusObserver = nil
        player.replaceCurrentItem(with: nil)
        loader?.invalidate()
        loader = nil
        loaded = false
    }

    private func load(autoplay: Bool, at positionMs: Int64 = 0) {
        teardown()
        guard let track = state.current else { return }
        state.durationMs = track.durationMs ?? 0
        state.ended = false
        state.buffering = true
        state.playWhenReady = autoplay
        pendingPositionMs = positionMs
        refused = false
        countedPlay = false
        updateNowPlaying()
        let token = loadToken
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let resolved = try await self.graph.resolver.resolve(track)
                guard self.loadToken == token else { return }
                self.attach(resolved, autoplay: autoplay, at: positionMs)
            } catch {
                guard self.loadToken == token, !(error is CancellationError) else { return }
                self.failed(track, error)
            }
        }
    }

    private func attach(_ resolved: StreamResolver.Resolved, autoplay: Bool, at positionMs: Int64) {
        let item: AVPlayerItem
        switch resolved {
        case .local(let url):
            item = AVPlayerItem(url: url)
        case .remote(let stream):
            guard let url = URL(string: stream.url) else {
                if let track = state.current { failed(track, KultrError("The stream's address is broken.")) }
                return
            }
            if stream.kind == .hls {
                var headers = stream.headers
                if headers["User-Agent"] == nil { headers["User-Agent"] = Http.browserUserAgent }
                let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
                item = AVPlayerItem(asset: asset)
            } else if let chunked = ChunkedStream(stream: stream, onRefused: { [weak self] _ in
                Task { @MainActor in self?.refused = true }
            }) {
                loader = chunked
                item = AVPlayerItem(asset: chunked.asset)
            } else {
                item = AVPlayerItem(url: url)
            }
        }
        item.preferredForwardBufferDuration = 30
        statusObserver = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            let status = item.status
            let error = item.error
            let duration = item.duration.seconds
            Task { @MainActor in self?.itemStatusChanged(status, error: error, duration: duration) }
        }
        let center = NotificationCenter.default
        itemObservers.append(center.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reachedEnd() }
        })
        itemObservers.append(center.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: item, queue: .main) { [weak self] note in
            let error = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            MainActor.assumeIsolated { self?.itemFailed(error) }
        })
        player.replaceCurrentItem(with: item)
        loaded = true
        if positionMs > 0 {
            player.seek(to: CMTime(value: positionMs, timescale: 1000), toleranceBefore: .zero, toleranceAfter: .zero)
        }
        if autoplay {
            activateSession()
            player.play()
        }
    }

    private func itemStatusChanged(_ status: AVPlayerItem.Status, error: Error?, duration: Double) {
        switch status {
        case .readyToPlay:
            if duration.isFinite, duration > 0 { state.durationMs = Int64(duration * 1000) }
            updateNowPlaying()
            if state.index + 1 < state.queue.count { graph.resolver.prefetch(state.queue[state.index + 1]) }
        case .failed:
            itemFailed(error)
        default:
            break
        }
    }

    private func itemFailed(_ error: Error?) {
        guard let track = state.current else { return }
        if refused, graph.resolver.refuse(track.id) {
            // YouTube refused this client's stream: ask another, from where it was.
            let at = positionMs()
            graph.messages.show("YouTube refused the stream; trying another way…")
            load(autoplay: state.playWhenReady, at: at)
            return
        }
        failed(track, error ?? KultrError("This track couldn't be played."))
    }

    private func failed(_ track: Track, _ error: Error) {
        state.buffering = false
        failuresInARow += 1
        graph.messages.error("Couldn't play “\(track.title)”: \(describe(error))")
        if failuresInARow < 4, state.playWhenReady, state.index + 1 < state.queue.count {
            jumpToKeepingFailures(state.index + 1)
        } else {
            state.playWhenReady = false
            state.isPlaying = false
            updateNowPlaying()
        }
    }

    private func jumpToKeepingFailures(_ index: Int) {
        let failures = failuresInARow
        jumpTo(index)
        failuresInARow = failures
    }

    private func timeControlChanged(_ status: AVPlayer.TimeControlStatus) {
        state.isPlaying = status == .playing
        state.buffering = status == .waitingToPlayAtSpecifiedRate || (!loaded && state.playWhenReady)
        if status == .playing, let track = state.current {
            failuresInARow = 0
            if !countedPlay {
                countedPlay = true
                graph.library.markPlayed(track.id)
                graph.resolver.playing(track.id)
            }
        }
        updateNowPlaying()
    }

    private func reachedEnd() {
        switch state.repeatMode {
        case .one:
            seekTo(0)
            player.play()
        case .all where state.index + 1 >= state.queue.count:
            jumpTo(0)
        default:
            if state.index + 1 < state.queue.count {
                jumpTo(state.index + 1)
            } else {
                state.ended = true
                state.playWhenReady = false
                updateNowPlaying()
            }
        }
    }

    // -------------------------------------------------------------- system --

    private func activateSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        try? session.setActive(true)
    }

    private func interrupted(_ info: [AnyHashable: Any]?) {
        guard let raw = info?[AVAudioSessionInterruptionTypeKey] as? UInt, let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            if state.playWhenReady { player.pause() }
        case .ended:
            let options = AVAudioSession.InterruptionOptions(rawValue: info?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
            if options.contains(.shouldResume), state.playWhenReady { player.play() }
        @unknown default:
            break
        }
    }

    private func setUpRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.resume() }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.pause() }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.toggle() }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.next() }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.previous() }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let ms = Int64(event.positionTime * 1000)
            MainActor.assumeIsolated { self?.seekTo(ms) }
            return .success
        }
    }

    private func updateNowPlaying() {
        guard let track = state.current else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artist,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: Double(positionMs()) / 1000,
            MPNowPlayingInfoPropertyPlaybackRate: state.isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        if let album = track.album { info[MPMediaItemPropertyAlbumTitle] = album }
        if state.durationMs > 0 { info[MPMediaItemPropertyPlaybackDuration] = Double(state.durationMs) / 1000 }
        if artworkFor == track.artworkUrl, let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        MPNowPlayingInfoCenter.default().playbackState = state.isPlaying ? .playing : (state.playWhenReady ? .interrupted : .paused)
        if artworkFor != track.artworkUrl {
            artworkFor = track.artworkUrl
            artwork = nil
            if let url = track.artworkUrl.flatMap(URL.init(string:)) {
                Task { [weak self] in
                    guard let image = await ImageLoader.shared.image(url, pixelSize: 600) else { return }
                    guard let self, self.artworkFor == track.artworkUrl else { return }
                    self.artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                    self.updateNowPlaying()
                }
            }
        }
    }

    // --------------------------------------------------------- persistence --

    private func queueChanged() {
        updateNowPlaying()
        scheduleSave()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        saveTask?.cancel()
        let saved = SavedQueue(
            queue: Array(state.queue.prefix(2000)), original: original.map { Array($0.prefix(2000)) },
            index: state.index, positionMs: positionMs(), shuffle: state.shuffle, repeatMode: state.repeatMode
        )
        Storage.save(saved, "player.json")
    }

    /** The queue as it was, paused, so play (here or on headphones) picks it up. */
    private func restore() {
        guard let saved = Storage.load(SavedQueue.self, "player.json"), saved.queue.indices.contains(saved.index) else { return }
        state.queue = saved.queue
        state.index = saved.index
        state.current = saved.queue[saved.index]
        state.shuffle = saved.shuffle
        state.repeatMode = saved.repeatMode
        state.durationMs = state.current?.durationMs ?? 0
        original = saved.original
        pendingPositionMs = saved.positionMs
        updateNowPlaying()
    }
}
