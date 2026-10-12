import Combine
import Foundation

@MainActor
final class ListenTogetherStore: ObservableObject {
    @Published private(set) var isInRoom = false
    @Published private(set) var connecting = false
    @Published private(set) var roomCode = ""
    @Published private(set) var room: RoomDetails?
    @Published private(set) var remainingSeconds: Int64 = 3_600
    @Published var autoRenew = true
    @Published var errorMessage: String?
    @Published var successMessage: String?

    private unowned let app: AppStore
    private var socket: URLSessionWebSocketTask?
    private var jobs: [Task<Void, Never>] = []
    private var expectingFirstState = false
    private var serverOffsetMs: Int64 = 0
    private var lastRoomStateServerMs: Int64 = 0
    private var roomSongID: String?
    private var loadingSongID: String?
    private var generation = 0
    private var renewing = false
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    init(app: AppStore) { self.app = app }

    func createRoom(nickname: String, anonymous: Bool) async {
        storeIdentity(nickname: nickname, anonymous: anonymous)
        connecting = true
        defer { connecting = false }
        do {
            guard let code = try await app.api.createRoom().code else { throw APIError.invalidResponse(200) }
            try await connect(code: code)
        } catch { errorMessage = "创建房间失败：\(error.localizedDescription)" }
    }

    func joinRoom(code: String, nickname: String, anonymous: Bool) async {
        let code = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard code.count == 6 else { errorMessage = "请输入 6 位房间号"; return }
        storeIdentity(nickname: nickname, anonymous: anonymous)
        connecting = true
        defer { connecting = false }
        do {
            guard try await app.api.checkRoom(code: code).exists else { errorMessage = "房间不存在或已过期"; return }
            try await connect(code: code)
        } catch { errorMessage = "加入房间失败：\(error.localizedDescription)" }
    }

    private func connect(code: String) async throws {
        leaveRoom(reason: nil)
        guard let url = URL(string: "wss://music.met6.top:444/api/room/ws/\(code)") else { throw APIError.invalidURL }
        expectingFirstState = true
        generation += 1
        roomCode = code
        let task = URLSession.shared.webSocketTask(with: url)
        socket = task
        task.resume()
        try await send(.init(action: "join", userId: sessionID, user: currentUser, data: nil))
        isInRoom = true
        startJobs()
    }

    func send(action: String) {
        Task { try? await send(.init(action: action, userId: sessionID, user: currentUser, data: nil)) }
    }
    func sendPlayOrPause() { send(action: app.audio.isPlaying ? "pause" : "play") }
    func seek(toSeconds seconds: Double) {
        Task { try? await send(.init(action: "seek", userId: sessionID, user: currentUser, data: .init(currentTime: seconds))) }
    }
    func addSong(_ song: Song) {
        guard room?.playlist.contains(where: { $0.id == song.id }) != true else { return }
        Task { try? await send(.init(action: "playlist_add", userId: sessionID, user: currentUser, data: .init(song: .init(song: song)))) }
    }
    func removeSong(at index: Int) {
        Task { try? await send(.init(action: "playlist_remove", userId: sessionID, user: currentUser, data: .init(index: index))) }
    }
    func playSong(at index: Int) {
        Task {
            try? await send(.init(action: "play_index", userId: sessionID, user: currentUser, data: .init(index: index)))
            try? await Task.sleep(for: .milliseconds(100))
            try? await send(.init(action: "play", userId: sessionID, user: currentUser, data: nil))
        }
    }
    func setPlayMode(_ mode: String) {
        Task { try? await send(.init(action: "set_play_mode", userId: sessionID, user: currentUser, data: .init(playMode: mode))) }
    }
    func updateSettings(deleteAfterPlayed: Bool, loopPlaylist: Bool) {
        let settings = WSActionSettings(deleteAfterPlayed: deleteAfterPlayed, loopPlaylist: loopPlaylist)
        Task { try? await send(.init(action: "update_settings", userId: sessionID, user: currentUser, data: .init(settings: settings))) }
    }
    func deleteRoom() { send(action: "delete_room") }

    func renewRoom() {
        guard !renewing, !roomCode.isEmpty else { return }
        renewing = true
        Task {
            defer { Task { try? await Task.sleep(for: .seconds(10)); renewing = false } }
            do {
                let result = try await app.api.renewRoom(code: roomCode)
                if result.status == "ok", let expires = result.expiresAt {
                    room?.expiresAt = expires
                    successMessage = "房间已续期"
                    if let room { updateSettings(deleteAfterPlayed: room.deleteAfterPlayed, loopPlaylist: room.loopPlaylist) }
                } else { errorMessage = result.detail ?? "续期失败" }
            } catch { errorMessage = "续期失败：\(error.localizedDescription)" }
        }
    }

    func leaveRoom() { leaveRoom(reason: nil) }
    private func leaveRoom(reason: String?) {
        let wasInRoom = isInRoom
        isInRoom = false
        generation += 1
        roomSongID = nil; loadingSongID = nil; roomCode = ""; room = nil
        jobs.forEach { $0.cancel() }; jobs.removeAll()
        socket?.cancel(with: .goingAway, reason: nil); socket = nil
        if let reason { errorMessage = reason }
        if wasInRoom, app.audio.isReady { app.audio.pause(); app.showToast("一起听已结束，播放已暂停") }
    }

    private func startJobs() {
        jobs.forEach { $0.cancel() }
        jobs = [
            Task { await receiveLoop() },
            Task { await heartbeatLoop() },
            Task { await serverTimeLoop() },
            Task { await countdownLoop() },
            Task { await playbackCorrectionLoop() },
        ]
    }

    private func receiveLoop() async {
        do {
            while !Task.isCancelled, let socket {
                let message = try await socket.receive()
                switch message {
                case let .string(text): handle(text)
                case let .data(data): if let text = String(data: data, encoding: .utf8) { handle(text) }
                @unknown default: break
                }
            }
        } catch {
            if isInRoom { leaveRoom(reason: "连接已断开") }
        }
    }

    private func handle(_ text: String) {
        guard let data = text.data(using: .utf8), let payload = try? decoder.decode(RoomStatePayload.self, from: data) else { return }
        if payload.type == "error" {
            let message = payload.message ?? "服务器错误"
            errorMessage = message
            if message.contains("解散") || message.contains("到期") || message.contains("不存在") { leaveRoom(reason: message) }
            return
        }
        guard payload.type == "room_state", let latest = payload.room else { return }
        let first = expectingFirstState
        expectingFirstState = false
        let serverTime = Int64(payload.serverTime ?? Double(nowMs() + serverOffsetMs))
        lastRoomStateServerMs = serverTime
        room = latest
        sync(latest, event: first ? "first_state" : payload.event ?? "", serverTime: serverTime)
    }

    private func sync(_ latest: RoomDetails, event: String, serverTime: Int64) {
        app.queue = latest.playlist.map(\.song)
        app.currentIndex = latest.currentSongIndex
        guard latest.playlist.indices.contains(latest.currentSongIndex) else {
            app.audio.stop(); app.currentSong = nil; app.lyrics = []; return
        }
        let song = latest.playlist[latest.currentSongIndex].song
        let targetMs = roomPositionMs(latest, stateServerTime: serverTime)
        let sameSong = app.currentSong?.id == song.id && roomSongID == song.id
        if !sameSong {
            playRoomSong(song, initialPositionMs: targetMs, playing: latest.isPlaying)
            return
        }
        latest.isPlaying ? app.audio.resume() : app.audio.pause()
        if event == "seek" || abs(app.audio.positionMs - targetMs) > Int64(app.syncThresholdSeconds * 1_000) {
            Task { await app.audio.seek(to: targetMs) }
        }
    }

    private func playRoomSong(_ song: Song, initialPositionMs: Int64, playing: Bool) {
        guard loadingSongID != song.id else { return }
        generation += 1
        let request = generation
        loadingSongID = song.id
        roomSongID = nil
        app.clearStandaloneStreamingSource()
        app.audio.stop()
        app.currentSong = song
        app.lyrics = []
        Task {
            do {
                let local: URL
                if let cached = await app.cache.cachedAudioURL(songID: song.id) { local = cached }
                else {
                    let remote: URL
                    if let cached = await app.cache.remoteURL(songID: song.id, quality: app.soundQuality) { remote = cached }
                    else { remote = try await app.api.songURL(id: song.id, quality: app.soundQuality) }
                    await app.cache.setRemoteURL(remote, songID: song.id, quality: app.soundQuality)
                    local = try await app.cache.audioURL(songID: song.id, remoteURL: remote, waitForCache: false)
                }
                guard request == generation, isInRoom,
                      let latest = room,
                      latest.playlist.indices.contains(latest.currentSongIndex),
                      latest.playlist[latest.currentSongIndex].id == song.id else { return }
                // Recompute after URL resolution so this client starts at the latest room position.
                let position = roomPositionMs(latest, stateServerTime: lastRoomStateServerMs)
                roomSongID = song.id
                await app.playTogether(song: song, localURL: local, positionMs: position, isPlaying: latest.isPlaying)
                try? await app.cache.saveSongMetadata(song, quality: app.soundQuality)
            } catch { errorMessage = "同步歌曲失败：\(error.localizedDescription)" }
            if request == generation { loadingSongID = nil }
        }
    }

    private func roomPositionMs(_ room: RoomDetails, stateServerTime: Int64) -> Int64 {
        let elapsed = room.isPlaying ? max(0, nowMs() + serverOffsetMs - stateServerTime) : 0
        return Int64((room.seekPosition * 1_000).rounded()) + elapsed
    }

    private func heartbeatLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(30))
            try? await send(.init(action: "ping", userId: sessionID, user: nil, data: nil))
        }
    }
    private func serverTimeLoop() async {
        while !Task.isCancelled {
            let start = nowMs()
            if let server = try? await app.api.serverTime().serverTime {
                serverOffsetMs = Int64(server) - (start + nowMs()) / 2
            }
            try? await Task.sleep(for: .seconds(10))
        }
    }
    private func countdownLoop() async {
        while !Task.isCancelled {
            if let room {
                remainingSeconds = max(0, Int64((room.expiresAt - Double(nowMs())) / 1_000))
                if remainingSeconds == 0 { leaveRoom(reason: "房间已到期"); return }
                if autoRenew, (1...1_800).contains(remainingSeconds) { renewRoom() }
            }
            try? await Task.sleep(for: .seconds(1))
        }
    }
    private func playbackCorrectionLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(1))
            guard let room, room.isPlaying, app.audio.isPlaying,
                  room.playlist.indices.contains(room.currentSongIndex),
                  room.playlist[room.currentSongIndex].id == app.currentSong?.id else { continue }
            let target = roomPositionMs(room, stateServerTime: lastRoomStateServerMs)
            if abs(app.audio.positionMs - target) > Int64(app.syncThresholdSeconds * 1_000) {
                await app.audio.seek(to: target)
            }
        }
    }

    private func send(_ action: WSAction) async throws {
        guard let socket else { return }
        let data = try encoder.encode(action)
        guard let text = String(data: data, encoding: .utf8) else { throw APIError.invalidResponse(0) }
        try await socket.send(.string(text))
    }

    private var sessionID: String {
        let defaults = UserDefaults.standard
        if let value = defaults.string(forKey: "listen_session_id"), !value.isEmpty { return value }
        let value = String((0..<32).map { _ in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789".randomElement()! })
        defaults.set(value, forKey: "listen_session_id")
        return value
    }
    private var currentUser: RoomUserPayload {
        let defaults = UserDefaults.standard
        let anonymous = defaults.bool(forKey: "listen_anonymous")
        let preferred = defaults.string(forKey: "listen_nickname")?.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = anonymous ? "Anonymous" : (preferred?.isEmpty == false ? preferred! : (app.nickname == "未登录" ? "Anonymous" : app.nickname))
        let avatar = anonymous ? defaultAvatar : (!app.qqID.isEmpty ? "https://q1.qlogo.cn/g?b=qq&nk=\(app.qqID)&s=640" : defaultAvatar)
        return .init(nickname: name, avatar: avatar, qq: anonymous ? "" : app.qqID, isAnonymous: anonymous)
    }
    private var defaultAvatar: String { "https://music.met6.top:444/app/images/pic/avatar.jpg" }
    private func storeIdentity(nickname: String, anonymous: Bool) {
        UserDefaults.standard.set(nickname, forKey: "listen_nickname")
        UserDefaults.standard.set(anonymous, forKey: "listen_anonymous")
    }
    private func nowMs() -> Int64 { Int64((Date().timeIntervalSince1970 * 1_000).rounded()) }
}
