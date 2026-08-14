import Foundation

struct CreatorInfo: Codable, Hashable, Sendable {
    var nickname: String?
    var avatarUrl: String?

    var avatarURL: URL? { RemoteAssetURL.make(avatarUrl) }
}

struct CoverSizes: Codable, Hashable, Sendable {
    var s: String?
    var m: String?
    var l: String?
    var xl: String?

    var best: String { [xl, l, m, s].compactMap { $0?.nonEmpty }.first ?? "" }
}

struct Playlist: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var name: String
    var cover: String?
    var coverSize: CoverSizes?
    var trackCount: Int
    var playCount: Int64
    var description: String?
    var creator: CreatorInfo?

    var bestCoverURL: URL? {
        RemoteAssetURL.make([cover, coverSize?.best].compactMap { $0?.nonEmpty }.first)
    }

    enum CodingKeys: String, CodingKey {
        case id, name, cover, coverImgUrl, coverSize, trackCount, playCount, description, creator
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = values.flexibleString(forKey: .id) ?? ""
        name = (try? values.decode(String.self, forKey: .name)) ?? "未知歌单"
        cover = (try? values.decodeIfPresent(String.self, forKey: .coverImgUrl))
            ?? (try? values.decodeIfPresent(String.self, forKey: .cover))
        coverSize = try? values.decodeIfPresent(CoverSizes.self, forKey: .coverSize)
        trackCount = values.flexibleInt(forKey: .trackCount) ?? 0
        playCount = values.flexibleInt64(forKey: .playCount) ?? 0
        description = try? values.decodeIfPresent(String.self, forKey: .description)
        creator = try? values.decodeIfPresent(CreatorInfo.self, forKey: .creator)
    }

    init(id: String, name: String, cover: String? = nil, coverSize: CoverSizes? = nil, trackCount: Int = 0, playCount: Int64 = 0, description: String? = nil, creator: CreatorInfo? = nil) {
        self.id = id; self.name = name; self.cover = cover; self.coverSize = coverSize
        self.trackCount = trackCount; self.playCount = playCount; self.description = description; self.creator = creator
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(name, forKey: .name)
        try values.encodeIfPresent(cover, forKey: .coverImgUrl)
        try values.encodeIfPresent(coverSize, forKey: .coverSize)
        try values.encode(trackCount, forKey: .trackCount)
        try values.encode(playCount, forKey: .playCount)
        try values.encodeIfPresent(description, forKey: .description)
        try values.encodeIfPresent(creator, forKey: .creator)
    }
}

struct Artist: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var name: String

    enum CodingKeys: CodingKey { case id, name }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = values.flexibleString(forKey: .id) ?? ""
        name = (try? values.decode(String.self, forKey: .name)) ?? ""
    }
    init(id: String, name: String) { self.id = id; self.name = name }
}

struct Album: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var name: String
    var picUrl: String?

    enum CodingKeys: CodingKey { case id, name, picUrl }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = values.flexibleString(forKey: .id) ?? ""
        name = (try? values.decode(String.self, forKey: .name)) ?? ""
        picUrl = try? values.decodeIfPresent(String.self, forKey: .picUrl)
    }
    init(id: String, name: String, picUrl: String? = nil) { self.id = id; self.name = name; self.picUrl = picUrl }
}

struct Song: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var mid: String?
    var name: String
    var artists: [Artist]
    var album: Album?
    var cover: String?
    var coverSize: CoverSizes?
    var durationMs: Int64
    var ttml: Int

    var lyricMid: String { mid?.isEmpty == false ? mid! : id }
    var bestCover: String {
        [cover, coverSize?.best, album?.picUrl].compactMap { $0?.nonEmpty }.first ?? ""
    }
    var bestCoverURL: URL? { RemoteAssetURL.make(bestCover) }
    var artistText: String { artists.map(\.name).joined(separator: " & ") }
    var formattedDuration: String { String(format: "%02lld:%02lld", durationMs / 60_000, durationMs / 1_000 % 60) }
    var hasTTML: Bool { ttml == 1 }

    enum CodingKeys: String, CodingKey { case id, mid, name, artists = "ar", album = "al", cover, coverSize, durationMs = "dt", ttml }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = values.flexibleString(forKey: .id) ?? ""
        mid = values.flexibleString(forKey: .mid)
        name = (try? values.decode(String.self, forKey: .name)) ?? "未知歌曲"
        artists = (try? values.decode([Artist].self, forKey: .artists)) ?? []
        album = try? values.decodeIfPresent(Album.self, forKey: .album)
        cover = try? values.decodeIfPresent(String.self, forKey: .cover)
        coverSize = try? values.decodeIfPresent(CoverSizes.self, forKey: .coverSize)
        durationMs = values.flexibleInt64(forKey: .durationMs) ?? 0
        ttml = values.flexibleInt(forKey: .ttml) ?? 0
    }
    init(id: String, mid: String? = nil, name: String, artists: [Artist] = [], album: Album? = nil, cover: String? = nil, coverSize: CoverSizes? = nil, durationMs: Int64 = 0, ttml: Int = 0) {
        self.id = id; self.mid = mid; self.name = name; self.artists = artists; self.album = album
        self.cover = cover; self.coverSize = coverSize; self.durationMs = durationMs; self.ttml = ttml
    }
}

enum RemoteAssetURL {
    private static let publicHost = "music.met6.top"
    private static let publicPort = 444

    static func make(_ rawValue: String?) -> URL? {
        guard var value = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty else { return nil }
        if value.hasPrefix("//") { value = "https:" + value }
        if value.lowercased().hasPrefix("http://") {
            value = "https://" + String(value.dropFirst("http://".count))
        }
        if !value.contains("://") { value = "https://" + value }
        if let url = normalizedURL(from: value) { return url }
        guard let encoded = value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return nil }
        return normalizedURL(from: encoded)
    }

    private static func normalizedURL(from value: String) -> URL? {
        guard var components = URLComponents(string: value) else { return nil }
        let loopbackHosts = ["localhost", "127.0.0.1", "::1"]
        if let host = components.host?.lowercased(), loopbackHosts.contains(host) {
            components.scheme = "https"
            components.host = publicHost
            components.port = publicPort
        }
        return components.url
    }
}

private extension String {
    var nonEmpty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty || value.lowercased() == "null" ? nil : value
    }
}

struct UserPlaylistsResponse: Decodable, Sendable {
    var playlist: [Playlist] = []
    var username: String?
    var avatarUrl: String?
}

struct PlaylistDetailResponse: Decodable, Sendable { var playlist: Playlist }
struct PlaylistTracksResponse: Decodable, Sendable { var songs: [Song] = [] }
struct SongURLInfo: Decodable, Sendable {
    var id: String
    var url: String?
    enum CodingKeys: CodingKey { case id, url }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = values.flexibleString(forKey: .id) ?? ""
        url = try? values.decodeIfPresent(String.self, forKey: .url)
    }
}
struct SongURLResponse: Decodable, Sendable { var data: [SongURLInfo] = [] }
struct LyricResponse: Codable, Sendable {
    var lrc: String?
    var lrctrans: String?
    var qrc: String?
    var qrctrans: String?
    var qrcroma: String?
}
struct TTMLLyricResponse: Decodable, Sendable { var status: String; var content: String? }

extension KeyedDecodingContainer {
    func flexibleString(forKey key: Key) -> String? {
        if let value = try? decodeIfPresent(String.self, forKey: key) { return value }
        if let value = try? decodeIfPresent(Int64.self, forKey: key) { return String(value) }
        if let value = try? decodeIfPresent(Double.self, forKey: key) { return String(format: "%.0f", value) }
        return nil
    }

    func flexibleInt(forKey key: Key) -> Int? {
        if let value = try? decodeIfPresent(Int.self, forKey: key) { return value }
        if let value = flexibleString(forKey: key) { return Int(value) }
        return nil
    }

    func flexibleInt64(forKey key: Key) -> Int64? {
        if let value = try? decodeIfPresent(Int64.self, forKey: key) { return value }
        if let value = flexibleString(forKey: key) { return Int64(value) }
        return nil
    }
}
