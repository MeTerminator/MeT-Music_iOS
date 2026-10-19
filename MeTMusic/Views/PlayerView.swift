import SwiftUI
#if os(iOS)
import UIKit
#endif

func playerArtworkSide(in size: CGSize) -> CGFloat {
    guard size.width > 0, size.height > 0 else { return 0 }
    return min(max(0, size.width - 48) * 0.85, size.height * 0.54)
}

func playerPageTarget(
    currentPage: Int,
    translation: CGFloat,
    projectedTranslation: CGFloat,
    pageWidth: CGFloat
) -> Int {
    let distanceThreshold = max(52, pageWidth * 0.14)
    let projectionThreshold = max(120, pageWidth * 0.32)
    if translation <= -distanceThreshold || projectedTranslation <= -projectionThreshold {
        return 1
    }
    if translation >= distanceThreshold || projectedTranslation >= projectionThreshold {
        return 0
    }
    return min(max(currentPage, 0), 1)
}

func playerShouldDismiss(translation: CGFloat, projectedTranslation: CGFloat, height: CGFloat) -> Bool {
    // An upward flick cancels even after crossing the distance threshold.
    guard projectedTranslation - translation > -60 else { return false }
    return translation > max(100, height * 0.18)
        || (translation > 24 && projectedTranslation > max(180, height * 0.32))
}

struct PlayerView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = PlayerViewModel()
    @GestureState private var dismissGestureActive = false
    @GestureState private var pageGestureActive = false
    var onDismiss: (() -> Void)?
    var onDismissDrag: (CGFloat) -> Void

    init(onDismiss: (() -> Void)? = nil, onDismissDrag: @escaping (CGFloat) -> Void = { _ in }) {
        self.onDismiss = onDismiss
        self.onDismissDrag = onDismissDrag
    }

    var body: some View {
        playerBody
    }

    private var playerBody: some View {
        GeometryReader { container in
            Group {
                if usesSideBySideLayout(container.size) {
                    sideBySidePlayer(in: container.size)
                } else {
                    portraitPagedPlayer(in: container.size)
                }
            }
            .modifier(LyricsScreenAwake(isEnabled: usesSideBySideLayout(container.size) || model.page == 1))
        }
        #if !os(macOS)
        .background {
            // The background stays fixed between pages without participating in layout.
            MusicArtworkBackground(artworkURL: store.currentSong?.bestCoverURL)
        }
        #endif
        .preferredColorScheme(.dark)
        .sheet(isPresented: $model.showingQueue) { QueueView() }
        .onChange(of: dismissGestureActive) { _, active in
            // Gesture cancellation does not call onEnded (e.g. a system gesture
            // takes over). Restore the surface instead of leaving it displaced.
            if !active && model.isDismissing {
                model.isDismissing = false
                withAnimation(.interactiveSpring(response: 0.32, dampingFraction: 0.88)) {
                    onDismissDrag(0)
                }
            }
        }
        .onChange(of: pageGestureActive) { _, active in
            if !active && model.pageDragOffset != 0 {
                withAnimation(.interactiveSpring(response: 0.32, dampingFraction: 0.88)) {
                    model.pageDragOffset = 0
                }
                model.endPagingAfterSettle()
            }
        }
        .onChange(of: model.isControlDragging) { _, dragging in
            if dragging { onDismissDrag(0) }
        }
        .onChange(of: store.currentSong?.id) { _, _ in
            model.scrubbing = false
            model.scrubValue = 0
        }
        .accessibilityAction(named: "关闭播放器") { closePlayer() }
        .accessibilityAction(named: "显示歌词") {
            model.page = 1
        }
        .accessibilityAction(named: "显示封面") {
            model.page = 0
        }
    }

    @ViewBuilder
    private func portraitPagedPlayer(in size: CGSize) -> some View {
        HStack(spacing: 0) {
            nowPlayingPage(in: size, controlsEnabled: model.page == 0)
                .frame(width: size.width, height: size.height)
            lyricsChrome(in: size, allowsPageSwipe: true, compactChrome: false)
                .frame(width: size.width, height: size.height)
        }
        .frame(width: size.width * 2, height: size.height, alignment: .leading)
        .offset(x: -CGFloat(model.page) * size.width + model.pageDragOffset)
        .frame(width: size.width, height: size.height, alignment: .leading)
        .contentShape(Rectangle())
        .simultaneousGesture(pageGesture(pageWidth: size.width))
        .clipped()
    }

    private func pageGesture(pageWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .updating($pageGestureActive) { _, active, _ in active = true }
            .onChanged { value in
                guard !model.isControlDragging, !model.isDismissing else { return }
                guard abs(value.translation.width) > abs(value.translation.height) * 1.12 else { return }
                model.beginPaging()
                let raw = value.translation.width
                let atBoundary = (model.page == 0 && raw > 0) || (model.page == 1 && raw < 0)
                model.pageDragOffset = atBoundary ? raw * 0.18 : raw
            }
            .onEnded { value in
                guard model.isPaging else { return }
                let target = playerPageTarget(
                    currentPage: model.page,
                    translation: value.translation.width,
                    projectedTranslation: value.predictedEndTranslation.width,
                    pageWidth: pageWidth
                )
                withAnimation(.interactiveSpring(response: 0.32, dampingFraction: 0.88, blendDuration: 0.08)) {
                    model.page = target
                    model.pageDragOffset = 0
                }
                model.endPagingAfterSettle()
            }
    }

    private func sideBySidePlayer(in size: CGSize) -> some View {
        let leftWidth = floor(size.width * 0.48)
        let rightWidth = max(0, size.width - leftWidth)
        return HStack(spacing: 0) {
            Group {
                if usesLargeScreenLyricOptimizations {
                    nowPlayingPage(in: .init(width: leftWidth, height: size.height))
                } else {
                    landscapeCover(in: .init(width: leftWidth, height: size.height))
                }
            }
            .frame(width: leftWidth, height: size.height)

            lyricsChrome(
                in: .init(width: rightWidth, height: size.height),
                allowsPageSwipe: false,
                compactChrome: true
            )
            .frame(width: rightWidth, height: size.height)
        }
        .frame(width: size.width, height: size.height)
        .clipped()
    }

    private func usesSideBySideLayout(_ size: CGSize) -> Bool {
        #if os(macOS)
        true
        #else
        size.width > size.height
        #endif
    }

    private func landscapeCover(in size: CGSize) -> some View {
        let side = max(0, min(size.width - 32, size.height * 0.85))
        return VStack(spacing: 0) {
            playerHandle
            ZStack {
                ArtworkView(url: store.currentSong?.bestCoverURL, cornerRadius: 16)
                if model.showLandscapeControls {
                    RoundedRectangle(cornerRadius: 16).fill(.black.opacity(0.75))
                    VStack(spacing: 4) {
                        songTitleBlock
                        progressSection
                        playbackControls(compact: true)
                    }
                    .padding(12)
                }
            }
            .frame(width: side, height: side)
            .contentShape(Rectangle())
            .onTapGesture { model.showLandscapeControls.toggle() }
            .accessibilityAction(named: "显示播放控制") { model.showLandscapeControls = true }
            Spacer(minLength: 0)
        }
        .frame(width: size.width, height: size.height)
        .simultaneousGesture(dismissGesture(height: size.height), including: dismissGestureMask)
    }

    private func nowPlayingPage(in size: CGSize, controlsEnabled: Bool = true) -> some View {
        let contentWidth = max(0, size.width - 48)
        let artworkSide = playerArtworkSide(in: size)
        return VStack(spacing: 0) {
            playerHandle
            Spacer(minLength: 8)
            ArtworkView(url: store.currentSong?.bestCoverURL, cornerRadius: 16)
                .frame(width: artworkSide, height: artworkSide)
            Spacer(minLength: 16)
            VStack(spacing: 0) {
                songTitleBlock
                Spacer().frame(height: 16)
                progressSection.padding(.horizontal, 8)
                Spacer().frame(height: 8)
                mainPlaybackControls
                    .allowsHitTesting(controlsEnabled)
                    .disabled(model.isPaging || model.isDismissing)
            }
            .frame(width: contentWidth)
            Spacer(minLength: 12)
        }
        .padding(.horizontal, 24)
        .foregroundStyle(.white)
        .frame(width: size.width, height: size.height)
        .contentShape(Rectangle())
        .simultaneousGesture(dismissGesture(height: size.height), including: dismissGestureMask)
    }

    private var songTitleBlock: some View {
        VStack(spacing: 4) {
            if let song = store.currentSong {
                Text(song.name).font(.system(size: 20, weight: .bold)).lineLimit(1)
                Text(song.artistText).font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.7)).lineLimit(1)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .frame(height: 48)
    }

    @ViewBuilder
    private var playerHandle: some View {
        #if os(iOS)
        Capsule()
            .fill(.white.opacity(0.7))
            .frame(width: 42, height: 5)
            .frame(maxWidth: .infinity)
            .frame(height: 32)
            .contentShape(Rectangle())
            .accessibilityHidden(true)
        #endif
    }

    private var dismissGestureMask: GestureMask {
        #if os(iOS)
        .all
        #else
        .none
        #endif
    }

    private func dismissGesture(height: CGFloat) -> some Gesture {
        // The surface moves during this gesture. Local coordinates would feed
        // that movement back into translation and make tracking oscillate.
        DragGesture(minimumDistance: 8, coordinateSpace: .global)
            .updating($dismissGestureActive) { _, active, _ in active = true }
            .onChanged { value in
                guard !model.isControlDragging, !model.isPaging else { return }
                if !model.isDismissing {
                    guard value.translation.height > 0,
                          value.translation.height > abs(value.translation.width) * 1.2 else { return }
                    model.isDismissing = true
                }
                // No implicit animation during tracking: the surface stays under the finger.
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    onDismissDrag(max(0, value.translation.height))
                }
            }
            .onEnded { value in
                guard model.isDismissing else { return }
                model.isDismissing = false
                if playerShouldDismiss(
                    translation: value.translation.height,
                    projectedTranslation: value.predictedEndTranslation.height,
                    height: height
                ) {
                    closePlayer()
                } else {
                    withAnimation(.interactiveSpring(response: 0.32, dampingFraction: 0.88)) {
                        onDismissDrag(0)
                    }
                }
            }
    }

    private func lyricsChrome(
        in size: CGSize,
        allowsPageSwipe: Bool,
        compactChrome: Bool
    ) -> some View {
        return VStack(spacing: 0) {
            if !compactChrome {
                VStack(spacing: 0) {
                    playerHandle
                    lyricsHeader.padding(.bottom, 16)
                }
                .frame(width: max(0, size.width - 48))
                .contentShape(Rectangle())
                .simultaneousGesture(dismissGesture(height: size.height), including: dismissGestureMask)
            }
            AppleMusicLyricsView(
                lyricLines: store.lyrics,
                currentTimeMs: lyricPresentationTime(
                    mediaPositionMs: store.audio.positionMs,
                    lyricOffsetMs: store.lyricOffsetMs
                ),
                currentTimeProvider: {
                    lyricPresentationTime(
                        mediaPositionMs: store.audio.lyricClockPositionMs(),
                        lyricOffsetMs: store.lyricOffsetMs
                    )
                },
                lineTransitionLeadMs: store.effectiveLyricLeadMs,
                playbackDiscontinuityRevision: store.audio.playbackDiscontinuityRevision,
                isPlaying: store.audio.isPlaying,
                isActive: compactChrome || model.page == 1,
                isPageTransitioning: model.isPaging || model.isDismissing,
                largeScreenOptimizations: usesLargeScreenLyricOptimizations,
                style: lyricStyle,
                showTranslation: model.showTranslation,
                onLineTap: { line in
                    let target = lyricTapSeekTime(line: line, lyricOffsetMs: store.lyricOffsetMs)
                    Task { await store.seek(to: target) }
                },
                onLineBoundary: {
                    store.audio.calibrateLyricClockAtLineBoundary()
                },
                handlesHorizontalSwipe: false,
                onHorizontalSwipe: { direction in
                    guard allowsPageSwipe else { return }
                    switch direction {
                    case .previous:
                        model.page = 0
                    case .next:
                        break
                    }
                }
            )
            .padding(.horizontal, 24)
            .frame(width: size.width)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())

            if compactChrome {
                translationToggle
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 10)
            } else {
                lyricsPlaybackBar
                    .allowsHitTesting(model.page == 1)
                    .disabled(model.isPaging || model.isDismissing)
                    .frame(width: max(0, size.width - 48))
                    .padding(.vertical, 16)
            }
        }
        .frame(width: size.width, height: size.height)
        .foregroundStyle(.white)
        .clipped()
    }

    private var lyricsHeader: some View {
        HStack(spacing: 12) {
            ArtworkView(url: store.currentSong?.bestCoverURL, cornerRadius: 8)
                .frame(width: 56, height: 56)
            if let song = store.currentSong {
                VStack(alignment: .leading, spacing: 2) {
                    Text(song.name).font(.system(size: 18, weight: .bold)).lineLimit(1)
                    Text(song.artistText).font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(height: 56)
    }

    private var lyricsPlaybackBar: some View {
        HStack(spacing: 0) {
            Button { model.showingQueue = true } label: {
                Image(systemName: "list.bullet")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 48, height: 44)
            }
            .accessibilityLabel("播放列表")

            Spacer(minLength: 8)

            HStack(spacing: 16) {
                Button(action: { performPlaybackAction(store.previous) }) {
                    Image(systemName: "backward.end.fill")
                        .font(.system(size: 24))
                        .frame(width: 42, height: 48)
                }

                Button(action: { performPlaybackAction(store.togglePlayback) }) {
                    PlaybackButtonContent(
                        isLoading: store.isPlaybackLoading,
                        isPlaying: store.audio.isPlaying,
                        fontSize: 24
                    )
                    .frame(width: 48, height: 48)
                    .background(.white.opacity(0.1), in: Circle())
                }
                .disabled(store.isPlaybackLoading)
                .accessibilityLabel(store.isPlaybackLoading ? "加载中" : (store.audio.isPlaying ? "暂停" : "播放"))

                Button(action: { performPlaybackAction { store.next() } }) {
                    Image(systemName: "forward.end.fill")
                        .font(.system(size: 24))
                        .frame(width: 42, height: 48)
                }
            }

            Spacer(minLength: 8)

            translationToggle
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
    }

    private var translationToggle: some View {
        Button { model.showTranslation.toggle() } label: {
            Text("翻译")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(model.showTranslation ? .white : .white.opacity(0.5))
                .padding(.horizontal, 13)
                .frame(height: 34)
                .background(
                    model.showTranslation ? .white.opacity(0.18) : .clear,
                    in: Capsule()
                )
                .overlay {
                    if !model.showTranslation {
                        Capsule().stroke(.white.opacity(0.22), lineWidth: 1)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(model.showTranslation ? "隐藏翻译" : "显示翻译")
    }

    private var progressSection: some View {
        GeometryReader { geometry in
            VStack(spacing: 5) {
                PlayerScrubber(
                    value: Binding(
                        get: { displayedScrubValue },
                        set: { model.scrubValue = $0 }
                    ),
                    upperBound: Double(max(store.audio.durationMs, store.currentSong?.durationMs ?? 1, 1))
                ) { editing in
                    if editing {
                        model.beginControlInteraction()
                        model.scrubValue = Double(store.audio.positionMs)
                    } else {
                        model.endControlInteraction()
                    }
                    model.scrubbing = editing
                    if !editing {
                        Task { await store.seek(to: Int64(model.scrubValue.rounded())) }
                    }
                }
                .frame(width: geometry.size.width)
                HStack(spacing: 0) {
                    Text(format(Int64(displayedScrubValue)))
                        .frame(width: geometry.size.width / 2, alignment: .leading)
                    Text(format(effectiveDuration))
                        .frame(width: geometry.size.width / 2, alignment: .trailing)
                }
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(.white.opacity(0.5))
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .frame(height: 38)
    }

    private var mainPlaybackControls: some View { playbackControls() }

    private func playbackControls(compact: Bool = false) -> some View {
        HStack(spacing: 0) {
            Button { model.showingQueue = true } label: {
                Image(systemName: "list.bullet").font(.system(size: compact ? 16 : 22))
                    .frame(width: compact ? 32 : 44, height: 48)
            }
            .accessibilityLabel("播放列表")
            Spacer(minLength: 0)
            Button(action: { performPlaybackAction(store.previous) }) {
                Image(systemName: "backward.end.fill").font(.system(size: compact ? 22 : 30))
                    .frame(width: compact ? 36 : 48, height: 48)
            }
            .accessibilityLabel("上一首")
            Spacer(minLength: 0)
            Button(action: { performPlaybackAction(store.togglePlayback) }) {
                PlaybackButtonContent(
                    isLoading: store.isPlaybackLoading,
                    isPlaying: store.audio.isPlaying,
                    fontSize: compact ? 28 : 40
                )
                .frame(width: compact ? 48 : 72, height: compact ? 48 : 72)
                .background(.white.opacity(0.1), in: Circle())
            }
            .disabled(store.isPlaybackLoading)
            .accessibilityLabel(store.isPlaybackLoading ? "加载中" : (store.audio.isPlaying ? "暂停" : "播放"))
            Spacer(minLength: 0)
            Button(action: { performPlaybackAction { store.next() } }) {
                Image(systemName: "forward.end.fill").font(.system(size: compact ? 22 : 30))
                    .frame(width: compact ? 36 : 48, height: 48)
            }
            .accessibilityLabel("下一首")
            Spacer(minLength: 0)
            Button(action: { performPlaybackAction(store.cyclePlaybackMode) }) {
                Image(systemName: store.playbackMode == .sequence ? "repeat" : store.playbackMode.symbol)
                    .font(.system(size: compact ? 16 : 22))
                    .foregroundStyle(.white.opacity(store.playbackMode == .sequence ? 0.65 : 1))
                    .frame(width: compact ? 32 : 44, height: 48)
            }
            .accessibilityLabel(store.playbackMode.title)
            .accessibilityHint("切换播放模式")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .padding(.vertical, compact ? 4 : 12)
    }

    private func performPlaybackAction(_ action: () -> Void) {
        // A simultaneous page drag can end over a button that moved under the
        // finger. Keep the release (and the settling animation) from activating it.
        guard !model.isPaging, !model.isDismissing, !model.isControlDragging,
              !pageGestureActive, !dismissGestureActive else { return }
        action()
    }

    private var lyricStyle: AppleMusicLyricsStyle {
        var style = AppleMusicLyricsStyle()
        style.fontSize = store.lyricFontSize
        style.secondaryFontSize = store.translationFontSize
        style.lineWidthFraction = 1
        style.horizontalPadding = 16
        style.alignPosition = 0.2
        style.lineSpacing = 6
        style.wordFadeWidth = 0.5
        style.userScrollResumeDelay = .seconds(5)
        return style
    }

    private var usesLargeScreenLyricOptimizations: Bool {
        #if os(macOS)
        true
        #elseif os(iOS)
        UIDevice.current.userInterfaceIdiom == .pad
        #else
        false
        #endif
    }

    private var effectiveDuration: Int64 {
        max(store.audio.durationMs, store.currentSong?.durationMs ?? 0)
    }

    private var displayedScrubValue: Double {
        model.scrubbing ? model.scrubValue : Double(store.audio.positionMs)
    }

    private func closePlayer() {
        if let onDismiss { onDismiss() }
        else { dismiss() }
    }

    private func format(_ milliseconds: Int64) -> String {
        String(format: "%lld:%02lld", milliseconds / 60_000, milliseconds / 1_000 % 60)
    }
}

private struct PlayerScrubber: View {
    @Binding var value: Double
    let upperBound: Double
    let onEditingChanged: (Bool) -> Void
    @State private var editing = false

    var body: some View {
        GeometryReader { geometry in
            let fraction = min(max(value / max(upperBound, 1), 0), 1)
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.24))
                Capsule()
                    .fill(.white.opacity(0.86))
                    .frame(width: geometry.size.width * fraction)
            }
            .frame(height: editing ? 9 : 5)
            .frame(maxHeight: .infinity)
            .animation(.easeOut(duration: 0.16), value: editing)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        if !editing { editing = true; onEditingChanged(true) }
                        value = min(max(gesture.location.x / max(geometry.size.width, 1), 0), 1) * upperBound
                    }
                    .onEnded { _ in
                        editing = false
                        onEditingChanged(false)
                    }
            )
        }
        .frame(height: 18)
        .accessibilityValue(format(value))
        .accessibilityAdjustableAction { direction in
            let step = max(upperBound / 100, 5_000)
            switch direction {
            case .increment: value = min(upperBound, value + step)
            case .decrement: value = max(0, value - step)
            @unknown default: break
            }
            onEditingChanged(false)
        }
        .onDisappear {
            if editing { onEditingChanged(false) }
        }
    }

    private func format(_ milliseconds: Double) -> String {
        let value = Int64(milliseconds)
        return String(format: "%lld:%02lld", value / 60_000, value / 1_000 % 60)
    }
}

@MainActor
private final class PlayerViewModel: ObservableObject {
    @Published var page = 0
    @Published var showLandscapeControls = false
    @Published var scrubValue = 0.0
    @Published var scrubbing = false
    @Published var showingQueue = false
    @Published var showTranslation = true
    @Published var isDismissing = false
    @Published var pageDragOffset: CGFloat = 0
    @Published private(set) var isPaging = false
    @Published private(set) var isControlDragging = false
    private var pagingSettleTask: Task<Void, Never>?

    func beginPaging() {
        guard !isControlDragging else { return }
        pagingSettleTask?.cancel()
        if !isPaging { isPaging = true }
    }

    func beginControlInteraction() {
        pagingSettleTask?.cancel()
        isControlDragging = true
        isDismissing = false
        isPaging = false
        pageDragOffset = 0
    }

    func endControlInteraction() {
        isControlDragging = false
    }

    func endPagingAfterSettle() {
        pagingSettleTask?.cancel()
        pagingSettleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(320))
            guard !Task.isCancelled else { return }
            self?.isPaging = false
        }
    }

    deinit { pagingSettleTask?.cancel() }
}

struct QueueView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List(Array(store.queue.enumerated()), id: \.offset) { index, song in
                    Button { store.play(at: index); dismiss() } label: {
                        SongRow(
                            song: song,
                            number: index + 1,
                            active: index == store.currentIndex,
                            hasTTML: song.hasTTML
                        )
                    }
                    .buttonStyle(.plain)
                    .id(index)
                }
                .navigationTitle("播放队列")
                .toolbar {
                    ToolbarItem(placement: .navigation) {
                        Button {
                            guard store.queue.indices.contains(store.currentIndex) else { return }
                            withAnimation(.easeInOut(duration: 0.28)) {
                                proxy.scrollTo(store.currentIndex, anchor: .center)
                            }
                        } label: {
                            Image(systemName: "scope")
                        }
                        .disabled(!store.queue.indices.contains(store.currentIndex))
                        .accessibilityLabel("跳转到当前歌曲")
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") { dismiss() }
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// Own the idle-timer override only while lyrics are visible in the foreground.
private struct LyricsScreenAwake: ViewModifier {
    let isEnabled: Bool
    @Environment(\.scenePhase) private var scenePhase
    @State private var previousIdleTimerDisabled: Bool?

    func body(content: Content) -> some View {
        content
            .onChange(of: isEnabled && scenePhase == .active, initial: true) { _, enabled in
                updateIdleTimer(enabled: enabled)
            }
            .onDisappear { updateIdleTimer(enabled: false) }
    }

    private func updateIdleTimer(enabled: Bool) {
        #if os(iOS)
        if enabled {
            guard previousIdleTimerDisabled == nil else { return }
            previousIdleTimerDisabled = UIApplication.shared.isIdleTimerDisabled
            UIApplication.shared.isIdleTimerDisabled = true
        } else if let previous = previousIdleTimerDisabled {
            UIApplication.shared.isIdleTimerDisabled = previous
            previousIdleTimerDisabled = nil
        }
        #endif
    }
}
