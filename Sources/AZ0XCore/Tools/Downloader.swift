import Foundation

/// Byte progress callback: completed and total.
typealias ByteProgress = (Int64, Int64?) -> Void

/// Large-file download with progress.
enum Downloader {

    /// Downloads to the given path.
    static func download(from url: URL,
                         to destination: URL,
                         onProgress: ByteProgress? = nil) async throws {
        let box = TaskBox()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                let delegate = Delegate(destination: destination,
                                        onProgress: onProgress,
                                        continuation: continuation)
                let config = URLSessionConfiguration.ephemeral
                // Limit for the whole download.
                config.timeoutIntervalForResource = 3600
                let session = URLSession(configuration: config,
                                         delegate: delegate, delegateQueue: nil)
                let task = session.downloadTask(with: url)
                box.adopt(task)
                task.resume()
                // Invalidate immediately: a resumed task still runs to completion and the session.
                session.finishTasksAndInvalidate()
            }
        } onCancel: {
            box.cancel()
        }
    }
}

/// Failures of the download itself.
enum DownloadError: LocalizedError {
    /// A non-2xx HTTP status.
    case httpStatus(Int, String)
    var errorDescription: String? {
        switch self {
        case let .httpStatus(c, u): return "下载失败：HTTP \(c)（\(u)）"
        }
    }
}

/// Holds the download task so that the cancellation handler can cancel it from another thread.
private final class TaskBox {
    private let lock = NSLock()
    private var task: URLSessionTask?
    func adopt(_ t: URLSessionTask) { lock.lock(); task = t; lock.unlock() }
    func cancel() { lock.lock(); let t = task; lock.unlock(); t?.cancel() }
}

private final class Delegate: NSObject, URLSessionDownloadDelegate {

    private let destination: URL
    private let onProgress: ByteProgress?
    /// Guards `continuation` only; resuming it twice traps.
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    /// Read and written only on the serial delegate queue, so no lock is needed.
    private var lastReport = Date.distantPast

    init(destination: URL,
         onProgress: ByteProgress?,
         continuation: CheckedContinuation<Void, Error>) {
        self.destination = destination
        self.onProgress = onProgress
        self.continuation = continuation
    }

    /// Resumes the continuation exactly once.
    private func finish(_ result: Result<Void, Error>) {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        guard let c else { return }
        c.resume(with: result)
    }

    /// Progress reporting is throttled to 5 Hz.
    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil
        // When the total is unknown it is -1 or 0, so a direct comparison would always be true.
        let isLast = total.map { totalBytesWritten >= $0 } ?? false
        let now = Date()
        guard isLast || now.timeIntervalSince(lastReport) >= 0.2 else { return }
        lastReport = now
        onProgress?(totalBytesWritten, total)
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // An HTTP error status does not reach didCompleteWithError.
        if let http = downloadTask.response as? HTTPURLResponse,
           !(200..<300).contains(http.statusCode) {
            finish(.failure(DownloadError.httpStatus(http.statusCode,
                                                     downloadTask.originalRequest?.url?
                                                         .absoluteString ?? "")))
            return
        }
        // The file must be moved before this method returns.
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).partial-\(UUID().uuidString)")
        do {
            try FileManager.default.moveItem(at: location, to: staging)
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: staging)
            } else {
                try FileManager.default.moveItem(at: staging, to: destination)
            }
            finish(.success(()))
        } catch {
            try? FileManager.default.removeItem(at: staging)
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        // The success path is resumed by didFinishDownloadingTo.
        if let error { finish(.failure(error)) }
    }
}
