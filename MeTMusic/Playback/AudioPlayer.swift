import AVFoundation
import Combine
import Foundation

@MainActor
final class AudioPlayer: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var isReady = false
    @Published private(set) var positionMs: Int64 = 0
    @Published private(set) var durationMs: Int64 = 0
    @Published private(set) var playbackDiscontinuityRevision: UInt = 0
    @Published var volume: Float = 1 { didSet { player.volume = volume } }

    var onPlaybackComplete: (() -> Void)?
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

    private var playbackClockIsUsable: Bool {
        playbackClockDescribesRequestedPosition(
            hasCurrentItem: player.currentItem != nil,
            isPositioned: clockIsAuthoritative,
            hasPendingSeek: pendingSeekRevision != nil
        )
    }

    struct PreparedSeek: Sendable {
        let positionMs: Int64
        let revision: UInt
        let generation: Int
    }

    init() {
        player.automaticallyWaitsToMinimizeStalling = true
        player.actionAtItemEnd = .pause
        timeObserver = player.addPeriodicTimeObserver(
            // UI consumers only need a coarse source clock; the lyric view
            // interpolates this internally at display cadence. Publishing at
            // 10 Hz avoids invalidating the entire app hierarchy every frame.
            forInterval: CMTime(value: 1, timescale: 10),
            queue: .main
        ) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let seconds = time.seconds
                if seconds.isFinite,
                   playbackClockIsUsable,
                   Date.now >= suppressPeriodicPositionUpdatesUntil {
                    positionMs = max(0, Int64((seconds * 1_000).rounded()))
                }
                isPlaying = player.timeControlStatus == .playing
            }
        }
    }

    func play(url: URL, autoPlay: Bool = true, startPositionMs: Int64 = 0) {
        generation += 1
        let request = generation
        playbackDiscontinuityRevision &+= 1
        player.pause()
        isPlaying = false
        isReady = false
        pendingSeekRevision = nil
        clockIsAuthoritative = false
        suppressPeriodicPositionUpdatesUntil = Date.now.addingTimeInterval(0.15)
        positionMs = max(0, startPositionMs)
        durationMs = 0
        Task {
            await configureAudioSession()
            guard request == generation else { return }
            let item = AVPlayerItem(url: url)
            observe(item)
            player.replaceCurrentItem(with: item)
            player.volume = volume
            do {
                _ = try await item.asset.load(.isPlayable)
                let duration = try await item.asset.load(.duration)
                guard request == generation else { return }
                durationMs = duration.seconds.isFinite ? Int64((duration.seconds * 1_000).rounded()) : 0
                guard await waitUntilReady(item, generation: request) else { return }
                isReady = true
                if startPositionMs > 0 {
                    let completed = await seekPrecisely(to: startPositionMs)
                    guard request == generation else { return }
                    let actualPosition = playerPositionMs(fallback: completed ? startPositionMs : 0)
                    if !completed || abs(actualPosition - startPositionMs) > 80 {
                        playbackDiscontinuityRevision &+= 1
                    }
                    positionMs = actualPosition
                }
                guard request == generation else { return }
                clockIsAuthoritative = true
                if autoPlay { player.play(); isPlaying = true }
            } catch {
                guard request == generation else { return }
                isReady = false
            }
        }
    }

    func pause() { player.pause(); isPlaying = false }
    func resume() { guard player.currentItem != nil else { return }; player.play(); isPlaying = true }
    func toggle() { isPlaying ? pause() : resume() }
    func stop() {
        generation += 1
        playbackDiscontinuityRevision &+= 1
        player.pause()
        player.replaceCurrentItem(with: nil)
        statusObservation = nil
        pendingSeekRevision = nil
        clockIsAuthoritative = false
        suppressPeriodicPositionUpdatesUntil = .distantPast
        isPlaying = false; isReady = false; positionMs = 0; durationMs = 0
    }

    func seek(to positionMs: Int64) async {
        let prepared = prepareSeek(to: positionMs)
        await commitPreparedSeek(prepared)
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

    /// Re-anchors lyric interpolation to AVPlayer's authoritative clock at a
    /// lyric-line boundary. This is deliberately low frequency and is skipped
    /// while a seek is still pending, because seek completion performs its own
    /// authoritative reconciliation.
    func calibrateLyricClockAtLineBoundary() {
        guard playbackClockIsUsable else { return }
        let actualPosition = playerPositionMs(fallback: positionMs)
        positionMs = actualPosition
        playbackDiscontinuityRevision &+= 1
        suppressPeriodicPositionUpdatesUntil = Date.now.addingTimeInterval(0.05)
    }

    /// Publishes a seek discontinuity before AVPlayer finishes moving its
    /// playhead. While it is pending, coarse periodic callbacks are ignored so
    /// they cannot pull lyric rendering back to the old position.
    @discardableResult
    func prepareSeek(to requestedPositionMs: Int64) -> PreparedSeek {
        let upperBound = durationMs > 0 ? durationMs : max(requestedPositionMs, 0)
        let target = min(max(requestedPositionMs, 0), upperBound)
        playbackDiscontinuityRevision &+= 1
        pendingSeekRevision = playbackDiscontinuityRevision
        positionMs = target
        return .init(
            positionMs: target,
            revision: playbackDiscontinuityRevision,
            generation: generation
        )
    }

    func commitPreparedSeek(_ prepared: PreparedSeek) async {
        let completed = await seekPrecisely(to: prepared.positionMs)
        guard generation == prepared.generation,
              playbackDiscontinuityRevision == prepared.revision else { return }
        pendingSeekRevision = nil
        clockIsAuthoritative = player.currentItem != nil
        suppressPeriodicPositionUpdatesUntil = Date.now.addingTimeInterval(0.15)
        let actualPosition = playerPositionMs(fallback: completed ? prepared.positionMs : 0)
        if !completed || abs(actualPosition - prepared.positionMs) > 80 {
            playbackDiscontinuityRevision &+= 1
        }
        positionMs = actualPosition
    }

    /// Releases a prepared seek that will never be committed, so the position
    /// stays pinned to a target no playback is moving towards.
    func cancelPreparedSeek(_ prepared: PreparedSeek) {
        guard generation == prepared.generation,
              pendingSeekRevision == prepared.revision else { return }
        pendingSeekRevision = nil
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
        let seconds = player.currentTime().seconds
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

    private func configureAudioSession() async {
        #if os(iOS)
        await Task.detached(priority: .userInitiated) {
            let session = AVAudioSession.sharedInstance()
            try? session.setCategory(.playback, mode: .default, options: [.allowAirPlay, .allowBluetoothA2DP])
            try? session.setActive(true)
        }.value
        #endif
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
