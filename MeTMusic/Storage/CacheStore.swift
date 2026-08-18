import Foundation
import CryptoKit
import ImageIO
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

let supportedAudioFileExtensions: Set<String> = ["mp3", "m4a", "mp4", "aac", "flac", "wav", "ogg", "opus"]

struct AudioDownloadProgress: Sendable, Equatable {
    var songID: String
    var receivedBytes: Int64 = 0
    var expectedBytes: Int64 = 0
}

/// Nil while the download length is still unknown, which is what a server that
/// sends no content length leaves us with.
func audioDownloadFraction(receivedBytes: Int64, expectedBytes: Int64) -> Double? {
    guard expectedBytes > 0 else { return nil }
    return min(max(Double(receivedBytes) / Double(expectedBytes), 0), 1)
}

/// Label shown under the download progress bar while precache mode holds
/// playback back. The percentage is only appended once it is actually known.
func audioDownloadStatusText(_ progress: AudioDownloadProgress) -> String {
    guard let fraction = audioDownloadFraction(
        receivedBytes: progress.receivedBytes,
        expectedBytes: progress.expectedBytes
    ) else { return "下载中" }
    return "下载中 \(Int((fraction * 100).rounded()))%"
}

func preferredAudioFileExtension(
    remoteURL: URL,
    mimeType: String? = nil,
    suggestedFilename: String? = nil
) -> String {
    let mimeExtensions = [
        "audio/mpeg": "mp3",
        "audio/mp3": "mp3",
        "audio/mp4": "m4a",
        "audio/x-m4a": "m4a",
        "audio/aac": "aac",
        "audio/flac": "flac",
        "audio/x-flac": "flac",
        "audio/wav": "wav",
        "audio/x-wav": "wav",
        "audio/ogg": "ogg",
        "audio/opus": "opus",
    ]
    if let mimeType, let value = mimeExtensions[mimeType.lowercased()] { return value }
    if let suggestedFilename {
        let value = URL(fileURLWithPath: suggestedFilename).pathExtension.lowercased()
        if supportedAudioFileExtensions.contains(value) { return value }
    }
    let remoteExtension = remoteURL.pathExtension.lowercased()
    return supportedAudioFileExtensions.contains(remoteExtension) ? remoteExtension : "mp3"
}

actor CacheStore {
    enum Category: String, CaseIterable, Sendable { case playlists, covers, songs, songMetadata, lyrics }

    struct CachedAudio: Identifiable, Sendable {
        var song: Song
        var quality: String
        var size: Int64
        var id: String { song.id }
    }

    private struct RemoteEntry: Sendable { var url: URL; var date: Date }
    private struct CachedSongMetadata: Codable, Sendable { var song: Song; var quality: String; var cachedAt: Date }

    private let root: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var activeDownloads: [String: Task<URL, Error>] = [:]
    /// Broadcasts byte progress for every audio download, whether it is a
    /// precache the player is waiting on or a background warm-up.
    nonisolated let downloadProgressUpdates: AsyncStream<AudioDownloadProgress>
    private nonisolated let downloadProgressContinuation: AsyncStream<AudioDownloadProgress>.Continuation
    private var activeCoverDownloads: [String: Task<Data, Error>] = [:]
    private var remoteURLs: [String: RemoteEntry] = [:]

    init() {
        let (stream, continuation) = AsyncStream.makeStream(
            of: AudioDownloadProgress.self,
            bufferingPolicy: .bufferingNewest(4)
        )
        downloadProgressUpdates = stream
        downloadProgressContinuation = continuation
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        root = base.appending(path: "MeTMusic", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for category in Category.allCases {
            try? FileManager.default.createDirectory(at: root.appending(path: category.rawValue, directoryHint: .isDirectory), withIntermediateDirectories: true)
        }
    }

    func remoteURL(songID: String, quality: String) -> URL? {
        let key = "\(songID)-\(quality)"
        guard let entry = remoteURLs[key], Date().timeIntervalSince(entry.date) < 5_400 else {
            remoteURLs[key] = nil
            return nil
        }
        return entry.url
    }

    func setRemoteURL(_ url: URL, songID: String, quality: String) {
        remoteURLs["\(songID)-\(quality)"] = .init(url: url, date: Date())
    }

    /// Standalone playback returns the network URL immediately and warms disk in
    /// the background. Together playback waits for a complete local, seekable file.
    func audioURL(songID: String, remoteURL: URL, waitForCache: Bool) async throws -> URL {
        if !waitForCache {
            Task { _ = try? await self.audioURL(songID: songID, remoteURL: remoteURL, waitForCache: true) }
            return remoteURL
        }
        if let cached = cachedAudioURL(songID: songID) { return cached }
        if let active = activeDownloads[songID] { return try await active.value }
        let songsDirectory = root.appending(path: Category.songs.rawValue, directoryHint: .isDirectory)
        let cachedName = safe(songID)
        let progress = downloadProgressContinuation
        let task = Task<URL, Error> {
            let downloaded = try await AudioDownloader.shared.download(from: remoteURL) { received, expected in
                progress.yield(.init(songID: songID, receivedBytes: received, expectedBytes: expected))
            }
            let temporary = downloaded.url
            guard (200..<300).contains(downloaded.statusCode) else {
                try? FileManager.default.removeItem(at: temporary)
                throw APIError.invalidResponse(downloaded.statusCode)
            }
            let fileExtension = preferredAudioFileExtension(
                remoteURL: remoteURL,
                mimeType: downloaded.mimeType,
                suggestedFilename: downloaded.suggestedFilename
            )
            let destination = songsDirectory.appending(path: "\(cachedName).\(fileExtension)")
            let oldFiles = (try? FileManager.default.contentsOfDirectory(
                at: songsDirectory,
                includingPropertiesForKeys: nil
            )) ?? []
            for file in oldFiles where file.deletingPathExtension().lastPathComponent == cachedName {
                try? FileManager.default.removeItem(at: file)
            }
            try FileManager.default.moveItem(at: temporary, to: destination)
            return destination
        }
        activeDownloads[songID] = task
        do {
            let url = try await task.value
            activeDownloads[songID] = nil
            return url
        } catch {
            activeDownloads[songID] = nil
            throw error
        }
    }

    func cachedAudioURL(songID: String) -> URL? {
        cachedAudioFiles(songID: songID).first
    }

    func cachedAudios() -> [CachedAudio] {
        let directory = root.appending(path: Category.songs.rawValue, directoryHint: .isDirectory)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]
        )) ?? []
        return files.compactMap { file in
            let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true,
                  supportedAudioFileExtensions.contains(file.pathExtension.lowercased()) else { return nil }
            let cachedID = file.deletingPathExtension().lastPathComponent
            let metadataURL = fileURL(.songMetadata, name: cachedID + ".json")
            let metadata = try? decoder.decode(CachedSongMetadata.self, from: Data(contentsOf: metadataURL))
            let song = metadata?.song ?? Song(id: cachedID, name: "未知歌曲 (ID: \(cachedID))")
            return .init(song: song, quality: metadata?.quality ?? "unknown", size: Int64(values?.fileSize ?? 0))
        }
        .sorted { $0.song.name.localizedStandardCompare($1.song.name) == .orderedAscending }
    }

    func deleteCachedAudio(songID: String) throws {
        activeDownloads[songID]?.cancel()
        activeDownloads[songID] = nil
        let metadata = fileURL(.songMetadata, name: safe(songID) + ".json")
        for audio in cachedAudioFiles(songID: songID, includeLegacy: true) {
            try FileManager.default.removeItem(at: audio)
        }
        if FileManager.default.fileExists(atPath: metadata.path) { try FileManager.default.removeItem(at: metadata) }
    }

    func coverData(remoteURL: URL) async throws -> Data {
        guard let normalizedURL = RemoteAssetURL.make(remoteURL.absoluteString) else {
            throw APIError.invalidImageData
        }
        let digest = SHA256.hash(data: Data(normalizedURL.absoluteString.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        let destination = fileURL(.covers, name: digest + ".image")
        if let data = try? Data(contentsOf: destination), isImage(data) { return data }
        try? FileManager.default.removeItem(at: destination)

        if let active = activeCoverDownloads[digest] { return try await active.value }
        let task = Task<Data, Error> {
            var request = URLRequest(url: normalizedURL)
            request.setValue("image/avif,image/webp,image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else { throw APIError.invalidResponse(status) }
            guard Self.isImageData(data) else { throw APIError.invalidImageData }
            try data.write(to: destination, options: .atomic)
            return data
        }
        activeCoverDownloads[digest] = task
        do {
            let data = try await task.value
            activeCoverDownloads[digest] = nil
            return data
        } catch {
            activeCoverDownloads[digest] = nil
            throw error
        }
    }

    private func isImage(_ data: Data) -> Bool {
        Self.isImageData(data)
    }

    nonisolated private static func isImageData(_ data: Data) -> Bool {
        CGImageSourceCreateWithData(data as CFData, nil) != nil
    }

    func saveSongMetadata(_ song: Song, quality: String) throws {
        try encoder.encode(CachedSongMetadata(song: song, quality: quality, cachedAt: Date()))
            .write(to: fileURL(.songMetadata, name: safe(song.id) + ".json"), options: .atomic)
    }

    func savePlaylists(_ playlists: [Playlist], uid: String) throws {
        try save(playlists, category: .playlists, name: "playlists_\(safe(uid)).json")
    }
    func playlists(uid: String) -> [Playlist]? {
        try? load([Playlist].self, category: .playlists, name: "playlists_\(safe(uid)).json")
    }
    func saveTracks(_ songs: [Song], playlistID: String) throws {
        try save(songs, category: .playlists, name: "tracks_\(safe(playlistID)).json")
    }
    func tracks(playlistID: String) -> [Song]? {
        try? load([Song].self, category: .playlists, name: "tracks_\(safe(playlistID)).json")
    }
    func saveLyric(_ lyric: LyricResponse, songID: String) throws {
        try save(lyric, category: .lyrics, name: safe(songID) + ".json")
    }
    func lyric(songID: String) -> LyricResponse? {
        try? load(LyricResponse.self, category: .lyrics, name: safe(songID) + ".json")
    }

    func cacheSize(_ category: Category) -> Int64 {
        let directory = root.appending(path: category.rawValue, directoryHint: .isDirectory)
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)) ?? []
        return files.reduce(0) { result, url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            return result + Int64(values?.isRegularFile == true ? values?.fileSize ?? 0 : 0)
        }
    }

    func clear(_ category: Category) throws {
        let directory = root.appending(path: category.rawValue, directoryHint: .isDirectory)
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            try FileManager.default.removeItem(at: file)
        }
        if category == .songs {
            try clear(.songMetadata)
            activeDownloads.values.forEach { $0.cancel() }
            activeDownloads.removeAll()
        }
        if category == .covers {
            activeCoverDownloads.values.forEach { $0.cancel() }
            activeCoverDownloads.removeAll()
        }
    }

    private func save<Value: Encodable>(_ value: Value, category: Category, name: String) throws {
        try encoder.encode(value).write(to: fileURL(category, name: name), options: .atomic)
    }
    private func load<Value: Decodable>(_ type: Value.Type, category: Category, name: String) throws -> Value {
        try decoder.decode(type, from: Data(contentsOf: fileURL(category, name: name)))
    }
    private func fileURL(_ category: Category, name: String) -> URL {
        root.appending(path: category.rawValue, directoryHint: .isDirectory).appending(path: name)
    }
    private func cachedAudioFiles(songID: String, includeLegacy: Bool = false) -> [URL] {
        let directory = root.appending(path: Category.songs.rawValue, directoryHint: .isDirectory)
        let cachedName = safe(songID)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]
        )) ?? []
        return files.filter { file in
            guard file.deletingPathExtension().lastPathComponent == cachedName else { return false }
            let fileExtension = file.pathExtension.lowercased()
            guard supportedAudioFileExtensions.contains(fileExtension) || (includeLegacy && fileExtension == "audio") else { return false }
            let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            return values?.isRegularFile == true && (values?.fileSize ?? 0) > 0
        }
    }
    private func safe(_ value: String) -> String {
        value.replacingOccurrences(of: #"[^A-Za-z0-9._-]"#, with: "_", options: .regularExpression)
    }
}
