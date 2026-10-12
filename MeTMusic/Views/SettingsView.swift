import SwiftUI

struct SettingsView: View {
  var usesNavigationStack = true
  @EnvironmentObject private var store: AppStore
  @StateObject private var model = SettingsViewModel()

  private enum Page: String, CaseIterable, Identifiable {
    case account = "账户"
    case playback = "播放"
    case lyrics = "歌词"
    case cache = "缓存"
    case about = "关于"
    var id: Self { self }
    var subtitle: String {
      switch self {
      case .account: "管理你的音乐库账户"
      case .playback: "选择音质与播放方式"
      case .lyrics: "调整歌词的时间与显示大小"
      case .cache: "管理离线音频与本地存储"
      case .about: "关于 MeT-Music"
      }
    }
  }
  @State private var page: Page = .playback

  private func shows(_ item: Page) -> Bool {
    #if os(macOS)
      page == item
    #else
      true
    #endif
  }

  private let qualities = [
    "web": "标准", "hq": "高品质", "sq": "无损", "rs": "Hi-Res",
    "dts": "DTS", "q360v1": "360 Reality Audio", "q360v2": "360 高品质", "qai": "臻品母带",
  ]

  var body: some View {
    Group {
      if usesNavigationStack { NavigationStack { settingsContent } } else { settingsContent }
    }
    #if os(macOS)
      .preferredColorScheme(.dark)
    #endif
  }

  private var settingsContent: some View {
    Group {
      VStack(spacing: 0) {
        #if os(macOS)
          VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
              Text(page.rawValue).font(.system(size: 26, weight: .bold))
              Text(page.subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
            Picker("设置分类", selection: $page) {
              ForEach(Page.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .padding(.horizontal, 28)
          .padding(.top, 24)
          .padding(.bottom, 12)
        #endif
        settingsForm
      }
      .navigationTitle("设置")
      .musicNavigationBarHidden(false)
      .task { await store.refreshCacheSizes() }
      .confirmationDialog("确定退出登录？", isPresented: $model.confirmLogout, titleVisibility: .visible) {
        Button("退出登录", role: .destructive, action: store.logout)
      }
    }
  }

  private var settingsForm: some View {
    Form {
      if shows(.account) {
        Section("账户") {
          HStack {
            ArtworkView(url: RemoteAssetURL.make(store.avatarURL), cornerRadius: 28).frame(
              width: 56, height: 56)
            VStack(alignment: .leading) {
              Text(store.nickname).font(.headline)
              Text("QQ \(store.qqID)").foregroundStyle(.secondary)
            }
          }
          Button("退出登录", role: .destructive) { model.confirmLogout = true }
        }
      }
      if shows(.playback) {
        Section("播放") {
          Picker("音质", selection: Binding(get: { store.soundQuality }, set: store.setQuality)) {
            ForEach(qualities.keys.sorted(), id: \.self) { key in Text(qualities[key]!).tag(key) }
          }
          Picker(
            "播放模式", selection: Binding(get: { store.playbackMode }, set: store.setPlaybackMode)
          ) {
            ForEach(PlaybackMode.allCases) { mode in
              Label(mode.title, systemImage: mode.symbol).tag(mode)
            }
          }
          VStack(alignment: .leading, spacing: 12) {
            HStack {
              Text("同步修正阈值")
              Spacer()
              Text(String(format: "%.1f 秒", store.syncThresholdSeconds))
                .foregroundStyle(.secondary).monospacedDigit()
            }
            Slider(
              value: Binding(
                get: { store.syncThresholdSeconds },
                set: {
                  store.syncThresholdSeconds = $0
                  UserDefaults.standard.set($0, forKey: "sync_threshold")
                }), in: 0.1...1, step: 0.1
            )
            .accessibilityLabel("同步修正阈值")
          }
        }
      }
      if shows(.lyrics) {
        Section("歌词") {
          Toggle(
            "移除 QRC 歌曲信息行",
            isOn: Binding(
              get: { store.removeQRCInformation },
              set: store.setRemoveQRCInformation
            ))
          Stepper(
            "时间偏移：\(store.lyricOffsetMs) ms",
            value: Binding(
              get: { store.lyricOffsetMs },
              set: {
                store.lyricOffsetMs = $0
                UserDefaults.standard.set(Int($0), forKey: "lyric_offset")
              }), in: -3_000...3_000, step: 50)
          Stepper(
            "提前步进：\(store.lyricLeadMs) ms",
            value: Binding(
              get: { store.lyricLeadMs },
              set: {
                store.lyricLeadMs = $0
                UserDefaults.standard.set(Int($0), forKey: "lyric_lead")
              }), in: 0...1_000, step: 50)
          VStack(alignment: .leading) {
            Text("主歌词字号 \(Int(store.lyricFontSize))")
            Slider(
              value: Binding(
                get: { store.lyricFontSize },
                set: {
                  store.lyricFontSize = $0
                  UserDefaults.standard.set($0, forKey: "lyric_font_size")
                }), in: 22...46, step: 1)
          }
          VStack(alignment: .leading) {
            Text("翻译字号 \(Int(store.translationFontSize))")
            Slider(
              value: Binding(
                get: { store.translationFontSize },
                set: {
                  store.translationFontSize = $0
                  UserDefaults.standard.set($0, forKey: "translation_font_size")
                }), in: 11...22, step: 1)
          }
        }
      }
      if shows(.cache) {
        Section {
          Toggle(
            "预缓存模式",
            isOn: Binding(
              get: { store.precacheEnabled },
              set: store.setPrecacheEnabled
            ))
          NavigationLink("管理已缓存音频") { CachedAudioView() }
          ForEach(CacheStore.Category.allCases, id: \.self) { category in
            HStack {
              VStack(alignment: .leading) {
                Text(categoryTitle(category))
                Text(byteText(store.cacheSizes[category] ?? 0)).font(.caption).foregroundStyle(
                  .secondary)
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
      }
      if shows(.about) {
        Section("关于") {
          LabeledContent("应用", value: "MeT-Music")
          LabeledContent("歌词引擎", value: "内置 Apple Music 风格歌词")
          LabeledContent("许可证", value: "MIT")
        }
      }

    }
    #if os(macOS)
      .formStyle(.grouped)
      .scrollContentBackground(.hidden)
      .background(.quaternary.opacity(0.3))
    #endif
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
  private func byteText(_ bytes: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
  }
}

private final class SettingsViewModel: ObservableObject {
  @Published var confirmLogout = false
}
