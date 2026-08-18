import Foundation

struct DownloadedAudioFile: Sendable {
    let url: URL
    let statusCode: Int
    let mimeType: String?
    let suggestedFilename: String?
}

/// Downloads audio to disk while reporting byte progress.
///
/// `URLSession`'s async `download(from:)` never reports progress, and precache
/// mode has to show how far the current song has downloaded, so this drives a
/// delegate-backed session and bridges its callbacks back to async/await.
final class AudioDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    static let shared = AudioDownloader()

    private struct Request {
        let onProgress: @Sendable (Int64, Int64) -> Void
        let continuation: CheckedContinuation<DownloadedAudioFile, Error>
    }

    private let lock = NSLock()
    private var requests: [Int: Request] = [:]
    private var session: URLSession!

    override init() {
        super.init()
        session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    }

    /// `onProgress` receives received and expected byte counts. The expected
    /// count is negative when the server sends no content length.
    func download(
        from url: URL,
        onProgress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws -> DownloadedAudioFile {
        try await withCheckedThrowingContinuation { continuation in
            let task = session.downloadTask(with: url)
            lock.withLock { requests[task.taskIdentifier] = .init(onProgress: onProgress, continuation: continuation) }
            task.resume()
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        progressHandler(for: downloadTask)?(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // The downloaded file only exists for the duration of this callback, so
        // it has to be claimed before returning.
        let destination = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .notDirectory)
        let response = downloadTask.response
        do {
            try FileManager.default.moveItem(at: location, to: destination)
            takeRequest(for: downloadTask)?.continuation.resume(returning: .init(
                url: destination,
                statusCode: (response as? HTTPURLResponse)?.statusCode ?? 0,
                mimeType: response?.mimeType,
                suggestedFilename: response?.suggestedFilename
            ))
        } catch {
            takeRequest(for: downloadTask)?.continuation.resume(throwing: error)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        // A successful download already resumed its continuation above.
        takeRequest(for: task)?.continuation.resume(throwing: error ?? URLError(.unknown))
    }

    private func progressHandler(for task: URLSessionTask) -> (@Sendable (Int64, Int64) -> Void)? {
        lock.withLock { requests[task.taskIdentifier]?.onProgress }
    }

    private func takeRequest(for task: URLSessionTask) -> Request? {
        lock.withLock { requests.removeValue(forKey: task.taskIdentifier) }
    }
}
