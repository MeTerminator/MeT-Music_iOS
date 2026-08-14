import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum APIError: LocalizedError {
    case invalidURL
    case invalidResponse(Int)
    case missingSongURL
    case invalidImageData

    var errorDescription: String? {
        switch self {
        case .invalidURL: "无法构造请求地址"
        case let .invalidResponse(status): "服务器返回状态码 \(status)"
        case .missingSongURL: "服务器未返回歌曲地址"
        case .invalidImageData: "服务器返回的封面不是有效图片"
        }
    }
}

struct APIClient: Sendable {
    static let shared = APIClient()
    private let base = URL(string: "https://music.met6.top:444/api/web")!
    private let roomBase = URL(string: "https://music.met6.top:444/api/room")!
    private let decoder: JSONDecoder = {
        let value = JSONDecoder()
        return value
    }()
    private let encoder = JSONEncoder()

    func userPlaylists(uid: String) async throws -> UserPlaylistsResponse {
        try await get(base.appending(path: "user/playlist"), query: ["uid": uid, "limit": "100", "timestamp": nonce()])
    }
    func playlistDetail(id: String) async throws -> PlaylistDetailResponse {
        try await get(base.appending(path: "playlist/detail"), query: ["id": id, "timestamp": nonce()])
    }
    func playlistTracks(id: String, limit: Int = 500) async throws -> PlaylistTracksResponse {
        try await get(base.appending(path: "playlist/track/all"), query: ["id": id, "limit": String(limit), "timestamp": nonce()])
    }
    func songURL(id: String, quality: String) async throws -> URL {
        let response: SongURLResponse = try await get(base.appending(path: "song/url/v1"), query: ["id": id, "level": quality, "timestamp": nonce()])
        guard let raw = response.data.first?.url, let url = RemoteAssetURL.make(raw) else { throw APIError.missingSongURL }
        return url
    }
    func lyric(id: String) async throws -> LyricResponse {
        try await get(base.appending(path: "lyric/new"), query: ["id": id])
    }
    func ttml(mid: String) async throws -> TTMLLyricResponse {
        try await get(base.appending(path: "lyric/ttml"), query: ["mid": mid])
    }
    func checkRoom(code: String) async throws -> CheckRoomResponse {
        try await get(roomBase.appending(path: "check"), query: ["code": code])
    }
    func createRoom() async throws -> CreateRoomResponse {
        try await post(roomBase.appending(path: "create"), body: Optional<String>.none)
    }
    func renewRoom(code: String) async throws -> RenewRoomResponse {
        try await post(roomBase.appending(path: "renew"), body: ["code": code])
    }
    func serverTime() async throws -> ServerTimeResponse {
        try await get(roomBase.appending(path: "time"), query: [:])
    }

    private func nonce() -> String { String(Int.random(in: 0...99_999_999)) }

    private func get<Response: Decodable>(_ url: URL, query: [String: String]) async throws -> Response {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw APIError.invalidURL }
        components.queryItems = query.map(URLQueryItem.init)
        guard let finalURL = components.url else { throw APIError.invalidURL }
        let (data, response) = try await URLSession.shared.data(from: finalURL)
        try validate(response)
        return try decoder.decode(Response.self, from: data)
    }

    private func post<Response: Decodable, Body: Encodable>(_ url: URL, body: Body?) async throws -> Response {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        if let body {
            request.httpBody = try encoder.encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response)
        return try decoder.decode(Response.self, from: data)
    }

    private func validate(_ response: URLResponse) throws {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw APIError.invalidResponse(status) }
    }
}
