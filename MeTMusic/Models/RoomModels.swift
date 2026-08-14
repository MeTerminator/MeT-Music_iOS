import Foundation

struct RoomUserPayload: Codable, Hashable, Sendable {
    var nickname: String
    var avatar: String
    var qq: String = ""
    var isAnonymous = false
    enum CodingKeys: String, CodingKey { case nickname, avatar, qq; case isAnonymous = "is_anonymous" }
}

struct RoomMember: Codable, Hashable, Identifiable, Sendable {
    var userId = ""
    var nickname = ""
    var avatar = ""
    var qq = ""
    var isAnonymous = false
    var user: RoomUserPayload?
    var id: String { userId.isEmpty ? nickname : userId }
    enum CodingKeys: String, CodingKey { case userId, nickname, avatar, qq, user; case isAnonymous = "is_anonymous" }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        userId = (try? values.decodeIfPresent(String.self, forKey: .userId)) ?? ""
        nickname = (try? values.decodeIfPresent(String.self, forKey: .nickname)) ?? ""
        avatar = (try? values.decodeIfPresent(String.self, forKey: .avatar)) ?? ""
        qq = (try? values.decodeIfPresent(String.self, forKey: .qq)) ?? ""
        isAnonymous = (try? values.decodeIfPresent(Bool.self, forKey: .isAnonymous)) ?? false
        user = try? values.decodeIfPresent(RoomUserPayload.self, forKey: .user)
    }
}

struct RoomLog: Codable, Hashable, Identifiable, Sendable {
    var timestamp = 0.0
    var user = ""
    var action = ""
    var id: String { "\(timestamp):\(user):\(action)" }

    enum CodingKeys: CodingKey { case timestamp, user, action }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        timestamp = (try? values.decodeIfPresent(Double.self, forKey: .timestamp)) ?? 0
        user = (try? values.decodeIfPresent(String.self, forKey: .user)) ?? ""
        action = (try? values.decodeIfPresent(String.self, forKey: .action)) ?? ""
    }
}

struct RoomSong: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var mid: String?
    var name: String
    var artists: [Artist] = []
    var album: Album?
    var cover: String?
    var coverSize: CoverSizes?
    var durationMs: Int64 = 0
    var duration: String?

    var song: Song { .init(id: id, mid: mid, name: name, artists: artists, album: album, cover: cover, coverSize: coverSize, durationMs: durationMs) }
    enum CodingKeys: CodingKey { case id, mid, name, artists, album, cover, coverSize, durationMs, duration }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = values.flexibleString(forKey: .id) ?? ""
        mid = values.flexibleString(forKey: .mid)
        name = (try? values.decodeIfPresent(String.self, forKey: .name)) ?? "未知歌曲"
        artists = (try? values.decodeIfPresent([Artist].self, forKey: .artists)) ?? []
        album = try? values.decodeIfPresent(Album.self, forKey: .album)
        cover = try? values.decodeIfPresent(String.self, forKey: .cover)
        coverSize = try? values.decodeIfPresent(CoverSizes.self, forKey: .coverSize)
        durationMs = values.flexibleInt64(forKey: .durationMs) ?? 0
        duration = try? values.decodeIfPresent(String.self, forKey: .duration)
        if durationMs <= 0 { durationMs = Self.parseDuration(duration) }
    }
    init(song: Song) {
        id = song.id; mid = song.mid; name = song.name; artists = song.artists; album = song.album
        cover = song.cover; coverSize = song.coverSize; durationMs = song.durationMs; duration = song.formattedDuration
    }

    private static func parseDuration(_ value: String?) -> Int64 {
        guard let value else { return 0 }
        let parts = value.split(separator: ":").compactMap { Int64($0) }
        guard parts.count == 2 else { return 0 }
        return (parts[0] * 60 + parts[1]) * 1_000
    }
}

struct RoomDetails: Codable, Hashable, Sendable {
    var code: String
    var uuid: String
    var playlist: [RoomSong] = []
    var members: [RoomMember] = []
    var currentSongIndex = -1
    var isPlaying = false
    var seekPosition = 0.0
    var playMode = "normal"
    var deleteAfterPlayed = false
    var loopPlaylist = true
    var expiresAt = 0.0
    var logs: [RoomLog] = []
    enum CodingKeys: String, CodingKey {
        case code, uuid, playlist, members, logs
        case currentSongIndex = "current_song_index"
        case isPlaying = "is_playing"
        case seekPosition = "seek_position"
        case playMode = "play_mode"
        case deleteAfterPlayed = "delete_after_played"
        case loopPlaylist = "loop_playlist"
        case expiresAt = "expires_at"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        code = (try? values.decodeIfPresent(String.self, forKey: .code)) ?? ""
        uuid = (try? values.decodeIfPresent(String.self, forKey: .uuid)) ?? ""
        playlist = (try? values.decodeIfPresent([RoomSong].self, forKey: .playlist)) ?? []
        members = (try? values.decodeIfPresent([RoomMember].self, forKey: .members)) ?? []
        currentSongIndex = (try? values.decodeIfPresent(Int.self, forKey: .currentSongIndex)) ?? -1
        isPlaying = (try? values.decodeIfPresent(Bool.self, forKey: .isPlaying)) ?? false
        seekPosition = (try? values.decodeIfPresent(Double.self, forKey: .seekPosition)) ?? 0
        playMode = (try? values.decodeIfPresent(String.self, forKey: .playMode)) ?? "normal"
        deleteAfterPlayed = (try? values.decodeIfPresent(Bool.self, forKey: .deleteAfterPlayed)) ?? false
        loopPlaylist = (try? values.decodeIfPresent(Bool.self, forKey: .loopPlaylist)) ?? true
        expiresAt = (try? values.decodeIfPresent(Double.self, forKey: .expiresAt)) ?? 0
        logs = (try? values.decodeIfPresent([RoomLog].self, forKey: .logs)) ?? []
    }
}

struct RoomStatePayload: Decodable, Sendable {
    var type: String
    var event: String?
    var serverTime: Double?
    var room: RoomDetails?
    var message: String?
    enum CodingKeys: String, CodingKey { case type, event, room, message; case serverTime = "server_time" }
}

struct WSAction: Encodable, Sendable {
    var action: String
    var userId: String
    var user: RoomUserPayload?
    var data: WSActionData?
}

struct WSActionData: Encodable, Sendable {
    var currentTime: Double?
    var song: RoomSong?
    var index: Int?
    var playlist: [RoomSong]?
    var playMode: String?
    var settings: WSActionSettings?
    enum CodingKeys: String, CodingKey { case currentTime, song, index, playlist, settings; case playMode = "play_mode" }

    init(currentTime: Double? = nil, song: RoomSong? = nil, index: Int? = nil, playlist: [RoomSong]? = nil, playMode: String? = nil, settings: WSActionSettings? = nil) {
        self.currentTime = currentTime; self.song = song; self.index = index
        self.playlist = playlist; self.playMode = playMode; self.settings = settings
    }
}

struct WSActionSettings: Encodable, Sendable {
    var deleteAfterPlayed: Bool
    var loopPlaylist: Bool
    enum CodingKeys: String, CodingKey { case deleteAfterPlayed = "delete_after_played"; case loopPlaylist = "loop_playlist" }
}

struct CreateRoomResponse: Decodable, Sendable { var code: String? }
struct CheckRoomResponse: Decodable, Sendable { var exists = false }
struct RenewRoomResponse: Decodable, Sendable {
    var status: String?
    var expiresAt: Double?
    var detail: String?
    enum CodingKeys: String, CodingKey { case status, detail; case expiresAt = "expires_at" }
}
struct ServerTimeResponse: Decodable, Sendable {
    var serverTime: Double
    enum CodingKeys: String, CodingKey { case serverTime = "server_time" }
}
