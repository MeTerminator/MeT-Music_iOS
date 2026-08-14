import CoreGraphics
import Testing
@testable import MeTMusic

@Suite struct TimelineAndLayoutTests {
    @Test func overlappingLinesRemainActiveTogether() {
        let timeline = LyricTimeline(bounds: [
            .init(startTime: 0, endTime: 2_000),
            .init(startTime: 1_000, endTime: 3_000),
            .init(startTime: 4_000, endTime: 5_000),
        ])
        #expect(timeline.sync(timeMs: 1_500).playingIndices == [0, 1])
        #expect(timeline.sync(timeMs: 2_500).playingIndices == [1])
        let seek = timeline.sync(timeMs: 4_200, forceSeek: true)
        #expect(seek.playingIndices == [2])
        #expect(seek.isSeeking)
    }

    @Test func multiTimestampEnglishWordIsAtomic() {
        let chunks = chunkLyricWords([
            .init(startTime: 0, endTime: 100, word: "Ap"),
            .init(startTime: 100, endTime: 200, word: "ple"),
            .init(startTime: 200, endTime: 200, word: " "),
            .init(startTime: 200, endTime: 300, word: "Music"),
        ])
        #expect(chunks.map(\.text) == ["Apple", " ", "Music"])
    }

    @Test func springPreservesVelocityAcrossTargetChanges() {
        var spring = AMLLSpring(position: 0)
        spring.updateTarget(100)
        _ = spring.step(deltaSeconds: 1.0 / 60.0)
        let velocity = spring.velocity
        spring.updateTarget(160)
        #expect(spring.velocity == velocity)
        #expect(spring.step(deltaSeconds: 1.0 / 60.0) > 0)
    }

    @Test func groupedBackgroundUsesFullRenderBounds() {
        let main = LyricLine(words: [.init(startTime: 1_000, endTime: 3_000, word: "main")], startTime: 1_100, endTime: 2_900)
        let background = LyricLine(words: [.init(startTime: 800, endTime: 3_400, word: "background")], startTime: 900, endTime: 3_300, isBackground: true)
        let groups = groupLyricLines([main, background])
        #expect(groups.count == 1)
        #expect(groups[0].background?.text == "background")
        #expect(groups[0].renderBounds == .init(startTime: 800, endTime: 3_400))
    }

    @Test func syllableChunksUseContinuousProgress() {
        let words = [
            LyricWord(startTime: 0, endTime: 300, word: "hel"),
            LyricWord(startTime: 300, endTime: 600, word: "lo"),
        ]
        #expect(abs(lyricChunkProgress(words: words, timeMs: 150) - 0.3) < 0.001)
        #expect(abs(lyricChunkProgress(words: words, timeMs: 300) - 0.6) < 0.001)
        #expect(abs(lyricChunkProgress(words: words, timeMs: 450) - 0.8) < 0.001)
    }

    @Test func playbackClockInterpolatesAndSnapsOnSeek() {
        var clock = PlaybackTimeInterpolator(initialSourceTimeMs: 1_000)
        #expect(clock.update(sourceTimeMs: 1_000, frameNanoseconds: 0, isPlaying: true) == 1_000)
        #expect(clock.update(sourceTimeMs: 1_000, frameNanoseconds: 16_000_000, isPlaying: true) == 1_016)
        #expect(clock.update(sourceTimeMs: 5_000, frameNanoseconds: 32_000_000, isPlaying: true) == 5_000)
        #expect(clock.update(sourceTimeMs: 900, frameNanoseconds: 48_000_000, isPlaying: false) == 900)
    }

    @Test func playbackClockResetsWhenSeekIsAnnouncedBeforeSourceClockChanges() {
        var clock = PlaybackTimeInterpolator(initialSourceTimeMs: 1_000)
        #expect(clock.update(sourceTimeMs: 1_000, frameNanoseconds: 0, isPlaying: true) == 1_000)
        #expect(clock.update(sourceTimeMs: 1_000, frameNanoseconds: 32_000_000, isPlaying: true) == 1_032)
        #expect(clock.update(
            sourceTimeMs: 1_000,
            frameNanoseconds: 48_000_000,
            isPlaying: true,
            discontinuityRevision: 1
        ) == 1_000)
    }

    @Test func lyricTapUsesAuthoredWordTimeInsteadOfAdvancedVisualStart() {
        let line = LyricLine(
            words: [
                .init(startTime: 1_200, endTime: 1_300, word: " "),
                .init(startTime: 2_000, endTime: 2_600, word: "歌词"),
            ],
            startTime: 1_400,
            endTime: 2_600
        )
        #expect(lyricTapSeekTime(line: line, lyricOffsetMs: 100) == 1_900)
    }

    @Test func interludeAndEmphasisAnimationsMatchBoundaries() {
        #expect(calculateInterludeDotsAnimation(elapsedMs: 250, durationMs: 5_000).opacities.allSatisfy { $0 == 0 })
        let entering = calculateInterludeDotsAnimation(elapsedMs: 750, durationMs: 5_000)
        #expect(entering.opacities[0] > entering.opacities[1])
        let active = calculateEmphasisCharacterMotion(progress: 0.75, characterIndex: 4, characterCount: 5, amount: 1)
        #expect(active.scale > 1)
        #expect(active.translationYEm < 0)
    }

    @Test func lyricViewportRejectsTransientRotationSizes() {
        #expect(!lyricViewportIsUsable(.zero))
        #expect(!lyricViewportIsUsable(.init(width: 1_366, height: 0)))
        #expect(!lyricViewportIsUsable(.init(width: CGFloat.infinity, height: 498)))
        #expect(lyricViewportIsUsable(.init(width: 683, height: 1_024)))
    }

    @Test func lyricFrameUpdatesPauseWhileOffscreenOrPaging() {
        #expect(lyricRenderingShouldAnimate(
            isPlaying: true,
            frameInterpolationEnabled: true,
            isActive: true,
            isPageTransitioning: false
        ))
        #expect(!lyricRenderingShouldAnimate(
            isPlaying: true,
            frameInterpolationEnabled: true,
            isActive: false,
            isPageTransitioning: false
        ))
        #expect(!lyricRenderingShouldAnimate(
            isPlaying: true,
            frameInterpolationEnabled: true,
            isActive: true,
            isPageTransitioning: true
        ))
    }

    @Test func playerPagingChoosesPageFromDragAndProjection() {
        #expect(playerPageTarget(currentPage: 1, translation: 90, projectedTranslation: 120, pageWidth: 390) == 0)
        #expect(playerPageTarget(currentPage: 1, translation: 20, projectedTranslation: 35, pageWidth: 390) == 1)
        #expect(playerPageTarget(currentPage: 0, translation: -30, projectedTranslation: -180, pageWidth: 390) == 1)
        #expect(playerPageTarget(currentPage: 0, translation: 120, projectedTranslation: 180, pageWidth: 390) == 0)
    }

    @Test func lyricTimelineUsesPeriodicLargeScreenCadenceAndSleepsWhenInactive() {
        #expect(abs(lyricTimelineInterval(largeScreenOptimizations: true, updatesFrames: true) - 1.0 / 24.0) < 0.0001)
        #expect(abs(lyricTimelineInterval(largeScreenOptimizations: false, updatesFrames: true) - 1.0 / 30.0) < 0.0001)
        #expect(lyricTimelineInterval(largeScreenOptimizations: true, updatesFrames: false) == 3_600)
    }
}
