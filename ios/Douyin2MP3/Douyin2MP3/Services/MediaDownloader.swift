// 用途：媒体文件下载器。用「后台会话 + 会话级 delegate」：
// 1) 只有会话级 delegate 才会稳定收到 didWriteData（任务级 delegate 收不到下载进度，
//    所以旧代码里数据一路下到几百 MB，界面却停在 25%）；
// 2) background 配置让锁屏/切后台时交给系统的 nsurlsessiond 继续下，不被挂起掐断。
import Foundation

final class MediaDownloader: NSObject, URLSessionDownloadDelegate {
    static let shared = MediaDownloader()

    /// 后台会话标识：App 被系统拉起时用同一个标识重连未完成的下载。
    static let sessionIdentifier = "com.yajun.douyin2mp3.media"

    private struct Pending {
        let destination: URL
        let onProgress: @Sendable (Int64, Int64) -> Void
        let continuation: CheckedContinuation<Void, Error>
    }

    private let lock = NSLock()
    private var pending: [Int: Pending] = [:]
    private var backgroundCompletion: (() -> Void)?

    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        // 不交给系统挑时机，用户点了就下
        configuration.isDiscretionary = false
        // 下载完成时把 App 拉起来收文件
        configuration.sessionSendsLaunchEvents = true
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 3600
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    /// 下载到 destination。onProgress 回传 (已写字节, 期望总字节；未知为负)。
    func download(
        _ request: URLRequest,
        to destination: URL,
        onProgress: @Sendable @escaping (Int64, Int64) -> Void
    ) async throws {
        let task = session.downloadTask(with: request)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            lock.lock()
            pending[task.taskIdentifier] = Pending(
                destination: destination,
                onProgress: onProgress,
                continuation: continuation
            )
            lock.unlock()
            task.resume()
        }
    }

    // MARK: - 后台会话事件

    func setBackgroundCompletion(_ handler: @escaping () -> Void) {
        lock.lock()
        backgroundCompletion = handler
        lock.unlock()
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        lock.lock()
        let handler = backgroundCompletion
        backgroundCompletion = nil
        lock.unlock()
        DispatchQueue.main.async { handler?() }
    }

    // MARK: - URLSessionDownloadDelegate

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        lock.lock()
        let item = pending[downloadTask.taskIdentifier]
        lock.unlock()
        item?.onProgress(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        lock.lock()
        let item = pending[downloadTask.taskIdentifier]
        lock.unlock()
        guard let item else { return }

        // 后台会话拿不到异步返回值，状态码只能在这里读
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            finish(taskIdentifier: downloadTask.taskIdentifier, error: DouyinError.downloadRejected("HTTP \(http.statusCode)"))
            return
        }

        do {
            try FileManager.default.createDirectory(
                at: item.destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if FileManager.default.fileExists(atPath: item.destination.path) {
                try FileManager.default.removeItem(at: item.destination)
            }
            // 系统临时文件必须在这里同步搬走，回调返回后就可能被清理
            try FileManager.default.moveItem(at: location, to: item.destination)
            finish(taskIdentifier: downloadTask.taskIdentifier, error: nil)
        } catch {
            finish(taskIdentifier: downloadTask.taskIdentifier, error: error)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        finish(taskIdentifier: task.taskIdentifier, error: error)
    }

    private func finish(taskIdentifier: Int, error: Error?) {
        lock.lock()
        let item = pending.removeValue(forKey: taskIdentifier)
        lock.unlock()
        guard let item else { return }
        if let error {
            try? FileManager.default.removeItem(at: item.destination)
            item.continuation.resume(throwing: error)
        } else {
            item.continuation.resume()
        }
    }

    /// 清掉 CFNetwork 残留在 tmp 里的半截下载。
    /// 每次下载被掐断都会留一个，实测能堆到 1GB+（App 本体才 2.4MB）。
    @discardableResult
    static func purgeOrphanedTempFiles() -> Int {
        let fileManager = FileManager.default
        let tmp = fileManager.temporaryDirectory
        guard let names = try? fileManager.contentsOfDirectory(atPath: tmp.path) else { return 0 }
        var removed = 0
        for name in names where name.hasPrefix("CFNetworkDownload_") {
            if (try? fileManager.removeItem(at: tmp.appendingPathComponent(name))) != nil {
                removed += 1
            }
        }
        return removed
    }
}
