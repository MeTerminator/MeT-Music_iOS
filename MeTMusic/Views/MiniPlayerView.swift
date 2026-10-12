import SwiftUI

struct MiniPlayerView: View {
    @EnvironmentObject private var store: AppStore
    @State private var showingQueue = false

    var body: some View {
        if let song = store.currentSong {
            HStack(spacing: 12) {
                ArtworkView(url: song.bestCoverURL, cornerRadius: 6)
                    .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(song.name)
                        .font(.system(size: 14, weight: .bold)).lineLimit(1)
                    Text(song.artistText)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button(action: store.togglePlayback) {
                    PlaybackButtonContent(
                        isLoading: store.isPlaybackLoading,
                        isPlaying: store.audio.isPlaying,
                        fontSize: 28
                    )
                    .frame(width: 44, height: 48)
                }
                .disabled(store.isPlaybackLoading)
                .accessibilityLabel(store.isPlaybackLoading ? "加载中" : (store.audio.isPlaying ? "暂停" : "播放"))
                Button { showingQueue = true } label: {
                    Image(systemName: "list.bullet")
                        .font(.system(size: 25)).frame(width: 44, height: 48)
                }
                .accessibilityLabel("播放列表")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .miniPlayerSurface()
            .onTapGesture { store.isPlayerPresented = true }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("正在播放：\(song.name)，\(song.artistText)")
            .sheet(isPresented: $showingQueue) { QueueView() }
        }
    }
}

private extension View {
    @ViewBuilder
    func miniPlayerSurface() -> some View {
        #if os(macOS)
        self
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity)
            .frame(height: 72)
            .background(.black.opacity(0.2))
            .overlay(alignment: .top) {
                Rectangle().fill(.white.opacity(0.1)).frame(height: 1)
            }
            .contentShape(Rectangle())
        #else
        self
            .padding(.horizontal, 12)
            .frame(height: 60)
            .transparentPlayerGlass()
            .contentShape(RoundedRectangle(cornerRadius: 32))
        #endif
    }

    #if os(iOS)
    @ViewBuilder
    func transparentPlayerGlass() -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(.clear.interactive(), in: .rect(cornerRadius: 32))
        } else {
            background(.ultraThinMaterial.opacity(0.35), in: RoundedRectangle(cornerRadius: 32))
        }
    }
    #endif
}

/// Keeps every player surface consistent while a song is being prepared.
struct PlaybackButtonContent: View {
    let isLoading: Bool
    let isPlaying: Bool
    let fontSize: CGFloat

    var body: some View {
        Group {
            if isLoading {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(.white)
            } else {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: fontSize))
            }
        }
    }
}
