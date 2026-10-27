// 用途：手机本地转换任务的结构化状态。App 只按这些字段展示，不做额外推断。
import Foundation

enum JobState: String, Codable {
    case queued, running, ready, failed

    var isActive: Bool { self == .queued || self == .running }
}

struct Job: Identifiable, Equatable {
    let id: String
    /// 这条链接是抖音还是 YouTube。定下扩展名（mp4/mp3）、决定谁来取流，
    /// 也是界面上「这条走的是哪条链路」的唯一依据。
    let source: MediaSource
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
        return source == .youtube ? "YouTube 音频" : "抖音视频"
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

/// 「下过、后来被删掉」的链接。只记链接和标题，一条几十字节。
///
/// 为什么删了还要记：YouTube 那条是**按首花钱**的。删掉一首歌再贴同一条链接，
/// 若什么都不记得就会重新开一次 Apify run、重新扣一次钱，而用户完全没被问过。
/// 所以这些链接**默认不再自动重下**，只在确认框和结论里点名「这条下过、后来删了」，
/// 要重下得由用户明确点一下。
struct DeletedLink: Codable, Identifiable, Equatable {
    var sourceURL: String
    /// 当时入库的标题。只为了在提示里指名道姓（「下过又删了：Ice Paper…」），
    /// 光甩一条 URL 用户认不出那是哪首。
    var title: String
    var deletedAt: Date

    var id: String { sourceURL }
}
