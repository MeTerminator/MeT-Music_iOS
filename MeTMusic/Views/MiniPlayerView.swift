import SwiftUI

struct MiniPlayerView: View {
    var usesSystemGlass = false

    @ViewBuilder
    var body: some View {
        if usesSystemGlass {
            content
        } else {
            content.miniPlayerGlassBackground()
        }
    }

    private var content: some View {
        MiniPlayerContent(compact: false)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
    }
}

private extension View {
    @ViewBuilder
    func miniPlayerGlassBackground() -> some View {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            glassEffect(.regular.interactive(), in: .rect(cornerRadius: 22))
        } else {
            background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(.white.opacity(0.14), lineWidth: 0.5)
                }
        }
        #else
        background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        #endif
    }
}

private struct MiniPlayerContent: View {
    @EnvironmentObject private var store: AppStore
    @State private var showingQueue = false
    let compact: Bool

    var body: some View {
        if let song = store.currentSong {
            HStack(spacing: compact ? 8 : 11) {
                if !compact {
                    ArtworkView(url: song.bestCoverURL, cornerRadius: 7)
                        .frame(width: 44, height: 44)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(song.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    if !compact {
                        Text(song.artistText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button(action: store.togglePlayback) {
                    Image(systemName: store.audio.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: compact ? 15 : 18, weight: .semibold))
                        .frame(width: compact ? 30 : 36, height: compact ? 30 : 36)
                }
                .buttonStyle(.plain)

                Button { showingQueue = true } label: {
                    Image(systemName: "list.bullet")
                        .font(.system(size: compact ? 15 : 17, weight: .semibold))
                        .frame(width: compact ? 30 : 34, height: compact ? 30 : 36)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("播放列表")
            }
            .overlay(alignment: .bottomLeading) {
                GeometryReader { geometry in
                    Capsule()
                        .fill(.primary.opacity(0.42))
                        .frame(width: geometry.size.width * progress, height: 2)
                }
                .frame(height: 2)
                .padding(.horizontal, compact ? 6 : 10)
            }
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .onTapGesture { store.isPlayerPresented = true }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("正在播放：\(song.name)，\(song.artistText)")
            .sheet(isPresented: $showingQueue) { QueueView() }
        }
    }

    private var progress: CGFloat {
        guard store.audio.durationMs > 0 else { return 0 }
        return min(max(CGFloat(store.audio.positionMs) / CGFloat(store.audio.durationMs), 0), 1)
    }
}
