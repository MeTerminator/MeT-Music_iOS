import Combine
import SwiftUI

public struct AppleMusicLyricsStyle: Sendable {
    public var activeColor: Color = .white
    public var inactiveColor: Color = .white.opacity(0.2)
    public var fontSize: CGFloat = 32
    public var secondaryFontSize: CGFloat = 16
    public var lineWidthFraction: CGFloat = 0.8
    public var horizontalPadding: CGFloat = 16
    public var alignPosition: CGFloat = 0.2
    /// Complete fade-band width in em. `0.5` is half the line font size.
    public var wordFadeWidth: CGFloat = 0.5
    /// Vertical distance between lyric groups. Wrapped rows inside one lyric
    /// stay tight while separate lyrics keep Apple Music's clear visual rhythm.
    public var lineSpacing: CGFloat = 6
    public var backgroundLineScale: CGFloat = 0.7
    public var enableScale = true
    public var enableBlur = true
    /// Maximum defocus radius in points for upcoming lyric groups.
    public var maximumBlurRadius: CGFloat = 5
    public var enableFrameInterpolation = true
    public var playbackRate: Double = 1
    public var alwaysPostpositionBackground = false
    public var userScrollResumeDelay: Duration = .seconds(3)

    public init() {}
}

public enum LyricsHorizontalSwipeDirection: Sendable {
    case previous
    case next
}

public struct AppleMusicLyricsView: View {
    public let lyricLines: [LyricLine]
    public let currentTimeMs: Int64
    public let currentTimeProvider: (@MainActor () -> Int64)?
    public let lineTransitionLeadMs: Int64
    public let playbackDiscontinuityRevision: UInt
    public let isPlaying: Bool
    public let isActive: Bool
    public let isPageTransitioning: Bool
    public let largeScreenOptimizations: Bool
    public let style: AppleMusicLyricsStyle
    public let showTranslation: Bool
    public let showRomanization: Bool
    public let optimizeOptions: OptimizeLyricOptions
    public let onLineTap: (LyricLine) -> Void
    public let onLineBoundary: @MainActor @Sendable () -> Void
    public let handlesHorizontalSwipe: Bool
    public let onHorizontalSwipe: (LyricsHorizontalSwipeDirection) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var model: LyricsViewModel

    public init(
        lyricLines: [LyricLine],
        currentTimeMs: Int64,
        currentTimeProvider: (@MainActor () -> Int64)? = nil,
        lineTransitionLeadMs: Int64 = 0,
        playbackDiscontinuityRevision: UInt = 0,
        isPlaying: Bool,
        isActive: Bool = true,
        isPageTransitioning: Bool = false,
        largeScreenOptimizations: Bool = false,
        style: AppleMusicLyricsStyle = .init(),
        showTranslation: Bool = true,
        showRomanization: Bool = true,
        optimizeOptions: OptimizeLyricOptions = .init(),
        onLineTap: @escaping (LyricLine) -> Void = { _ in },
        onLineBoundary: @escaping @MainActor @Sendable () -> Void = {},
        handlesHorizontalSwipe: Bool = true,
        onHorizontalSwipe: @escaping (LyricsHorizontalSwipeDirection) -> Void = { _ in }
    ) {
        self.lyricLines = lyricLines
        self.currentTimeMs = currentTimeMs
        self.currentTimeProvider = currentTimeProvider
        self.lineTransitionLeadMs = lineTransitionLeadMs
        self.playbackDiscontinuityRevision = playbackDiscontinuityRevision
        self.isPlaying = isPlaying
        self.isActive = isActive
        self.isPageTransitioning = isPageTransitioning
        self.largeScreenOptimizations = largeScreenOptimizations
        self.style = style
        self.showTranslation = showTranslation
        self.showRomanization = showRomanization
        self.optimizeOptions = optimizeOptions
        self.onLineTap = onLineTap
        self.onLineBoundary = onLineBoundary
        self.handlesHorizontalSwipe = handlesHorizontalSwipe
        self.onHorizontalSwipe = onHorizontalSwipe
        _model = StateObject(wrappedValue: LyricsViewModel(groups: [], timeMs: currentTimeMs))
    }

    public var body: some View {
        let signature = LyricSourceSignature(lines: lyricLines, options: optimizeOptions)
        lyricsBody(groups: model.groups)
        .onAppear { updateSourceIfNeeded(signature) }
        .onChange(of: signature) { _, _ in
            updateSourceIfNeeded(signature)
        }
        .onChange(of: playbackDiscontinuityRevision, initial: true) { _, revision in
            model.reanchorPlayback(
                timeMs: currentTimeProvider?() ?? currentTimeMs,
                revision: revision
            )
        }
        .onDisappear { model.cancelTasks() }
    }

    private func updateSourceIfNeeded(_ signature: LyricSourceSignature) {
        guard model.sourceSignature != signature else { return }
        model.reset(
            groups: groupLyricLines(optimizeLyricLines(lyricLines, options: optimizeOptions)),
            timeMs: currentTimeMs,
            sourceSignature: signature
        )
    }

    private func lyricsBody(groups: [LyricGroup]) -> some View {
        let hasDuet = groups.contains { $0.main.isDuet }
        return GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    let updatesFrames = lyricRenderingShouldAnimate(
                        isPlaying: isPlaying,
                        frameInterpolationEnabled: style.enableFrameInterpolation,
                        isActive: isActive,
                        isPageTransitioning: isPageTransitioning || model.isHorizontalSwiping
                    )
                    // A schedule starting at `.now` is a different schedule on
                    // every evaluation, and the parent re-evaluates this view
                    // with every published playback position.
                    TimelineView(.periodic(
                        from: model.timelineEpoch,
                        by: lyricTimelineInterval(
                            largeScreenOptimizations: largeScreenOptimizations,
                            updatesFrames: updatesFrames || model.lineTransition != nil,
                            rapidTransitions: currentTimeProvider != nil || model.lineTransition != nil || model.needsRapidLineUpdates(timeMs: currentTimeMs)
                        )
                    )) { context in
                        // A TimelineView date can be an old scheduled tick on a
                        // parent-driven update, especially while paused. Pair a
                        // fresh media sample with the time it was actually read.
                        let sampledAt = Date.now
                        let sourceTime = model.mediaClock.sample(
                            provider: currentTimeProvider, fallback: currentTimeMs,
                            revision: playbackDiscontinuityRevision, now: sampledAt
                        )
                        let mediaTime = model.presentationTime(
                            sourceTimeMs: sourceTime,
                            frameDate: sampledAt,
                            isPlaying: isPlaying,
                            enabled: style.enableFrameInterpolation && isActive
                                && !isPageTransitioning && !model.isHorizontalSwiping,
                            playbackRate: style.playbackRate,
                            discontinuityRevision: playbackDiscontinuityRevision,
                            authoritative: currentTimeProvider != nil
                        )
                        let snapshot = model.sync(timeMs: mediaTime, lineTransitionLeadMs: lineTransitionLeadMs)
                        let time = model.renderTimeMs
                        let rowWidth = max(0, geometry.size.width - style.horizontalPadding * (hasDuet ? 4 : 2)) * style.lineWidthFraction
                        let wrappedGroups = model.wrappedGroups(width: rowWidth, fontSize: style.fontSize, backgroundScale: style.backgroundLineScale)
                        LazyVStack(spacing: style.lineSpacing) {
                            Color.clear.frame(height: geometry.size.height * style.alignPosition)
                            ForEach(groups.indices, id: \.self) { index in
                                let group = wrappedGroups[index]
                                lyricRow(
                                    group: group, index: index, groups: groups, snapshot: snapshot,
                                    time: time, sampledAt: sampledAt, updatesFrames: updatesFrames,
                                    viewport: geometry.size, hasDuet: hasDuet, proxy: proxy
                                )
                            }
                            Color.clear.frame(height: geometry.size.height * (1 - style.alignPosition))
                        }
                        .animation(
                            reduceMotion || !isActive || isPageTransitioning || model.isUserScrolling
                                || model.isHorizontalSwiping ? nil : .spring(response: 0.38, dampingFraction: 0.92),
                            value: [rowWidth, style.fontSize, style.secondaryFontSize,
                                    showTranslation ? 1 : 0, showRomanization ? 1 : 0]
                        )
                        .padding(.horizontal, style.horizontalPadding)
                        .coordinateSpace(name: model.contentCoordinateSpace)
                        .background {
                            GeometryReader { content in
                                Color.clear.preference(
                                    key: LyricContentOriginPreference.self,
                                    value: Optional(content.frame(in: .named(model.scrollCoordinateSpace)).minY)
                                )
                            }
                        }
                        .onChange(of: LyricScrollRequest(
                            index: snapshot.scrollTargetIndex,
                            isSeeking: snapshot.isSeeking,
                            lineBoundaryIndex: snapshot.playingIndices.max(),
                            positionCheckTick: Int(sampledAt.timeIntervalSince(model.timelineEpoch) * 2),
                            discontinuityRevision: playbackDiscontinuityRevision,
                            sourceRevision: model.sourceRevision
                        ), initial: true) { _, request in
                            followLyrics(request, proxy: proxy, groups: groups, viewport: geometry.size)
                        }
                    }
                }
                .coordinateSpace(name: model.scrollCoordinateSpace)
                .onPreferenceChange(LyricAnchorFramePreference.self) { frames in
                    model.anchorFrames = frames
                }
                .onPreferenceChange(LyricContentOriginPreference.self) { origin in
                    model.contentOriginY = origin
                }
                .scrollIndicators(.hidden)
                .background {
                    #if os(macOS)
                    LyricScrollWheelObserver {
                        guard isActive, !isPageTransitioning, !model.isHorizontalSwiping else { return }
                        if !model.isUserScrolling { beginUserScroll() }
                        // Wheel events have no DragGesture.onEnded. Rearm on
                        // each delta, including trackpad momentum, so following
                        // resumes only after native scrolling has been idle.
                        scheduleResume(proxy: proxy, groups: groups)
                    }
                    #endif
                }
                .overlay {
                    if groups.isEmpty {
                        Text("暂无歌词").font(.system(size: 16)).foregroundStyle(.gray)
                    }
                }
                .simultaneousGesture(
                    DragGesture(minimumDistance: 2)
                        .onChanged { value in
                            let horizontal = abs(value.translation.width)
                            let vertical = abs(value.translation.height)
                            if handlesHorizontalSwipe && horizontal > max(8, vertical * 1.15) {
                                model.beginHorizontalSwipe()
                            } else if vertical > horizontal {
                                beginUserScroll()
                            }
                        }
                        .onEnded { value in
                            // A diagonal drag can begin as a vertical scroll
                            // and finish horizontally. Always rearm following.
                            if model.isUserScrolling {
                                scheduleResume(proxy: proxy, groups: groups)
                            }
                            if handlesHorizontalSwipe {
                                finishHorizontalSwipe(value)
                                model.endHorizontalSwipe()
                            }
                        }
                )
                .onChange(of: groups.first?.id) { _, _ in
                    followCurrentLyrics(proxy: proxy, groups: groups, viewport: geometry.size)
                }
                .onChange(of: isActive) { _, active in
                    guard active else { return }
                    model.layoutDidChange()
                    followCurrentLyrics(proxy: proxy, groups: groups, viewport: geometry.size)
                }
                .onChange(of: isPageTransitioning) { _, transitioning in
                    if transitioning { model.layoutDidChange() }
                    else { followCurrentLyrics(proxy: proxy, groups: groups, viewport: geometry.size) }
                }
                .onChange(of: model.isHorizontalSwiping) { _, swiping in
                    if !swiping { followCurrentLyrics(proxy: proxy, groups: groups, viewport: geometry.size) }
                }
                .onChange(of: geometry.size) { _, newSize in
                    model.layoutDidChange()
                    guard lyricViewportIsUsable(newSize) else { return }
                    let snapshot = model.sync(
                        timeMs: model.lastPresentationTimeMs,
                        lineTransitionLeadMs: lineTransitionLeadMs
                    )
                    let index = snapshot.scrollTargetIndex
                    guard groups.indices.contains(index) else { return }
                    scrollImmediately(proxy: proxy, to: groups[index].id)
                }
            }
        }
    }

    private func lyricRow(
        group: LyricGroup, index: Int, groups: [LyricGroup], snapshot: LyricTimelineSnapshot,
        time: Int64, sampledAt: Date, updatesFrames: Bool, viewport: CGSize,
        hasDuet: Bool, proxy: ScrollViewProxy
    ) -> some View {
        let timelineTime = time
        let active = snapshot.playingIndices.contains(index)
        let gap = model.interludeGaps[index]
        let showsInterlude = gap.map {
            shouldShowLyricInterlude(
                previousEndTimeMs: $0.startTime,
                nextStartTimeMs: $0.endTime,
                currentTimeMs: timelineTime,
                hasActiveLyrics: !snapshot.playingIndices.isEmpty
            )
        } ?? false
        return VStack(alignment: group.main.isDuet ? .trailing : .leading, spacing: 0) {
            if let gap {
                // Keep the slot mounted and animate its occupied height.
                // This pushes every following lyric down instead of
                // instantly inserting a full-height row into the stack.
                VerticalLyricRevealLayout(progress: showsInterlude ? 1 : 0, attachedAbove: false) {
                    LyricInterludeView(
                        gap: gap, timeMs: timelineTime, sampledAt: sampledAt,
                        playbackRate: style.playbackRate, updatesFrames: updatesFrames && showsInterlude,
                        color: style.activeColor, trailing: group.main.isDuet
                    )
                    .padding(.bottom, style.lineSpacing)
                    .opacity(showsInterlude ? 1 : 0)
                }
                .allowsHitTesting(false)
                .accessibilityHidden(!showsInterlude)
            }
            LyricGroupView(
                group: group,
                currentTimeMs: active ? time : 0,
                isProgressFrozen: model.hasPendingTap,
                sampledAt: sampledAt,
                mediaClock: model.mediaClock,
                currentTimeProvider: currentTimeProvider,
                clockRevision: playbackDiscontinuityRevision,
                active: active,
                highlighted: snapshot.highlightedIndices.contains(index),
                rapidTransition: model.rapidTransitions[index],
                blurRadius: lyricUpcomingBlurRadius(
                    index: index,
                    focusIndex: snapshot.highlightedIndices.max() ?? snapshot.scrollTargetIndex,
                    isUpcoming: timelineTime < group.renderBounds.startTime,
                    isFocused: active || snapshot.highlightedIndices.contains(index),
                    isUserScrolling: model.isUserScrolling,
                    enabled: style.enableBlur && isActive && !isPageTransitioning && !model.isHorizontalSwiping,
                    fontSize: style.fontSize,
                    maximumRadius: style.maximumBlurRadius
                ),
                isPlaying: isPlaying && isActive
                    && !isPageTransitioning && !model.isHorizontalSwiping,
                isUserScrolling: model.isUserScrolling,
                reduceEffects: !isActive || isPageTransitioning || model.isHorizontalSwiping,
                disableTransforms: reduceMotion,
                style: style,
                styleSignature: .init(style),
                showTranslation: showTranslation,
                showRomanization: showRomanization,
                onTap: {
                    if currentTimeProvider != nil {
                        // The real seek publishes its clock revision.
                        // Do not render an invented lyric position first.
                        model.resumeAutomaticFollowing()
                        onLineTap(group.main)
                        return
                    }
                    model.selectLineForSeeking(index: index)
                    onLineTap(group.main)
                    model.scheduleAutoScroll(index: index, force: true) {
                        scroll(
                            proxy: proxy, to: group.id,
                            index: index, groups: groups,
                            isSeeking: true,
                            animated: model.allowsAnimatedScroll
                        )
                    }
                }
            )
            .equatable()
            .id(model.sourceRevision)
        }
        // Animate the whole group, including the lyric's placement.
        // On exit, the dots' slot collapses as the next lyric rises
        // into it, rather than only animating the indicator itself.
        .animation(
            isActive && !isPageTransitioning && !model.isHorizontalSwiping
                && !model.isUserScrolling && !snapshot.isSeeking && !reduceMotion
                ? (showsInterlude
                    ? .interpolatingSpring(mass: 0.9, stiffness: 115, damping: 16, initialVelocity: 0)
                    : .easeInOut(duration: 0.45))
                : nil,
            value: showsInterlude
        )
        .id(group.id)
        .frame(maxWidth: max(0, viewport.width - style.horizontalPadding * (hasDuet ? 4 : 2)) * style.lineWidthFraction,
               alignment: group.main.isDuet ? .trailing : .leading)
        .frame(maxWidth: .infinity, alignment: group.main.isDuet ? .trailing : .leading)
        .modifier(LyricLineTransitionModifier(
            transition: model.lineTransition, index: index,
            coordinateSpace: model.scrollCoordinateSpace,
            contentCoordinateSpace: model.contentCoordinateSpace,
            frameDate: sampledAt,
            enabled: isActive && !isPageTransitioning
                && !model.isHorizontalSwiping && !reduceMotion
        ))
        .background {
            // Capture enough neighbors for the next step without
            // measuring every previously realized row while browsing.
            if abs(index - snapshot.scrollTargetIndex) <= 8 {
                GeometryReader { row in
                    Color.clear.preference(
                        key: LyricAnchorFramePreference.self,
                        value: [index: row.frame(in: .named(model.scrollCoordinateSpace))]
                    )
                }
            }
        }
    }

    private func followCurrentLyrics(proxy: ScrollViewProxy, groups: [LyricGroup], viewport: CGSize) {
        let snapshot = model.sync(
            timeMs: model.lastPresentationTimeMs,
            lineTransitionLeadMs: lineTransitionLeadMs
        )
        followLyrics(.init(
            index: snapshot.scrollTargetIndex,
            isSeeking: snapshot.isSeeking,
            lineBoundaryIndex: snapshot.playingIndices.max()
        ), proxy: proxy, groups: groups, viewport: viewport)
    }

    private func followLyrics(
        _ request: LyricScrollRequest,
        proxy: ScrollViewProxy,
        groups: [LyricGroup],
        viewport: CGSize
    ) {
        guard isActive, !isPageTransitioning, !model.isHorizontalSwiping else { return }
        if let boundaryIndex = request.lineBoundaryIndex, !model.hasPendingTap {
            model.scheduleClockCalibration(index: boundaryIndex) { onLineBoundary() }
        }
        guard lyricViewportIsUsable(viewport), !model.isUserScrolling,
              groups.indices.contains(request.index) else { return }
        let needsCorrection = model.anchorNeedsCorrection(
            index: request.index, viewportHeight: viewport.height, alignPosition: style.alignPosition
        )
        model.scheduleAutoScroll(index: request.index, force: needsCorrection) {
            scroll(
                proxy: proxy, to: groups[request.index].id,
                index: request.index, groups: groups,
                isSeeking: request.isSeeking, animated: model.allowsAnimatedScroll
            )
        }
    }

    private func finishHorizontalSwipe(_ value: DragGesture.Value) {
        let horizontal = value.translation.width
        let projected = value.predictedEndTranslation.width
        guard abs(horizontal) > abs(value.translation.height) * 1.15 else { return }
        if horizontal >= 52 || projected >= 120 {
            onHorizontalSwipe(.previous)
        } else if horizontal <= -52 || projected <= -120 {
            onHorizontalSwipe(.next)
        }
    }

    private func scroll(
        proxy: ScrollViewProxy,
        to id: String,
        index: Int,
        groups: [LyricGroup],
        isSeeking: Bool,
        animated: Bool = true
    ) {
        if isSeeking {
            model.beginLineTransition(index: index, enabled: false)
            scrollImmediately(proxy: proxy, to: id)
            return
        }
        let interval = groups.indices.contains(index - 1) ? groups[index].main.startTime - groups[index - 1].main.startTime : nil
        let interlude = model.interludeGaps[safe: index].flatMap { $0 } != nil
        let parameters = lyricScrollSpringPolicy(isSeeking: isSeeking, isInterludeActive: interlude, intervalMs: interval)
        let animation = Animation.interpolatingSpring(
            mass: parameters.mass,
            stiffness: parameters.stiffness,
            damping: parameters.damping,
            initialVelocity: 0
        )
        var transaction = Transaction()
        transaction.disablesAnimations = true
        let usesLineSprings = withTransaction(transaction) {
            let prepared = model.beginLineTransition(
                index: index, enabled: animated && !reduceMotion && !isSeeking && !interlude
            )
            if prepared { scrollImmediately(proxy: proxy, to: id) }
            return prepared
        }
        guard !usesLineSprings else { return }
        if animated && !reduceMotion {
            withAnimation(animation) {
                proxy.scrollTo(id, anchor: .init(x: 0.5, y: style.alignPosition))
            }
        } else {
            scrollImmediately(proxy: proxy, to: id)
        }
    }

    private func scrollImmediately(proxy: ScrollViewProxy, to id: String) {
        var transaction = Transaction()
        transaction.animation = nil
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            proxy.scrollTo(id, anchor: .init(x: 0.5, y: style.alignPosition))
        }
    }

    private func beginUserScroll() {
        withAnimation(.easeOut(duration: 0.16)) { model.beginUserScroll() }
    }

    private func scheduleResume(proxy: ScrollViewProxy, groups: [LyricGroup]) {
        model.resumeTask?.cancel()
        model.resumeTask = Task { @MainActor in
            try? await Task.sleep(for: style.userScrollResumeDelay)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.2)) { model.isUserScrolling = false }
            let latest = model.sync(
                timeMs: model.lastPresentationTimeMs,
                lineTransitionLeadMs: lineTransitionLeadMs
            )
            guard groups.indices.contains(latest.scrollTargetIndex) else { return }
            scroll(
                proxy: proxy,
                to: groups[latest.scrollTargetIndex].id,
                index: latest.scrollTargetIndex,
                groups: groups,
                isSeeking: latest.isSeeking,
                animated: model.allowsAnimatedScroll
            )
        }
    }
}

func lyricViewportIsUsable(_ size: CGSize) -> Bool {
    size.width.isFinite && size.height.isFinite && size.width > 1 && size.height > 1
}

func lyricRenderingShouldAnimate(
    isPlaying: Bool,
    frameInterpolationEnabled: Bool,
    isActive: Bool,
    isPageTransitioning: Bool
) -> Bool {
    isPlaying && frameInterpolationEnabled && isActive && !isPageTransitioning
}

func lyricTimelineInterval(
    largeScreenOptimizations: Bool,
    updatesFrames: Bool,
    rapidTransitions: Bool = false
) -> TimeInterval {
    guard updatesFrames else { return 3_600 }
    if rapidTransitions { return 1.0 / 60.0 }
    // Without a live provider, coarse samples use the lightweight fallback.
    // A live provider requests display-rate boundary checks via rapidTransitions.
    return 1.0 / 10.0
}

struct LyricSourceSignature: Equatable {
    // Array equality short-circuits shared storage during ordinary playback,
    // but still detects changed middle timestamps/text in a replacement source.
    let lines: [LyricLine]
    let options: OptimizeLyricOptions

    init(lines: [LyricLine], options: OptimizeLyricOptions) {
        self.lines = lines
        self.options = options
    }
}

private struct LyricScrollRequest: Equatable {
    var index: Int
    var isSeeking: Bool
    var lineBoundaryIndex: Int?
    var positionCheckTick: Int = 0
    var discontinuityRevision: UInt = 0
    var sourceRevision: UInt = 0
}

private struct LyricAnchorFramePreference: PreferenceKey {
    static let defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct LyricContentOriginPreference: PreferenceKey {
    static let defaultValue: CGFloat? = nil
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        if let next = nextValue() { value = next }
    }
}

@MainActor
final class LyricsViewModel: ObservableObject {
    @Published var isUserScrolling = false
    @Published private(set) var isHorizontalSwiping = false
    @Published private(set) var groups: [LyricGroup]
    private(set) var rapidTransitions: [Bool]
    private(set) var interludeGaps: [LyricTimeBounds?]
    private(set) var renderTimeMs: Int64
    private var tapSelection: LyricTapSelection?
    @Published private(set) var selectionRevision: UInt = 0
    @Published private(set) var sourceRevision: UInt = 0
    let mediaClock = LyricMediaClock()
    private var observedPlaybackRevision: UInt?
    private var needsTimelineReanchor = false
    @Published private(set) var lineTransition: LyricLineTransition?
    private(set) var lineTransitionTask: Task<Void, Never>?
    private var previousTransitionIndex: Int?
    var hasPendingTap: Bool { tapSelection != nil }
    var resumeTask: Task<Void, Never>?
    private var horizontalSwipeTask: Task<Void, Never>?
    private(set) var tapReconciliationTask: Task<Void, Never>?
    private(set) var autoScrollTask: Task<Void, Never>?
    private var clockCalibrationTask: Task<Void, Never>?
    let timelineEpoch = Date()
    private var timeline: LyricTimeline
    private var transitionLeadMs: Int64 = 0
    private var wrappedCache: [LyricGroup] = []
    private var wrapKey: [CGFloat] = []
    private var interpolator: PlaybackTimeInterpolator
    private(set) var lastPresentationTimeMs: Int64
    private(set) var sourceSignature: LyricSourceSignature?
    let scrollCoordinateSpace = UUID()
    let contentCoordinateSpace = UUID()
    var contentOriginY: CGFloat?
    var anchorFrames: [Int: CGRect] = [:]
    private var lastAutoScrollDate = Date.distantPast
    private var lastAutoScrollTarget: Int?
    private var lastCalibratedLineIndex: Int?
    private var suppressAnimatedScrollUntil = Date.distantPast

    init(groups: [LyricGroup], timeMs: Int64) {
        self.groups = groups
        interludeGaps = lyricInterludeGaps(bounds: groups.map(\.renderBounds))
        renderTimeMs = timeMs
        rapidTransitions = lyricRapidTransitionFlags(bounds: groups.map(\.renderBounds))
        timeline = Self.makeTimeline(groups)
        interpolator = .init(initialSourceTimeMs: timeMs)
        lastPresentationTimeMs = timeMs
    }

    func wrappedGroups(width: CGFloat, fontSize: CGFloat, backgroundScale: CGFloat) -> [LyricGroup] {
        let key = [width, fontSize, backgroundScale]
        if wrapKey != key {
            wrappedCache = groups.map { group in
                var result = group
                result.mainChunks = wrapOversizedLyricChunks(group.mainChunks, width: width, fontSize: fontSize)
                result.backgroundChunks = wrapOversizedLyricChunks(group.backgroundChunks, width: width, fontSize: fontSize * backgroundScale)
                result.wrappingWidth = width
                return result
            }
            wrapKey = key
        }
        return wrappedCache
    }

    func needsRapidLineUpdates(timeMs: Int64) -> Bool {
        groups.indices.contains { index in
            let bounds = groups[index].renderBounds
            return rapidTransitions[index] && timeMs >= bounds.startTime - 200 && timeMs <= bounds.endTime
        }
    }

    func sync(timeMs: Int64, lineTransitionLeadMs: Int64 = 0, now: Date = .now) -> LyricTimelineSnapshot {
        let lead = max(0, lineTransitionLeadMs)
        if lead != transitionLeadMs {
            transitionLeadMs = lead
            timeline = Self.makeTimeline(groups, lineTransitionLeadMs: lead)
        }
        let resolution = tapSelection?.resolve(mediaTimeMs: timeMs, now: now)
        renderTimeMs = resolution?.timeMs ?? timeMs
        let shouldReconcile = tapSelection != nil && resolution?.holdsSelection != true
        if shouldReconcile { tapSelection = nil }
        var snapshot = timeline.sync(timeMs: renderTimeMs, forceSeek: shouldReconcile || needsTimelineReanchor)
        needsTimelineReanchor = false
        if let selection = tapSelection { snapshot.scrollTargetIndex = selection.index }
        return snapshot
    }

    func reanchorPlayback(timeMs: Int64, revision: UInt) {
        guard observedPlaybackRevision != revision else { return }
        observedPlaybackRevision = revision
        cancelTasks()
        mediaClock.invalidate()
        interpolator = .init(initialSourceTimeMs: timeMs)
        lastPresentationTimeMs = timeMs
        renderTimeMs = timeMs
        needsTimelineReanchor = true
        lastAutoScrollTarget = nil
        lastCalibratedLineIndex = nil
        suppressAnimatedScrollUntil = Date.now.addingTimeInterval(0.35)
        selectionRevision &+= 1
    }

    /// Animates a shared content displacement with ordered per-row delays.
    /// Individual lyric frames never become independent animation targets.
    @discardableResult
    func beginLineTransition(index: Int, enabled: Bool, now: Date = .now) -> Bool {
        let previous = previousTransitionIndex
        previousTransitionIndex = index
        guard enabled else {
            lineTransitionTask?.cancel()
            lineTransition = nil
            return false
        }
        guard previous != index else { return false }
        guard let previous, (1...3).contains(index - previous),
              anchorFrames[index] != nil, let contentOriginY else {
            lineTransitionTask?.cancel()
            lineTransition = nil
            return false
        }
        let rapid = rapidTransitions[safe: index] == true
        lineTransition = lineTransition?.appendingStep(index: index, at: now, contentOriginY: contentOriginY, rapid: rapid)
            ?? .init(focusIndex: index, startDate: now, contentOriginY: contentOriginY, rapid: rapid)
        scheduleLineTransitionCompletion()
        return true
    }

    private func scheduleLineTransitionCompletion() {
        lineTransitionTask?.cancel()
        guard let duration = lineTransition?.duration else { return }
        lineTransitionTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            self?.lineTransition = nil
        }
    }

    /// Hand manual scrolling the current picture, not the already-final native
    /// anchor. Residual drawing offsets fade while native input moves freely.
    private func releaseLineTransition(now: Date = .now) {
        previousTransitionIndex = nil
        guard let motion = lineTransition, let contentOriginY else { return }
        lineTransition = motion.released(at: now, contentOriginY: contentOriginY)
        scheduleLineTransitionCompletion()
    }

    private func cancelLineTransition() {
        lineTransitionTask?.cancel()
        lineTransition = nil
        previousTransitionIndex = nil
    }

    func selectLineForSeeking(index: Int, now: Date = .now) {
        guard groups.indices.contains(index) else { return }
        resumeAutomaticFollowing()
        let time = lyricTapSeekTime(line: groups[index].main, lyricOffsetMs: 0)
        tapSelection = .init(index: index, timeMs: time, date: now)
        selectionRevision &+= 1
        renderTimeMs = time
        _ = timeline.sync(timeMs: time, forceSeek: true)
        tapReconciliationTask?.cancel()
        tapReconciliationTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self, self.tapSelection != nil else { return }
            self.tapSelection = nil
            // Also reconcile when playback is paused and there are no media
            // samples or display ticks to end the optimistic selection.
            _ = self.timeline.sync(timeMs: self.lastPresentationTimeMs, forceSeek: true)
            self.selectionRevision &+= 1
        }
    }

    func reset(groups: [LyricGroup], timeMs: Int64, sourceSignature: LyricSourceSignature) {
        cancelTasks()
        isUserScrolling = false
        isHorizontalSwiping = false
        self.groups = groups
        interludeGaps = lyricInterludeGaps(bounds: groups.map(\.renderBounds))
        renderTimeMs = timeMs
        rapidTransitions = lyricRapidTransitionFlags(bounds: groups.map(\.renderBounds))
        wrappedCache = []
        wrapKey = []
        anchorFrames = [:]
        self.sourceSignature = sourceSignature
        sourceRevision &+= 1
        mediaClock.invalidate()
        needsTimelineReanchor = true
        suppressAnimatedScrollUntil = Date.now.addingTimeInterval(0.35)
        timeline = Self.makeTimeline(groups, lineTransitionLeadMs: transitionLeadMs)
        interpolator = .init(initialSourceTimeMs: timeMs)
        lastPresentationTimeMs = timeMs
        lastAutoScrollTarget = nil
        lastCalibratedLineIndex = nil
        _ = timeline.sync(timeMs: timeMs, forceSeek: true)
    }

    func scheduleClockCalibration(
        index: Int,
        action: @escaping @MainActor @Sendable () -> Void
    ) {
        guard lastCalibratedLineIndex != index else { return }
        lastCalibratedLineIndex = index
        clockCalibrationTask?.cancel()
        clockCalibrationTask = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled else { return }
            action()
        }
    }

    func anchorNeedsCorrection(index: Int, viewportHeight: CGFloat, alignPosition: CGFloat) -> Bool {
        guard !isUserScrolling, !isHorizontalSwiping, lineTransition == nil,
              Date.now.timeIntervalSince(lastAutoScrollDate) >= 1 else { return false }
        // A lazy row outside the realized area also needs to be brought back.
        guard let frame = anchorFrames[index] else { return true }
        let expectedTop = (viewportHeight - frame.height) * alignPosition
        return abs(frame.minY - expectedTop) > 4
    }

    func scheduleAutoScroll(index: Int, force: Bool = false, action: @escaping @MainActor () -> Void) {
        guard force || lastAutoScrollTarget != index else { return }
        autoScrollTask?.cancel()
        let prioritizeHighlight = rapidTransitions[safe: index] == true
        autoScrollTask = Task { @MainActor [weak self] in
            await Task.yield()
            // Give the clear, audio-timed row a display opportunity before
            // moving the stack. A newer line cancels this pending motion.
            if prioritizeHighlight { try? await Task.sleep(for: .milliseconds(32)) }
            guard !Task.isCancelled, let self, force || self.lastAutoScrollTarget != index else { return }
            self.lastAutoScrollTarget = index
            self.lastAutoScrollDate = .now
            action()
        }
    }

    var allowsAnimatedScroll: Bool { Date.now >= suppressAnimatedScrollUntil }

    func layoutDidChange() {
        cancelLineTransition()
        resumeTask?.cancel()
        autoScrollTask?.cancel()
        resumeTask = nil
        autoScrollTask = nil
        lastAutoScrollTarget = nil
        isUserScrolling = false
        suppressAnimatedScrollUntil = Date.now.addingTimeInterval(0.35)
    }

    func resumeAutomaticFollowing() {
        resumeTask?.cancel()
        autoScrollTask?.cancel()
        resumeTask = nil
        autoScrollTask = nil
        lastAutoScrollTarget = nil
        isUserScrolling = false
    }

    func beginUserScroll() {
        if !isUserScrolling { releaseLineTransition() }
        tapSelection = nil
        resumeTask?.cancel()
        autoScrollTask?.cancel()
        isUserScrolling = true
        lastAutoScrollTarget = nil
    }

    func beginHorizontalSwipe() {
        cancelLineTransition()
        resumeTask?.cancel()
        autoScrollTask?.cancel()
        isUserScrolling = false
        lastAutoScrollTarget = nil
        guard !isHorizontalSwiping else { return }
        var transaction = Transaction()
        transaction.animation = nil
        transaction.disablesAnimations = true
        withTransaction(transaction) { isHorizontalSwiping = true }
    }

    func endHorizontalSwipe() {
        horizontalSwipeTask?.cancel()
        horizontalSwipeTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(260))
            guard !Task.isCancelled else { return }
            self?.isHorizontalSwiping = false
        }
    }

    func cancelTasks() {
        cancelLineTransition()
        tapSelection = nil
        resumeTask?.cancel()
        horizontalSwipeTask?.cancel()
        tapReconciliationTask?.cancel()
        autoScrollTask?.cancel()
        clockCalibrationTask?.cancel()
        lastAutoScrollTarget = nil
        isUserScrolling = false
        isHorizontalSwiping = false
    }

    func presentationTime(
        sourceTimeMs: Int64,
        frameDate: Date,
        isPlaying: Bool,
        enabled: Bool,
        playbackRate: Double,
        discontinuityRevision: UInt,
        authoritative: Bool = false
    ) -> Int64 {
        let seconds = max(frameDate.timeIntervalSince1970, 0)
        let nanoseconds = UInt64(min(seconds * 1_000_000_000, Double(UInt64.max)))
        lastPresentationTimeMs = interpolator.update(
            sourceTimeMs: sourceTimeMs,
            frameNanoseconds: nanoseconds,
            isPlaying: isPlaying && enabled && !authoritative,
            playbackRate: playbackRate,
            discontinuityRevision: discontinuityRevision
        )
        return lastPresentationTimeMs
    }

    private static func makeTimeline(_ groups: [LyricGroup], lineTransitionLeadMs: Int64 = 0) -> LyricTimeline {
        .init(
            bounds: groups.map { .init(startTime: $0.renderBounds.startTime, endTime: $0.renderBounds.endTime) },
            lineTransitionLeadMs: lineTransitionLeadMs
        )
    }

    deinit {
        lineTransitionTask?.cancel()
        resumeTask?.cancel()
        horizontalSwipeTask?.cancel()
        tapReconciliationTask?.cancel()
        autoScrollTask?.cancel()
        clockCalibrationTask?.cancel()
    }
}

private struct LyricRenderStyleSignature: Equatable, Sendable {
    let fontSize: CGFloat
    let secondaryFontSize: CGFloat
    let activeColor: Color
    let inactiveColor: Color
    let wordFadeWidth: CGFloat
    let enableFrameInterpolation: Bool
    let playbackRate: Double
    let enableScale: Bool
    let backgroundLineScale: CGFloat
    let alwaysPostpositionBackground: Bool

    @MainActor init(_ style: AppleMusicLyricsStyle) {
        fontSize = style.fontSize
        secondaryFontSize = style.secondaryFontSize
        activeColor = style.activeColor
        inactiveColor = style.inactiveColor
        wordFadeWidth = style.wordFadeWidth
        enableFrameInterpolation = style.enableFrameInterpolation
        playbackRate = style.playbackRate
        enableScale = style.enableScale
        backgroundLineScale = style.backgroundLineScale
        alwaysPostpositionBackground = style.alwaysPostpositionBackground
    }
}

private struct LyricGroupView: View, Equatable {
    let group: LyricGroup
    let currentTimeMs: Int64
    let isProgressFrozen: Bool
    let sampledAt: Date
    let mediaClock: LyricMediaClock
    let currentTimeProvider: (@MainActor () -> Int64)?
    let clockRevision: UInt
    let active: Bool
    let highlighted: Bool
    let rapidTransition: Bool
    let blurRadius: CGFloat
    let isPlaying: Bool
    let isUserScrolling: Bool
    let reduceEffects: Bool
    let disableTransforms: Bool
    let style: AppleMusicLyricsStyle
    let styleSignature: LyricRenderStyleSignature
    let showTranslation: Bool
    let showRomanization: Bool
    let onTap: () -> Void
    @State private var isVisible = true
    @State private var isHovered = false

    private var animatesWords: Bool {
        !isProgressFrozen && !group.main.isLineTimed && active && isVisible && isPlaying && !reduceEffects && style.enableFrameInterpolation
    }

    var body: some View {
        Button(action: onTap) { lyricContent }
            .buttonStyle(LyricLineButtonStyle(color: style.activeColor, reduceMotion: disableTransforms || reduceEffects))
            .onHover { isHovered = $0 }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(group.main.text)
            .accessibilityHint("跳转到此句歌词")
            .accessibilityAddTraits(.isButton)
            .accessibilityAddTraits(active ? .isSelected : [])
            .onAppear { isVisible = true }
            .onDisappear { isVisible = false }
    }

    private var displayStyle: AppleMusicLyricsStyle {
        var result = style
        if isUserScrolling || isHovered { result.inactiveColor = style.activeColor.opacity(0.55) }
        return result
    }

    @ViewBuilder private var lyricContent: some View {
        let targetScale: CGFloat = style.enableScale && !disableTransforms && !reduceEffects && !highlighted && !isUserScrolling && !isHovered && isPlaying ? 0.97 : 1
        // Let the display choose its native cadence, including ProMotion.
        // Only active rows tick here; rapid passages also poll boundaries faster.
        TimelineView(.animation(minimumInterval: nil, paused: !animatesWords)) { frame in
            let elapsed = animatesWords ? max(0, frame.date.timeIntervalSince(sampledAt)) : 0
            // Live playback uses the shared authoritative frame sample. Only
            // callers without a media provider extrapolate a coarse sample;
            // overlapping voices never query the player independently.
            let time = !isProgressFrozen && currentTimeProvider != nil
                ? mediaClock.sample(provider: currentTimeProvider, fallback: currentTimeMs, revision: clockRevision)
                : (animatesWords ? currentTimeMs + Int64(elapsed * 1_000 * style.playbackRate) : currentTimeMs)
            groupContent(timeMs: time)
                // A scroll transaction must never tween the audio-driven
                // mask or delay insertion of the newly active highlight.
                .transaction { $0.animation = nil }
        }
        // These effects depend on line state, not word progress. Keep them
        // outside the display-linked subtree so each frame only updates words.
        .padding(.vertical, style.fontSize * 0.4)
        .animation(active || highlighted ? nil : .easeInOut(duration: 0.4)) { content in
            content
                .foregroundStyle(highlighted ? style.activeColor : displayStyle.inactiveColor)
                .opacity(lyricLineOpacity(isHighlighted: highlighted))
        }
        .animation(reduceEffects || disableTransforms ? nil : .spring(response: 0.55, dampingFraction: 0.9).delay(rapidTransition ? 0.06 : 0)) { content in
            content.scaleEffect(targetScale, anchor: group.main.isDuet ? .trailing : .leading)
        }
        // Focus changes precede the first sung word. Remove blur immediately
        // on activation, independently of the line's scale/opacity animation.
        .animation(active || highlighted || disableTransforms || reduceEffects ? nil : .easeInOut(duration: 0.4)) { content in
            content.blur(radius: active || highlighted || isHovered ? 0 : blurRadius)
        }
        .animation(.easeOut(duration: 0.18), value: isUserScrolling)
        .animation(.easeOut(duration: 0.18), value: isHovered)
        .animation(nil, value: reduceEffects)
        .contentShape(Rectangle())
        .background {
            RoundedRectangle(cornerRadius: 12)
                .fill(style.activeColor.opacity(isHovered ? 0.08 : 0))
                .padding(.horizontal, -8)
        }
    }

    private func groupContent(timeMs: Int64) -> some View {
        let backgroundFirst = !style.alwaysPostpositionBackground
            && (group.background?.words.first?.startTime ?? .max) < (group.main.words.first?.startTime ?? group.main.startTime)
        return VStack(
            alignment: group.main.isDuet ? .trailing : .leading,
            spacing: style.fontSize * 0.3
        ) {
            if backgroundFirst { background(attachedAbove: true, timeMs: timeMs) }
            line(group.main, chunks: group.mainChunks, scale: 1, timeMs: timeMs)
            if !backgroundFirst { background(attachedAbove: false, timeMs: timeMs) }
        }
    }

    /// Compares by identity rather than by content.
    ///
    /// Every rendered lyric runs this check on every frame, and the lyrics that
    /// stay realized in the lazy stack only accumulate as a song plays, so a
    /// content comparison — which walks every word, ruby and roman string of
    /// every lyric on screen — made rendering progressively more expensive the
    /// longer playback ran. A group's content is fixed for its identity: new
    /// lyrics arrive as a new source, which rebuilds every group.
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.group.id == rhs.group.id
            && lhs.group.wrappingWidth == rhs.group.wrappingWidth
            && lhs.group.renderBounds == rhs.group.renderBounds
            && lhs.group.mainChunks.count == rhs.group.mainChunks.count
            && lhs.group.backgroundChunks.count == rhs.group.backgroundChunks.count
            && lhs.clockRevision == rhs.clockRevision
            && (lhs.currentTimeProvider == nil) == (rhs.currentTimeProvider == nil)
            && lhs.currentTimeMs == rhs.currentTimeMs
            && lhs.isProgressFrozen == rhs.isProgressFrozen
            && lhs.active == rhs.active
            && lhs.highlighted == rhs.highlighted
            && lhs.rapidTransition == rhs.rapidTransition
            && lhs.blurRadius == rhs.blurRadius
            && lhs.isPlaying == rhs.isPlaying
            && lhs.isUserScrolling == rhs.isUserScrolling
            && lhs.reduceEffects == rhs.reduceEffects
            && lhs.disableTransforms == rhs.disableTransforms
            && lhs.styleSignature == rhs.styleSignature
            && lhs.showTranslation == rhs.showTranslation
            && lhs.showRomanization == rhs.showRomanization
    }

    @ViewBuilder private func background(attachedAbove: Bool, timeMs: Int64) -> some View {
        if let background = group.background {
            let revealed = active || !isPlaying || isUserScrolling
            VerticalLyricRevealLayout(
                progress: revealed ? 1 : 0,
                attachedAbove: attachedAbove
            ) {
                line(background, chunks: group.backgroundChunks, scale: style.backgroundLineScale, timeMs: timeMs)
                    .opacity(revealed ? 0.4 : 0)
                    .scaleEffect(
                        x: disableTransforms || revealed ? 1 : 0.9,
                        y: disableTransforms || revealed ? 1 : 0.72,
                        anchor: attachedAbove ? .bottom : .top
                    )
                    .offset(y: disableTransforms || revealed ? 0 : (attachedAbove ? 10 : -10))
            }
            // Height and opacity animate the reveal; clipping here also cut
            // off the background vocal's emphasis glow at full height.
            .allowsHitTesting(revealed)
            .animation(
                disableTransforms || reduceEffects ? nil : .interpolatingSpring(mass: 0.9, stiffness: 115, damping: 16, initialVelocity: 0),
                value: revealed
            )
        }
    }

    private func line(_ line: LyricLine, chunks: [LyricWordChunk], scale: CGFloat, timeMs: Int64) -> some View {
        let hasRuby = chunks.contains { !$0.rubyText.isEmpty }
        let hasRoman = chunks.contains { !$0.romanText.isEmpty }
        let wordStyle = scaledStyle(scale)
        return VStack(alignment: line.isDuet ? .trailing : .leading, spacing: 0) {
            BalancedLyricLayout(
                trailingAlignment: line.isDuet,
                spaces: chunks.map(\.isSpace),
                singleCharacterWords: chunks.map(\.isSingleCJKCharacter),
                breakOpportunities: chunks.map(\.breakAfter),
                forcedBreaks: chunks.map(\.forcesBreakAfter)
            ) {
                ForEach(chunks) { chunk in
                    if line.isLineTimed {
                        Text(chunk.displayText)
                            .font(.system(size: wordStyle.fontSize, weight: .bold, design: .default))
                            .foregroundStyle(active ? style.activeColor : displayStyle.inactiveColor)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        TimedChunkView(
                            chunk: chunk, progress: active ? lyricChunkProgress(words: chunk.words, timeMs: timeMs) : 0,
                            emphasisProgress: active ? lyricEmphasisProgress(words: chunk.words, timeMs: timeMs) : 0,
                            active: active, style: wordStyle,
                            lift: active ? lyricWordLift(words: chunk.words, timeMs: timeMs - (rapidTransition ? 60 : 0)) : 0,
                            effectsEnabled: !reduceEffects && !disableTransforms,
                            backgroundVocal: line.isBackground,
                            usesFrameClock: animatesWords,
                            hasRubyLine: hasRuby, hasRomanLine: hasRoman
                        )
                        .equatable()
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .animation(
                disableTransforms || reduceEffects || isUserScrolling ? nil : .spring(response: 0.38, dampingFraction: 0.92),
                value: group.wrappingWidth
            )
            .animation(
                disableTransforms || reduceEffects || isUserScrolling ? nil : .spring(response: 0.38, dampingFraction: 0.92),
                value: wordStyle.fontSize
            )
            if showTranslation, !line.translatedLyric.isEmpty {
                Text(line.translatedLyric)
                    .font(.system(size: style.secondaryFontSize * scale, weight: .semibold, design: .default))
                    .foregroundStyle(style.activeColor.opacity(0.3))
                    .lineSpacing(max(0, style.fontSize * scale * 0.75 - style.secondaryFontSize * scale * 1.2))
                    .frame(minHeight: style.fontSize * scale * 0.75)
            }
            if showRomanization, !line.romanLyric.isEmpty {
                Text(line.romanLyric)
                    .font(.system(size: style.secondaryFontSize * scale, weight: .semibold, design: .default))
                    .foregroundStyle(style.activeColor.opacity(0.3))
                    .lineSpacing(max(0, style.fontSize * scale * 0.75 - style.secondaryFontSize * scale * 1.2))
                    .frame(minHeight: style.fontSize * scale * 0.75)
            }
        }
    }

    private func scaledStyle(_ scale: CGFloat) -> AppleMusicLyricsStyle {
        var value = displayStyle
        value.fontSize *= scale
        value.secondaryFontSize *= scale
        return value
    }
}

/// Keep motion outside the equatable lyric subtree, so a scroll frame does
/// not remeasure text or reevaluate word masks in inactive rows.
private struct LyricLineTransitionModifier: ViewModifier {
    let transition: LyricLineTransition?
    let index: Int
    let coordinateSpace: UUID
    let contentCoordinateSpace: UUID
    let frameDate: Date
    let enabled: Bool

    func body(content: Content) -> some View {
        // One frame date for the entire stack. Independent row clocks could
        // render adjacent rows at different phases during a busy layout pass.
        content
            .visualEffect { effect, geometry in
                let origin = geometry.frame(in: .named(coordinateSpace)).minY
                    - geometry.frame(in: .named(contentCoordinateSpace)).minY
                return effect.offset(y: enabled ? transition?.offset(
                    index: index, contentOriginY: origin, at: frameDate
                ) ?? 0 : 0)
            }
            .transaction { $0.animation = nil }
    }
}

private struct LyricLineButtonStyle: ButtonStyle {
    let color: Color
    let reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background {
                RoundedRectangle(cornerRadius: 12)
                    .fill(color.opacity(configuration.isPressed ? 0.12 : 0))
                    .padding(.horizontal, -8)
            }
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: configuration.isPressed)
    }
}

/// Animates occupied height so surrounding lyrics move with the reveal.
/// Content attached above reveals from the bottom; content below from the top.
private struct VerticalLyricRevealLayout: Layout {
    var progress: CGFloat
    let attachedAbove: Bool

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        guard let subview = subviews.first else { return .zero }
        let size = subview.sizeThatFits(.init(width: proposal.width, height: nil))
        return .init(
            width: proposal.width ?? size.width,
            height: size.height * min(max(progress, 0), 1)
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        guard let subview = subviews.first else { return }
        let size = subview.sizeThatFits(.init(width: bounds.width, height: nil))
        let originY = attachedAbove ? bounds.maxY - size.height : bounds.minY
        subview.place(
            at: .init(x: bounds.minX, y: originY),
            anchor: .topLeading,
            proposal: .init(width: bounds.width, height: size.height)
        )
    }
}

private struct TimedChunkView: View, Equatable {
    let chunk: LyricWordChunk
    let progress: CGFloat
    let emphasisProgress: CGFloat
    let active: Bool
    let style: AppleMusicLyricsStyle
    let lift: Double
    let effectsEnabled: Bool
    let backgroundVocal: Bool
    let usesFrameClock: Bool

    var hasRubyLine: Bool
    var hasRomanLine: Bool

    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.chunk.id == rhs.chunk.id && lhs.progress == rhs.progress && lhs.active == rhs.active
            && lhs.emphasisProgress == rhs.emphasisProgress
            && lhs.lift == rhs.lift && lhs.effectsEnabled == rhs.effectsEnabled
            && lhs.backgroundVocal == rhs.backgroundVocal
            && lhs.usesFrameClock == rhs.usesFrameClock
            && lhs.style.fontSize == rhs.style.fontSize
            && lhs.style.secondaryFontSize == rhs.style.secondaryFontSize
            && lhs.style.wordFadeWidth == rhs.style.wordFadeWidth
            && lhs.style.activeColor == rhs.style.activeColor
            && lhs.style.inactiveColor == rhs.style.inactiveColor
            && lhs.hasRubyLine == rhs.hasRubyLine && lhs.hasRomanLine == rhs.hasRomanLine
    }
    var body: some View {
        let bleed = lyricEffectBleed(fontSize: style.fontSize, characterCount: chunk.characters.count)
        VStack(spacing: 0) {
            if hasRubyLine {
                Text(chunk.rubyText.isEmpty ? " " : chunk.rubyText)
                    .font(.system(size: style.fontSize * 0.5, weight: .bold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(height: style.fontSize * 0.5)
            }
            wordContent(bleed: bleed)
                .modifier(LyricFloatModifier(
                    offset: effectsEnabled ? -style.fontSize * (backgroundVocal ? 0.1 : 0.05) * lift : 0,
                    active: active,
                    effectsEnabled: effectsEnabled,
                    usesFrameClock: usesFrameClock
                ))
            if hasRomanLine {
                Text(chunk.romanText.isEmpty ? " " : chunk.romanText)
                    .font(.system(size: style.fontSize * 0.5, weight: .bold))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(height: style.fontSize * 0.5)
            }
        }
    }
    private func wordContent(bleed: CGFloat) -> some View {
        // Both glyph layers stay mounted for the entire active line. Swapping
        // the completed highlight into the base changed compositing at word
        // boundaries, while a newly inserted overlay had no animation history.
        chunkText()
            .foregroundStyle(active ? style.activeColor.opacity(0.4) : style.inactiveColor)
            .padding(bleed)
            .overlay {
                if active {
                    chunkText()
                        .foregroundStyle(style.activeColor)
                        .padding(bleed)
                        .mask {
                            WordProgressMask(progress: progress, fadeWidth: style.fontSize * style.wordFadeWidth, contentInset: bleed)
                        }
                        // Place the broad halo after the sweep mask so the
                        // luminous edge can feather beyond the sung glyphs.
                        .shadow(
                            color: style.activeColor.opacity(effectsEnabled ? lyricWordGlow(progress: progress, amount: chunk.emphasisAmount) : 0),
                            radius: effectsEnabled && progress > 0 && progress < 1
                                ? style.fontSize * (chunk.emphasizes ? 0.22 : 0.14) : 0
                        )
                        .transition(.identity)
                }
            }
            .padding(-bleed)
    }

    private func chunkText() -> some View {
        ChunkText(text: chunk.displayText, characters: chunk.characters, progress: emphasisProgress,
                  emphasize: chunk.emphasizes, amount: effectsEnabled ? chunk.emphasisAmount : 0, style: style)
    }
}

/// Coarse updates interpolate the pose outside the content subtree, keeping
/// the sweep mask on the audio clock. Display-linked poses need no extra tween.
private struct LyricFloatModifier: ViewModifier {
    let offset: CGFloat
    let active: Bool
    let effectsEnabled: Bool
    let usesFrameClock: Bool

    func body(content: Content) -> some View {
        content
            .transaction { $0.animation = nil }
            .offset(y: offset)
            // A display-linked clock already supplies intermediate poses.
            // Restarting an implicit animation on every frame adds work and
            // makes the pose chase a continuously moving target.
            .animation(effectsEnabled && !usesFrameClock ? .linear(duration: 0.10) : nil, value: offset)
            .animation(effectsEnabled ? .easeInOut(duration: 0.35) : nil, value: active)
    }
}

private struct ChunkText: View {
    let text: String
    let characters: [String]
    let progress: CGFloat
    let emphasize: Bool
    let amount: CGFloat
    let style: AppleMusicLyricsStyle

    var body: some View {
        if emphasize {
            let motions = characters.indices.map { index in
                calculateEmphasisCharacterMotion(
                    progress: progress, characterIndex: index,
                    characterCount: characters.count, amount: amount
                )
            }
            EmphasisGlyphLayout(scales: motions.map(\.scale)) {
                ForEach(characters.indices, id: \.self) { index in
                    let motion = motions[index]
                    Text(characters[index])
                        .font(.system(size: style.fontSize, weight: .bold, design: .default))
                        .scaleEffect(x: motion.scale, y: motion.verticalScale, anchor: .bottom)
                        .offset(x: motion.translationXEm * style.fontSize, y: motion.translationYEm * style.fontSize)
                        // Base and highlight must use the exact same pose.
                        // Independent implicit animations diverge on insertion
                        // and rapid progress updates, producing double edges.
                }
            }
        } else {
            Text(text).font(.system(size: style.fontSize, weight: .bold, design: .default))
        }
    }
}

/// Transforms may expand into drawing bleed, but the line layout always sees
/// the resting width. Both the dim glyphs and highlight use this same layout.
private struct EmphasisGlyphLayout: Layout {
    let scales: [Double]

    func makeCache(subviews: Subviews) -> [CGSize] {
        subviews.map { $0.sizeThatFits(.unspecified) }
    }

    func updateCache(_ cache: inout [CGSize], subviews: Subviews) {
        cache = makeCache(subviews: subviews)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout [CGSize]) -> CGSize {
        CGSize(width: cache.reduce(0) { $0 + $1.width }, height: cache.map(\.height).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout [CGSize]) {
        let offsets = emphasisGlyphOffsets(widths: cache.map(\.width), scales: scales)
        var x = bounds.minX
        for index in subviews.indices {
            let size = cache[index]
            subviews[index].place(
                at: CGPoint(x: x + offsets[index], y: bounds.maxY - size.height),
                anchor: .topLeading, proposal: ProposedViewSize(size)
            )
            x += size.width
        }
    }
}

private struct WordProgressMask: View {
    let progress: CGFloat
    let fadeWidth: CGFloat
    let contentInset: CGFloat

    var body: some View {
        GeometryReader { geometry in
            let stops = lyricProgressMaskStops(
                progress: progress,
                surfaceWidth: geometry.size.width,
                contentInset: contentInset,
                fadeWidth: fadeWidth
            )
            LinearGradient(
                stops: [
                    .init(color: .white, location: 0),
                    .init(color: .white, location: stops.opaqueEnd),
                    .init(color: .white.opacity(0.84), location: stops.opaqueEnd + (stops.clearStart - stops.opaqueEnd) * 0.25),
                    .init(color: .white.opacity(0.5), location: (stops.opaqueEnd + stops.clearStart) * 0.5),
                    .init(color: .white.opacity(0.16), location: stops.opaqueEnd + (stops.clearStart - stops.opaqueEnd) * 0.75),
                    .init(color: .clear, location: stops.clearStart),
                    .init(color: .clear, location: 1),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            // Keep a single mask identity at 0 and 1 too. At completion the
            // opaque band covers every glyph; no brightness handoff is needed.
            .opacity(progress <= 0 ? 0 : 1)
        }
    }
}

private struct LyricInterludeView: View {
    let gap: LyricTimeBounds
    let timeMs: Int64
    let sampledAt: Date
    let playbackRate: Double
    let updatesFrames: Bool
    let color: Color
    let trailing: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: !updatesFrames)) { frame in
            let elapsed = updatesFrames ? max(0, frame.date.timeIntervalSince(sampledAt)) : 0
            let delta = Int64(elapsed * 1_000 * playbackRate)
            let animation = calculateInterludeDotsAnimation(
                elapsedMs: timeMs - gap.startTime + delta,
                durationMs: gap.endTime - gap.startTime
            )
            InterludeDotsView(animation: animation, color: color, trailing: trailing)
        }
    }
}

private struct InterludeDotsView: View {
    let animation: InterludeDotsAnimation
    let color: Color
    let trailing: Bool

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3) { index in
                Circle().fill(color).frame(width: 8, height: 8).opacity(animation.opacities[index])
            }
        }
        .frame(maxWidth: .infinity, alignment: trailing ? .trailing : .leading)
        .frame(height: 32)
        .scaleEffect(animation.scale, anchor: trailing ? .trailing : .leading)
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? { indices.contains(index) ? self[index] : nil }
}
