// 用途：手机本地转换任务的结构化状态。App 只按这些字段展示，不做额外推断。
import Foundation

enum JobState: String, Codable {
    case queued, running, ready, failed

    var isActive: Bool { self == .queued || self == .running }
}

struct Job: Identifiable, Equatable {
    let id: String
    let sourceURL: String
    var state: JobState = .queued
    var stage: String = "排队中"
    var progress: Double = 0
    /// 服务器没给总大小时为 true：此时进度条走「不确定」样式，只显示已下载字节。
    var progressUnknown: Bool = false
    var downloadedBytes: Int64 = 0
    /// 正在尝试的「清晰度·线路」，让用户看到换线路重试的过程。
    var attempt: String?
    var title: String?
    var videoID: String?
    var fileName: String?
    var sizeBytes: Int?
    var durationSec: Double?
    var error: String?
    var createdAt = Date()

    var displayTitle: String {
        if let title, !title.isEmpty { return title }
        return "未命名音频"
    }

    var sizeText: String {
        guard let sizeBytes else { return "" }
        return String(format: "%.1f MB", Double(sizeBytes) / 1024 / 1024)
    }

    var downloadedText: String {
        String(format: "%.1f MB", Double(downloadedBytes) / 1024 / 1024)
    }
}

struct MediaItem: Codable, Identifiable, Equatable {
    let id: String
    var title: String
    var fileName: String
    var artworkFileName: String?
    var sizeBytes: Int?
    var durationSec: Double?
    var savedAt: Date
    /// 来源链接。用于「粘贴即下载」时判断这条是否已经下过，避免重复下载。
    /// 老索引里没有这个字段，解码为 nil，只是无法参与去重。
    var sourceURL: String?

    var durationText: String {
        guard let durationSec, durationSec > 0 else { return "--:--" }
        let total = Int(durationSec.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    var sizeText: String {
        guard let sizeBytes else { return "" }
        return String(format: "%.1f MB", Double(sizeBytes) / 1024 / 1024)
    }
}
