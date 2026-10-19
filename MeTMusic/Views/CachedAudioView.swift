import SwiftUI

struct CachedAudioView: View {
    @EnvironmentObject private var store: AppStore
    @State private var audios: [CacheStore.CachedAudio] = []
    @State private var loading = true

    var body: some View {
        List {
            Section {
                HStack {
                    LabeledContent("总计缓存", value: ByteCountFormatter.string(
                        fromByteCount: audios.reduce(0) { $0 + $1.size },
                        countStyle: .file
                    ))
                    Spacer()
                    Text("\(audios.count) 首").foregroundStyle(.secondary)
                }
            }
            if !loading, audios.isEmpty {
                ContentUnavailableView("暂无已缓存歌曲", systemImage: "externaldrive.badge.xmark")
                    .listRowBackground(Color.clear)
            } else {
                Section("歌曲") {
                    ForEach(audios) { cached in
                        HStack(spacing: 12) {
                            ArtworkView(url: cached.song.bestCoverURL, cornerRadius: 7)
                                .frame(width: 50, height: 50)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(cached.song.name).font(.headline).lineLimit(1)
                                Text(cached.song.artistText).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                HStack(spacing: 8) {
                                    Text(qualityName(cached.quality))
                                        .font(.caption2.bold())
                                        .foregroundStyle(qualityColor(cached.quality))
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .overlay(Capsule().stroke(qualityColor(cached.quality)))
                                    Text(ByteCountFormatter.string(fromByteCount: cached.size, countStyle: .file))
                                        .font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .swipeActions {
                            Button("删除", role: .destructive) { Task { await delete(cached) } }
                        }
                    }
                }
            }
        }
        .musicNavigationTitle("已缓存音频")
        .macTransparentScrollBackground()
        .overlay { if loading { ProgressView() } }
        .refreshable { await refresh() }
        .task { await refresh() }
        .toolbar { Button { Task { await refresh() } } label: { Image(systemName: "arrow.clockwise") } }
    }

    private func refresh() async {
        loading = true
        audios = await store.cache.cachedAudios()
        loading = false
    }

    private func delete(_ cached: CacheStore.CachedAudio) async {
        do {
            try await store.cache.deleteCachedAudio(songID: cached.id)
            await store.refreshCacheSizes()
            await refresh()
            store.showToast("已删除 \(cached.song.name) 的缓存")
        } catch { store.showToast("删除失败：\(error.localizedDescription)") }
    }

    private func qualityName(_ quality: String) -> String {
        switch quality {
        case "web": "普通 WEB"
        case "hq": "极高 HQ"
        case "sq": "无损 SQ"
        case "rs": "Hi-Res"
        case "dts": "杜比 5.1"
        case "q360v1": "全景声 V1"
        case "q360v2": "全景声 V2"
        case "qai": "臻品母带"
        default: "未知"
        }
    }

    private func qualityColor(_ quality: String) -> Color {
        switch quality {
        case "qai": .purple
        case "q360v1", "q360v2": .cyan
        case "dts": .orange
        case "rs": .yellow
        case "sq": .pink
        case "hq": .green
        case "web": .blue
        default: .secondary
        }
    }
}
