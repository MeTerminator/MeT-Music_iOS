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
                    Image(systemName: store.audio.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 28))
                        .frame(width: 44, height: 48)
                }
                .accessibilityLabel(store.audio.isPlaying ? "暂停" : "播放")
                Button { showingQueue = true } label: {
                    Image(systemName: "list.bullet")
                        .font(.system(size: 25)).frame(width: 44, height: 48)
                }
                .accessibilityLabel("播放列表")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .frame(height: 60)
            .transparentPlayerGlass()
            .contentShape(RoundedRectangle(cornerRadius: 32))
            .onTapGesture { store.isPlayerPresented = true }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("正在播放：\(song.name)，\(song.artistText)")
            .sheet(isPresented: $showingQueue) { QueueView() }
        }
    }
}

private extension View {
    @ViewBuilder
    func transparentPlayerGlass() -> some View {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            glassEffect(.clear.interactive(), in: .rect(cornerRadius: 32))
        } else {
            background(.ultraThinMaterial.opacity(0.35), in: RoundedRectangle(cornerRadius: 32))
        }
        #else
        background(.ultraThinMaterial.opacity(0.35), in: RoundedRectangle(cornerRadius: 32))
        #endif
    }
}
