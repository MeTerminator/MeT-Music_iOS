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

/// Anticipation changes activation starts, never the clock or line ends.
/// Spend only the silent gap before a line; authored overlapping vocals keep
/// their original start instead of being delayed or advanced further.
func lyricTransitionBounds(_ bounds: [LyricTimeBounds], lineTransitionLeadMs: Int64) -> [LyricTimeBounds] {
    let lead = max(0, lineTransitionLeadMs)
    guard lead > 0 else { return bounds }
    var previousEnd: Int64 = 0
    return bounds.map { bound in
        defer { previousEnd = max(previousEnd, bound.endTime) }
        return .init(
            startTime: min(bound.startTime, max(previousEnd, bound.startTime - lead)),
            endTime: bound.endTime
        )
    }
}

/// Line opacity depends on playback emphasis, never on the number of timed
/// words. LRC lyrics often represent an entire visual line as one timed word.
public func lyricLineOpacity(isHighlighted: Bool) -> Double {
    isHighlighted ? 0.85 : 1
}

/// Fast phrases need their activation observed before a scroll/float animation
/// can obscure the next sung syllable. Include both neighbors and short solos.
func lyricRapidTransitionFlags(bounds: [LyricRenderBounds]) -> [Bool] {
    bounds.indices.map { index in
        var intervals = [bounds[index].endTime - bounds[index].startTime]
        if index > 0 { intervals.append(bounds[index].startTime - bounds[index - 1].startTime) }
        if index + 1 < bounds.count { intervals.append(bounds[index + 1].startTime - bounds[index].startTime) }
        return intervals.contains { $0 > 0 && $0 <= 650 }
    }
}

/// Upcoming groups gradually fall out of focus with their distance from the
/// last highlighted group. Overlapping vocals remain clear, and manual
/// browsing reveals all text. The radius is constant between line boundaries.
func lyricUpcomingBlurRadius(
    index: Int,
    focusIndex: Int,
    isUpcoming: Bool,
    isFocused: Bool,
    isUserScrolling: Bool,
    enabled: Bool,
    fontSize: CGFloat,
    maximumRadius: CGFloat
) -> CGFloat {
    guard enabled, isUpcoming, !isFocused, !isUserScrolling else { return 0 }
    let distance = max(0, index - focusIndex)
    let scale = min(max(fontSize / 40, 0.8), 1.2)
    return min(CGFloat(1 + distance) * scale, max(0, maximumRadius))
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

/// The window a lyric occupies on screen.
///
/// The start is the first word actually sung, never `line.startTime`: the
/// optimizer moves that up to 600 ms earlier for visual anticipation. Keep
/// these authored bounds intact; `lyricTransitionBounds` separately advances
/// activation by the listener's lead setting, bounded by prior vocal endings.
///
/// The end still spans everything the line covers, so trailing words and an
/// attached background vocal keep the lyric on screen until they finish.
public func lyricGroupRenderBounds(main: LyricLine, background: LyricLine?) -> LyricRenderBounds {
    var earliest: Int64?
    var latest: Int64?
    func includeSungTimes(of line: LyricLine) {
        let sung = line.words.filter { !$0.word.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let words = sung.isEmpty ? line.words : sung
        guard !words.isEmpty else {
            earliest = min(earliest ?? line.startTime, min(line.startTime, line.endTime))
            latest = max(latest ?? line.endTime, max(line.startTime, line.endTime))
            return
        }
        for word in words {
            earliest = min(earliest ?? word.startTime, min(word.startTime, word.endTime))
            latest = max(latest ?? word.endTime, max(word.startTime, word.endTime))
        }
        latest = max(latest ?? line.endTime, line.endTime)
    }
    includeSungTimes(of: main)
    if let background { includeSungTimes(of: background) }
    let start = earliest ?? min(main.startTime, main.endTime)
    return .init(startTime: start, endTime: max(start, latest ?? max(main.startTime, main.endTime)))
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
    public var verticalScale: Double = 1
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
    // Overlap the crests: the reference holds a long note as one elastic
    // word, rather than sending a narrow bump through isolated letters.
    let local = min(max((min(max(progress, 0), 1) - ratio * 0.22) / 0.78, 0), 1)
    func smoothstep(_ value: Double) -> Double {
        let x = min(max(value, 0), 1)
        return x * x * x * (x * (x * 6 - 15) + 10)
    }
    // A slower release keeps the last letters from snapping down. Quintic
    // easing has zero velocity and acceleration at every phase boundary.
    let wave = smoothstep(local / 0.38) * (1 - smoothstep((local - 0.58) / 0.42))
    guard wave > 0 else { return .init(wave: 0, scale: 1, translationXEm: 0, translationYEm: 0) }
    let strength = min(max(amount, 0), 1.2)
    return .init(
        wave: wave,
        scale: 1 + wave * 0.065 * strength,
        verticalScale: 1 + wave * 0.18 * strength,
        // Horizontal expansion is resolved using actual glyph advances by
        // EmphasisGlyphLayout, so wide and narrow letters keep their spacing.
        translationXEm: 0,
        translationYEm: -wave * 0.035 * strength
    )
}

/// Offsets for center-anchored glyph scales, keeping the expanded word centered
/// without changing the measured word width or triggering lyric rewrapping.
func emphasisGlyphOffsets(widths: [CGFloat], scales: [Double]) -> [CGFloat] {
    guard widths.count == scales.count else { return Array(repeating: 0, count: widths.count) }
    let growth = zip(widths, scales).map { max(0, $0.0) * CGFloat($0.1 - 1) }
    let halfGrowth = growth.reduce(0, +) / 2
    var preceding: CGFloat = 0
    return growth.map { extra in
        defer { preceding += extra }
        return preceding + extra / 2 - halfGrowth
    }
}

/// Geometry follows elapsed note time. The highlight uses weighted syllable
/// progress instead, which can pause in gaps between timed syllables.
func lyricEmphasisProgress(words: [LyricWord], timeMs: Int64) -> CGFloat {
    guard let first = words.first, let last = words.last else { return 0 }
    guard last.endTime > first.startTime else { return timeMs >= first.startTime ? 1 : 0 }
    return min(max(CGFloat(timeMs - first.startTime) / CGFloat(last.endTime - first.startTime), 0), 1)
}

/// Float has its own clock: short syllables should not jump upward just
/// because their highlight finishes in 100 ms. Completed words hold the lift.
func lyricWordLift(words: [LyricWord], timeMs: Int64) -> Double {
    guard let first = words.first, let last = words.last else { return 0 }
    let duration = max(1_000, last.endTime - first.startTime)
    let progress = min(max(Double(timeMs - first.startTime) / Double(duration), 0), 1)
    return progress * progress * (3 - 2 * progress)
}

/// A broad, quiet halo underneath the brighter long-note character glow.
/// The envelope reaches zero smoothly before the completed-word fast path.
func lyricWordGlow(progress: Double, amount: Double) -> Double {
    let phase = min(max(progress, 0), 1)
    guard phase > 0 && phase < 1 else { return 0 }
    return pow(sin(phase * .pi), 2) * min(max(amount, 0.12), 0.65)
}

func lyricChunkProgress(words: [LyricWord], timeMs: Int64) -> CGFloat {
    guard !words.isEmpty else { return 0 }
    var total = 0
    var completed = 0.0
    for word in words {
        let weight = max(word.word.count, 1)
        total += weight
        let progress: Double
        if word.endTime <= word.startTime {
            progress = timeMs >= word.startTime ? 1 : 0
        } else {
            progress = min(max(Double(timeMs - word.startTime) / Double(word.endTime - word.startTime), 0), 1)
        }
        completed += Double(weight) * progress
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

/// Apple Music's tap handling protects selection briefly while a seek reaches
/// its timing provider. The timeout always restores the authoritative clock.
struct LyricTapSelection {
    let index: Int
    let timeMs: Int64
    let date: Date

    func resolve(mediaTimeMs: Int64, now: Date) -> (timeMs: Int64, holdsSelection: Bool) {
        let waiting = now.timeIntervalSince(date) < 1
            && abs(Double(mediaTimeMs) - Double(timeMs)) > 500
        return (waiting ? timeMs : mediaTimeMs, waiting)
    }
}

/// Silence begins after ALL earlier voices have ended, including background
/// vocals. Index zero represents a leading instrumental section.
func lyricInterludeGaps(bounds: [LyricRenderBounds], minimumGapMs: Int64 = 4_000) -> [LyricTimeBounds?] {
    var previousEnd: Int64 = 0
    return bounds.map { bound in
        defer { previousEnd = max(previousEnd, bound.endTime) }
        guard bound.startTime - previousEnd >= minimumGapMs else { return nil }
        return .init(startTime: previousEnd, endTime: bound.startTime)
    }
}

/// Every row shares the same scroll displacement. For an upward step, the
/// residual offset is nondecreasing with row index: adding it to an ordered
/// stack cannot make a later row cross an earlier one. Active steps add rather
/// than restarting independent positions/velocities on each lyric boundary.
struct LyricLineTransition: Equatable, Sendable {
    struct Step: Equatable, Sendable {
        let focusIndex: Int
        let startDate: Date
        let originY: CGFloat
        var displacement: CGFloat?
        let rapid: Bool
    }

    private(set) var steps: [Step]
    private var releaseDate: Date?
    var focusIndex: Int { steps.last?.focusIndex ?? 0 }
    var rapid: Bool { steps.last?.rapid ?? false }
    var isRelease: Bool { releaseDate != nil }
    var duration: TimeInterval { isRelease ? 0.16 : 1.4 }

    init(focusIndex: Int, startDate: Date, contentOriginY: CGFloat, rapid: Bool = false) {
        steps = [.init(focusIndex: focusIndex, startDate: startDate, originY: contentOriginY, rapid: rapid)]
    }

    func appendingStep(index: Int, at date: Date, contentOriginY: CGFloat, rapid: Bool) -> Self {
        guard !isRelease else { return .init(focusIndex: index, startDate: date, contentOriginY: contentOriginY, rapid: rapid) }
        var result = self
        result.freezeDisplacements(contentOriginY: contentOriginY)
        result.steps.removeAll { date.timeIntervalSince($0.startDate) >= 1.4 }
        result.steps.append(.init(focusIndex: index, startDate: date, originY: contentOriginY, rapid: rapid))
        return result
    }

    func released(at date: Date, contentOriginY: CGFloat) -> Self {
        var result = self
        result.freezeDisplacements(contentOriginY: contentOriginY)
        result.releaseDate = date
        return result
    }

    private mutating func freezeDisplacements(contentOriginY: CGFloat) {
        for index in steps.indices where steps[index].displacement == nil {
            steps[index].displacement = steps[index].originY - contentOriginY
        }
    }

    func offset(index: Int, contentOriginY: CGFloat, at date: Date) -> CGFloat {
        let poseDate = releaseDate ?? date
        var value: CGFloat = 0
        for step in steps {
            let elapsed = max(0, poseDate.timeIntervalSince(step.startDate))
            guard elapsed < 1.4 else { continue }
            let displacement = step.displacement ?? (step.originY - contentOriginY)
            // A downward correction moves the entire stack together. Using
            // ascending delays with a negative displacement would compress it.
            let delay = displacement > 0
                ? min(Double(max(0, index - step.focusIndex)) * (step.rapid ? 0.018 : 0.055), step.rapid ? 0.072 : 0.22)
                : 0
            let time = max(0, elapsed - delay)
            let frequency: CGFloat = step.rapid ? 18 : 12
            value += displacement * (1 + frequency * time) * exp(-frequency * time)
        }
        if let releaseDate {
            let phase = min(max(date.timeIntervalSince(releaseDate) / 0.16, 0), 1)
            value *= 1 - phase * phase * (3 - 2 * phase)
        }
        return value
    }
}

/// One authoritative sample shared by boundary detection and overlapping vocal
/// rows. No free-running interpolation: a paused or buffering media clock stays
/// still. At most one source read per 120 Hz display interval.
@MainActor
final class LyricMediaClock {
    private var sampledAt: Date?
    private var sampledRevision: UInt?
    private var sampledTimeMs: Int64 = 0

    func sample(provider: (@MainActor () -> Int64)?, fallback: Int64, revision: UInt, now: Date = .now) -> Int64 {
        guard let provider else { return fallback }
        if sampledRevision == revision, let sampledAt {
            let age = now.timeIntervalSince(sampledAt)
            if age >= 0 && age < 1.0 / 120 { return sampledTimeMs }
        }
        sampledTimeMs = provider()
        sampledAt = now
        sampledRevision = revision
        return sampledTimeMs
    }

    func invalidate() {
        sampledAt = nil
        sampledRevision = nil
    }
}
