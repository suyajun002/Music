// 用途：转换记录持久化。重启/发布后仍能保留失败原因并直接重试；
// 上次没跑完的任务在下次启动时标成「已中断」，免费来源自动重试一次，付费来源一律等用户确认。
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
            restored.error = restored.source.isPaid
                ? "上次下载中断（YouTube 走付费接口，重试会重新计费）"
                : "App 重启或发布时下载中断，可重试"
            return restored
        }
    }

    /// 上次启动时还没跑完、且没自动重试过的记录。返回 id 是因为调用方还要按原顺序
    /// 把它们重新入队；这里只负责判断「谁该自动重试」，不碰并发闸门。
    ///
    /// **付费来源不参与自动重试**：一次重试就是一次新的 Apify run，会再扣一次钱；
    /// 而且第二次 run 更容易踩到 actor 的断线恢复 bug（只给开头几秒）。这种必须让用户
    /// 自己点重试，手动重试那条有费用确认。
    static func interruptedJobsToAutoRetry(_ jobs: [Job]) -> [String] {
        normalized(jobs, limit: maxRecords)
            .filter { $0.state.isActive && !$0.autoRetried && !$0.source.isPaid }
            .map(\.id)
    }

    /// 哪些记录该跟着「某几条链接被清理」一起消失。
    ///
    /// 判定只看两点：**同一去重键**、**不在跑**。正在排队/下载的任务不动 —— 那是此刻
    /// 的真实状态，清历史不该把它从界面上抹掉；跑完自然变成正常记录。
    /// `keyFor` 由调用方注入，是为了让这段逻辑能脱离 `MediaSource` 单独单测。
    static func jobIDsToDropRelating(
        to keys: Set<String>,
        in jobs: [Job],
        keyFor: (String) -> String?
    ) -> Set<String> {
        guard !keys.isEmpty else { return [] }
        return Set(jobs.filter { job in
            guard !job.state.isActive else { return false }
            guard let key = keyFor(job.sourceURL) else { return false }
            return keys.contains(key)
        }.map(\.id))
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
