// 用途：转换记录持久化。重启/发布后仍能保留失败原因并直接重试；
// 上次没跑完的任务在下次启动时标成「已中断」，每条记录只自动重试一次。
import Foundation

struct ConversionHistoryStore {
    /// 和「下过又删了」的列表一样，只留最近这些；转换记录是提醒，不是永久账本。
    static let maxRecords = 200

    private struct Snapshot: Codable {
        let version: Int
        let jobs: [Job]
    }

    private let directory: URL
    private let fileURL: URL
    private let backupURL: URL
    private let fileManager: FileManager
    private let maxRecords: Int

    init(
        directory: URL? = nil,
        maxRecords: Int = ConversionHistoryStore.maxRecords,
        fileManager: FileManager = .default
    ) {
        let documents = directory ?? fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.directory = documents
        self.fileURL = documents.appendingPathComponent("conversion-history.json")
        self.backupURL = self.fileURL.appendingPathExtension("bak")
        self.fileManager = fileManager
        self.maxRecords = maxRecords
    }

    /// 读上次保存的记录。索引坏了就留档后从空历史开始，不阻塞 App 启动。
    func load() -> [Job] {
        guard fileManager.fileExists(atPath: fileURL.path) else { return [] }
        guard let data = try? Data(contentsOf: fileURL) else { return [] }

        let decoded: [Job]
        if let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) {
            decoded = snapshot.jobs
        } else if let legacy = try? JSONDecoder().decode([Job].self, from: data) {
            decoded = legacy
        } else {
            let stamp = Int(Date().timeIntervalSince1970)
            let corrupt = fileURL.appendingPathExtension("corrupt-\(stamp)")
            try? fileManager.moveItem(at: fileURL, to: corrupt)
            MusicDebug.log("转换记录解码失败，已留档 \(corrupt.lastPathComponent)")
            return []
        }

        try? data.write(to: backupURL, options: .atomic)
        return Self.normalized(decoded, limit: maxRecords)
    }

    func save(_ jobs: [Job]) {
        let snapshot = Snapshot(version: 1, jobs: Self.normalized(jobs, limit: maxRecords))
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            MusicDebug.log("转换记录写盘失败：\(error.localizedDescription)")
        }
    }

    /// 启动时把上次没跑完的任务变成失败记录。失败原因要能回答「为什么」，
    /// 而不是让用户面对一条永远不会动的「排队中」。
    static func restoredForLaunch(_ jobs: [Job], limit: Int = maxRecords) -> [Job] {
        normalized(jobs, limit: limit).map { job in
            var restored = job
            if restored.fileName == nil {
                restored.fileName = "\(restored.id).\(restored.source.fileExtension)"
            }
            guard restored.state.isActive else { return restored }
            restored.state = .failed
            restored.stage = "已中断"
            restored.progress = 0
            restored.progressUnknown = false
            restored.downloadedBytes = 0
            restored.attempt = nil
            restored.error = "App 重启或发布时下载中断，可重试"
            return restored
        }
    }

    /// 上次启动时还没跑完、且没自动重试过的记录。返回 id 是因为调用方还要按原顺序
    /// 把它们重新入队；这里只负责判断「谁该自动重试」，不碰并发闸门。
    static func interruptedJobsToAutoRetry(_ jobs: [Job]) -> [String] {
        normalized(jobs, limit: maxRecords)
            .filter { $0.state.isActive && !$0.autoRetried }
            .map(\.id)
    }

    /// 去重、丢掉没有可用链接的记录、限制条数。保持原有顺序（新任务在前）。
    private static func normalized(_ jobs: [Job], limit: Int) -> [Job] {
        var seen = Set<String>()
        var result: [Job] = []
        for job in jobs {
            guard URL(string: job.sourceURL) != nil, seen.insert(job.id).inserted else { continue }
            result.append(job)
            if result.count >= limit { break }
        }
        return result
    }
}
