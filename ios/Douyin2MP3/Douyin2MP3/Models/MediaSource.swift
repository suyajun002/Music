// 用途：来源识别。一条链接是抖音还是 YouTube，只按域名判断 —— 用户永远不用自己选来源，
// 粘贴框和剪贴板那条路都是自动路由。
import Foundation

enum MediaSource: String, CaseIterable {
    case douyin
    case youtube

    /// 落到沙盒时用什么扩展名。抖音下的是无水印 MP4；YouTube 那头是 Apify 用 yt-dlp
    /// 转好的 MP3。这一条决定了入库后是「有画面」还是「只有封面」（见 `MediaKind`）。
    var fileExtension: String {
        switch self {
        case .douyin: return "mp4"
        case .youtube: return "mp3"
        }
    }

    var displayName: String {
        switch self {
        case .douyin: return "抖音"
        case .youtube: return "YouTube"
        }
    }

    /// 按首计费的来源：YouTube 是把活外包给 Apify，确认框据此把「这一下要花钱」说清楚。
    var isPaid: Bool { self == .youtube }

    /// 认哪些域名为这个来源。表从各自的 Config 读 —— 新增来源时只加一行，
    /// 不在路由里散落域名串（硬编码约束）。
    private static let hostSuffixes: [(source: MediaSource, suffix: String)] =
        DouyinConfig().douyinHostSuffixes.map { (MediaSource.douyin, $0) }
        + YouTubeConfig().youtubeHostSuffixes.map { (MediaSource.youtube, $0) }

    /// 这条链接归谁管；不认识的域名返回 nil。
    static func of(_ url: URL) -> MediaSource? { ofHost(url.host) }

    /// 匹配规则是「等于该域名 或 以 `.该域名` 结尾」——
    /// **不能用 `contains`**，否则 `douyin.com.evil.example` 会被当成抖音。
    static func ofHost(_ host: String?) -> MediaSource? {
        guard let host = host?.lowercased() else { return nil }
        return hostSuffixes.first { host == $0.suffix || host.hasSuffix("." + $0.suffix) }?.source
    }

    /// 去重用的「同一条内容」标识。
    ///
    /// **不能拿 URL 原串当键。** 同一个 YouTube 视频能贴成好几种写法：
    /// `youtu.be/ID`、`www.youtube.com/watch?v=ID`、`music.youtube.com/watch?v=ID`、
    /// 再挂一串 `?si=` 分享跟踪参数、或者末尾多个斜杠 —— 四种写法四个键，
    /// 就会开四次 Apify run、**同一首歌重复扣四份钱**。所以 YouTube 一律收敛到视频 ID。
    ///
    /// 抖音短链（`v.douyin.com/xxx`）离线还原不出作品 ID（得先请求一次跳转），
    /// 只能退一步规范化 URL：域名小写、去掉 `www.`、去掉查询串和结尾斜杠。
    /// 分享文案里带的 `?ug_source=` 之类就落在这条上。
    func dedupeKey(for url: URL) -> String {
        if self == .youtube, let id = YouTubeExtractor.videoID(of: url) {
            return "youtube:v\(id)"
        }
        return "\(rawValue):\(Self.normalizedURLString(url))"
    }

    /// 规范化后的 URL 串。**路径大小写必须保留**：抖音短链的路径是区分大小写的
    /// base62 码，转小写会把两条不同的链接并成一条、直接少下一首。
    static func normalizedURLString(_ url: URL) -> String {
        var host = (url.host ?? "").lowercased()
        if host.hasPrefix("www.") { host.removeFirst(4) }
        var path = url.path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return host + path
    }
}

/// 从一段文本里抠链接。分享文案、剪贴板内容都是「一段话里夹一条链接」，
/// 所以「怎么抠」和「抠出来归谁」放在一起：先扫出所有 https，再按域名分派给来源。
enum LinkScanner {
    /// 抠出文本里所有 https 链接（去重、去掉结尾中文标点），支持一次粘贴多条分享文本。
    static func allURLs(in text: String) -> [URL] {
        let pattern = "https://[^\\s]+"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))

        var urls: [URL] = []
        for match in matches {
            guard let range = Range(match.range, in: text) else { continue }
            var raw = String(text[range])
            while let last = raw.last, "，。；;、".contains(last) {
                raw.removeLast()
            }
            guard let url = URL(string: raw), !urls.contains(url) else { continue }
            urls.append(url)
        }
        return urls
    }

    /// 只保留**认得出来源**的链接（抖音或 YouTube）。`allURLs` 会认任何 https 链接，
    /// 而剪贴板里放的多半是别的东西：不加这一层，复制个淘宝/B站链接打开 App 就会弹确认框，
    /// 确认了还只会下失败。
    static func recognizableURLs(in text: String) -> [URL] {
        allURLs(in: text).filter { MediaSource.of($0) != nil }
    }
}
