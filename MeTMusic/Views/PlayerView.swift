import SwiftUI
#if os(iOS)
import AVFoundation
import AVKit
import UIKit
#endif

func playerArtworkSide(in size: CGSize) -> CGFloat {
    guard size.width > 0, size.height > 0 else { return 0 }
    return min(min(size.width * 0.8, 320), size.height * 0.48)
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

struct PlayerView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model = PlayerViewModel()
    var onDismiss: (() -> Void)?

    init(onDismiss: (() -> Void)? = nil) {
        self.onDismiss = onDismiss
    }

    var body: some View {
        playerBody
    }

    private var playerBody: some View {
        GeometryReader { container in
            if usesSideBySideLayout(container.size) {
                sideBySidePlayer(in: container.size)
            } else {
                portraitPagedPlayer(in: container.size)
            }
        }
        .background {
            // The background stays fixed between pages without participating in layout.
            artworkBackground
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $model.showingQueue) { QueueView() }
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
            nowPlayingPage(in: size)
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
            .onChanged { value in
                guard !model.isControlDragging else { return }
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
            nowPlayingPage(in: .init(width: leftWidth, height: size.height))
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
        guard size.width > size.height else { return false }
        #if os(macOS)
        return true
        #elseif os(iOS)
        return UIDevice.current.userInterfaceIdiom == .pad
        #else
        return false
        #endif
    }

    private var artworkBackground: some View {
        ZStack {
            Color(red: 0.08, green: 0.09, blue: 0.13)
            ArtworkView(url: store.currentSong?.bestCoverURL, cornerRadius: 0)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .scaleEffect(1.4)
                .blur(radius: 72, opaque: true)
                .opacity(0.72)
            Rectangle().fill(.black.opacity(0.32))
            LinearGradient(
                colors: [.black.opacity(0.06), .black.opacity(0.2), .black.opacity(0.5)],
                startPoint: .top,
                endPoint: .bottom
            )
        }
        .ignoresSafeArea()
    }

    private func nowPlayingPage(in size: CGSize) -> some View {
        let contentWidth = max(0, size.width - 56)
        let artworkSide = playerArtworkSide(in: size)
        return ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                ZStack {
                    ArtworkView(url: store.currentSong?.bestCoverURL, cornerRadius: 8)
                        // Keep a generous 20% visual margin around the artwork.
                        .frame(width: artworkSide, height: artworkSide)
                        .shadow(color: .black.opacity(0.36), radius: 22, y: 12)
                        .scaleEffect(store.audio.isPlaying ? 1 : 0.92)
                        .animation(
                            model.page == 0 && !model.isPaging
                                ? .spring(response: 0.48, dampingFraction: 0.82)
                                : nil,
                            value: store.audio.isPlaying
                        )
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .layoutPriority(1)

                VStack(spacing: 0) {
                    songTitleBlock.frame(width: contentWidth)
                    Spacer().frame(height: 16)
                    progressSection.frame(width: contentWidth)
                    Spacer().frame(height: 18)
                    mainPlaybackControls.frame(width: contentWidth)
                    Spacer().frame(height: 18)
                    volumeControl.frame(width: contentWidth)
                    Spacer().frame(height: 14)
                    playerPageActions.frame(width: contentWidth)
                    routeLabel.frame(width: contentWidth).padding(.top, 8)
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 6)
            .padding(.bottom, 10)

            closeButton
                .padding(.leading, 18)
                .safeAreaPadding(.top, 8)
        }
        .foregroundStyle(.white)
        .frame(width: size.width, height: size.height)
        .clipped()
    }

    private var songTitleBlock: some View {
        HStack {
            if let song = store.currentSong {
                VStack(alignment: .leading, spacing: 3) {
                    Text(song.name).font(.headline.weight(.bold)).lineLimit(1)
                    Text(song.artistText).font(.subheadline).foregroundStyle(.white.opacity(0.62)).lineLimit(1)
                }
            }
            Spacer()
        }
        .frame(height: 48)
    }

    private func lyricsChrome(
        in size: CGSize,
        allowsPageSwipe: Bool,
        compactChrome: Bool
    ) -> some View {
        return VStack(spacing: 0) {
            if !compactChrome {
                lyricsHeader
                    .frame(width: max(0, size.width - 52))
                    .padding(.top, 4)
                    .padding(.bottom, 8)
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
                lineTransitionLeadMs: store.lyricLeadMs,
                playbackDiscontinuityRevision: store.audio.playbackDiscontinuityRevision,
                isPlaying: store.audio.isPlaying,
                isActive: compactChrome || model.page == 1,
                isPageTransitioning: model.isPaging,
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
                    .frame(width: max(0, size.width - 44))
                    .padding(.vertical, 10)
            }
        }
        .frame(width: size.width, height: size.height)
        .foregroundStyle(.white)
        .clipped()
    }

    private var lyricsHeader: some View {
        HStack(spacing: 11) {
            ArtworkView(url: store.currentSong?.bestCoverURL, cornerRadius: 7).frame(width: 48, height: 48)
            if let song = store.currentSong {
                VStack(alignment: .leading, spacing: 2) {
                    Text(song.name).font(.subheadline.weight(.bold)).lineLimit(1)
                    Text(song.artistText).font(.caption).foregroundStyle(.white.opacity(0.62)).lineLimit(1)
                    if let author = store.ttmlAuthor {
                        Text("TTML · \(author)").font(.caption2).foregroundStyle(.white.opacity(0.48)).lineLimit(1)
                    }
                }
            }
            Spacer()
        }
        .frame(height: 48)
    }

    private var closeButton: some View {
        Button(action: closePlayer) {
            Image(systemName: "xmark")
                .font(.system(size: 15, weight: .bold))
                .frame(width: 38, height: 38)
                .background(.ultraThinMaterial, in: Circle())
                .overlay {
                    Circle().stroke(.white.opacity(0.14), lineWidth: 0.5)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("关闭播放器")
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

            HStack(spacing: 10) {
                Button(action: store.previous) {
                    Image(systemName: "backward.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .frame(width: 42, height: 42)
                }

                Button(action: store.togglePlayback) {
                    Image(systemName: store.audio.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 20, weight: .bold))
                        .frame(width: 48, height: 48)
                        .background(.white.opacity(0.12), in: Circle())
                }

                Button(action: { store.next() }) {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .frame(width: 42, height: 42)
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
                if let download = store.precacheDownload {
                    DownloadProgressBar(fraction: audioDownloadFraction(
                        receivedBytes: download.receivedBytes,
                        expectedBytes: download.expectedBytes
                    ))
                    .frame(width: geometry.size.width)
                    Text(audioDownloadStatusText(download))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.5))
                        .frame(width: geometry.size.width)
                } else {
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
                        Text("-" + format(max(0, effectiveDuration - Int64(displayedScrubValue))))
                            .frame(width: geometry.size.width / 2, alignment: .trailing)
                    }
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.5))
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .frame(height: 38)
    }

    private var mainPlaybackControls: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                Button(action: store.previous) {
                    Image(systemName: "backward.fill").font(.system(size: 30, weight: .semibold))
                }
                .frame(width: geometry.size.width / 3, height: 62)
                Button(action: store.togglePlayback) {
                    Image(systemName: store.audio.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 42, weight: .semibold))
                }
                .frame(width: geometry.size.width / 3, height: 62)
                Button(action: { store.next() }) {
                    Image(systemName: "forward.fill").font(.system(size: 30, weight: .semibold))
                }
                .frame(width: geometry.size.width / 3, height: 62)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .frame(height: 62)
    }

    private var volumeControl: some View {
        GeometryReader { geometry in
            HStack(spacing: 9) {
                Image(systemName: "speaker.fill").font(.caption2).frame(width: 13)
                PlayerVolumeSlider(
                    value: Binding(
                        get: { Double(store.audio.volume) },
                        set: { store.audio.volume = Float($0) }
                    ),
                    onEditingChanged: { editing in
                        if editing { model.beginControlInteraction() }
                        else { model.endControlInteraction() }
                    }
                )
                .frame(width: max(0, geometry.size.width - 62))
                Image(systemName: "speaker.wave.3.fill").font(.caption2).frame(width: 31)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .foregroundStyle(.white.opacity(0.58))
        .frame(height: 30)
    }

    private var playerPageActions: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                #if os(iOS)
                AirPlayRouteButton().frame(width: geometry.size.width / 2, height: 34)
                #else
                Image(systemName: "airplayaudio").frame(width: geometry.size.width / 2, height: 34)
                #endif

                Button { model.showingQueue = true } label: {
                    Image(systemName: "list.bullet").font(.system(size: 17, weight: .semibold))
                }
                .buttonStyle(.plain)
                .frame(width: geometry.size.width / 2, height: 34)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .foregroundStyle(.white.opacity(0.88))
        .frame(height: 34)
    }

    private var routeLabel: some View {
        Text(routeDescription)
            .font(.caption2.weight(.medium))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(maxWidth: .infinity)
    }

    private var lyricStyle: AppleMusicLyricsStyle {
        var style = AppleMusicLyricsStyle()
        style.fontSize = store.lyricFontSize
        style.secondaryFontSize = store.translationFontSize
        style.alignPosition = 0.2
        style.lineSpacing = 16
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

    private var routeDescription: String {
        #if os(iOS)
        let route = AVAudioSession.sharedInstance().currentRoute.outputs.first?.portName ?? "此 iPhone"
        return route == "iPhone" ? "此 iPhone" : "iPhone → \(route)"
        #else
        return "此 Mac"
        #endif
    }

    private func closePlayer() {
        if let onDismiss { onDismiss() }
        else { dismiss() }
    }

    private func format(_ milliseconds: Int64) -> String {
        String(format: "%lld:%02lld", milliseconds / 60_000, milliseconds / 1_000 % 60)
    }
}

private struct PlayerVolumeSlider: View {
    @Binding var value: Double
    let onEditingChanged: (Bool) -> Void
    @State private var editing = false

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.26))
                Capsule()
                    .fill(.white.opacity(0.82))
                    .frame(width: geometry.size.width * min(max(value, 0), 1))
            }
            .frame(height: 5)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        if !editing {
                            editing = true
                            onEditingChanged(true)
                        }
                        value = min(max(gesture.location.x / max(geometry.size.width, 1), 0), 1)
                    }
                    .onEnded { _ in
                        editing = false
                        onEditingChanged(false)
                    }
            )
        }
        .frame(height: 22)
        .onDisappear {
            if editing { onEditingChanged(false) }
        }
    }
}

/// Replaces the playback scrubber while precache mode downloads the song. It
/// deliberately keeps the scrubber's track geometry so the controls below do
/// not shift when playback finally starts.
private struct DownloadProgressBar: View {
    let fraction: Double?

    var body: some View {
        GeometryReader { geometry in
            Group {
                if let fraction {
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.24))
                        Capsule()
                            .fill(.white.opacity(0.86))
                            .frame(width: geometry.size.width * min(max(fraction, 0), 1))
                    }
                    .animation(.easeOut(duration: 0.2), value: fraction)
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .tint(.white.opacity(0.86))
                }
            }
            .frame(height: 5)
            .frame(maxHeight: .infinity)
        }
        .frame(height: 18)
        .accessibilityElement()
        .accessibilityLabel("下载中")
        .accessibilityValue(fraction.map { "\(Int(($0 * 100).rounded()))%" } ?? "")
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
    @Published var scrubValue = 0.0
    @Published var scrubbing = false
    @Published var showingQueue = false
    @Published var showTranslation = true
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

#if os(iOS)
private struct AirPlayRouteButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.prioritizesVideoDevices = false
        picker.tintColor = UIColor.white.withAlphaComponent(0.84)
        picker.activeTintColor = UIColor.systemPink
        return picker
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
#endif

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
