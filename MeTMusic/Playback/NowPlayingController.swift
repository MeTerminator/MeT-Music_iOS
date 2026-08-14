import Foundation
#if canImport(MediaPlayer)
import MediaPlayer
#endif
#if os(iOS)
import ImageIO
import UIKit
#endif

#if canImport(MediaPlayer)
/// MediaPlayer invokes command handlers on an internal queue. Keep those
/// Objective-C entry points nonisolated, then explicitly hop to MainActor for
/// all AppStore mutations.
private final class RemoteCommandBridge: NSObject, @unchecked Sendable {
    private weak var store: AppStore?

    init(store: AppStore) {
        self.store = store
    }

    @objc func play(_ event: MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        Task { @MainActor [weak store] in store?.remotePlay() }
        return .success
    }

    @objc func pause(_ event: MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        Task { @MainActor [weak store] in store?.remotePause() }
        return .success
    }

    @objc func next(_ event: MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        Task { @MainActor [weak store] in store?.next() }
        return .success
    }

    @objc func previous(_ event: MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        Task { @MainActor [weak store] in store?.previous() }
        return .success
    }

    @objc func changePlaybackPosition(_ event: MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
        guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
        let positionMs = Int64(event.positionTime * 1_000)
        Task { @MainActor [weak store] in await store?.seek(to: positionMs) }
        return .success
    }
}
#endif

#if os(iOS)
/// MPMediaItemArtwork may request its image from a background MediaPlayer
/// queue, so its provider must not inherit MainActor isolation.
private enum MediaArtworkFactory {
    nonisolated static func make(image: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
    }
}
#endif

@MainActor
final class NowPlayingController {
    private weak var store: AppStore?
    private var currentSong: Song?
    private var currentPlaying = false
    private var currentPositionMs: Int64 = 0
    private var currentDurationMs: Int64 = 0
    private var artworkSongID: String?
    private var artworkTask: Task<Void, Never>?
    #if os(iOS)
    private var artwork: MPMediaItemArtwork?
    #endif
    #if canImport(MediaPlayer)
    private let commandBridge: RemoteCommandBridge
    #endif

    init(store: AppStore) {
        self.store = store
        #if canImport(MediaPlayer)
        commandBridge = RemoteCommandBridge(store: store)
        let commands = MPRemoteCommandCenter.shared()
        commands.playCommand.addTarget(commandBridge, action: #selector(RemoteCommandBridge.play(_:)))
        commands.pauseCommand.addTarget(commandBridge, action: #selector(RemoteCommandBridge.pause(_:)))
        commands.nextTrackCommand.addTarget(commandBridge, action: #selector(RemoteCommandBridge.next(_:)))
        commands.previousTrackCommand.addTarget(commandBridge, action: #selector(RemoteCommandBridge.previous(_:)))
        commands.changePlaybackPositionCommand.addTarget(
            commandBridge,
            action: #selector(RemoteCommandBridge.changePlaybackPosition(_:))
        )
        #endif
    }

    func update(song: Song?, playing: Bool, positionMs: Int64, durationMs: Int64) {
        #if canImport(MediaPlayer)
        let songChanged = currentSong?.id != song?.id
        currentSong = song
        currentPlaying = playing
        currentPositionMs = positionMs
        currentDurationMs = durationMs

        guard let song else {
            artworkTask?.cancel()
            artworkTask = nil
            artworkSongID = nil
            #if os(iOS)
            artwork = nil
            #endif
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }

        if songChanged { loadArtwork(for: song) }
        publish()
        #endif
    }

    #if canImport(MediaPlayer)
    private func publish() {
        guard let song = currentSong else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: song.name,
            MPMediaItemPropertyArtist: song.artistText,
            MPMediaItemPropertyAlbumTitle: song.album?.name ?? "",
            MPMediaItemPropertyPlaybackDuration: Double(max(currentDurationMs, song.durationMs)) / 1_000,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: Double(currentPositionMs) / 1_000,
            MPNowPlayingInfoPropertyPlaybackRate: currentPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        #if os(iOS)
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        #endif
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func loadArtwork(for song: Song) {
        artworkTask?.cancel()
        artworkTask = nil
        artworkSongID = song.id
        #if os(iOS)
        artwork = nil
        #endif

        guard let url = song.bestCoverURL, let store else { return }
        artworkTask = Task { [weak self, weak store] in
            guard let store, let data = try? await store.cache.coverData(remoteURL: url),
                  !Task.isCancelled else { return }
            #if os(iOS)
            guard let image = Self.decodeArtwork(data) else { return }
            #endif
            guard let self, self.artworkSongID == song.id, self.currentSong?.id == song.id else { return }
            #if os(iOS)
            self.artwork = MediaArtworkFactory.make(image: image)
            #endif
            self.publish()
        }
    }
    #endif

    #if os(iOS)
    private static func decodeArtwork(_ data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return UIImage(cgImage: image)
    }
    #endif

    deinit { artworkTask?.cancel() }
}
