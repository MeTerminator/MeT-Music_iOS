import AVFoundation
import Foundation
import Testing
@testable import MeTMusic

@MainActor
@Suite struct AudioPlayerTests {
    /// Writes a silent-ish tone so the player has a real, complete local file
    /// to load — the case a cached song hits.
    private func makeAudioFile(seconds: Double = 4) throws -> URL {
        let sampleRate = 44_100.0
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "audio-player-test-\(seconds).caf")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = AVAudioFrameCount(sampleRate * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for index in 0..<Int(frames) {
            buffer.floatChannelData![0][index] = Float(sin(Double(index) * 2 * .pi * 440 / sampleRate)) * 0.05
        }
        try file.write(from: buffer)
        return url
    }

    @Test func realMediaSeeksAndReloadsReanchorLyricsIncludingSmallMoves() async throws {
        let player = AudioPlayer()
        defer { player.stop() }
        let file = try makeAudioFile()
        #expect(await player.load(url: file, autoPlay: false))
        let groups = (0..<4).map { index in
            let start = Int64(index * 1_000)
            return LyricGroup(main: .init(words: [.init(startTime: start, endTime: start + 1_000, word: "line")], startTime: start, endTime: start + 1_000))
        }
        let model = LyricsViewModel(groups: groups, timeMs: 0)
        for target: Int64 in [900, 1_100, 1_050, 2_600, 200, 3_100] {
            let before = player.playbackDiscontinuityRevision
            #expect(await player.seekExactly(to: target))
            #expect(player.playbackDiscontinuityRevision >= before + 2)
            let actual = player.lyricClockPositionMs()
            model.reanchorPlayback(timeMs: actual, revision: player.playbackDiscontinuityRevision)
            let display = model.presentationTime(sourceTimeMs: actual, frameDate: .now, isPlaying: false, enabled: true, playbackRate: 1, discontinuityRevision: player.playbackDiscontinuityRevision, authoritative: true)
            let snapshot = model.sync(timeMs: display)
            #expect(display == actual)
            #expect(snapshot.isSeeking)
            #expect(snapshot.playingIndices == [Int(actual / 1_000)])
            #expect(snapshot.scrollTargetIndex == Int(actual / 1_000))
        }
        let revision = player.playbackDiscontinuityRevision
        player.calibrateLyricClockAtLineBoundary()
        #expect(player.playbackDiscontinuityRevision == revision)
        #expect(await player.load(url: file, autoPlay: false, startPositionMs: 500))
        #expect(player.playbackDiscontinuityRevision > revision)
        model.reanchorPlayback(timeMs: player.lyricClockPositionMs(), revision: player.playbackDiscontinuityRevision)
        #expect(model.sync(timeMs: player.lyricClockPositionMs()).playingIndices == [0])
    }

    @Test func completeLocalFilesPlayThroughTheFileEngine() async throws {
        let player = AudioPlayer()
        defer { player.stop() }
        #expect(await player.load(url: try makeAudioFile(), autoPlay: false, startPositionMs: 1_500))
        #expect(player.usesFileEngine)
        #expect(player.isReady)
        #expect(player.durationMs == 4_000)
        #expect(abs(player.positionMs - 1_500) <= 120)
        // Lyrics read the same clock the progress bar does.
        #expect(abs(player.lyricClockPositionMs() - 1_500) <= 120)
    }

    @Test func repeatedSeeksToOneLyricAlwaysLandOnIt() async throws {
        let player = AudioPlayer()
        defer { player.stop() }
        #expect(await player.load(url: try makeAudioFile(), autoPlay: false))

        // Tapping the same lyric over and over is what left audio in a
        // different place every time on the streaming engine.
        for _ in 0..<8 {
            #expect(await player.seekExactly(to: 2_400))
            #expect(abs(player.positionMs - 2_400) <= 120)
        }
        // And a different target still takes effect immediately.
        #expect(await player.seekExactly(to: 600))
        #expect(abs(player.positionMs - 600) <= 120)
        #expect(abs(player.lyricClockPositionMs() - 600) <= 120)
    }

    @Test func overlappingSeeksSettleOnTheLastRequestedPosition() async throws {
        let player = AudioPlayer()
        defer { player.stop() }
        #expect(await player.load(url: try makeAudioFile(), autoPlay: false))

        async let first: Void = player.seek(to: 3_000)
        async let second: Void = player.seek(to: 1_000)
        async let third: Void = player.seek(to: 2_000)
        _ = await (first, second, third)

        // Whatever order they settle in, the position is one of the requested
        // ones and the clock agrees with it — never a place nobody asked for.
        #expect([1_000, 2_000, 3_000].contains { abs(player.positionMs - Int64($0)) <= 120 })
        #expect(abs(player.lyricClockPositionMs() - player.positionMs) <= 120)
    }

    @Test func seekingWithoutMediaLeavesTheClockUsable() async throws {
        let player = AudioPlayer()
        defer { player.stop() }
        // A pin that outlives its seek would freeze lyrics and progress alike.
        player.pinSeekTarget(30_000)
        #expect(player.positionMs == 30_000)
        player.releaseSeekPin()
        #expect(await player.load(url: try makeAudioFile(), autoPlay: false, startPositionMs: 500))
        #expect(abs(player.lyricClockPositionMs() - 500) <= 120)
    }
    @Test func audioSessionFailureStopsLoadingAndReportsTheError() async throws {
        let player = AudioPlayer(audioSessionActivation: {
            throw NSError(domain: NSOSStatusErrorDomain, code: -50)
        })
        defer { player.stop() }
        var reportedError: String?
        player.onPlaybackFailure = { reportedError = $0 }
        let loaded = await player.load(url: try makeAudioFile(), autoPlay: true)
        #expect(!loaded)
        #expect(!player.isReady)
        #expect(!player.isLoading)
        #expect(!player.isPlaying)
        #expect(!player.usesFileEngine)
        #expect(reportedError?.contains("音频会话激活失败") == true)
    }

    @Test func loadingStaysVisibleUntilActivationAndMediaPreparationFinish() async throws {
        let gate = AudioSessionActivationGate()
        let player = AudioPlayer(audioSessionActivation: { await gate.activate() })
        defer { player.stop() }
        let url = try makeAudioFile()
        let pending = Task { await player.load(url: url, autoPlay: false) }
        await gate.waitUntilEntered()
        #expect(player.isLoading)
        #expect(!player.isReady)
        for _ in 0..<8 { player.toggle(); player.resume() }
        #expect(player.isLoading)
        #expect(!player.isPlaying)
        await gate.release()
        #expect(await pending.value)
        #expect(!player.isLoading)
        #expect(player.isReady)
        #expect(!player.isPlaying)
    }

    @Test func stoppedLoadDoesNotResumeAfterAudioSessionActivation() async throws {
        let gate = AudioSessionActivationGate()
        let player = AudioPlayer(audioSessionActivation: { await gate.activate() })
        let url = try makeAudioFile()
        let pending = Task { await player.load(url: url, autoPlay: true) }
        await gate.waitUntilEntered()
        #expect(player.isLoading)
        player.stop()
        #expect(!player.isLoading)
        await gate.release()
        let loaded = await pending.value
        #expect(!loaded)
        #expect(!player.isPlaying)
        #expect(!player.isReady)
    }

}

private actor AudioSessionActivationGate {
    private var entered = false
    private var continuation: CheckedContinuation<Void, Never>?

    func activate() async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            entered = true
        }
    }

    func waitUntilEntered() async {
        while !entered { await Task.yield() }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}
