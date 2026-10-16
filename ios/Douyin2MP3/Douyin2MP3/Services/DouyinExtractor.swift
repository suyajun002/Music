// 用途：在手机上完成取流全链路（短链解析 → ttwid 凭证 → share 页解析 → CDN 直链 → 无水印下载）。
// 取流逻辑集中在本文件；接口调整时只改这里的 DouyinConfig 与各解析方法。
import Foundation

/// 诊断开关：`D2M_DEBUG=1` 时把取流关键量打到 stdout，
/// 便于用 `devicectl device process launch --console` 在真机上看请求/下载细节。默认关闭。
enum DouyinDebug {
    static let enabled = ProcessInfo.processInfo.environment["D2M_DEBUG"] == "1"

    static func log(_ message: @autoclosure () -> String) {
        guard enabled else { return }
        print("[d2m] \(message())")
        // stdout 在 `devicectl --console` 这种管道下是块缓冲的：不主动 flush，
        // 进程被 kill（或 --terminate-existing）时最后几行还在缓冲里，日志会缺关键结论。
        fflush(stdout)
    }
}

enum DouyinError: LocalizedError {
    case linkFormat
    case shortLinkFailed
    case shellPage
    case noVideoData
    case imageOnly
    case playRejected(String)
    case downloadRejected(String)

    var errorDescription: String? {
        switch self {
        case .linkFormat: return "没找到链接，请粘贴分享文本或链接"
        case .shortLinkFailed: return "短链接解析失败，链接可能已失效"
        case .shellPage: return "服务端返回了空壳页面（风控或接口已调整），稍后重试"
        case .noVideoData: return "这条作品没有可下载的视频数据"
        case .imageOnly: return "这是图文作品，没有视频"
        case .playRejected(let detail): return "获取视频直链失败：\(detail)"
        case .downloadRejected(let detail): return "视频下载失败：\(detail)"
        }
    }
}

struct ExtractedVideo {
    let videoID: String
    let title: String?
    let imageCount: Int
}

/// 取流进度。`fraction` 为 nil 表示服务器没给总大小（CDN 走 chunked），
/// 这时只报已下载字节，由上层按「大小未知」渲染，而不是假装卡在某个百分比。
struct FetchProgress {
    var fraction: Double?
    var bytesWritten: Int64 = 0
    /// 当前在试的「清晰度·线路」说明，让用户看到正在换线路重试而不是卡死。
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

/// 取流所需的全部请求参数集中在这里，便于接口变化时统一调整。
struct DouyinConfig {
    var mobileUserAgent =
        "Mozilla/5.0 (iPhone; CPU iPhone OS 16_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Mobile/15E148 Safari/604.1"
    var desktopUserAgent =
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"
    var clarityCandidates = ["1080p", "720p", "540p"]
    /// CDN 线路：同一条视频换 line 会命中不同边缘节点；手机侧某个节点连不上时换线比重试同一地址有用。
    var lineCandidates = [0, 1, 2]
    var requestTimeout: TimeInterval = 60
    /// 下载空闲上限：超过这么久没有新数据就断开重试，避免连接卡死后一停停十分钟。
    var downloadIdleTimeout: TimeInterval = 30
    /// 并发下载时复用凭证，避免每个任务都去打一次 ttwid
    var cookieRefreshInterval: TimeInterval = 300
    /// 壳页（风控）重试次数
    var shareRetryCount = 1
    /// 认哪些域名为「抖音链接」。剪贴板闸门用它把无关链接（淘宝、B站…）挡在确认框之外，
    /// 匹配规则是「等于该域名 或 以 .该域名 结尾」。
    var douyinHostSuffixes = ["douyin.com", "iesdouyin.com"]
}

actor DouyinExtractor {
    private let config: DouyinConfig
    private var cookieJar: [String: String] = [:]
    private var lastCookieRefresh: Date?

    private let noRedirect = NoRedirectSession()
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        // 整体上限，避免超大文件（几百 MB）被默认 7 天兜底无限挂着
        configuration.timeoutIntervalForResource = 1800
        configuration.httpCookieAcceptPolicy = .always
        configuration.httpShouldSetCookies = true
        return URLSession(configuration: configuration)
    }()

    init(config: DouyinConfig = DouyinConfig()) {
        self.config = config
    }

    // MARK: - 主流程

    /// 取回流媒体文件并落到 destination；stage 回调用于向用户展示当前进度。
    func fetchVideo(
        shareText: String,
        to destination: URL,
        onStage: @Sendable @escaping (String, FetchProgress) -> Void
    ) async throws -> ExtractedVideo {
        guard let url = Self.allURLs(in: shareText).first else { throw DouyinError.linkFormat }
        return try await fetchVideo(url: url, to: destination, onStage: onStage)
    }

    func fetchVideo(
        url: URL,
        to destination: URL,
        onStage: @Sendable @escaping (String, FetchProgress) -> Void
    ) async throws -> ExtractedVideo {
        onStage("解析链接", .at(0.05))
        let videoID = try await resolveVideoID(from: url)
        DouyinDebug.log("作品 ID \(videoID)")

        onStage("获取访问凭证", .at(0.10))
        await refreshCookies()

        onStage("解析作品信息", .at(0.16))
        let html = try await fetchShareHTML(videoID: videoID)
        let parsed = parseShareHTML(html)
        DouyinDebug.log("share 页 \(html.count) 字节，uri=\(parsed.uri ?? "nil")，images=\(parsed.images.count)")

        if parsed.uri == nil {
            if !parsed.images.isEmpty { throw DouyinError.imageOnly }
            throw DouyinError.noVideoData
        }
        guard let uri = parsed.uri else { throw DouyinError.noVideoData }

        onStage("下载视频", .at(0.25))
        try await downloadFirstAvailable(uri: uri, to: destination) { progress in
            guard let fraction = progress.fraction else {
                onStage("下载视频", progress)
                return
            }
            onStage("下载视频", FetchProgress(
                fraction: 0.25 + fraction * 0.7,
                bytesWritten: progress.bytesWritten
            ))
        }

        onStage("保存到手机", .at(0.98))
        return ExtractedVideo(videoID: videoID, title: parsed.desc, imageCount: parsed.images.count)
    }

    // MARK: - 链接解析

    func resolveVideoID(from shareText: String) async throws -> String {
        let firstURL = try Self.firstURL(in: shareText)
        return try await resolveVideoID(from: firstURL)
    }

    func resolveVideoID(from firstURL: URL) async throws -> String {
        let isShortLink = firstURL.host?.contains("v.douyin.com") == true
        let resolved: URL
        if isShortLink {
            guard
                let location = try await redirectLocation(
                    url: firstURL,
                    userAgent: config.mobileUserAgent,
                    referer: nil
                ),
                let target = URL(string: location, relativeTo: firstURL)
            else { throw DouyinError.shortLinkFailed }
            resolved = target
        } else {
            resolved = firstURL
        }

        if let modalID = URLComponents(url: resolved, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "modal_id" })?.value,
           !modalID.isEmpty {
            return modalID
        }

        let last = resolved.path.split(separator: "/").last.map(String.init) ?? ""
        // 短链已跳转但没有作品 ID，说明链接本身失效，不要误报「没找到链接」。
        guard !last.isEmpty else { throw isShortLink ? DouyinError.shortLinkFailed : DouyinError.linkFormat }
        return last
    }

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

    /// 只要抖音自己的链接。`allURLs` 会认任何 https 链接，而剪贴板里放的多半是别的东西：
    /// 不加这一层，复制个淘宝/B站链接打开 App 就会弹确认框，确认了还只会下失败。
    static func douyinURLs(in text: String) -> [URL] {
        allURLs(in: text).filter { isDouyinHost($0.host) }
    }

    static func isDouyinHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return DouyinConfig().douyinHostSuffixes.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// 兼容旧调用：取第一条链接。
    static func firstURL(in text: String) throws -> URL {
        guard let url = allURLs(in: text).first else { throw DouyinError.linkFormat }
        return url
    }

    // MARK: - 反爬 Cookie

    private func refreshCookies(force: Bool = false) async {
        if !force, !cookieJar.isEmpty, let last = lastCookieRefresh,
           Date().timeIntervalSince(last) < config.cookieRefreshInterval {
            return
        }
        // 1. 首页基础 Cookie（失败不致命）
        if let url = URL(string: "https://www.douyin.com/") {
            var request = URLRequest(url: url)
            request.setValue(config.desktopUserAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("https://www.douyin.com/", forHTTPHeaderField: "Referer")
            if let (data, response) = try? await session.data(for: request) {
                storeCookies(from: response, url: url, body: data)
            }
        }

        // 2. 注册 ttwid（无它 share 页会退化为壳页）
        guard let url = URL(string: "https://ttwid.bytedance.com/ttwid/union/register/") else { return }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(config.desktopUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://www.douyin.com/", forHTTPHeaderField: "Referer")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let payload: [String: Any] = [
            "region": "cn",
            "aid": 1768,
            "needFid": false,
            "union": true,
            "service": "www.ixigua.com",
            "cbUrlProtocol": "https",
            "migrate_info": ["ticket": "", "source": "node"],
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)
        if let (data, response) = try? await session.data(for: request) {
            storeCookies(from: response, url: url, body: data)
        }
        lastCookieRefresh = Date()
        DouyinDebug.log("Cookie 刷新完成，共 \(cookieJar.count) 项")
    }

    /// 同时解析响应头里的 Set-Cookie 与 URLSession Cookie 存储，尽量贴近脚本的 Cookie 池行为。
    private func storeCookies(from response: URLResponse, url: URL, body: Data) {
        guard let http = response as? HTTPURLResponse else { return }
        for cookie in HTTPCookie.cookies(withResponseHeaderFields: http.allHeaderFields as? [String: String] ?? [:], for: url) {
            cookieJar[cookie.name] = cookie.value
        }
        for cookie in session.configuration.httpCookieStorage?.cookies ?? [] {
            cookieJar[cookie.name] = cookie.value
        }
    }

    private var cookieHeader: String {
        cookieJar.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
    }

    // MARK: - share 页

    private func fetchShareHTML(videoID: String) async throws -> String {
        for attempt in 0...config.shareRetryCount {
            do {
                return try await fetchShareHTMLOnce(videoID: videoID)
            } catch {
                guard attempt < config.shareRetryCount else { throw error }
                // 并发下载时可能被风控降级，刷新凭证后再试一次
                await refreshCookies(force: true)
            }
        }
        throw DouyinError.shellPage
    }

    private func fetchShareHTMLOnce(videoID: String) async throws -> String {
        let candidates = [
            "https://www.iesdouyin.com/share/video/\(videoID)/",
            "https://www.iesdouyin.com/share/note/\(videoID)/",
        ]

        for candidate in candidates {
            guard let url = URL(string: candidate) else { continue }
            var request = URLRequest(url: url)
            request.setValue(config.mobileUserAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("https://www.douyin.com/", forHTTPHeaderField: "Referer")
            if !cookieHeader.isEmpty {
                request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
            }
            guard
                let (data, _) = try? await session.data(for: request),
                let html = String(data: data, encoding: .utf8)
            else { continue }

            // 壳页只有几 KB 且不含 aweme 数据
            if html.contains("\"aweme_type\"") { return html }
        }

        throw DouyinError.shellPage
    }

    // MARK: - 页面解析

    struct ParsedShare {
        let uri: String?
        let images: [[String]]
        let desc: String?
    }

    func parseShareHTML(_ html: String) -> ParsedShare {
        let images = Self.extractImages(html)

        var uri: String?
        if let match = Self.firstMatch(#""play_addr":\{"uri":"([^"]+)""#, in: html) {
            uri = match
        }

        var desc: String?
        if let raw = Self.firstMatch(#""desc":"((?:[^"\\]|\\.)*)""#, in: html) {
            desc = JSONEscapes.decode(raw)
        }

        return ParsedShare(uri: uri, images: images, desc: desc)
    }

    /// 图文作品的 images 数组会被页面重复插入，按 uri 去重合并各规格 URL。
    static func extractImages(_ html: String) -> [[String]] {
        let bytes = Array(html.utf8)
        let needle = Array("\"images\":[".utf8)
        var byURI: [String: [String]] = [:]
        var order: [String] = []

        var index = 0
        while index + needle.count <= bytes.count {
            guard let found = find(needle, in: bytes, from: index) else { break }
            let openIndex = found + needle.count - 1
            index = openIndex + 1

            guard let slice = balancedArray(bytes, from: openIndex) else { continue }
            let json = String(decoding: slice, as: UTF8.self)
                .replacingOccurrences(of: "\\u002F", with: "/")
            guard
                let data = json.data(using: .utf8),
                let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
            else { continue }

            for item in list {
                guard let uri = item["uri"] as? String else { continue }
                let urls = (item["url_list"] as? [String]) ?? []
                if var existing = byURI[uri] {
                    for url in urls where !existing.contains(url) { existing.append(url) }
                    byURI[uri] = existing
                } else {
                    byURI[uri] = urls
                    order.append(uri)
                }
            }
        }

        return order.compactMap { byURI[$0] }
    }

    private static func find(_ needle: [UInt8], in haystack: [UInt8], from start: Int) -> Int? {
        guard !needle.isEmpty, start >= 0, start < haystack.count else { return nil }
        let limit = haystack.count - needle.count
        var i = start
        while i <= limit {
            if haystack[i] == needle[0] {
                var j = 1
                while j < needle.count, haystack[i + j] == needle[j] { j += 1 }
                if j == needle.count { return i }
            }
            i += 1
        }
        return nil
    }

    /// 从 `[` 起取配平方括号内容（页面里的 JSON 是分段插入的，不能直接整体 parse）。
    private static func balancedArray(_ bytes: [UInt8], from openIndex: Int) -> [UInt8]? {
        var depth = 0
        var i = openIndex
        while i < bytes.count {
            if bytes[i] == UInt8(ascii: "[") {
                depth += 1
            } else if bytes[i] == UInt8(ascii: "]") {
                depth -= 1
                if depth == 0 { return Array(bytes[openIndex...i]) }
            }
            i += 1
        }
        return nil
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard
            let regex = try? NSRegularExpression(pattern: pattern),
            let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
            match.numberOfRanges > 1,
            let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[range])
    }


    // MARK: - 换取 CDN 直链并下载

    private func cdnURL(uri: String, ratio: String, line: Int) async throws -> URL {
        guard
            let url = URL(string: "https://aweme.snssdk.com/aweme/v1/play/?video_id=\(uri)&ratio=\(ratio)&line=\(line)")
        else { throw DouyinError.playRejected("地址拼装失败") }

        guard
            let location = try await redirectLocation(
                url: url,
                userAgent: config.mobileUserAgent,
                referer: nil
            ),
            let cdn = URL(string: location)
        else { throw DouyinError.playRejected("接口没有返回跳转（\(ratio)/line\(line)）") }

        return cdn
    }

    /// 逐个「清晰度 × 线路」组合尝试：任一组合成功即返回。
    /// 坏一个边缘节点不影响整体；全部失败才把最后一个错误抛出。
    private func downloadFirstAvailable(
        uri: String,
        to destination: URL,
        onProgress: @Sendable @escaping (FetchProgress) -> Void
    ) async throws {
        var lastError: Error = DouyinError.downloadRejected("所有清晰度和线路均失败")

        for ratio in config.clarityCandidates {
            for line in config.lineCandidates {
                let label = "\(ratio)·线路\(line)"
                do {
                    let cdn = try await cdnURL(uri: uri, ratio: ratio, line: line)
                    DouyinDebug.log("试 \(label) → \(cdn.host ?? "-")")
                    // 先报一次，让界面显示「正在试哪个线路」，而不是原地停在 25%
                    onProgress(FetchProgress(fraction: 0.25, bytesWritten: 0, attempt: label))
                    try await download(cdn: cdn, to: destination) { progress in
                        var tagged = progress
                        tagged.attempt = label
                        // 每 50MB 打一条日志，足够定位又不会刷屏
                        if progress.bytesWritten / 1_048_576 % 50 == 0 {
                            DouyinDebug.log("\(label) 已下 \(progress.bytesWritten / 1_048_576)MB")
                        }
                        onProgress(tagged)
                    }
                    DouyinDebug.log("\(label) 下载成功")
                    return
                } catch {
                    DouyinDebug.log("\(label) 失败：\(error.localizedDescription)")
                    lastError = error
                }
            }
        }

        throw lastError
    }

    private func download(
        cdn: URL,
        to destination: URL,
        onProgress: @Sendable @escaping (FetchProgress) -> Void
    ) async throws {
        var request = URLRequest(url: cdn)
        request.setValue(config.mobileUserAgent, forHTTPHeaderField: "User-Agent")
        // CDN 强制校验 referer，缺失会 403
        request.setValue("https://www.douyin.com/", forHTTPHeaderField: "Referer")
        request.timeoutInterval = config.downloadIdleTimeout

        // 走后台会话：锁屏/切后台时下载继续，且会话级 delegate 才收得到进度
        try await MediaDownloader.shared.download(request, to: destination) { written, expected in
            onProgress(FetchProgress.fromBytes(totalWritten: written, expected: expected))
        }

        let size = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int) ?? nil
        guard let size, size > 1024 else {
            try? FileManager.default.removeItem(at: destination)
            throw DouyinError.downloadRejected("文件过小")
        }
        guard try Self.looksLikeMP4(destination) else {
            try? FileManager.default.removeItem(at: destination)
            throw DouyinError.downloadRejected("下载内容不是有效视频")
        }
    }

    /// 校验 MP4 的 ftyp 签名，只读前 64 字节。
    static func looksLikeMP4(_ url: URL) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let head = try handle.read(upToCount: 64) ?? Data()
        return head.range(of: Data("ftyp".utf8)) != nil
    }

    /// 发一个不跟随跳转的请求，返回 302 的 Location。
    private func redirectLocation(url: URL, userAgent: String, referer: String?) async throws -> String? {
        var request = URLRequest(url: url)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if let referer {
            request.setValue(referer, forHTTPHeaderField: "Referer")
        }
        let (_, response) = try await noRedirect.session.data(for: request, delegate: noRedirect)
        return (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Location")
    }
}

/// 取消自动跟随跳转，让上层自己读 Location（短链与 play 接口都依赖这一步）。
private final class NoRedirectSession: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.httpCookieAcceptPolicy = .always
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        nil
    }
}

