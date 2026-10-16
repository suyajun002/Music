// 用途：取流这件事的统一出口。上层只需要「给一条链接」，不关心底下是自己抓还是外包。
import Foundation

/// 取流：给一条链接，把媒体落到 destination，过程中通过 `onStage` 报「在干什么 + 进度」。
///
/// 抖音是自己抓（解析分享页 → 换 CDN 直链 → 下 MP4），YouTube 是把活外包给 Apify
/// （等它转好 MP3 → 下 MP3）—— 两边实现毫无共同点，但对 `ConversionService` 是同一件事，
/// 所以只约定这一个方法。
protocol MediaExtracting: Sendable {
    func fetch(
        url: URL,
        to destination: URL,
        onStage: @Sendable @escaping (String, FetchProgress) -> Void
    ) async throws -> ExtractedMedia
}

/// 取流结果：入库要用的最小信息。
/// 不在这里放「是视频还是音频」—— 那由落在磁盘上的扩展名决定（`MediaKind`），
/// 多存一份就多一个会和文件对不上的口径。
struct ExtractedMedia {
    /// 作品的唯一 id，兼作库内主键与去重键。
    let videoID: String
    /// 分享文案里的标题；取不到就交给 `MediaLibrary` 回落文件元数据/文件名。
    let title: String?
}

/// 取流进度。`fraction` 为 nil 表示服务器没给总大小（CDN 走 chunked），
/// 这时只报已下载字节，由上层按「大小未知」渲染，而不是假装卡在某个百分比。
struct FetchProgress {
    var fraction: Double?
    var bytesWritten: Int64 = 0
    /// 当前在干什么的补充说明：抖音是「清晰度·线路」，YouTube 是「已等多少秒」。
    /// 让用户看到进度在动、或者看到正在换线路重试，而不是卡死。
    var attempt: String?

    static func at(_ fraction: Double) -> FetchProgress {
        FetchProgress(fraction: fraction, bytesWritten: 0)
    }

    /// 由下载字节换算进度：服务器给了总大小就给比例（0…1），
    /// chunked 没给总大小就只有字节数，`fraction` 为 nil。
    static func fromBytes(totalWritten: Int64, expected: Int64) -> FetchProgress {
        guard expected > 0 else {
            return FetchProgress(fraction: nil, bytesWritten: max(totalWritten, 0))
        }
        let ratio = Double(totalWritten) / Double(expected)
        return FetchProgress(fraction: min(max(ratio, 0), 1), bytesWritten: totalWritten)
    }
}
