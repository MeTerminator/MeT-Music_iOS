import Combine
import SwiftUI

public struct AppleMusicLyricsStyle {
    public var activeColor: Color = .white
    public var inactiveColor: Color = .white.opacity(0.2)
    public var fontSize: CGFloat = 32
    public var secondaryFontSize: CGFloat = 15
    public var lineWidthFraction: CGFloat = 0.8
    public var horizontalPadding: CGFloat = 16
    public var alignPosition: CGFloat = 0.2
    /// Complete fade-band width in em. `0.5` is half the line font size.
    public var wordFadeWidth: CGFloat = 0.5
    /// Vertical distance between lyric groups. Wrapped rows inside one lyric
    /// stay tight while separate lyrics keep Apple Music's clear visual rhythm.
    public var lineSpacing: CGFloat = 16
    public var backgroundLineScale: CGFloat = 0.7
    public var enableBlur = true
    public var enableScale = true
    public var enableFrameInterpolation = true
    public var playbackRate: Double = 1
    public var alwaysPostpositionBackground = false
    public var userScrollResumeDelay: Duration = .seconds(5)

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
        GeometryReader { geometry in
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
                            updatesFrames: updatesFrames
                        )
                    )) { context in
                        let usesAuthoritativeClock = currentTimeProvider != nil
                        let sourceTime = currentTimeProvider?() ?? currentTimeMs
                        let time = model.presentationTime(
                            sourceTimeMs: sourceTime,
                            frameDate: context.date,
                            isPlaying: isPlaying,
                            enabled: style.enableFrameInterpolation && isActive
                                && !isPageTransitioning && !model.isHorizontalSwiping
                                && !usesAuthoritativeClock,
                            playbackRate: style.playbackRate,
                            discontinuityRevision: playbackDiscontinuityRevision
                        )
                        let timelineTime = lyricTimelineTime(
                            presentationTimeMs: time,
                            lineTransitionLeadMs: lineTransitionLeadMs
                        )
                        let snapshot = model.sync(timeMs: timelineTime)
                        LazyVStack(spacing: style.lineSpacing) {
                            Color.clear.frame(height: geometry.size.height * style.alignPosition)
                            ForEach(groups.indices, id: \.self) { index in
                                let group = groups[index]
                                let active = snapshot.playingIndices.contains(index)
                                VStack(alignment: group.main.isDuet ? .trailing : .leading, spacing: style.lineSpacing) {
                                    if let previous = groups[safe: index - 1],
                                       shouldShowLyricInterlude(
                                           previousEndTimeMs: previous.renderBounds.endTime,
                                           nextStartTimeMs: group.main.startTime,
                                           currentTimeMs: timelineTime,
                                           hasActiveLyrics: !snapshot.playingIndices.isEmpty
                                       ) {
                                        InterludeDotsView(
                                            animation: calculateInterludeDotsAnimation(
                                                elapsedMs: timelineTime - previous.renderBounds.endTime,
                                                durationMs: group.main.startTime - previous.renderBounds.endTime
                                            ),
                                            color: style.activeColor,
                                            trailing: group.main.isDuet
                                        )
                                    }
                                    LyricGroupView(
                                        group: group,
                                        currentTimeMs: active ? time : 0,
                                        active: active,
                                        highlighted: snapshot.highlightedIndices.contains(index),
                                        isPlaying: isPlaying && isActive
                                            && !isPageTransitioning && !model.isHorizontalSwiping,
                                        isUserScrolling: model.isUserScrolling,
                                        reduceEffects: !isActive || isPageTransitioning || model.isHorizontalSwiping,
                                        // Blurring a lyric costs an offscreen
                                        // pass, and every lyric scrolled past
                                        // stays realized, so only the ones that
                                        // can actually be on screen are blurred.
                                        disableBlur: largeScreenOptimizations
                                            || abs(index - snapshot.scrollTargetIndex) > 16,
                                        disableTransforms: largeScreenOptimizations,
                                        style: style,
                                        styleSignature: .init(style),
                                        showTranslation: showTranslation,
                                        showRomanization: showRomanization,
                                        onTap: { onLineTap(group.main) }
                                    )
                                    .equatable()
                                }
                                .id(group.id)
                                .frame(maxWidth: geometry.size.width * style.lineWidthFraction,
                                       alignment: group.main.isDuet ? .trailing : .leading)
                                .frame(maxWidth: .infinity, alignment: group.main.isDuet ? .trailing : .leading)
                            }
                            Color.clear.frame(height: geometry.size.height * (1 - style.alignPosition))
                        }
                        .padding(.horizontal, style.horizontalPadding)
                        .preference(
                            key: LyricScrollRequestKey.self,
                            value: .init(
                                index: snapshot.scrollTargetIndex,
                                isSeeking: snapshot.isSeeking,
                                lineBoundaryIndex: snapshot.playingIndices.max()
                            )
                        )
                    }
                }
                .scrollIndicators(.hidden)
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
                            if abs(value.translation.height) > abs(value.translation.width) {
                                scheduleResume(proxy: proxy, groups: groups)
                            } else if handlesHorizontalSwipe {
                                finishHorizontalSwipe(value)
                                model.endHorizontalSwipe()
                            }
                        }
                )
                .onPreferenceChange(LyricScrollRequestKey.self) { request in
                    let index = request.index
                    if let boundaryIndex = request.lineBoundaryIndex {
                        model.scheduleClockCalibration(index: boundaryIndex) {
                            onLineBoundary()
                        }
                    }
                    guard lyricViewportIsUsable(geometry.size),
                          !model.isUserScrolling,
                          groups.indices.contains(index) else { return }
                    model.scheduleAutoScroll(index: index) {
                        scroll(
                            proxy: proxy,
                            to: groups[index].id,
                            index: index,
                            groups: groups,
                            isSeeking: request.isSeeking,
                            animated: model.allowsAnimatedScroll
                        )
                    }
                }
                .onChange(of: geometry.size) { _, newSize in
                    model.layoutDidChange()
                    guard lyricViewportIsUsable(newSize) else { return }
                    let snapshot = model.sync(timeMs: lyricTimelineTime(
                        presentationTimeMs: model.lastPresentationTimeMs,
                        lineTransitionLeadMs: lineTransitionLeadMs
                    ))
                    let index = snapshot.scrollTargetIndex
                    guard groups.indices.contains(index) else { return }
                    scrollImmediately(proxy: proxy, to: groups[index].id)
                }
            }
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
        let interval = groups.indices.contains(index - 1) ? groups[index].main.startTime - groups[index - 1].main.startTime : nil
        let interlude = groups.indices.contains(index - 1) && groups[index].main.startTime - groups[index - 1].renderBounds.endTime >= 4_000
        let parameters = lyricScrollSpringPolicy(isSeeking: isSeeking, isInterludeActive: interlude, intervalMs: interval)
        let animation = Animation.interpolatingSpring(
            mass: parameters.mass,
            stiffness: parameters.stiffness,
            damping: parameters.damping,
            initialVelocity: 0
        )
        if animated {
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
        model.resumeTask?.cancel()
        if !model.isUserScrolling { withAnimation(.easeOut(duration: 0.16)) { model.isUserScrolling = true } }
    }

    private func scheduleResume(proxy: ScrollViewProxy, groups: [LyricGroup]) {
        model.resumeTask?.cancel()
        model.resumeTask = Task { @MainActor in
            try? await Task.sleep(for: style.userScrollResumeDelay)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.2)) { model.isUserScrolling = false }
            let latest = model.sync(timeMs: lyricTimelineTime(
                presentationTimeMs: model.lastPresentationTimeMs,
                lineTransitionLeadMs: lineTransitionLeadMs
            ))
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
    updatesFrames: Bool
) -> TimeInterval {
    guard updatesFrames else { return 3_600 }
    return largeScreenOptimizations ? 1.0 / 24.0 : 1.0 / 30.0
}

private struct LyricSourceSignature: Equatable {
    let count: Int
    let firstID: String?
    let lastID: String?
    let firstStartTime: Int64?
    let lastEndTime: Int64?
    let options: OptimizeLyricOptions

    init(lines: [LyricLine], options: OptimizeLyricOptions) {
        count = lines.count
        firstID = lines.first?.id
        lastID = lines.last?.id
        firstStartTime = lines.first?.startTime
        lastEndTime = lines.last?.endTime
        self.options = options
    }
}

private struct LyricScrollRequest: Equatable {
    var index: Int
    var isSeeking: Bool
    var lineBoundaryIndex: Int?
}

private struct LyricScrollRequestKey: PreferenceKey {
    static let defaultValue = LyricScrollRequest(index: 0, isSeeking: false, lineBoundaryIndex: nil)

    static func reduce(value: inout LyricScrollRequest, nextValue: () -> LyricScrollRequest) {
        value = nextValue()
    }
}

@MainActor
private final class LyricsViewModel: ObservableObject {
    @Published var isUserScrolling = false
    @Published private(set) var isHorizontalSwiping = false
    @Published private(set) var groups: [LyricGroup]
    var resumeTask: Task<Void, Never>?
    private var horizontalSwipeTask: Task<Void, Never>?
    private var autoScrollTask: Task<Void, Never>?
    private var clockCalibrationTask: Task<Void, Never>?
    let timelineEpoch = Date()
    private var timeline: LyricTimeline
    private var interpolator: PlaybackTimeInterpolator
    private(set) var lastPresentationTimeMs: Int64
    private(set) var sourceSignature: LyricSourceSignature?
    private var lastAutoScrollTarget: Int?
    private var lastCalibratedLineIndex: Int?
    private var suppressAnimatedScrollUntil = Date.distantPast

    init(groups: [LyricGroup], timeMs: Int64) {
        self.groups = groups
        timeline = Self.makeTimeline(groups)
        interpolator = .init(initialSourceTimeMs: timeMs)
        lastPresentationTimeMs = timeMs
    }

    func sync(timeMs: Int64) -> LyricTimelineSnapshot { timeline.sync(timeMs: timeMs) }

    func reset(groups: [LyricGroup], timeMs: Int64, sourceSignature: LyricSourceSignature) {
        clockCalibrationTask?.cancel()
        clockCalibrationTask = nil
        self.groups = groups
        self.sourceSignature = sourceSignature
        timeline = Self.makeTimeline(groups)
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

    func scheduleAutoScroll(index: Int, action: @escaping @MainActor () -> Void) {
        guard lastAutoScrollTarget != index else { return }
        autoScrollTask?.cancel()
        autoScrollTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard !Task.isCancelled, let self, self.lastAutoScrollTarget != index else { return }
            self.lastAutoScrollTarget = index
            action()
        }
    }

    var allowsAnimatedScroll: Bool { Date.now >= suppressAnimatedScrollUntil }

    func layoutDidChange() {
        resumeTask?.cancel()
        autoScrollTask?.cancel()
        resumeTask = nil
        autoScrollTask = nil
        lastAutoScrollTarget = nil
        suppressAnimatedScrollUntil = Date.now.addingTimeInterval(0.35)
    }

    func beginHorizontalSwipe() {
        resumeTask?.cancel()
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
        resumeTask?.cancel()
        horizontalSwipeTask?.cancel()
        autoScrollTask?.cancel()
        clockCalibrationTask?.cancel()
    }

    func presentationTime(
        sourceTimeMs: Int64,
        frameDate: Date,
        isPlaying: Bool,
        enabled: Bool,
        playbackRate: Double,
        discontinuityRevision: UInt
    ) -> Int64 {
        let seconds = max(frameDate.timeIntervalSince1970, 0)
        let nanoseconds = UInt64(min(seconds * 1_000_000_000, Double(UInt64.max)))
        lastPresentationTimeMs = interpolator.update(
            sourceTimeMs: sourceTimeMs,
            frameNanoseconds: nanoseconds,
            isPlaying: isPlaying && enabled,
            playbackRate: playbackRate,
            discontinuityRevision: discontinuityRevision
        )
        return lastPresentationTimeMs
    }

    private static func makeTimeline(_ groups: [LyricGroup]) -> LyricTimeline {
        .init(bounds: groups.map { .init(startTime: $0.renderBounds.startTime, endTime: $0.renderBounds.endTime) })
    }

    deinit {
        resumeTask?.cancel()
        horizontalSwipeTask?.cancel()
        autoScrollTask?.cancel()
        clockCalibrationTask?.cancel()
    }
}

private struct LyricRenderStyleSignature: Equatable, Sendable {
    let fontSize: CGFloat
    let secondaryFontSize: CGFloat
    let enableBlur: Bool
    let enableScale: Bool
    let backgroundLineScale: CGFloat
    let alwaysPostpositionBackground: Bool

    @MainActor init(_ style: AppleMusicLyricsStyle) {
        fontSize = style.fontSize
        secondaryFontSize = style.secondaryFontSize
        enableBlur = style.enableBlur
        enableScale = style.enableScale
        backgroundLineScale = style.backgroundLineScale
        alwaysPostpositionBackground = style.alwaysPostpositionBackground
    }
}

private struct LyricGroupView: View, Equatable {
    let group: LyricGroup
    let currentTimeMs: Int64
    let active: Bool
    let highlighted: Bool
    let isPlaying: Bool
    let isUserScrolling: Bool
    let reduceEffects: Bool
    let disableBlur: Bool
    let disableTransforms: Bool
    let style: AppleMusicLyricsStyle
    let styleSignature: LyricRenderStyleSignature
    let showTranslation: Bool
    let showRomanization: Bool
    let onTap: () -> Void

    var body: some View {
        let backgroundFirst = !style.alwaysPostpositionBackground
            && (group.background?.words.first?.startTime ?? .max) < (group.main.words.first?.startTime ?? group.main.startTime)
        VStack(
            alignment: group.main.isDuet ? .trailing : .leading,
            spacing: 0
        ) {
            if backgroundFirst { background(attachedAbove: true) }
            line(group.main, chunks: group.mainChunks, scale: 1)
            if !backgroundFirst { background(attachedAbove: false) }
        }
        .foregroundStyle(highlighted ? style.activeColor : style.inactiveColor)
        .opacity(lyricLineOpacity(isHighlighted: highlighted))
        .scaleEffect(style.enableScale && !disableTransforms && !reduceEffects && !highlighted && isPlaying ? 0.97 : 1,
                     anchor: group.main.isDuet ? .trailing : .leading)
        .blur(radius: style.enableBlur && !disableBlur && !reduceEffects && !isUserScrolling && !highlighted ? 2.2 : 0)
        .animation(.interpolatingSpring(mass: 1, stiffness: 90, damping: 15), value: highlighted)
        .animation(.easeOut(duration: 0.18), value: isUserScrolling)
        .animation(nil, value: reduceEffects)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        .accessibilityAddTraits(active ? .isSelected : [])
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
            && lhs.group.renderBounds == rhs.group.renderBounds
            && lhs.group.mainChunks.count == rhs.group.mainChunks.count
            && lhs.group.backgroundChunks.count == rhs.group.backgroundChunks.count
            && lhs.currentTimeMs == rhs.currentTimeMs
            && lhs.active == rhs.active
            && lhs.highlighted == rhs.highlighted
            && lhs.isPlaying == rhs.isPlaying
            && lhs.isUserScrolling == rhs.isUserScrolling
            && lhs.reduceEffects == rhs.reduceEffects
            && lhs.disableBlur == rhs.disableBlur
            && lhs.disableTransforms == rhs.disableTransforms
            && lhs.styleSignature == rhs.styleSignature
            && lhs.showTranslation == rhs.showTranslation
            && lhs.showRomanization == rhs.showRomanization
    }

    @ViewBuilder private func background(attachedAbove: Bool) -> some View {
        if let background = group.background {
            let revealed = active || !isPlaying
            let spacing = max(2, style.fontSize * 0.18)
            BackgroundLyricRevealLayout(
                progress: revealed ? 1 : 0,
                attachedAbove: attachedAbove
            ) {
                line(background, chunks: group.backgroundChunks, scale: style.backgroundLineScale)
                    .padding(attachedAbove ? .bottom : .top, spacing)
                    .opacity(revealed ? 0.4 : 0)
                    .scaleEffect(
                        x: disableTransforms || revealed ? 1 : 0.9,
                        y: disableTransforms || revealed ? 1 : 0.72,
                        anchor: attachedAbove ? .bottom : .top
                    )
                    .offset(y: disableTransforms || revealed ? 0 : (attachedAbove ? 10 : -10))
            }
            .clipped()
            .allowsHitTesting(revealed)
            .animation(
                .interpolatingSpring(mass: 0.9, stiffness: 115, damping: 16, initialVelocity: 0),
                value: revealed
            )
        }
    }

    private func line(_ line: LyricLine, chunks: [LyricWordChunk], scale: CGFloat) -> some View {
        VStack(alignment: line.isDuet ? .trailing : .leading, spacing: 3) {
            BalancedLyricLayout(trailingAlignment: line.isDuet) {
                ForEach(chunks) { chunk in
                    TimedChunkView(chunk: chunk, currentTimeMs: currentTimeMs, active: active, style: scaledStyle(scale))
                        .fixedSize()
                }
            }
            if showTranslation, !line.translatedLyric.isEmpty {
                Text(line.translatedLyric)
                    .font(.system(size: style.secondaryFontSize * scale, weight: .semibold, design: .default))
            }
            if showRomanization, !line.romanLyric.isEmpty {
                Text(line.romanLyric)
                    .font(.system(size: style.secondaryFontSize * scale, weight: .semibold, design: .default))
            }
        }
    }

    private func scaledStyle(_ scale: CGFloat) -> AppleMusicLyricsStyle {
        var value = style
        value.fontSize *= scale
        value.secondaryFontSize *= scale
        return value
    }
}

/// Animates the occupied layout height while keeping the background lyric
/// attached to the main line. An upper background reveals from its bottom
/// edge; a lower background reveals from its top edge.
private struct BackgroundLyricRevealLayout: Layout {
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

private struct TimedChunkView: View {
    let chunk: LyricWordChunk
    let currentTimeMs: Int64
    let active: Bool
    let style: AppleMusicLyricsStyle

    private var progress: CGFloat { active ? lyricChunkProgress(words: chunk.words, timeMs: currentTimeMs) : 0 }
    var body: some View {
        VStack(spacing: -1) {
            if !chunk.rubyText.isEmpty {
                Text(chunk.rubyText)
                    .font(.system(size: style.secondaryFontSize * 0.72, weight: .bold, design: .default))
            }
            ChunkText(text: chunk.displayText, progress: progress, emphasize: chunk.emphasizes && active, amount: chunk.emphasisAmount, style: style)
                .foregroundStyle(style.inactiveColor)
                .overlay {
                    ChunkText(text: chunk.displayText, progress: progress, emphasize: chunk.emphasizes && active, amount: chunk.emphasisAmount, style: style)
                        .foregroundStyle(style.activeColor)
                        .mask { WordProgressMask(progress: progress, fadeWidth: style.fontSize * style.wordFadeWidth) }
                }
            if !chunk.romanText.isEmpty {
                Text(chunk.romanText)
                    .font(.system(size: style.secondaryFontSize * 0.78, weight: .bold, design: .default))
            }
        }
    }
}

private struct ChunkText: View {
    let text: String
    let progress: CGFloat
    let emphasize: Bool
    let amount: CGFloat
    let style: AppleMusicLyricsStyle

    var body: some View {
        if emphasize {
            HStack(alignment: .bottom, spacing: 0) {
                ForEach(Array(text.enumerated()), id: \.offset) { index, character in
                    let motion = calculateEmphasisCharacterMotion(
                        progress: progress,
                        characterIndex: index,
                        characterCount: text.count,
                        amount: amount
                    )
                    Text(String(character))
                        .font(.system(size: style.fontSize, weight: .bold, design: .default))
                        .scaleEffect(motion.scale)
                        .offset(x: motion.translationXEm * style.fontSize, y: motion.translationYEm * style.fontSize)
                        .shadow(color: style.activeColor.opacity(motion.wave * 0.5), radius: motion.wave * style.fontSize * 0.25)
                }
            }
        } else {
            Text(text).font(.system(size: style.fontSize, weight: .bold, design: .default))
        }
    }
}

private struct WordProgressMask: View {
    let progress: CGFloat
    let fadeWidth: CGFloat

    var body: some View {
        GeometryReader { geometry in
            if progress <= 0 { Color.clear }
            else if progress >= 1 { Color.white }
            else {
                let band = min(0.5, fadeWidth / max(geometry.size.width, 1))
                let head = progress * (1 + band) - band / 2
                LinearGradient(
                    stops: [
                        .init(color: .white, location: 0),
                        .init(color: .white, location: max(0, head - band / 2)),
                        .init(color: .clear, location: min(1, head + band / 2)),
                        .init(color: .clear, location: 1),
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            }
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
