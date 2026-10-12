import SwiftUI
import ImageIO
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

struct LibraryView: View {
    @EnvironmentObject private var store: AppStore

    private enum Destination: Hashable { case together, settings }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                libraryHeader
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 16)], spacing: 16) {
                        ForEach(store.playlists) { playlist in
                            NavigationLink(value: playlist) {
                                VStack(alignment: .leading, spacing: 8) {
                                    ArtworkView(url: playlist.bestCoverURL, cornerRadius: 8)
                                        .aspectRatio(1, contentMode: .fit)
                                    Text(playlist.name)
                                        .font(.system(size: 14, weight: .semibold))
                                        .lineLimit(1).foregroundStyle(.primary)
                                    Text("\(playlist.trackCount) 首歌曲")
                                        .font(.system(size: 12)).foregroundStyle(.secondary)
                                }
                                .padding(4)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .refreshable { await store.loadUserPlaylists() }
                .overlay {
                    if store.playlists.isEmpty {
                        if store.loadingPlaylists { ProgressView() }
                        else { Text("没有找到歌单").foregroundStyle(.secondary) }
                    }
                }
            }
            .musicNavigationBarHidden(true)
            .navigationDestination(for: Playlist.self) { PlaylistDetailView(playlist: $0) }
            .navigationDestination(for: Destination.self) { destination in
                switch destination {
                case .together: ListenTogetherView(usesNavigationStack: false)
                case .settings: SettingsView(usesNavigationStack: false)
                }
            }
        }
    }

    private var libraryHeader: some View {
        HStack(spacing: 12) {
            ArtworkView(url: RemoteAssetURL.make(store.avatarURL), cornerRadius: 18)
                .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text("资料库").font(.system(size: 20, weight: .bold))
                Text(store.nickname).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if store.loadingPlaylists, !store.playlists.isEmpty { ProgressView() }
            NavigationLink(value: Destination.together) {
                Image(systemName: "person.2.wave.2").frame(width: 44, height: 44)
            }
            .accessibilityLabel("一起听")
            NavigationLink(value: Destination.settings) {
                Image(systemName: "gearshape").frame(width: 44, height: 44)
            }
            .accessibilityLabel("设置")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .padding(.horizontal, 16)
        .frame(height: 64)
    }
}

struct PlaylistDetailView: View {
    @EnvironmentObject private var store: AppStore
    let playlist: Playlist
    @StateObject private var model = PlaylistDetailModel()

    var body: some View {
        GeometryReader { geometry in
            List {
                Section {
                    VStack(spacing: 14) {
                        ArtworkView(url: playlist.bestCoverURL, cornerRadius: 20).frame(width: 220, height: 220)
                        Text(playlist.name).font(.title2.bold()).multilineTextAlignment(.center)
                        if let creator = playlist.creator?.nickname { Text(creator).foregroundStyle(.pink) }
                        Button {
                            if !model.songs.isEmpty { store.playPlaylist(model.songs, from: 0) }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "play.fill")
                                Text("播放")
                            }
                            .foregroundStyle(.white)
                            .frame(width: geometry.size.width / 3, height: 43)
                            .background(.pink, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .disabled(model.songs.isEmpty)

                        Divider()
                            .frame(maxWidth: .infinity)
                    }
                    .frame(maxWidth: .infinity)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden, edges: .bottom)

                    ForEach(Array(model.songs.enumerated()), id: \.element.id) { index, song in
                        Button { store.playPlaylist(model.songs, from: index) } label: {
                            SongRow(
                                song: song,
                                number: index + 1,
                                active: store.currentSong?.id == song.id,
                                hasTTML: song.hasTTML
                            )
                        }
                        .buttonStyle(.plain)
                        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                    }
                }
            }
            .listStyle(.inset)
            #if os(macOS)
            .navigationTitle(store.isPlayerPresented ? "" : playlist.name)
            .navigationBarBackButtonHidden(store.isPlayerPresented)
            #else
            .navigationTitle(playlist.name)
            #endif
            .musicNavigationBarHidden(false)
            .task { model.songs = await store.tracks(for: playlist) }
            .refreshable { model.songs = await store.tracks(for: playlist, refresh: true) }
            .overlay { if store.loadingPlaylistIDs.contains(playlist.id) && model.songs.isEmpty { ProgressView().controlSize(.large) } }
        }
    }
}

private final class PlaylistDetailModel: ObservableObject {
    @Published var songs: [Song] = []
}

struct SongRow: View {
    let song: Song
    var number: Int? = nil
    var active = false
    var hasTTML = false
    var body: some View {
        HStack(spacing: 12) {
            if let number { Text(String(number)).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 24) }
            ArtworkView(url: song.bestCoverURL, cornerRadius: 7, maxPixelSize: 160)
                .frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(song.name)
                        .fontWeight(active ? .semibold : .regular)
                        .foregroundStyle(active ? .pink : .primary)
                        .lineLimit(1)
                    if hasTTML {
                        Text("TTML")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.pink)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(.pink.opacity(0.16), in: RoundedRectangle(cornerRadius: 4))
                    }
                }
                Text(song.artistText).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text(song.formattedDuration).font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
        }.contentShape(Rectangle())
    }
}

struct ArtworkView: View {
    @EnvironmentObject private var store: AppStore
    let url: URL?
    var cornerRadius: CGFloat = 10
    var maxPixelSize: Int = 600
    @StateObject private var model = ArtworkModel()
    var body: some View {
        Group {
            if let image = model.image {
                #if os(iOS)
                Image(uiImage: image).resizable().scaledToFill()
                #elseif os(macOS)
                Image(nsImage: image).resizable().scaledToFill()
                #endif
            } else {
                ZStack { placeholder; if model.isLoading { ProgressView() } }
            }
        }
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .task(id: ArtworkRequest(url: url, maxPixelSize: maxPixelSize)) {
            await model.load(url: url, maxPixelSize: maxPixelSize, cache: store.cache)
        }
    }
    private var placeholder: some View {
        ZStack { Color.secondary.opacity(0.14); Image(systemName: "music.note").font(.title2).foregroundStyle(.secondary) }
    }
}

private struct ArtworkRequest: Hashable {
    let url: URL?
    let maxPixelSize: Int
}

#if os(iOS)
private typealias PlatformArtworkImage = UIImage
#elseif os(macOS)
private typealias PlatformArtworkImage = NSImage
#endif

private final class SendableArtworkImage: @unchecked Sendable {
    let image: PlatformArtworkImage
    init(_ image: PlatformArtworkImage) { self.image = image }
}

private final class ArtworkMemoryCache: @unchecked Sendable {
    static let shared = ArtworkMemoryCache()
    private let cache = NSCache<NSString, SendableArtworkImage>()

    private init() {
        cache.countLimit = 180
        cache.totalCostLimit = 48 * 1_024 * 1_024
    }

    func image(for key: String) -> SendableArtworkImage? { cache.object(forKey: key as NSString) }
    func insert(_ image: SendableArtworkImage, for key: String, cost: Int) {
        cache.setObject(image, forKey: key as NSString, cost: cost)
    }
}

private actor ArtworkDecodePipeline {
    static let shared = ArtworkDecodePipeline()
    private var active: [String: Task<SendableArtworkImage?, Never>] = [:]

    func image(data: Data, key: String, maxPixelSize: Int) async -> SendableArtworkImage? {
        if let cached = ArtworkMemoryCache.shared.image(for: key) { return cached }
        if let task = active[key] { return await task.value }
        let task = Task.detached(priority: .userInitiated) {
            Self.decode(data: data, maxPixelSize: maxPixelSize)
        }
        active[key] = task
        let image = await task.value
        active[key] = nil
        if let image {
            ArtworkMemoryCache.shared.insert(
                image,
                for: key,
                cost: maxPixelSize * maxPixelSize * 4
            )
        }
        return image
    }

    nonisolated private static func decode(data: Data, maxPixelSize: Int) -> SendableArtworkImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: max(maxPixelSize, 32),
                  kCGImageSourceShouldCacheImmediately: true,
              ] as CFDictionary) else { return nil }
        #if os(iOS)
        return SendableArtworkImage(UIImage(cgImage: cgImage))
        #elseif os(macOS)
        return SendableArtworkImage(NSImage(cgImage: cgImage, size: .zero))
        #endif
    }
}

@MainActor
private final class ArtworkModel: ObservableObject {
    @Published var image: PlatformArtworkImage?
    @Published var isLoading = false

    func load(url: URL?, maxPixelSize: Int, cache: CacheStore) async {
        image = nil
        guard let url else { isLoading = false; return }
        let key = "\(url.absoluteString)#\(maxPixelSize)"
        if let cached = ArtworkMemoryCache.shared.image(for: key) {
            image = cached.image
            isLoading = false
            return
        }
        isLoading = true
        defer { isLoading = false }
        guard let data = try? await cache.coverData(remoteURL: url), !Task.isCancelled,
              let decoded = await ArtworkDecodePipeline.shared.image(
                  data: data,
                  key: key,
                  maxPixelSize: maxPixelSize
              ), !Task.isCancelled else { return }
        image = decoded.image
    }
}

extension View {
    @ViewBuilder
    func musicNavigationBarHidden(_ hidden: Bool) -> some View {
        #if os(iOS)
        toolbar(hidden ? .hidden : .visible, for: .navigationBar)
        #else
        self
        #endif
    }
}
