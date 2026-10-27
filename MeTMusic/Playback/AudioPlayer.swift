import AVFoundation
import Combine
import Foundation

@MainActor
final class AudioPlayer: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var isReady = false
    @Published private(set) var isLoading = false
    @Published private(set) var positionMs: Int64 = 0
    @Published private(set) var durationMs: Int64 = 0
    @Published private(set) var playbackDiscontinuityRevision: UInt = 0
    @Published var volume: Float = 1 {
        didSet {
            player.volume = volume
            filePlayer?.volume = volume
        }
    }

    var onPlaybackComplete: (() -> Void)?
    var onPlaybackFailure: ((String) -> Void)?
    private let audioSessionActivation: @Sendable () async throws -> Void
    /// Plays a complete local file. Its position is a plain property: assigning
    /// it moves playback immediately, with no completion to be overtaken and no
    /// item to reload, so a position can never end up somewhere else than the
    /// one that was asked for. Streaming still needs AVPlayer, so the two
    /// engines coexist and the URL decides which one plays.
    private var filePlayer: AVAudioPlayer?
    private var filePositionTask: Task<Void, Never>?
    private lazy var fileDelegate = AudioFilePlaybackDelegate(owner: self)
    private var interruptionObserver: NSObjectProtocol?
    private var routeChangeObserver: NSObjectProtocol?
    private var resumesAfterInterruption = false
    private let player = AVPlayer()
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var statusObservation: NSKeyValueObservation?
    private var generation = 0
    private var pendingSeekRevision: UInt?
    private var suppressPeriodicPositionUpdatesUntil = Date.distantPast
    /// AVPlayer's clock only describes the requested playback position once the
    /// current item is loaded and positioned. Before that it still reports the
    /// previous item's time, and then zero for the freshly installed item, so
    /// every consumer must fall back to the published target position instead.
    private var clockIsAuthoritative = false
    /// How many times a seek may be retried before playback is left wherever
    /// the player got to. Retries only happen when the player disagrees with
    /// the target, which a settled local file never does.
    private let seekAttempts = 3
    private let seekReadinessAttempts = 150

    /// Whether either engine currently holds media. The clock is meaningless
    /// without one, and the file engine deliberately leaves AVPlayer empty.
    private var hasLoadedMedia: Bool { filePlayer != nil || player.currentItem != nil }

    /// Whether playback is reading a complete local file rather than a stream.
    var usesFileEngine: Bool { filePlayer != nil }

    private var playbackClockIsUsable: Bool {
        playbackClockDescribesRequestedPosition(
            hasCurrentItem: hasLoadedMedia,
            isPositioned: clockIsAuthoritative,
            hasPendingSeek: pendingSeekRevision != nil
        )
    }

    init(audioSessionActivation: (@Sendable () async throws -> Void)? = nil) {
        self.audioSessionActivation = audioSessionActivation ?? { try await Self.activateAudioSession() }
        observeAudioSession()
        player.automaticallyWaitsToMinimizeStalling = true
        player.actionAtItemEnd = .pause
        timeObserver = player.addPeriodicTimeObserver(
            // General UI position remains coarse. Lyrics separately sample a
            // shared authoritative media clock at display cadence, without
            // publishing the entire app hierarchy on every frame.
            forInterval: CMTime(value: 1, timescale: 10),
            queue: .main
        ) { [weak self] _ in
            // The observer is explicitly delivered on .main. Read the current
            // engine now: a queued timestamp may belong to an earlier item.
            MainActor.assumeIsolated {
                guard let self, self.filePlayer == nil, self.player.currentItem != nil else { return }
                if self.playbackClockIsUsable, Date.now >= self.suppressPeriodicPositionUpdatesUntil {
                    self.positionMs = self.playerPositionMs(fallback: self.positionMs)
                }
                self.isPlaying = self.player.timeControlStatus == .playing
            }
        }
    }

    func play(url: URL, autoPlay: Bool = true, startPositionMs: Int64 = 0) {
        let request = beginLoad(startPositionMs: startPositionMs)
        Task {
            _ = await performLoad(
                url: url,
                autoPlay: autoPlay,
                startPositionMs: startPositionMs,
                request: request
            )
        }
    }

    /// Loads `url` and returns once the item is ready and sitting at
    /// `startPositionMs`, so a caller that has to know playback is actually
    /// there — a precise seek — can wait instead of guessing.
    @discardableResult
    func load(url: URL, autoPlay: Bool = false, startPositionMs: Int64 = 0) async -> Bool {
        let request = beginLoad(startPositionMs: startPositionMs)
        return await performLoad(
            url: url,
            autoPlay: autoPlay,
            startPositionMs: startPositionMs,
            request: request
        )
    }

    private func beginLoad(startPositionMs: Int64) -> Int {
        generation += 1
        playbackDiscontinuityRevision &+= 1
        player.pause()
        statusObservation = nil
        teardownFileEngine()
        isPlaying = false
        isReady = false
        isLoading = true
        pendingSeekRevision = nil
        clockIsAuthoritative = false
        suppressPeriodicPositionUpdatesUntil = Date.now.addingTimeInterval(0.15)
        positionMs = max(0, startPositionMs)
        durationMs = 0
        return generation
    }

    private func performLoad(
        url: URL,
        autoPlay: Bool,
        startPositionMs: Int64,
        request: Int
    ) async -> Bool {
        defer {
            // An obsolete load must not clear a newer song's loading state.
            if request == generation { isLoading = false }
        }
        guard await configureAudioSession(request: request), request == generation else { return false }
        if url.isFileURL,
           let loaded = await loadFileEngine(
               url: url,
               autoPlay: autoPlay,
               startPositionMs: startPositionMs,
               request: request
           ) {
            return loaded
        }
        let item = AVPlayerItem(url: url)
        observe(item)
        player.replaceCurrentItem(with: item)
        player.volume = volume
        do {
            _ = try await item.asset.load(.isPlayable)
            let duration = try await item.asset.load(.duration)
            guard request == generation else { return false }
            durationMs = duration.seconds.isFinite ? Int64((duration.seconds * 1_000).rounded()) : 0
            guard await waitUntilReady(item, generation: request) else { return false }
            isReady = true
            if startPositionMs > 0 {
                // The item is fresh, so this is the same verified seek a later
                // lyric tap performs: playback starts where it was asked to,
                // not at the nearest position the first attempt happened to
                // reach.
                _ = await performVerifiedSeek(to: startPositionMs, request: request)
                guard request == generation else { return false }
            }
            clockIsAuthoritative = true
            positionMs = playerPositionMs(fallback: startPositionMs)
            playbackDiscontinuityRevision &+= 1
            if autoPlay { player.play(); isPlaying = true }
            return true
        } catch {
            guard request == generation else { return false }
            isReady = false
            return false
        }
    }

    func pause() {
        resumesAfterInterruption = false
        if let filePlayer { filePlayer.pause() } else { player.pause() }
        isPlaying = false
    }

    func resume() {
        guard !isLoading, isReady else { return }
        if let filePlayer {
            filePlayer.play()
            isPlaying = filePlayer.isPlaying
            return
        }
        guard player.currentItem != nil else { return }
        player.play()
        isPlaying = true
    }

    func toggle() {
        guard !isLoading else { return }
        isPlaying ? pause() : resume()
    }
    func stop() {
        generation += 1
        playbackDiscontinuityRevision &+= 1
        player.pause()
        player.replaceCurrentItem(with: nil)
        teardownFileEngine()
        statusObservation = nil
        pendingSeekRevision = nil
        clockIsAuthoritative = false
        suppressPeriodicPositionUpdatesUntil = .distantPast
        isLoading = false
        isPlaying = false; isReady = false; positionMs = 0; durationMs = 0
    }

    /// Moves playback to an exact position and confirms it landed there.
    ///
    /// The player is paused for the move, because a zero-tolerance seek on a
    /// running player can report success while the clock has already moved on,
    /// and a seek that is overtaken by the next one leaves the player wherever
    /// the abandoned seek got to — which is how repeatedly tapping one lyric
    /// could start audio in a different place every time.
    @discardableResult
    func seekExactly(to positionMs: Int64) async -> Bool {
        let request = generation
        pinSeekTarget(positionMs)
        return await performVerifiedSeek(to: clamped(positionMs), request: request)
    }

    func seek(to positionMs: Int64) async {
        await seekExactly(to: positionMs)
    }

    /// Publishes a requested position before playback can reach it, and stops
    /// AVPlayer's clock from contradicting it meanwhile. Used while a precise
    /// seek is still waiting on its media — a stream buffering, an item
    /// being reloaded — so the progress bar and the lyrics both sit on the
    /// position the user asked for.
    func pinSeekTarget(_ target: Int64) {
        playbackDiscontinuityRevision &+= 1
        pendingSeekRevision = playbackDiscontinuityRevision
        positionMs = clamped(target)
    }

    /// Drops a pinned target that no seek is going to move to. A pin that
    /// outlives its transaction would freeze the position — and with it the
    /// lyrics — on somewhere playback is not heading for.
    func releaseSeekPin() {
        guard pendingSeekRevision != nil else { return }
        pendingSeekRevision = nil
        clockIsAuthoritative = hasLoadedMedia
        suppressPeriodicPositionUpdatesUntil = .distantPast
        positionMs = playerPositionMs(fallback: positionMs)
        playbackDiscontinuityRevision &+= 1
    }

    /// Seeks with zero tolerance, checks where the player actually ended up and
    /// tries again while it disagrees with the target.
    private func performVerifiedSeek(to target: Int64, request: Int) async -> Bool {
        if filePlayer != nil { return seekFileEngine(to: target) }
        var landed = false
        for _ in 0..<seekAttempts {
            guard request == generation else { return false }
            let isSeekable = await waitUntilSeekable(target, request: request)
            guard request == generation else { return false }
            // Media that never reported the position as seekable still gets one
            // best-effort attempt, but no second wait: retrying only pays off
            // when the player disagreed with a position it could serve.
            let finished = await seekPrecisely(to: target)
            guard request == generation else { return false }
            let actual = playerPositionMs(fallback: target)
            if seekLandedOnTarget(finished: finished, actualPositionMs: actual, targetPositionMs: target) {
                landed = true
                break
            }
            if !isSeekable { break }
        }
        guard request == generation else { return landed }
        pendingSeekRevision = nil
        clockIsAuthoritative = hasLoadedMedia
        suppressPeriodicPositionUpdatesUntil = Date.now.addingTimeInterval(0.15)
        let actual = playerPositionMs(fallback: target)
        positionMs = actual
        playbackDiscontinuityRevision &+= 1
        return landed
    }

    /// Waits until the current item is loaded far enough to seek to `target`.
    /// A cached local file passes immediately; a stream that has not buffered
    /// the position yet would otherwise silently land somewhere else.
    private func waitUntilSeekable(_ target: Int64, request: Int) async -> Bool {
        for _ in 0..<seekReadinessAttempts {
            guard request == generation, let item = player.currentItem else { return false }
            if item.status == .failed { return false }
            if item.status == .readyToPlay,
               seekableRangesCover(target, ranges: item.seekableTimeRanges.map(\.timeRangeValue)) {
                return true
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return player.currentItem?.status == .readyToPlay
    }

    private func clamped(_ positionMs: Int64) -> Int64 {
        let upperBound = durationMs > 0 ? durationMs : max(positionMs, 0)
        return min(max(positionMs, 0), upperBound)
    }

    /// Returns AVPlayer's current media time for display-cadence lyric
    /// rendering. The published position intentionally updates less often for
    /// the rest of the UI and can be delayed by a busy large-screen layout.
    /// While a seek is pending, or while a new item is still loading, keep
    /// exposing the target position so a stale player time cannot pull the
    /// lyrics back before playback actually reaches the requested position.
    func lyricClockPositionMs() -> Int64 {
        guard playbackClockIsUsable else { return positionMs }
        return playerPositionMs(fallback: positionMs)
    }

    /// Refreshes the coarse UI position from the authoritative clock at a
    /// lyric-line boundary. This is not a playback discontinuity. This is deliberately low frequency and is skipped
    /// while a seek is still pending, because seek completion performs its own
    /// authoritative reconciliation.
    func calibrateLyricClockAtLineBoundary() {
        guard playbackClockIsUsable else { return }
        let actualPosition = playerPositionMs(fallback: positionMs)
        positionMs = actualPosition
        suppressPeriodicPositionUpdatesUntil = Date.now.addingTimeInterval(0.05)
    }

    @discardableResult
    private func seekPrecisely(to milliseconds: Int64) async -> Bool {
        guard player.currentItem != nil else { return false }
        let target = CMTime(value: milliseconds, timescale: 1_000)
        return await withCheckedContinuation { continuation in
            player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { finished in
                Task { @MainActor in
                    continuation.resume(returning: finished)
                }
            }
        }
    }

    private func waitUntilReady(_ item: AVPlayerItem, generation request: Int) async -> Bool {
        for _ in 0..<250 {
            guard request == generation, player.currentItem === item else { return false }
            switch item.status {
            case .readyToPlay: return true
            case .failed: return false
            case .unknown: try? await Task.sleep(for: .milliseconds(20))
            @unknown default: return false
            }
        }
        return item.status == .readyToPlay
    }

    private func playerPositionMs(fallback: Int64) -> Int64 {
        let seconds = filePlayer?.currentTime ?? player.currentTime().seconds
        guard seconds.isFinite else { return max(0, fallback) }
        return max(0, Int64((seconds * 1_000).rounded()))
    }

    private func observe(_ item: AVPlayerItem) {
        statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            Task { @MainActor [weak self] in self?.isReady = item.status == .readyToPlay }
        }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.isPlaying = false
                self?.onPlaybackComplete?()
            }
        }
    }

    /// Installs the file engine, or returns `nil` when the format is one only
    /// AVPlayer can decode, so playback falls back to it instead of failing.
    private func loadFileEngine(
        url: URL,
        autoPlay: Bool,
        startPositionMs: Int64,
        request: Int
    ) async -> Bool? {
        // prepareToPlay also activates AVAudioSession internally. Even after
        // explicit activation, file decoding and preparation must leave the UI
        // thread free. Transfer the prepared, idle player back only once.
        let prepared = await Task.detached(priority: .userInitiated) { () -> PreparedAudioFile? in
            guard let file = try? AVAudioPlayer(contentsOf: url), file.prepareToPlay() else { return nil }
            return PreparedAudioFile(player: file)
        }.value
        guard request == generation else { return false }
        guard let file = prepared?.player else { return nil }
        player.replaceCurrentItem(with: nil)
        file.delegate = fileDelegate
        file.volume = volume
        filePlayer = file
        durationMs = file.duration.isFinite ? Int64((file.duration * 1_000).rounded()) : 0
        isReady = true
        if startPositionMs > 0 { file.currentTime = Double(clamped(startPositionMs)) / 1_000 }
        pendingSeekRevision = nil
        clockIsAuthoritative = true
        suppressPeriodicPositionUpdatesUntil = .distantPast
        positionMs = playerPositionMs(fallback: startPositionMs)
        playbackDiscontinuityRevision &+= 1
        if autoPlay {
            file.play()
            isPlaying = file.isPlaying
        }
        startFilePositionUpdates(request: request)
        return true
    }

    /// Moves a complete local file. The position takes effect on assignment, so
    /// this reads it straight back rather than waiting for a callback.
    private func seekFileEngine(to target: Int64) -> Bool {
        guard let filePlayer else { return false }
        filePlayer.currentTime = Double(target) / 1_000
        pendingSeekRevision = nil
        clockIsAuthoritative = true
        suppressPeriodicPositionUpdatesUntil = .distantPast
        let actual = playerPositionMs(fallback: target)
        positionMs = actual
        // A compressed file can only start on a packet boundary, so the exact
        // landing point is checked the same way the streaming engine is.
        let landed = seekLandedOnTarget(finished: true, actualPositionMs: actual, targetPositionMs: target)
        playbackDiscontinuityRevision &+= 1
        return landed
    }

    /// AVAudioPlayer has no periodic observer, so the published position is
    /// sampled at the same coarse rate the streaming engine publishes at.
    private func startFilePositionUpdates(request: Int) {
        filePositionTask?.cancel()
        filePositionTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, !Task.isCancelled, request == generation, let file = filePlayer else { return }
                isPlaying = file.isPlaying
                guard playbackClockIsUsable, Date.now >= suppressPeriodicPositionUpdatesUntil else { continue }
                positionMs = playerPositionMs(fallback: positionMs)
            }
        }
    }

    private func teardownFileEngine() {
        filePositionTask?.cancel()
        filePositionTask = nil
        filePlayer?.stop()
        filePlayer?.delegate = nil
        filePlayer = nil
        resumesAfterInterruption = false
    }

    func handleFilePlaybackCompletion() {
        guard filePlayer != nil else { return }
        isPlaying = false
        positionMs = durationMs
        onPlaybackComplete?()
    }

    /// AVPlayer reports an interruption through its own status, but a file
    /// engine that is silenced by a phone call would otherwise keep reporting
    /// itself as playing — and the lyrics would keep scrolling without audio.
    private func observeAudioSession() {
        #if os(iOS)
        let center = NotificationCenter.default
        interruptionObserver = center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let options = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
            Task { @MainActor [weak self] in
                self?.handleInterruption(typeValue: type, optionsValue: options)
            }
        }
        routeChangeObserver = center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let reason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            Task { @MainActor [weak self] in
                self?.handleRouteChange(reasonValue: reason)
            }
        }
        #endif
    }

    #if os(iOS)
    private func handleInterruption(typeValue: UInt?, optionsValue: UInt?) {
        guard let typeValue, let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }
        switch type {
        case .began:
            resumesAfterInterruption = isPlaying
            isPlaying = false
        case .ended:
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue ?? 0)
            let shouldResume = resumesAfterInterruption && options.contains(.shouldResume)
            resumesAfterInterruption = false
            guard shouldResume else { return }
            let request = generation
            Task { @MainActor [weak self] in
                guard let self,
                      await self.configureAudioSession(request: request),
                      self.generation == request else { return }
                self.resume()
            }
        @unknown default: return
        }
    }

    private func handleRouteChange(reasonValue: UInt?) {
        guard let reasonValue,
              AVAudioSession.RouteChangeReason(rawValue: reasonValue) == .oldDeviceUnavailable else { return }
        // Unplugging headphones stops audio; playback must not silently
        // continue on the speaker, and the lyrics must stop with it.
        pause()
    }
    #endif

    private func configureAudioSession(request: Int) async -> Bool {
        do {
            try await audioSessionActivation()
            return true
        } catch {
            guard request == generation else { return false }
            let message = "音频会话激活失败：\(error.localizedDescription)"
            NSLog("%@", message)
            onPlaybackFailure?(message)
            return false
        }
    }

    nonisolated private static func activateAudioSession() async throws {
        #if os(iOS)
        try await Task.detached(priority: .userInitiated) {
            let session = AVAudioSession.sharedInstance()
            // Playback already supports AirPlay and A2DP. Explicit allowAirPlay
            // is only valid for playAndRecord and caused parameter errors (-50).
            if session.category != .playback || session.mode != .default || !session.categoryOptions.isEmpty {
                try session.setCategory(.playback, mode: .default, options: [])
            }
            if #available(iOS 27.0, *) {
                let activated = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, any Error>) in
                    session.activate(options: []) { activated, error in
                        if let error { continuation.resume(throwing: error) }
                        else { continuation.resume(returning: activated) }
                    }
                }
                guard activated else {
                    throw NSError(domain: "MeTMusic.AudioSession", code: 1, userInfo: [
                        NSLocalizedDescriptionKey: "系统未能激活音频输出"
                    ])
                }
            } else {
                // Older systems only have the synchronous API; keep it off
                // the main thread and finish activation before creating media.
                try session.setActive(true)
            }
        }.value
        #endif
    }

}

/// One-way ownership transfer: the worker finishes all access before returning;
/// after awaiting its task, only AudioPlayer's main actor uses this instance.
private struct PreparedAudioFile: @unchecked Sendable {
    let player: AVAudioPlayer
}

/// Bridges AVAudioPlayer's delegate callbacks onto the main actor.
private final class AudioFilePlaybackDelegate: NSObject, AVAudioPlayerDelegate, @unchecked Sendable {
    private weak var owner: AudioPlayer?

    init(owner: AudioPlayer) {
        self.owner = owner
        super.init()
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let owner = owner
        Task { @MainActor in owner?.handleFilePlaybackCompletion() }
    }

    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) {
        let owner = owner
        Task { @MainActor in owner?.handleFilePlaybackCompletion() }
    }
}

/// Decides whether AVPlayer's own clock describes the position playback was
/// asked to reach.
///
/// It does not during a pending seek, and it does not while a new item is being
/// installed: the player keeps reporting the previous item's time, then reports
/// zero for the freshly replaced item, and only reaches the requested position
/// once the item is ready and the start seek has completed. Reading it in that
/// window is what made lyrics jump back to the pre-seek line — and then to the
/// first line — while the progress bar already showed the new position.
func playbackClockDescribesRequestedPosition(
    hasCurrentItem: Bool,
    isPositioned: Bool,
    hasPendingSeek: Bool
) -> Bool {
    hasCurrentItem && isPositioned && !hasPendingSeek
}

/// Whether a finished seek actually landed where it was asked to.
///
/// AVPlayer reports `finished == false` for a seek another seek overtook, and a
/// seek issued before the media could serve the position can report success
/// while the player sits somewhere else, so the result is checked rather than
/// trusted.
func seekLandedOnTarget(
    finished: Bool,
    actualPositionMs: Int64,
    targetPositionMs: Int64,
    toleranceMs: Int64 = 120
) -> Bool {
    finished && abs(actualPositionMs - targetPositionMs) <= toleranceMs
}

/// Whether the media can serve `positionMs` right now.
///
/// A complete local file covers its whole duration as soon as it is ready. A
/// stream only covers what it has buffered, and seeking outside that lands
/// wherever the player can manage instead of where the lyric asked for.
func seekableRangesCover(
    _ positionMs: Int64,
    ranges: [CMTimeRange],
    toleranceMs: Int64 = 250
) -> Bool {
    guard !ranges.isEmpty else { return false }
    return ranges.contains { range in
        let start = range.start.seconds
        let end = CMTimeRangeGetEnd(range).seconds
        guard start.isFinite, end.isFinite else { return false }
        let startMs = Int64((start * 1_000).rounded()) - toleranceMs
        // The last moment of a song is the end of its seekable range, so a seek
        // there has to count as covered rather than as beyond the media.
        let endMs = Int64((end * 1_000).rounded()) + toleranceMs
        return positionMs >= startMs && positionMs <= endMs
    }
}
