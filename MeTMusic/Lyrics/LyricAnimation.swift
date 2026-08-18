import Foundation

/// Returns the authored media position for a tapped lyric. The optimizer may
/// advance `line.startTime` for visual anticipation, so seeking must use the
/// first real timed word.
public func lyricTapSeekTime(line: LyricLine, lyricOffsetMs: Int64) -> Int64 {
    let authoredStart = line.words.first {
        !$0.word.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }?.startTime ?? line.startTime
    return max(0, authoredStart - lyricOffsetMs)
}

/// The clock used for word-by-word progress. A line-transition lead must never
/// be added here, otherwise the rendered lyric progress runs ahead of audio.
public func lyricPresentationTime(mediaPositionMs: Int64, lyricOffsetMs: Int64) -> Int64 {
    mediaPositionMs + lyricOffsetMs
}

/// The separate clock used only to anticipate active-line changes and scrolling.
public func lyricTimelineTime(presentationTimeMs: Int64, lineTransitionLeadMs: Int64) -> Int64 {
    presentationTimeMs + lineTransitionLeadMs
}

/// Line opacity depends on playback emphasis, never on the number of timed
/// words. LRC lyrics often represent an entire visual line as one timed word.
public func lyricLineOpacity(isHighlighted: Bool) -> Double {
    isHighlighted ? 0.85 : 1
}

/// Interlude dots represent a true gap in the complete lyric timeline. A gap
/// between two adjacent groups is not enough when another overlapping lyric
/// group is still active.
public func shouldShowLyricInterlude(
    previousEndTimeMs: Int64,
    nextStartTimeMs: Int64,
    currentTimeMs: Int64,
    hasActiveLyrics: Bool,
    minimumGapMs: Int64 = 4_000
) -> Bool {
    !hasActiveLyrics
        && nextStartTimeMs - previousEndTimeMs >= minimumGapMs
        && currentTimeMs >= previousEndTimeMs
        && currentTimeMs < nextStartTimeMs
}

/// Reconstructs a display-rate lyric clock from coarse media-position samples.
/// Fresh player samples remain authoritative and discontinuous seeks snap immediately.
public struct PlaybackTimeInterpolator: Sendable {
    private var visualTimeMs: Double
    private var lastFrameNanoseconds: UInt64?
    private var anchorSourceTimeMs: Double
    private var anchorFrameNanoseconds: UInt64
    private var observedSourceTimeMs: Int64
    private var observedSourceFrameNanoseconds: UInt64
    private var observedDiscontinuityRevision: UInt = 0

    public init(initialSourceTimeMs: Int64) {
        visualTimeMs = Double(initialSourceTimeMs)
        anchorSourceTimeMs = Double(initialSourceTimeMs)
        observedSourceTimeMs = initialSourceTimeMs
        anchorFrameNanoseconds = 0
        observedSourceFrameNanoseconds = 0
    }

    public mutating func update(
        sourceTimeMs: Int64,
        frameNanoseconds: UInt64,
        isPlaying: Bool,
        playbackRate: Double = 1,
        discontinuityRevision: UInt = 0
    ) -> Int64 {
        let rate = playbackRate.isFinite ? max(playbackRate, 0) : 1
        if discontinuityRevision != observedDiscontinuityRevision {
            observedDiscontinuityRevision = discontinuityRevision
            reset(sourceTimeMs: sourceTimeMs, frameNanoseconds: frameNanoseconds)
            return sourceTimeMs
        }
        guard isPlaying, rate > 0 else {
            reset(sourceTimeMs: sourceTimeMs, frameNanoseconds: frameNanoseconds)
            return sourceTimeMs
        }
        guard let previousFrame = lastFrameNanoseconds else {
            reset(sourceTimeMs: sourceTimeMs, frameNanoseconds: frameNanoseconds)
            return sourceTimeMs
        }

        if sourceTimeMs != observedSourceTimeMs {
            let elapsed = Double(nonnegativeDifference(frameNanoseconds, observedSourceFrameNanoseconds)) / 1_000_000
            let expected = Double(observedSourceTimeMs) + elapsed * rate
            let discontinuity = abs(Double(sourceTimeMs) - expected) > 120
            anchorSourceTimeMs = Double(sourceTimeMs)
            anchorFrameNanoseconds = frameNanoseconds
            observedSourceTimeMs = sourceTimeMs
            observedSourceFrameNanoseconds = frameNanoseconds
            if discontinuity {
                reset(sourceTimeMs: sourceTimeMs, frameNanoseconds: frameNanoseconds)
                return sourceTimeMs
            }
        }

        let raw = anchorSourceTimeMs + Double(nonnegativeDifference(frameNanoseconds, anchorFrameNanoseconds)) / 1_000_000 * rate
        // Advance by the complete elapsed time. Capping this delta made the
        // lyric clock lose time whenever a large iPad layout missed frames;
        // audio kept advancing while lyrics only advanced by 64 ms per render.
        let frameDelta = Double(nonnegativeDifference(frameNanoseconds, previousFrame)) / 1_000_000
        let predicted = visualTimeMs + frameDelta * rate
        let error = raw - predicted
        if abs(error) > 250 {
            visualTimeMs = raw
        } else {
            // Keep source-sample jitter correction bounded without limiting
            // the media time advanced by the frame itself.
            let correction = max(0.25, min(frameDelta, 64) * 0.25)
            visualTimeMs = predicted + min(max(error, -correction), correction)
        }
        lastFrameNanoseconds = frameNanoseconds
        return Int64(visualTimeMs.rounded())
    }

    private mutating func reset(sourceTimeMs: Int64, frameNanoseconds: UInt64) {
        visualTimeMs = Double(sourceTimeMs)
        lastFrameNanoseconds = frameNanoseconds
        anchorSourceTimeMs = Double(sourceTimeMs)
        anchorFrameNanoseconds = frameNanoseconds
        observedSourceTimeMs = sourceTimeMs
        observedSourceFrameNanoseconds = frameNanoseconds
    }

    private func nonnegativeDifference(_ newer: UInt64, _ older: UInt64) -> UInt64 {
        newer >= older ? newer - older : 0
    }
}

public struct LyricRenderBounds: Hashable, Sendable {
    public var startTime: Int64
    public var endTime: Int64

    public init(startTime: Int64, endTime: Int64) {
        self.startTime = startTime
        self.endTime = endTime
    }
}

public func lyricGroupRenderBounds(main: LyricLine, background: LyricLine?) -> LyricRenderBounds {
    var earliest = min(main.startTime, main.endTime)
    var latest = max(main.startTime, main.endTime)
    func include(_ start: Int64, _ end: Int64) {
        earliest = min(earliest, min(start, end))
        latest = max(latest, max(start, end))
    }
    main.words.forEach { include($0.startTime, $0.endTime) }
    if let background {
        include(background.startTime, background.endTime)
        background.words.forEach { include($0.startTime, $0.endTime) }
    }
    return .init(startTime: earliest, endTime: latest)
}

public struct InterludeDotsAnimation: Hashable, Sendable {
    public var scale: Double
    public var opacities: [Double]
}

public func calculateInterludeDotsAnimation(elapsedMs: Int64, durationMs: Int64) -> InterludeDotsAnimation {
    guard durationMs > 0, (0...durationMs).contains(elapsedMs) else {
        return .init(scale: 0, opacities: [0, 0, 0])
    }
    let current = Double(elapsedMs)
    let duration = Double(durationMs)
    let breatheDuration = duration / max(ceil(duration / 1_500), 1)
    var scale = sin(1.5 * .pi - current / breatheDuration * 2) / 20 + 1
    var opacity: Double = current < 500 ? 0 : (current < 1_000 ? (current - 500) / 500 : 1)
    if current < 2_000 { scale *= easeOutExpo(current / 2_000) }
    let remaining = duration - current
    if remaining < 750 { scale *= 1 - easeInOutBack((750 - remaining) / 1_500) }
    if remaining < 375 { opacity *= min(max(remaining / 375, 0), 1) }
    let dotsDuration = max(duration - 750, 1)
    let opacities = (0..<3).map { index in
        let delayed = current - dotsDuration / 3 * Double(index)
        let local = min(max((delayed * 3 / dotsDuration) * 0.75, 0.25), 1)
        return min(max(opacity * local, 0), 1)
    }
    return .init(scale: max(scale, 0) * 0.7, opacities: opacities)
}

public struct EmphasisCharacterMotion: Hashable, Sendable {
    public var wave: Double
    public var scale: Double
    public var translationXEm: Double
    public var translationYEm: Double
}

public func calculateEmphasisCharacterMotion(
    progress: Double,
    characterIndex: Int,
    characterCount: Int,
    amount: Double
) -> EmphasisCharacterMotion {
    let count = max(characterCount, 1)
    let ratio = count == 1 ? 0 : Double(min(max(characterIndex, 0), count - 1)) / Double(count - 1)
    let local = min(max((min(max(progress, 0), 1) - ratio * 0.4) / 0.6, 0), 1)
    let wave = max(sin(local * .pi), 0)
    guard wave > 0 else { return .init(wave: 0, scale: 1, translationXEm: 0, translationYEm: 0) }
    let strength = max(amount, 0)
    let centerOffset = Double(count - 1) * 0.5 - Double(characterIndex)
    return .init(
        wave: wave,
        scale: 1 + wave * 0.1 * strength,
        translationXEm: -wave * 0.015 * strength * centerOffset,
        translationYEm: -wave * 0.05 * strength
    )
}

func lyricChunkProgress(words: [LyricWord], timeMs: Int64) -> CGFloat {
    guard !words.isEmpty else { return 0 }
    let weights = words.map { max($0.word.count, 1) }
    let total = max(weights.reduce(0, +), 1)
    let completed = zip(words, weights).reduce(0.0) { value, pair in
        let (word, weight) = pair
        let progress: Double
        if word.endTime <= word.startTime {
            progress = timeMs >= word.startTime ? 1 : 0
        } else {
            progress = min(max(Double(timeMs - word.startTime) / Double(word.endTime - word.startTime), 0), 1)
        }
        return value + Double(weight) * progress
    }
    return CGFloat(completed / Double(total))
}

private func easeOutExpo(_ value: Double) -> Double {
    value >= 1 ? 1 : 1 - pow(2, -10 * max(value, 0))
}

private func easeInOutBack(_ value: Double) -> Double {
    let x = min(max(value, 0), 1)
    let c1 = 1.70158
    let c2 = c1 * 1.525
    if x < 0.5 { return pow(2 * x, 2) * ((c2 + 1) * 2 * x - c2) / 2 }
    return (pow(2 * x - 2, 2) * ((c2 + 1) * (x * 2 - 2) + c2) + 2) / 2
}
