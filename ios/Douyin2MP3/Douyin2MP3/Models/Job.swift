// 用途：手机本地转换任务的结构化状态。App 只按这些字段展示，不做额外推断。
import Foundation

enum JobState: String, Codable {
    case queued, running, ready, failed

    var isActive: Bool { self == .queued || self == .running }
}

struct Job: Identifiable, Equatable {
    let id: String
    let sourceText: String
    var state: JobState = .queued
    var stage: String = "排队中"
    var progress: Double = 0
    var title: String?
    var videoID: String?
    var fileName: String?
    var sizeBytes: Int?
    var durationSec: Double?
    var error: String?
    var createdAt = Date()

    var displayTitle: String {
        if let title, !title.isEmpty { return title }
        return "抖音视频"
    }

    var sizeText: String {
        guard let sizeBytes else { return "" }
        return String(format: "%.1f MB", Double(sizeBytes) / 1024 / 1024)
    }
}

struct MediaItem: Codable, Identifiable, Equatable {
    let id: String
    var title: String
    var fileName: String
    var sizeBytes: Int?
    var durationSec: Double?
    var savedAt: Date

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
