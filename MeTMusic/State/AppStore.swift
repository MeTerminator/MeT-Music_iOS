import Combine
import Foundation

enum PlaybackMode: String, CaseIterable, Codable, Identifiable {
    case sequence, loopList, shuffle, loopSingle
    var id: String { rawValue }
    var title: String {
        switch self {
        case .sequence: "顺序播放"
        case .loopList: "列表循环"
        case .shuffle: "随机播放"
        case .loopSingle: "单曲循环"
        }
    }
    var symbol: String {
        switch self {
        case .sequence: "arrow.right"
        case .loopList: "repeat"
        case .shuffle: "shuffle"
        case .loopSingle: "repeat.1"
        }
    }
}

@MainActor
final class AppStore: ObservableObject {
    @Published var isLoggedIn = false
    @Published var qqID = ""
    @Published var nickname = "未登录"
    @Published var avatarURL = ""
    @Published var playlists: [Playlist] = []
    @Published var playlistTracks: [String: [Song]] = [:]
    @Published var loadingPlaylists = false
    @Published var loadingPlaylistIDs = Set<String>()

    @Published var queue: [Song] = []
    @Published var currentIndex = -1
    @Published var currentSong: Song?
    @Published var lyrics: [LyricLine] = []
    @Published var ttmlAuthor: String?
    @Published var isPlayerPresented = false
    @Published var playbackMode: PlaybackMode = .sequence

    @Published var soundQuality = "hq"
    @Published var lyricOffsetMs: Int64 = 0
    @Published var lyricLeadMs: Int64 = 0
    @Published var lyricFontSize: Double = 32
    @Published var translationFontSize: Double = 16
    @Published var removeQRCInformation = true
    @Published var syncThresholdSeconds = 0.3
    @Published var precacheEnabled = false
    /// Set while precache mode holds playback back for the current song, so the
    /// player can show download progress in place of the playback progress bar.
    @Published private(set) var precacheDownload: AudioDownloadProgress?
    @Published private var isResolvingPlayback = false

    var isPlaybackLoading: Bool {
        isResolvingPlayback || audio.isLoading || precacheDownload != nil
    }
    @Published var cacheSizes: [CacheStore.Category: Int64] = [:]
    @Published var toast: String?

    let audio = AudioPlayer()
    let cache = CacheStore()
    let api = APIClient.shared
    lazy var together = ListenTogetherStore(app: self)
    private lazy var nowPlaying = NowPlayingController(store: self)
    private var cancellables = Set<AnyCancellable>()
    private var playbackGeneration = 0
    private var accurateSeekGeneration = 0
    private var activeSeek: Task<Void, Never>?
    private var requestedSeekTargetMs: Int64?
    private var seekResumesPlayback = false
    private var standaloneStreamingSongID: String?
    private var standaloneStreamingURL: URL?
    private var toastTask: Task<Void, Never>?
    private let defaults = UserDefaults.standard

    init() {
        restoreSettings()
        restorePlayback()
        bindPlayer()
        observeDownloadProgress()
        _ = nowPlaying
        if !qqID.isEmpty {
            isLoggedIn = true
            Task { await loadUserPlaylists() }
        }
        Task { await refreshCacheSizes() }
    }

    func login(qq: String) async -> Bool {
        let value = qq.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { showToast("请输入 QQ 号"); return false }
        loadingPlaylists = true
        defer { loadingPlaylists = false }
        do {
            let response = try await api.userPlaylists(uid: value)
            guard !response.playlist.isEmpty else { showToast("没有找到该用户的歌单"); return false }
            try? await cache.savePlaylists(response.playlist, uid: value)
            qqID = value
            nickname = response.username ?? value
            avatarURL = response.avatarUrl ?? ""
            playlists = response.playlist
            isLoggedIn = true
            persistUser()
            showToast("登录成功")
            return true
        } catch {
            if let cached = await cache.playlists(uid: value) {
                qqID = value; playlists = cached; nickname = defaults.string(forKey: "nickname") ?? value
                avatarURL = defaults.string(forKey: "avatar_url") ?? ""; isLoggedIn = true; persistUser()
                showToast("网络不可用，已载入缓存歌单")
                return true
            }
            showToast("登录失败：\(error.localizedDescription)")
            return false
        }
    }

    func logout() {
        together.leaveRoom()
        playbackGeneration += 1
        clearStandaloneStreamingSource()
        precacheDownload = nil
        audio.stop()
        ["qq_id", "nickname", "avatar_url"].forEach(defaults.removeObject)
        isLoggedIn = false; qqID = ""; nickname = "未登录"; avatarURL = ""
        playlists = []; playlistTracks = [:]; queue = []; currentIndex = -1; currentSong = nil; lyrics = []
        ttmlAuthor = nil
    }

    func loadUserPlaylists() async {
        guard !qqID.isEmpty else { return }
        loadingPlaylists = true
        if let cached = await cache.playlists(uid: qqID) { playlists = cached }
        do {
            let response = try await api.userPlaylists(uid: qqID)
            playlists = response.playlist
            nickname = response.username ?? nickname
            avatarURL = response.avatarUrl ?? avatarURL
            try? await cache.savePlaylists(playlists, uid: qqID)
            persistUser()
        } catch {
            if playlists.isEmpty { showToast("载入歌单失败：\(error.localizedDescription)") }
        }
        loadingPlaylists = false
    }

    func tracks(for playlist: Playlist, refresh: Bool = false) async -> [Song] {
        if !refresh, let existing = playlistTracks[playlist.id] { return existing }
        loadingPlaylistIDs.insert(playlist.id)
        defer { loadingPlaylistIDs.remove(playlist.id) }
        if !refresh, let cached = await cache.tracks(playlistID: playlist.id) { playlistTracks[playlist.id] = cached }
        do {
            let response = try await api.playlistTracks(id: playlist.id)
            playlistTracks[playlist.id] = response.songs
            try? await cache.saveTracks(response.songs, playlistID: playlist.id)
        } catch {
            if playlistTracks[playlist.id] == nil { showToast("载入歌曲失败：\(error.localizedDescription)") }
        }
        return playlistTracks[playlist.id] ?? []
    }

    func playPlaylist(_ songs: [Song], from index: Int) {
        guard songs.indices.contains(index) else { return }
        if together.isInRoom { together.addSong(songs[index]); showToast("已添加到一起听播放列表"); return }
        queue = songs
        play(at: index)
    }

    func play(at index: Int) {
        guard queue.indices.contains(index) else { return }
        audio.stop()
        currentIndex = index
        currentSong = queue[index]
        startStandalone(queue[index], startPositionMs: 0)
    }

    func togglePlayback() {
        guard !isPlaybackLoading else { return }
        if together.isInRoom { together.sendPlayOrPause(); return }
        audio.isPlaying ? pause() : resume()
    }
    func pause() {
        // A running seek transaction resumes playback when it finishes, so
        // pausing during one has to cancel that rather than be overridden.
        seekResumesPlayback = false
        audio.pause()
    }
    func resume() {
        // The loaded item is still at the pre-seek position while a transaction
        // runs, so playing it now would start audio somewhere the user left.
        if activeSeek != nil { seekResumesPlayback = true; return }
        guard !isPlaybackLoading else { return }
        if audio.isReady { audio.resume() }
        else if let currentSong { startStandalone(currentSong) }
    }

    func next(auto: Bool = false) {
        if together.isInRoom { if !auto { together.send(action: "next") }; return }
        guard !queue.isEmpty else { return }
        var next = currentIndex
        switch playbackMode {
        case .sequence:
            next += 1
            if next >= queue.count { if auto { audio.stop(); return }; next = 0 }
        case .loopList: next = (next + 1) % queue.count
        case .loopSingle: if !auto { next = (next + 1) % queue.count }
        case .shuffle: next = randomIndex(excluding: currentIndex)
        }
        play(at: next)
    }

    func previous() {
        if together.isInRoom { together.send(action: "prev"); return }
        guard !queue.isEmpty else { return }
        let previous = playbackMode == .shuffle ? randomIndex(excluding: currentIndex) : (currentIndex - 1 + queue.count) % queue.count
        play(at: previous)
    }

    /// Seeks in one deliberate, sequential transaction: playback pauses, the
    /// media is made ready to seek — a stream is cached to a complete local
    /// file first — the player moves to the exact position, and only then does
    /// playback resume.
    ///
    /// Only one transaction runs at a time. Tapping lyrics repeatedly retargets
    /// the running one instead of starting a second move, so the player is
    /// never chasing two positions at once and audio always ends up at the
    /// lyric that was tapped last.
    func seek(to milliseconds: Int64) async {
        if together.isInRoom { together.seek(toSeconds: Double(milliseconds) / 1_000); return }
        requestSeek(to: milliseconds)
        await activeSeek?.value
    }

    private func requestSeek(to milliseconds: Int64) {
        // The requested position is published straight away, so the lyric that
        // was tapped lights up while the transaction runs.
        audio.pinSeekTarget(milliseconds)
        requestedSeekTargetMs = milliseconds
        guard activeSeek == nil else { return }
        // Captured before the first pause of a burst of taps, so a later tap
        // cannot conclude that playback was already stopped.
        seekResumesPlayback = audio.isPlaying
        audio.pause()
        accurateSeekGeneration += 1
        let request = accurateSeekGeneration
        let generation = playbackGeneration
        activeSeek = Task { @MainActor [weak self] in
            defer { self?.activeSeek = nil }
            var applied: Int64?
            while let self, let target = takeRequestedSeekTarget(applied: applied) {
                guard request == accurateSeekGeneration, generation == playbackGeneration else { return }
                if await applySeek(to: target) { applied = target }
            }
            guard let self, request == accurateSeekGeneration, generation == playbackGeneration else { return }
            // Every tap pins its target, including one this transaction already
            // reached, so the last pin is always released here.
            audio.releaseSeekPin()
            if seekResumesPlayback { audio.resume() }
            savePlayback()
        }
    }

    /// Returns the position the transaction still has to move to, skipping a
    /// repeat of the position it already reached — tapping the same lyric again
    /// must not seek again.
    private func takeRequestedSeekTarget(applied: Int64?) -> Int64? {
        guard let target = requestedSeekTargetMs else { return nil }
        requestedSeekTargetMs = nil
        return target == applied ? nil : target
    }

    /// Returns whether playback ended up at `target`, so a repeat tap on the
    /// same lyric does not move it again.
    @discardableResult
    private func applySeek(to target: Int64) async -> Bool {
        audio.pause()
        guard let song = currentSong,
              standaloneStreamingSongID == song.id,
              let remoteURL = standaloneStreamingURL else {
            return await audio.seekExactly(to: target)
        }
        // Streamed playback cannot seek precisely, so the complete file is
        // cached first and playback continues from it.
        let needsDownload = await cache.cachedAudioURL(songID: song.id) == nil
        if needsDownload, currentSong?.id == song.id { precacheDownload = .init(songID: song.id) }
        do {
            let localURL = try await cache.audioURL(songID: song.id, remoteURL: remoteURL, waitForCache: true)
            precacheDownload = nil
            guard currentSong?.id == song.id, !together.isInRoom else { return false }
            standaloneStreamingSongID = nil
            standaloneStreamingURL = nil
            return await audio.load(url: localURL, autoPlay: false, startPositionMs: target)
        } catch {
            precacheDownload = nil
            guard currentSong?.id == song.id else { return false }
            showToast("精确跳转缓存失败，已使用串流跳转")
            return await audio.seekExactly(to: target)
        }
    }

    func remotePlay() {
        if together.isInRoom { together.send(action: "play") } else { resume() }
    }

    func remotePause() {
        if together.isInRoom { together.send(action: "pause") } else { pause() }
    }

    func setPlaybackMode(_ mode: PlaybackMode) {
        playbackMode = mode
        defaults.set(mode.rawValue, forKey: "playback_mode")
    }
    func cyclePlaybackMode() {
        let modes = PlaybackMode.allCases
        setPlaybackMode(modes[(modes.firstIndex(of: playbackMode)! + 1) % modes.count])
    }

    func setPrecacheEnabled(_ enabled: Bool) {
        precacheEnabled = enabled
        defaults.set(enabled, forKey: "precache_mode")
    }

    func setQuality(_ quality: String) {
        let position = audio.positionMs
        soundQuality = quality
        defaults.set(quality, forKey: "sound_quality")
        if let currentSong, !together.isInRoom { startStandalone(currentSong, startPositionMs: position) }
    }

    func refreshCacheSizes() async {
        var values: [CacheStore.Category: Int64] = [:]
        for category in CacheStore.Category.allCases { values[category] = await cache.cacheSize(category) }
        cacheSizes = values
    }
    func clearCache(_ category: CacheStore.Category) async {
        do { try await cache.clear(category); await refreshCacheSizes(); showToast("缓存已清理") }
        catch { showToast("清理失败：\(error.localizedDescription)") }
    }

    func setRemoveQRCInformation(_ enabled: Bool) {
        removeQRCInformation = enabled
        defaults.set(enabled, forKey: "remove_qrc_song_info")
        guard let song = currentSong else { return }
        Task {
            let result = await loadLyricResult(for: song)
            apply(result, to: song)
        }
    }

    func showToast(_ text: String) {
        toastTask?.cancel()
        toast = text
        toastTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { toast = nil }
        }
    }

    func loadLyrics(for song: Song) async -> [LyricLine] {
        await loadLyricResult(for: song).lines
    }

    private struct LyricLoadResult {
        var lines: [LyricLine]
        var author: String?
        var hasTTML: Bool
    }

    private func loadOrdinaryLyricResult(for song: Song) async -> LyricLoadResult {
        var ordinary = await cache.lyric(songID: song.id)
        if ordinary == nil {
            ordinary = try? await api.lyric(id: song.id)
            if let ordinary { try? await cache.saveLyric(ordinary, songID: song.id) }
        }
        let fallback = ordinary.map { OrdinaryLyricParser.parse($0, removeQRCInformation: removeQRCInformation) } ?? []
        return .init(lines: fallback, author: nil, hasTTML: false)
    }

    private func loadTTMLLyricResult(for song: Song, fallback: [LyricLine]) async -> LyricLoadResult {
        do {
            let response = try await api.ttml(mid: song.lyricMid)
            guard response.status == "success", let content = response.content, !content.isEmpty else {
                return .init(lines: fallback, author: nil, hasTTML: false)
            }
            let result = try TTMLParser.parseAMLL(content)
            guard !result.lines.isEmpty else { return .init(lines: fallback, author: nil, hasTTML: false) }
            let author = result.metadata["ttmlAuthorGithubLogin"]?
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .reduce(into: [String]()) { values, value in if !values.contains(value) { values.append(value) } }
                .joined(separator: "、")
            return .init(lines: result.lines, author: author?.isEmpty == false ? author : nil, hasTTML: true)
        } catch { return .init(lines: fallback, author: nil, hasTTML: false) }
    }

    private func loadLyricResult(for song: Song) async -> LyricLoadResult {
        let ordinary = await loadOrdinaryLyricResult(for: song)
        return await loadTTMLLyricResult(for: song, fallback: ordinary.lines)
    }

    private func apply(_ result: LyricLoadResult, to song: Song) {
        guard currentSong?.id == song.id else { return }
        lyrics = result.lines
        ttmlAuthor = result.author
        if let author = result.author { showToast("TTML 作者：\(author)") }
    }

    private func startStandalone(_ song: Song, startPositionMs: Int64? = nil) {
        playbackGeneration += 1
        accurateSeekGeneration += 1
        requestedSeekTargetMs = nil
        seekResumesPlayback = false
        let generation = playbackGeneration
        audio.stop()
        standaloneStreamingSongID = nil
        standaloneStreamingURL = nil
        lyrics = []
        ttmlAuthor = nil
        precacheDownload = nil
        isResolvingPlayback = true
        // Precache mode downloads the complete file before playing, so playback
        // reads a local, fully seekable file instead of the network stream.
        let precaching = precacheEnabled
        Task {
            defer {
                if generation == playbackGeneration { isResolvingPlayback = false }
            }
            do {
                let remote: URL
                if let cached = await cache.remoteURL(songID: song.id, quality: soundQuality) { remote = cached }
                else { remote = try await api.songURL(id: song.id, quality: soundQuality) }
                await cache.setRemoteURL(remote, songID: song.id, quality: soundQuality)
                // An already cached song needs no download bar at all.
                let needsDownload = await cache.cachedAudioURL(songID: song.id) == nil
                if precaching, needsDownload, generation == playbackGeneration, currentSong?.id == song.id {
                    precacheDownload = .init(songID: song.id)
                }
                let playbackURL = try await cache.audioURL(
                    songID: song.id,
                    remoteURL: remote,
                    waitForCache: precaching
                )
                finishPrecache(generation: generation)
                guard generation == playbackGeneration, currentSong?.id == song.id else { return }
                let start = startPositionMs ?? restoredPosition(for: song)
                // Only playback that is actually reading the network needs the
                // cache-then-reload path to seek precisely; a local file seeks
                // exactly on its own.
                standaloneStreamingSongID = playbackURL.isFileURL ? nil : song.id
                standaloneStreamingURL = playbackURL.isFileURL ? nil : remote
                audio.play(url: playbackURL, startPositionMs: start)
                isResolvingPlayback = false
                if let cover = song.bestCoverURL { Task { _ = try? await cache.coverData(remoteURL: cover) } }
                let ordinary = await loadOrdinaryLyricResult(for: song)
                apply(ordinary, to: song)
                let ttml = await loadTTMLLyricResult(for: song, fallback: ordinary.lines)
                apply(ttml, to: song)
                try? await cache.saveSongMetadata(song, quality: soundQuality)
                savePlayback()
                preloadNext()
            } catch {
                guard generation == playbackGeneration else { return }
                precacheDownload = nil
                isResolvingPlayback = false
                showToast("播放失败：\(error.localizedDescription)")
                next(auto: true)
            }
        }
    }

    func playTogether(song: Song, localURL: URL, positionMs: Int64, isPlaying: Bool) async {
        playbackGeneration += 1
        clearStandaloneStreamingSource()
        currentSong = song
        lyrics = []
        ttmlAuthor = nil
        audio.play(url: localURL, autoPlay: isPlaying, startPositionMs: positionMs)
        let lyricResult = await loadLyricResult(for: song)
        apply(lyricResult, to: song)
    }

    private func preloadNext() {
        guard let song = nextSongCandidate() else { return }
        Task {
            if let cover = song.bestCoverURL { _ = try? await cache.coverData(remoteURL: cover) }
            let remote: URL?
            if let cached = await cache.remoteURL(songID: song.id, quality: soundQuality) { remote = cached }
            else { remote = try? await api.songURL(id: song.id, quality: soundQuality) }
            if let remote {
                await cache.setRemoteURL(remote, songID: song.id, quality: soundQuality)
                _ = try? await cache.audioURL(songID: song.id, remoteURL: remote, waitForCache: false)
            }
            _ = await loadLyrics(for: song)
        }
    }

    private func nextSongCandidate() -> Song? {
        guard !queue.isEmpty, queue.indices.contains(currentIndex) else { return nil }
        return queue[(currentIndex + 1) % queue.count]
    }
    private func randomIndex(excluding index: Int) -> Int {
        guard queue.count > 1 else { return 0 }
        var value = Int.random(in: queue.indices)
        while value == index { value = Int.random(in: queue.indices) }
        return value
    }

    private func bindPlayer() {
        audio.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        audio.onPlaybackComplete = { [weak self] in self?.next(auto: true) }
        audio.onPlaybackFailure = { [weak self] message in self?.showToast(message) }
        audio.$positionMs
            .combineLatest(audio.$isPlaying, audio.$durationMs)
            .throttle(for: .milliseconds(250), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] position, playing, duration in
                guard let self else { return }
                nowPlaying.update(song: currentSong, playing: playing, positionMs: position, durationMs: duration)
            }.store(in: &cancellables)
        audio.$isPlaying.dropFirst().sink { [weak self] _ in self?.savePlayback() }.store(in: &cancellables)
    }

    /// Background warm-ups report progress too, so only the song playback is
    /// actually waiting on may drive the player's download bar.
    private func observeDownloadProgress() {
        let updates = cache.downloadProgressUpdates
        Task { [weak self] in
            for await progress in updates {
                guard let self else { return }
                guard precacheDownload?.songID == progress.songID else { continue }
                precacheDownload = progress
            }
        }
    }

    private func finishPrecache(generation: Int) {
        guard generation == playbackGeneration else { return }
        precacheDownload = nil
    }

    func clearStandaloneStreamingSource() {
        isResolvingPlayback = false
        accurateSeekGeneration += 1
        requestedSeekTargetMs = nil
        seekResumesPlayback = false
        standaloneStreamingSongID = nil
        standaloneStreamingURL = nil
    }

    private func restoreSettings() {
        soundQuality = defaults.string(forKey: "sound_quality") ?? "hq"
        playbackMode = PlaybackMode(rawValue: defaults.string(forKey: "playback_mode") ?? "") ?? .sequence
        lyricOffsetMs = Int64(defaults.integer(forKey: "lyric_offset"))
        lyricLeadMs = defaults.object(forKey: "lyric_lead") == nil ? 0 : Int64(defaults.integer(forKey: "lyric_lead"))
        lyricFontSize = defaults.object(forKey: "lyric_font_size") == nil ? 32 : defaults.double(forKey: "lyric_font_size")
        translationFontSize = defaults.object(forKey: "translation_font_size") == nil ? 16 : defaults.double(forKey: "translation_font_size")
        removeQRCInformation = defaults.object(forKey: "remove_qrc_song_info") == nil ? true : defaults.bool(forKey: "remove_qrc_song_info")
        syncThresholdSeconds = defaults.object(forKey: "sync_threshold") == nil ? 0.3 : defaults.double(forKey: "sync_threshold")
        precacheEnabled = defaults.bool(forKey: "precache_mode")
        qqID = defaults.string(forKey: "qq_id") ?? ""
        nickname = defaults.string(forKey: "nickname") ?? (qqID.isEmpty ? "未登录" : qqID)
        avatarURL = defaults.string(forKey: "avatar_url") ?? ""
    }

    private func restorePlayback() {
        guard let data = defaults.data(forKey: "playback_queue"),
              let restored = try? JSONDecoder().decode([Song].self, from: data) else { return }
        let index = defaults.integer(forKey: "playback_index")
        guard restored.indices.contains(index) else { return }
        queue = restored; currentIndex = index; currentSong = restored[index]
        Task {
            let result = await loadLyricResult(for: restored[index])
            apply(result, to: restored[index])
        }
    }
    private func restoredPosition(for song: Song) -> Int64 {
        guard defaults.string(forKey: "playback_song_id") == song.id else { return 0 }
        let value = Int64(defaults.integer(forKey: "playback_position"))
        defaults.set(0, forKey: "playback_position")
        return value
    }
    private func persistUser() {
        defaults.set(qqID, forKey: "qq_id"); defaults.set(nickname, forKey: "nickname"); defaults.set(avatarURL, forKey: "avatar_url")
    }
    private func savePlayback() {
        if let data = try? JSONEncoder().encode(queue) { defaults.set(data, forKey: "playback_queue") }
        defaults.set(currentIndex, forKey: "playback_index")
        defaults.set(currentSong?.id, forKey: "playback_song_id")
        defaults.set(Int(audio.positionMs), forKey: "playback_position")
    }
}
