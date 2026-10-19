import CoreGraphics
import CoreMedia
import Testing
@testable import MeTMusic

@Suite struct TimelineAndLayoutTests {
    @Test func displayFramesStayContinuousAcrossJitteredClockCalibration() {
        var clock = PlaybackTimeInterpolator(initialSourceTimeMs: 1_000)
        var previous = Int64(999)
        // The player is sampled every 100 ms; rows interpolate at display
        // cadence. Small source jitter must not move glyphs backwards or
        // produce a visible jump at the next calibration boundary.
        for tick in 0..<100 {
            let base = Int64(tick * 100)
            let jitter: Int64 = tick == 0 ? 0 : (tick.isMultiple(of: 2) ? 8 : -8)
            let anchor = clock.update(
                sourceTimeMs: 1_000 + base + jitter,
                frameNanoseconds: UInt64(base) * 1_000_000,
                isPlaying: true
            )
            for frame in 0..<6 {
                let elapsed = Int64((Double(frame) * 1_000 / 60).rounded())
                let display = anchor + elapsed
                #expect(display > previous)
                #expect(display - previous <= 33)
                #expect(abs(display - (1_000 + base + elapsed)) <= 16)
                previous = display
            }
        }
    }

    @Test func upcomingLyricsDefocusWithDistanceAndStayReadableWhenBrowsing() {
        func radius(_ index: Int, upcoming: Bool = true, focused: Bool = false, browsing: Bool = false, enabled: Bool = true) -> CGFloat {
            lyricUpcomingBlurRadius(
                index: index, focusIndex: 2, isUpcoming: upcoming,
                isFocused: focused, isUserScrolling: browsing, enabled: enabled,
                fontSize: 32, maximumRadius: 5
            )
        }
        #expect(radius(3) > 0)
        #expect(radius(4) > radius(3))
        #expect(radius(100) == 5)
        #expect(radius(3, focused: true) == 0)
        #expect(radius(1, upcoming: false) == 0)
        #expect(radius(5, browsing: true) == 0)
        #expect(radius(5, enabled: false) == 0)
        // During an interlude the next row is the anchor, but is still unsung.
        #expect(radius(2) > 0)
    }

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

    @Test func renderBoundsIgnoreTheOptimizersVisualHeadStart() {
        // The optimizer moves line starts up to 600 ms earlier so lyrics change
        // with some anticipation. Taking that as the moment a lyric becomes
        // current — and then adding the transition lead on top — put lyrics
        // almost a second ahead of the singing.
        let optimized = optimizeLyricLines([
            LyricLine(words: [.init(startTime: 10_000, endTime: 12_000, word: "第一句")], startTime: 10_000, endTime: 12_000),
            LyricLine(words: [.init(startTime: 20_000, endTime: 23_000, word: "第二句")], startTime: 20_000, endTime: 23_000),
        ])
        #expect(optimized[1].startTime < 20_000)

        let groups = groupLyricLines(optimized)
        #expect(groups[1].renderBounds.startTime == 20_000)
        #expect(groups[1].renderBounds.endTime == 23_000)
    }

    @Test func renderBoundsStartAtTheFirstSungWord() {
        let line = LyricLine(
            words: [
                .init(startTime: 4_000, endTime: 4_000, word: " "),
                .init(startTime: 5_000, endTime: 6_000, word: "词"),
            ],
            startTime: 4_400,
            endTime: 6_400
        )
        let bounds = lyricGroupRenderBounds(main: line, background: nil)
        #expect(bounds.startTime == 5_000)
        // A line that runs past its last word keeps the lyric on screen.
        #expect(bounds.endTime == 6_400)
    }

    @Test func seekingAnchorsOnTheMostRecentlyStartedLyric() {
        // A lyric held over the next one, or a duet part, keeps playing while
        // the tapped lyric starts. Anchoring on the earliest of them scrolled
        // the view to a lyric that began long before the one that was tapped.
        let timeline = LyricTimeline(bounds: [
            .init(startTime: 0, endTime: 20_000),
            .init(startTime: 8_000, endTime: 12_000),
        ])
        _ = timeline.sync(timeMs: 1_000)
        let snapshot = timeline.sync(timeMs: 9_000)
        #expect(snapshot.isSeeking)
        #expect(snapshot.playingIndices == [0, 1])
        #expect(snapshot.scrollTargetIndex == 1)
    }

    @Test func overlappingLyricsFollowRemainingFirstLineWhenUpperLineEnds() {
        let timeline = LyricTimeline(bounds: [
            .init(startTime: 0, endTime: 2_000),
            .init(startTime: 1_000, endTime: 4_000),
            .init(startTime: 1_500, endTime: 5_000),
        ])
        for time: Int64 in [0, 500, 1_000, 1_500, 1_900] {
            #expect(timeline.sync(timeMs: time).scrollTargetIndex == 0)
        }
        let remaining = timeline.sync(timeMs: 2_000)
        #expect(remaining.playingIndices == [1, 2])
        #expect(remaining.scrollTargetIndex == 1)
        for time: Int64 in [2_500, 3_000, 3_500, 4_000] {
            _ = timeline.sync(timeMs: time)
        }
        #expect(timeline.sync(timeMs: 4_100).scrollTargetIndex == 2)
    }

    @Test @MainActor func lyricAnchorChecksDriftAndRespectsManualScrolling() {
        let model = LyricsViewModel(groups: [], timeMs: 0)
        model.anchorFrames = [0: CGRect(x: 0, y: 80, width: 300, height: 100)]
        #expect(!model.anchorNeedsCorrection(index: 0, viewportHeight: 500, alignPosition: 0.2))
        model.anchorFrames[0]?.origin.y = 120
        #expect(model.anchorNeedsCorrection(index: 0, viewportHeight: 500, alignPosition: 0.2))
        model.beginUserScroll()
        #expect(!model.anchorNeedsCorrection(index: 0, viewportHeight: 500, alignPosition: 0.2))
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

    @Test func playbackClockDoesNotLoseTimeWhenIPadMissesFrames() {
        var clock = PlaybackTimeInterpolator(initialSourceTimeMs: 1_000)
        #expect(clock.update(
            sourceTimeMs: 1_000,
            frameNanoseconds: 0,
            isPlaying: true
        ) == 1_000)
        #expect(clock.update(
            sourceTimeMs: 1_200,
            frameNanoseconds: 200_000_000,
            isPlaying: true
        ) == 1_200)
        #expect(clock.update(
            sourceTimeMs: 1_400,
            frameNanoseconds: 400_000_000,
            isPlaying: true
        ) == 1_400)
    }

    @Test func lyricClockIgnoresPlayerTimeUntilTheNewItemReachesTheSeekTarget() {
        // Seeking a streamed song reloads the item, so AVPlayer keeps reporting
        // the previous item's time and then zero before it reaches the target.
        #expect(!playbackClockDescribesRequestedPosition(
            hasCurrentItem: true,
            isPositioned: true,
            hasPendingSeek: true
        ))
        #expect(!playbackClockDescribesRequestedPosition(
            hasCurrentItem: true,
            isPositioned: false,
            hasPendingSeek: false
        ))
        #expect(!playbackClockDescribesRequestedPosition(
            hasCurrentItem: false,
            isPositioned: true,
            hasPendingSeek: false
        ))
        #expect(playbackClockDescribesRequestedPosition(
            hasCurrentItem: true,
            isPositioned: true,
            hasPendingSeek: false
        ))
    }

    @Test func aSeekIsOnlyDoneWhenThePlayerLandedOnTheTarget() {
        // Tapping the same lyric repeatedly used to leave audio in a different
        // place every time, because an overtaken seek reports back after the
        // player already moved elsewhere. The result is checked, not trusted.
        #expect(seekLandedOnTarget(finished: true, actualPositionMs: 90_040, targetPositionMs: 90_000))
        #expect(!seekLandedOnTarget(finished: false, actualPositionMs: 90_000, targetPositionMs: 90_000))
        #expect(!seekLandedOnTarget(finished: true, actualPositionMs: 87_000, targetPositionMs: 90_000))
    }

    @Test func seekWaitsUntilTheMediaCanServeTheRequestedPosition() {
        let buffered = [CMTimeRange(
            start: CMTime(value: 0, timescale: 1_000),
            duration: CMTime(value: 45_000, timescale: 1_000)
        )]
        #expect(seekableRangesCover(30_000, ranges: buffered))
        // Seeking into a part of the stream that has not arrived lands wherever
        // the player can manage, so the transaction waits for the cached file.
        #expect(!seekableRangesCover(90_000, ranges: buffered))
        #expect(!seekableRangesCover(30_000, ranges: []))
        // The very end of a song is the end of its seekable range.
        #expect(seekableRangesCover(45_000, ranges: buffered))
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

    @Test func lyricTapRoundTripKeepsWordProgressAlignedWithAudio() {
        let line = LyricLine(
            words: [.init(startTime: 2_000, endTime: 2_600, word: "歌词")],
            startTime: 1_400,
            endTime: 2_600
        )
        let offset: Int64 = 100
        let lead: Int64 = 300
        let mediaTarget = lyricTapSeekTime(line: line, lyricOffsetMs: offset)
        let presentationTime = lyricPresentationTime(
            mediaPositionMs: mediaTarget,
            lyricOffsetMs: offset
        )

        #expect(presentationTime == 2_000)
        let timeline = LyricTimeline(bounds: [.init(startTime: 2_000, endTime: 2_600)], lineTransitionLeadMs: lead)
        #expect(timeline.sync(timeMs: presentationTime).playingIndices == [0])
        #expect(lyricChunkProgress(words: line.words, timeMs: presentationTime) == 0)
    }

    @Test func transitionLeadUsesOnlyTheGapAndPreservesLineEnds() {
        let bounds: [LyricTimeBounds] = [
            .init(startTime: 1_000, endTime: 4_000),
            .init(startTime: 5_000, endTime: 6_900),
            .init(startTime: 7_000, endTime: 9_000),
            .init(startTime: 9_000, endTime: 10_000)
        ]
        let advanced = lyricTransitionBounds(bounds, lineTransitionLeadMs: 600)
        #expect(advanced.map(\.startTime) == [400, 4_400, 6_900, 9_000])
        #expect(advanced.map(\.endTime) == bounds.map(\.endTime))
        let timeline = LyricTimeline(bounds: bounds, lineTransitionLeadMs: 600)
        #expect(timeline.sync(timeMs: 3_999).playingIndices == [0])
        #expect(timeline.sync(timeMs: 4_000).playingIndices.isEmpty)
        #expect(timeline.sync(timeMs: 4_399).playingIndices.isEmpty)
        let early = timeline.sync(timeMs: 4_400)
        #expect(early.playingIndices == [1])
        #expect(early.highlightedIndices == [1])
        #expect(early.scrollTargetIndex == 1)
        #expect(timeline.sync(timeMs: 6_899).playingIndices == [1])
        #expect(timeline.sync(timeMs: 6_900).playingIndices == [2])
        let word = LyricWord(startTime: 5_000, endTime: 6_900, word: "next")
        #expect(lyricChunkProgress(words: [word], timeMs: 4_400) == 0)
        #expect(lyricChunkProgress(words: [word], timeMs: 5_950) == 0.5)
    }

    @Test func transitionLeadPreservesOverlapsAndWaitsForOutstandingVocals() {
        let bounds: [LyricTimeBounds] = [
            .init(startTime: 1_000, endTime: 8_000),
            .init(startTime: 3_000, endTime: 5_000),
            .init(startTime: 8_200, endTime: 10_000)
        ]
        let advanced = lyricTransitionBounds(bounds, lineTransitionLeadMs: 600)
        #expect(advanced.map(\.startTime) == [400, 3_000, 8_000])
        #expect(lyricTransitionBounds(bounds, lineTransitionLeadMs: 0) == bounds)
        #expect(lyricTransitionBounds(bounds, lineTransitionLeadMs: -100) == bounds)
        #expect(lyricTransitionBounds([.init(startTime: 200, endTime: 1_000)], lineTransitionLeadMs: 600).first?.startTime == 0)
    }

    @Test @MainActor func transitionLeadCanChangeWithoutChangingTheWordClock() {
        let group = LyricGroup(main: .init(
            words: [.init(startTime: 5_000, endTime: 7_000, word: "next")],
            startTime: 5_000, endTime: 7_000
        ))
        let model = LyricsViewModel(groups: [group], timeMs: 4_500)
        #expect(model.sync(timeMs: 4_500).playingIndices.isEmpty)
        #expect(model.sync(timeMs: 4_500, lineTransitionLeadMs: 600).playingIndices == [0])
        #expect(model.lastPresentationTimeMs == 4_500)
        #expect(model.sync(timeMs: 4_500, lineTransitionLeadMs: 0).playingIndices.isEmpty)
        let timeline = LyricTimeline(bounds: [.init(startTime: 5_000, endTime: 7_000)], lineTransitionLeadMs: 600)
        #expect(timeline.sync(timeMs: 4_500, forceSeek: true).playingIndices == [0])
        #expect(timeline.sync(timeMs: 7_000, forceSeek: true).playingIndices.isEmpty)
    }

    @Test func singleTimedWordLineUsesNormalLineOpacity() {
        #expect(lyricLineOpacity(isHighlighted: false) == 1)
        #expect(lyricLineOpacity(isHighlighted: true) == 0.85)
    }

    @Test func interludeDotsRequireACompletelyEmptyTimeline() {
        let overlappingTimeline = LyricTimeline(bounds: [
            .init(startTime: 0, endTime: 10_000),
            .init(startTime: 1_000, endTime: 2_000),
            .init(startTime: 8_000, endTime: 9_000),
        ])
        let overlapping = overlappingTimeline.sync(timeMs: 5_000)

        #expect(shouldShowLyricInterlude(
            previousEndTimeMs: 2_000,
            nextStartTimeMs: 8_000,
            currentTimeMs: 5_000,
            hasActiveLyrics: false
        ))
        #expect(!shouldShowLyricInterlude(
            previousEndTimeMs: 2_000,
            nextStartTimeMs: 8_000,
            currentTimeMs: 5_000,
            hasActiveLyrics: !overlapping.playingIndices.isEmpty
        ))
        #expect(!shouldShowLyricInterlude(
            previousEndTimeMs: 2_000,
            nextStartTimeMs: 8_000,
            currentTimeMs: 8_000,
            hasActiveLyrics: false
        ))
    }

    @Test func interludeAndEmphasisAnimationsMatchBoundaries() {
        #expect(calculateInterludeDotsAnimation(elapsedMs: 250, durationMs: 5_000).opacities.allSatisfy { $0 == 0 })
        let entering = calculateInterludeDotsAnimation(elapsedMs: 750, durationMs: 5_000)
        #expect(entering.opacities[0] > entering.opacities[1])
        let active = calculateEmphasisCharacterMotion(progress: 0.75, characterIndex: 4, characterCount: 5, amount: 1)
        #expect(active.scale > 1)
        #expect(active.translationYEm < 0)
    }

    @Test func shortSyllableFloatUsesAnIndependentClockAndHoldsItsHeight() {
        let words = [LyricWord(startTime: 1_000, endTime: 1_100, word: "你")]
        #expect(lyricWordLift(words: words, timeMs: 900) == 0)
        // Highlight is complete here, but lift is still near the baseline.
        #expect(lyricChunkProgress(words: words, timeMs: 1_100) == 1)
        #expect(lyricWordLift(words: words, timeMs: 1_100) < 0.03)
        #expect(lyricWordLift(words: words, timeMs: 1_500) == 0.5)
        #expect(lyricWordLift(words: words, timeMs: 2_000) == 1)
        #expect(lyricWordLift(words: words, timeMs: 3_000) == 1)
        let heldNote = [LyricWord(startTime: 1_000, endTime: 5_000, word: "啊")]
        #expect(lyricWordLift(words: heldNote, timeMs: 3_000) == 0.5)
        #expect(lyricWordLift(words: [], timeMs: 3_000) == 0)
    }

    @Test func emphasisAndGlowSettleWithoutEndpointVelocity() {
        for index in 0..<5 {
            let start = calculateEmphasisCharacterMotion(progress: 0, characterIndex: index, characterCount: 5, amount: 1)
            let end = calculateEmphasisCharacterMotion(progress: 1, characterIndex: index, characterCount: 5, amount: 1)
            #expect(start.scale == 1 && end.scale == 1)
            #expect(start.verticalScale == 1 && end.verticalScale == 1)
            #expect(end.translationXEm == 0 && end.translationYEm == 0)
        }
        let nearStart = calculateEmphasisCharacterMotion(progress: 0.0001, characterIndex: 0, characterCount: 5, amount: 1)
        let nearEnd = calculateEmphasisCharacterMotion(progress: 0.9999, characterIndex: 4, characterCount: 5, amount: 1)
        #expect(nearStart.wave < 0.000001 && nearEnd.wave < 0.000001)
        let crest = calculateEmphasisCharacterMotion(progress: 0.5, characterIndex: 2, characterCount: 5, amount: 1)
        #expect(crest.verticalScale > crest.scale)
        #expect(lyricWordGlow(progress: 0, amount: 1) == 0)
        #expect(lyricWordGlow(progress: 1, amount: 1) == 0)
        #expect(lyricWordGlow(progress: 0.5, amount: 1) == 0.65)
        #expect(lyricWordGlow(progress: 0.9999, amount: 1) < 0.000001)
    }

    @Test func heldEmphasisHasOverlappingCrestsAndContinuousFrameMotion() {
        let widths: [CGFloat] = [31, 24, 22, 10, 25, 21] // Unequal advances in "chains".
        let held = widths.indices.map {
            calculateEmphasisCharacterMotion(progress: 0.5, characterIndex: $0, characterCount: widths.count, amount: 1)
        }
        #expect(held.allSatisfy { $0.wave > 0.9 })
        var previous = widths.indices.map {
            calculateEmphasisCharacterMotion(progress: 0, characterIndex: $0, characterCount: widths.count, amount: 1)
        }
        // A three-second note at 60 Hz: no abrupt change at attack/hold/release.
        for frame in 1...180 {
            let motions = widths.indices.map {
                calculateEmphasisCharacterMotion(progress: Double(frame) / 180, characterIndex: $0, characterCount: widths.count, amount: 1)
            }
            for index in widths.indices {
                #expect(abs(motions[index].verticalScale - previous[index].verticalScale) < 0.007)
                #expect(motions[index].verticalScale >= 1)
            }
            previous = motions
        }
    }

    @Test func emphasisExpansionPreservesGlyphEdgesAndWordCenter() {
        let widths: [CGFloat] = [32, 10, 24, 12]
        for frame in 0...120 {
            let scales = widths.indices.map {
                calculateEmphasisCharacterMotion(progress: Double(frame) / 120, characterIndex: $0, characterCount: widths.count, amount: 1.2).scale
            }
            let offsets = emphasisGlyphOffsets(widths: widths, scales: scales)
            var x: CGFloat = 0
            var previousRight: CGFloat?
            var firstLeft: CGFloat = 0
            for index in widths.indices {
                let center = x + widths[index] / 2 + offsets[index]
                let halfWidth = widths[index] * scales[index] / 2
                let left = center - halfWidth
                if let previousRight { #expect(abs(left - previousRight) < 0.000001) }
                else { firstLeft = left }
                previousRight = center + halfWidth
                x += widths[index]
            }
            #expect(abs((firstLeft + (previousRight ?? 0)) / 2 - x / 2) < 0.000001)
        }
        #expect(emphasisGlyphOffsets(widths: widths, scales: [1, 1, 1, 1]) == [0, 0, 0, 0])
    }

    @Test func emphasisClockKeepsMovingBetweenSyllables() {
        let words = [
            LyricWord(startTime: 1_000, endTime: 1_500, word: "start"),
            LyricWord(startTime: 2_500, endTime: 4_000, word: "ing")
        ]
        #expect(lyricChunkProgress(words: words, timeMs: 1_600) == lyricChunkProgress(words: words, timeMs: 2_400))
        #expect(lyricEmphasisProgress(words: words, timeMs: 1_600) < lyricEmphasisProgress(words: words, timeMs: 2_400))
        #expect(lyricEmphasisProgress(words: words, timeMs: 900) == 0)
        #expect(lyricEmphasisProgress(words: words, timeMs: 4_100) == 1)
        #expect(lyricEmphasisProgress(words: [], timeMs: 2_000) == 0)
        #expect(lyricEmphasisProgress(words: [.init(startTime: 1_000, endTime: 1_000, word: "啊")], timeMs: 1_000) == 1)
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

    @Test func lyricBoundaryPollingIsCoarseAndSleepsWhenInactive() {
        #expect(abs(lyricTimelineInterval(largeScreenOptimizations: true, updatesFrames: true) - 1.0 / 10.0) < 0.0001)
        #expect(abs(lyricTimelineInterval(largeScreenOptimizations: false, updatesFrames: true) - 1.0 / 10.0) < 0.0001)
        #expect(lyricTimelineInterval(largeScreenOptimizations: true, updatesFrames: false) == 3_600)
    }
    @Test func playerDismissalRequiresDistanceOrADownwardFlick() {
        #expect(playerShouldDismiss(translation: 170, projectedTranslation: 190, height: 800))
        #expect(playerShouldDismiss(translation: 35, projectedTranslation: 400, height: 800))
        #expect(!playerShouldDismiss(translation: 20, projectedTranslation: 400, height: 800))
        #expect(!playerShouldDismiss(translation: 70, projectedTranslation: 90, height: 800))
        #expect(!playerShouldDismiss(translation: -170, projectedTranslation: -400, height: 800))
    }

    @Test func playerDismissalCanBeCancelledByPushingBackUp() {
        #expect(!playerShouldDismiss(translation: 220, projectedTranslation: 100, height: 800))
        #expect(!playerShouldDismiss(translation: 70, projectedTranslation: -50, height: 800))
        #expect(playerShouldDismiss(translation: 220, projectedTranslation: 210, height: 800))
        #expect(playerShouldDismiss(translation: 220, projectedTranslation: 220, height: 800))
    }

    @Test func emphasisMaskIncludesGlowWithoutChangingWordProgress() {
        let fontSize: CGFloat = 46
        let inset = lyricEffectBleed(fontSize: fontSize, characterCount: 7)
        // Three shadow radii plus the upward movement and scale expansion.
        #expect(inset > fontSize * (0.75 + 0.06 + 0.06))
        let width: CGFloat = 160
        for progress: CGFloat in [0.1, 0.5, 0.9] {
            let original = lyricProgressMaskStops(
                progress: progress, surfaceWidth: width, contentInset: 0, fadeWidth: 23
            )
            let expanded = lyricProgressMaskStops(
                progress: progress, surfaceWidth: width + inset * 2, contentInset: inset, fadeWidth: 23
            )
            #expect(abs(min(width, max(0, expanded.clearStart * (width + inset * 2) - inset)) - original.clearStart * width) < 0.001)
            #expect(expanded.opaqueEnd <= expanded.clearStart)
            #expect(expanded.opaqueEnd >= 0 && expanded.clearStart <= 1)
        }
    }

    @Test @MainActor func lyricFollowSchedulesEachNewLineAndDeduplicatesTicks() async {
        var groups: [LyricGroup] = []
        for index in 0..<3 {
            let start = Int64(index) * 1_000
            let end = start + 1_000
            let word = LyricWord(startTime: start, endTime: end, word: "歌词")
            let line = LyricLine(words: [word], startTime: start, endTime: end)
            groups.append(LyricGroup(main: line))
        }
        let model = LyricsViewModel(groups: groups, timeMs: 0)
        var visited: [Int] = []
        for time: Int64 in [0, 100, 1_100, 1_200, 2_100] {
            let index = model.sync(timeMs: time).scrollTargetIndex
            model.scheduleAutoScroll(index: index) { visited.append(index) }
            await model.autoScrollTask?.value
        }
        #expect(visited == [0, 1, 2])
    }

    @Test @MainActor func lyricFollowCanCorrectTheSameTargetWithoutRepeatingSettledTicks() async {
        let model = LyricsViewModel(groups: [], timeMs: 0)
        var calls = 0
        model.scheduleAutoScroll(index: 1) { calls += 1 }
        await model.autoScrollTask?.value
        model.scheduleAutoScroll(index: 1) { calls += 1 }
        await model.autoScrollTask?.value
        #expect(calls == 1)
        model.scheduleAutoScroll(index: 1, force: true) { calls += 1 }
        await model.autoScrollTask?.value
        #expect(calls == 2)
        model.anchorFrames = [1: CGRect(x: 0, y: 200, width: 300, height: 100)]
        // Let the correction settle before considering another position check.
        #expect(!model.anchorNeedsCorrection(index: 1, viewportHeight: 500, alignPosition: 0.2))
    }

    @Test @MainActor func lyricFollowRearmsAfterPageChangesAndManualScrolling() async {
        let model = LyricsViewModel(groups: [], timeMs: 0)
        var calls = 0
        model.scheduleAutoScroll(index: 2) { calls += 1 }
        await model.autoScrollTask?.value
        model.beginUserScroll()
        #expect(model.isUserScrolling)
        model.layoutDidChange()
        #expect(!model.isUserScrolling)
        // Reopening the lyric page must scroll even when the line hasn't changed.
        model.scheduleAutoScroll(index: 2) { calls += 1 }
        await model.autoScrollTask?.value
        #expect(calls == 2)
        model.cancelTasks()
        model.scheduleAutoScroll(index: 2) { calls += 1 }
        await model.autoScrollTask?.value
        #expect(calls == 3)
    }

    @Test @MainActor func tappingLyricRestoresFollowingAndCancelsDelayedResume() async {
        let model = LyricsViewModel(groups: [], timeMs: 0)
        model.beginUserScroll()
        var delayedResumeRan = false
        let delayedResume = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled else { return }
            delayedResumeRan = true
        }
        model.resumeTask = delayedResume
        var visited: [Int] = []
        model.scheduleAutoScroll(index: 1) { visited.append(1) }
        let pendingScroll = model.autoScrollTask
        model.resumeAutomaticFollowing()
        #expect(!model.isUserScrolling)
        #expect(model.resumeTask == nil)
        model.scheduleAutoScroll(index: 2, force: true) { visited.append(2) }
        await delayedResume.value
        await pendingScroll?.value
        await model.autoScrollTask?.value
        #expect(!delayedResumeRan)
        #expect(visited == [2])
        model.scheduleAutoScroll(index: 3) { visited.append(3) }
        await model.autoScrollTask?.value
        #expect(visited == [2, 3])
    }

    @Test @MainActor func manualLyricDragCancelsAnAlreadyScheduledScroll() async {
        let model = LyricsViewModel(groups: [], timeMs: 0)
        var calls = 0
        model.scheduleAutoScroll(index: 1) { calls += 1 }
        let pending = model.autoScrollTask
        model.beginUserScroll()
        await pending?.value
        #expect(calls == 0)
        model.beginHorizontalSwipe()
        #expect(!model.isUserScrolling)
        model.cancelTasks()
    }

    @Test @MainActor func lyricWrappingCacheTracksWidthFontMetricsAndSpacing() {
        var layout = BalancedLyricLayout(trailingAlignment: false)
        let sizes = [CGSize(width: 40, height: 30), CGSize(width: 40, height: 30)]
        var cache = BalancedLyricLayout.Cache(sizes: sizes)
        #expect(layout.cachedRows(width: 100, cache: &cache) == [0..<2])
        for _ in 0..<120 {
            cache.updateSizes(sizes)
            #expect(cache.width == 100) // Progress-only frames preserve the cached breakpoints.
            #expect(layout.cachedRows(width: 100, cache: &cache) == [0..<2])
        }
        #expect(layout.cachedRows(width: 60, cache: &cache) == [0..<1, 1..<2])
        cache.updateSizes([CGSize(width: 60, height: 45), CGSize(width: 60, height: 45)])
        #expect(cache.width == nil)
        #expect(layout.cachedRows(width: 100, cache: &cache) == [0..<1, 1..<2])
        cache.updateSizes(sizes)
        layout.horizontalSpacing = 30
        #expect(layout.cachedRows(width: 100, cache: &cache) == [0..<1, 1..<2])
    }

    @Test func lyricCharacterCachePreservesComposedGraphemes() {
        let text = "e\u{301}👨‍👩‍👧‍👦好"
        let chunk = LyricWordChunk(id: "unicode", words: [.init(startTime: 0, endTime: 2_000, word: text)])
        #expect(chunk.characters.count == 3)
        #expect(chunk.characters.joined() == chunk.displayText)
    }

    @Test @MainActor func longLyricsPreferPhraseAndWordBoundaries() {
        let sizes = Array(repeating: CGSize(width: 10, height: 30), count: 6)
        var layout = BalancedLyricLayout(
            trailingAlignment: false,
            breakOpportunities: [.character, .word, .character, .word, .character, .word]
        )
        var cache = BalancedLyricLayout.Cache(sizes: sizes)
        // Slightly unequal rows preserve words instead of cutting their middle.
        #expect(layout.cachedRows(width: 40, cache: &cache) == [0..<2, 2..<6])
        layout.breakOpportunities[2] = .phrase
        // Changed break metadata invalidates the cache even at the same width.
        #expect(layout.cachedRows(width: 40, cache: &cache) == [0..<3, 3..<6])
        layout.breakOpportunities = Array(repeating: .phrase, count: 6)
        #expect(layout.cachedRows(width: 30, cache: &cache).count == 2)
    }

    @Test @MainActor func lyricWrappingAvoidsHangingPunctuation() {
        let sizes = Array(repeating: CGSize(width: 10, height: 30), count: 6)
        let layout = BalancedLyricLayout(
            trailingAlignment: true,
            breakOpportunities: [.character, .word, .avoid, .word, .character, .word]
        )
        var cache = BalancedLyricLayout.Cache(sizes: sizes)
        #expect(layout.cachedRows(width: 40, cache: &cache) == [0..<2, 2..<6])
        let chunks = chunkLyricWords([.init(startTime: 0, endTime: 5_000, word: "你好，世界")])
        #expect(chunks[1].breakAfter == .avoid)
        #expect(chunks[2].breakAfter == .phrase)
    }

    @Test @MainActor func lyricRowsTrimOnlyBoundaryWhitespace() {
        let layout = BalancedLyricLayout(
            trailingAlignment: true,
            spaces: [true, false, true, false, true, false, true]
        )
        let sizes = [8, 25, 8, 25, 8, 25, 8].map { CGSize(width: $0, height: 30) }
        var cache = BalancedLyricLayout.Cache(sizes: sizes)
        #expect(layout.cachedRows(width: 100, cache: &cache) == [1..<6])
        let rows = layout.cachedRows(width: 60, cache: &cache)
        #expect(rows.count == 2)
        #expect(rows.flatMap { $0 }.filter { !layout.spaces[$0] } == [1, 3, 5])
        for row in rows {
            #expect(!layout.spaces[row.lowerBound])
            #expect(!layout.spaces[row.upperBound - 1])
            #expect(row.reduce(CGFloat.zero) { $0 + sizes[$1].width } <= 60)
        }
    }

    @Test @MainActor func indivisibleOversizedWordAndEmptyLyricsTerminate() {
        let layout = BalancedLyricLayout(trailingAlignment: false)
        var cache = BalancedLyricLayout.Cache(sizes: [.init(width: 200, height: 30), .init(width: 20, height: 30)])
        #expect(layout.cachedRows(width: 50, cache: &cache) == [0..<1, 1..<2])
        #expect(layout.cachedRows(width: 0, cache: &cache) == [0..<1, 1..<2])
        cache.updateSizes([])
        #expect(layout.cachedRows(width: 50, cache: &cache).isEmpty)
        let whitespace = BalancedLyricLayout(trailingAlignment: false, spaces: [true, true])
        cache.updateSizes([.init(width: 10, height: 30), .init(width: 10, height: 30)])
        #expect(whitespace.cachedRows(width: 50, cache: &cache).isEmpty)
    }

    @Test func rubySpacesKeepTheWordAndTimingIntact() {
        let ruby = [LyricWordBase(startTime: 100, endTime: 900, word: "とうきょう")]
        let chunks = chunkLyricWords([
            .init(startTime: 100, endTime: 900, word: " 東京 ", romanWord: "Tokyo", ruby: ruby)
        ])
        #expect(chunks.map(\.text) == [" ", "東京", " "])
        #expect(chunks[1].words[0].ruby == ruby)
        #expect(chunks[1].romanText == "Tokyo")
        #expect(chunks[1].words[0].startTime == 100)
        #expect(chunks[1].words[0].endTime == 900)
        #expect(chunks[0].words[0].endTime == 100)
        #expect(chunks[2].words[0].startTime == 900)
        #expect(chunks[0].rubyText.isEmpty && chunks[2].romanText.isEmpty)
    }

    @Test func romanizationIsAssignedToItsOwnPhrase() {
        let chunks = chunkLyricWords([
            .init(startTime: 0, endTime: 1_000, word: "你好 世界", romanWord: "nihao shijie")
        ])
        #expect(chunks.map(\.text) == ["你好", " ", "世界"])
        #expect(chunks.map(\.romanText) == ["nihao", "", "shijie"])
        #expect(chunks[0].words[0].endTime == 500)
        #expect(chunks[2].words[0].startTime == 500)
        #expect(chunks[2].words[0].endTime == 1_000)
        let unmatched = chunkLyricWords([
            .init(startTime: 0, endTime: 1_000, word: "你好 世界", romanWord: "ni hao shi jie")
        ])
        #expect(unmatched.map(\.romanText) == ["ni hao shi jie", "", ""])
    }

    @Test func wrappedCJKChunksPreserveTextAndContinuousTime() {
        let text = "这是一句很长的歌词，需要分段换行👨‍👩‍👧‍👦"
        let chunks = chunkLyricWords([.init(startTime: 100, endTime: 5_100, word: text)])
        #expect(chunks.map(\.text).joined() == text)
        #expect(chunks.first?.words.first?.startTime == 100)
        #expect(chunks.last?.words.last?.endTime == 5_100)
        for pair in zip(chunks, chunks.dropFirst()) {
            #expect(pair.0.words.last?.endTime == pair.1.words.first?.startTime)
        }
    }

    @Test @MainActor func singleCharacterLyricsSnapToSpacesWithinTwoCharacters() {
        // Force the original balanced break to sit two characters from a space.
        // Zero-width spaces make the expected measured break unambiguous.
        for (spaceIndex, originalBreak, expected) in [
            (2, 5, [0..<2, 3..<9]),
            (6, 4, [0..<6, 7..<9]),
        ] {
            let spaces = (0..<9).map { $0 == spaceIndex }
            var opportunities = Array(repeating: LyricBreakOpportunity.character, count: 9)
            opportunities[originalBreak - 1] = .phrase
            opportunities[spaceIndex] = .word
            var layout = BalancedLyricLayout(
                trailingAlignment: false, spaces: spaces, breakOpportunities: opportunities
            )
            var cache = BalancedLyricLayout.Cache(sizes: spaces.map { .init(width: $0 ? 0 : 10, height: 30) })
            #expect(layout.cachedRows(width: 60, cache: &cache) == [0..<originalBreak, originalBreak..<9])
            layout.singleCharacterWords = spaces.map { !$0 }
            // The new metadata must invalidate the original cached rows.
            #expect(layout.cachedRows(width: 60, cache: &cache) == expected)
        }
    }

    @Test @MainActor func nearbySpaceRuleRejectsDistantSpacesAndOverflow() {
        for (spaceIndex, width) in [(1, CGFloat(60)), (2, CGFloat(50))] {
            let spaces = (0..<9).map { $0 == spaceIndex }
            var opportunities = Array(repeating: LyricBreakOpportunity.character, count: 9)
            opportunities[4] = .phrase
            opportunities[spaceIndex] = .word
            let layout = BalancedLyricLayout(
                trailingAlignment: true, spaces: spaces,
                singleCharacterWords: spaces.map { !$0 }, breakOpportunities: opportunities
            )
            var cache = BalancedLyricLayout.Cache(sizes: spaces.map { .init(width: $0 ? 0 : 10, height: 30) })
            // Three characters away, or shifting would make the second row too wide.
            #expect(layout.cachedRows(width: width, cache: &cache) == [0..<5, 5..<9])
        }
    }

    @Test @MainActor func nearbySpaceRuleChoosesTheCloserOfBothSides() {
        let spaces = (0..<9).map { $0 == 2 || $0 == 6 }
        var opportunities = Array(repeating: LyricBreakOpportunity.character, count: 9)
        opportunities[4] = .phrase
        opportunities[2] = .word
        opportunities[6] = .word
        let layout = BalancedLyricLayout(
            trailingAlignment: false, spaces: spaces,
            singleCharacterWords: spaces.map { !$0 }, breakOpportunities: opportunities
        )
        var cache = BalancedLyricLayout.Cache(sizes: spaces.map { .init(width: $0 ? 0 : 10, height: 30) })
        // The right space is one character away; the left is two away.
        #expect(layout.cachedRows(width: 60, cache: &cache) == [0..<6, 7..<9])
    }

    @Test func nearbySpaceRuleRecognizesCJKGraphemesAndPreservesEnglishWords() {
        for text in ["汉", "한", "あ", "カ", "한"] {
            let chunk = LyricWordChunk(id: text, words: [.init(startTime: 0, endTime: 100, word: text)])
            #expect(chunk.isSingleCJKCharacter)
        }
        for text in ["English", "a", "東京", " ", "👨‍👩‍👧‍👦"] {
            let chunk = LyricWordChunk(id: text, words: [.init(startTime: 0, endTime: 100, word: text)])
            #expect(!chunk.isSingleCJKCharacter)
        }
    }

}
