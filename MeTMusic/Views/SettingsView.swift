import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var store: AppStore
    @StateObject private var model = SettingsViewModel()

    private let qualities = [
        "web": "标准", "hq": "高品质", "sq": "无损", "rs": "Hi-Res",
        "dts": "DTS", "q360v1": "360 Reality Audio", "q360v2": "360 高品质", "qai": "臻品母带",
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section("账户") {
                    HStack {
                        ArtworkView(url: RemoteAssetURL.make(store.avatarURL), cornerRadius: 28).frame(width: 56, height: 56)
                        VStack(alignment: .leading) { Text(store.nickname).font(.headline); Text("QQ \(store.qqID)").foregroundStyle(.secondary) }
                    }
                    Button("退出登录", role: .destructive) { model.confirmLogout = true }
                }
                Section("播放") {
                    Picker("音质", selection: Binding(get: { store.soundQuality }, set: store.setQuality)) {
                        ForEach(qualities.keys.sorted(), id: \.self) { key in Text(qualities[key]!).tag(key) }
                    }
                    Picker("播放模式", selection: Binding(get: { store.playbackMode }, set: store.setPlaybackMode)) {
                        ForEach(PlaybackMode.allCases) { mode in Label(mode.title, systemImage: mode.symbol).tag(mode) }
                    }
                    LabeledContent("同步修正阈值", value: String(format: "%.1f 秒", store.syncThresholdSeconds))
                    Slider(value: Binding(get: { store.syncThresholdSeconds }, set: {
                        store.syncThresholdSeconds = $0; UserDefaults.standard.set($0, forKey: "sync_threshold")
                    }), in: 0.1...1, step: 0.1)
                }
                Section("歌词") {
                    Toggle("移除 QRC 歌曲信息行", isOn: Binding(
                        get: { store.removeQRCInformation },
                        set: store.setRemoveQRCInformation
                    ))
                    Stepper("时间偏移：\(store.lyricOffsetMs) ms", value: Binding(get: { store.lyricOffsetMs }, set: {
                        store.lyricOffsetMs = $0; UserDefaults.standard.set(Int($0), forKey: "lyric_offset")
                    }), in: -3_000...3_000, step: 50)
                    Stepper("提前步进：\(store.lyricLeadMs) ms", value: Binding(get: { store.lyricLeadMs }, set: {
                        store.lyricLeadMs = $0; UserDefaults.standard.set(Int($0), forKey: "lyric_lead")
                    }), in: 0...1_000, step: 50)
                    VStack(alignment: .leading) {
                        Text("主歌词字号 \(Int(store.lyricFontSize))")
                        Slider(value: Binding(get: { store.lyricFontSize }, set: {
                            store.lyricFontSize = $0; UserDefaults.standard.set($0, forKey: "lyric_font_size")
                        }), in: 22...46, step: 1)
                    }
                    VStack(alignment: .leading) {
                        Text("翻译字号 \(Int(store.translationFontSize))")
                        Slider(value: Binding(get: { store.translationFontSize }, set: {
                            store.translationFontSize = $0; UserDefaults.standard.set($0, forKey: "translation_font_size")
                        }), in: 11...22, step: 1)
                    }
                }
                Section {
                    Toggle("预缓存模式", isOn: Binding(
                        get: { store.precacheEnabled },
                        set: store.setPrecacheEnabled
                    ))
                    NavigationLink("管理已缓存音频") { CachedAudioView() }
                    ForEach(CacheStore.Category.allCases, id: \.self) { category in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(categoryTitle(category))
                                Text(byteText(store.cacheSizes[category] ?? 0)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("清理", role: .destructive) { Task { await store.clearCache(category) } }
                        }
                    }
                } header: {
                    Text("缓存")
                } footer: {
                    Text("预缓存模式会先把整首歌下载完再开始播放，下载期间播放进度条显示下载进度。")
                }
                Section("关于") {
                    LabeledContent("应用", value: "MeT-Music iOS")
                    LabeledContent("歌词引擎", value: "内置 Apple Music 风格歌词")
                    LabeledContent("许可证", value: "MIT")
                }
            }
            .navigationTitle("设置")
            .task { await store.refreshCacheSizes() }
            .confirmationDialog("确定退出登录？", isPresented: $model.confirmLogout, titleVisibility: .visible) {
                Button("退出登录", role: .destructive, action: store.logout)
            }
        }
    }

    private func categoryTitle(_ category: CacheStore.Category) -> String {
        switch category {
        case .playlists: "歌单"
        case .covers: "封面"
        case .songs: "歌曲"
        case .songMetadata: "歌曲信息"
        case .lyrics: "歌词"
        }
    }
    private func byteText(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
}

private final class SettingsViewModel: ObservableObject {
    @Published var confirmLogout = false
}
