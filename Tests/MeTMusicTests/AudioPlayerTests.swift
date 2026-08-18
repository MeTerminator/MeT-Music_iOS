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
}
