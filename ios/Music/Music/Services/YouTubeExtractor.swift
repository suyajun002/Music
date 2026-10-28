// 用途：YouTube 取音频。手机上跑不了 yt-dlp，所以把「取流」这一步**外包给 Apify actor**，
// 自己只负责「起任务 → 等它转好 → 把 mp3 拿回来 → 入库」。
//
// 链路（与 skills/youtube-audio-download 的 `apify_yt_audio.py` 一致，是跑通过的那份）：
//   POST /acts/<actor>/runs          → runId + defaultDatasetId
//   GET  /actor-runs/<runId>         → 轮询到终态
//   GET  /datasets/<datasetId>/items → audioFileUrl
//   GET  audioFileUrl                → mp3
import Foundation

enum YouTubeError: LocalizedError {
    case missingToken
    case videoID
    case submitFailed(String)
    case runFailed(String)
    case noAudio(String)
    case downloadRejected(String)

    var errorDescription: String? {
        switch self {
        case .missingToken: return "还没填 Apify token：右上角设置里填一次"
        case .videoID: return "链接里没认出 YouTube 视频 ID"
        case .submitFailed(let detail): return "提交 Apify 任务失败：\(detail)"
        case .runFailed(let detail): return "Apify 任务失败：\(detail)"
        case .noAudio(let detail): return "这条没取到音频：\(detail)"
        case .downloadRejected(let detail): return "音频下载失败：\(detail)"
        }
    }
}

/// HTTP 401/403 在 Apify 这边就是「这个 token 不行」：可能是拼错了、被撤销了，
/// 或者账号没权限用这个 actor。三种都只有一个动作 —— 去设置里换一个，所以合成一个错误。
/// 参数带上状态码，是为了万一其实是别的原因，日志里还留得下线索。
struct YouTubeAuthError: LocalizedError {
    let statusCode: Int

    var errorDescription: String? {
        "Apify token 无效或没权限（HTTP \(statusCode)），去设置里换一个"
    }
}

/// YouTube 取流所需的全部参数集中在这里，便于接口变化时统一调整。
struct YouTubeConfig {
    var apiBase = "https://api.apify.com/v2"
    var actorID = "lurkapi~youtube-to-mp3-audio-downloader"
    var audioFormat = "mp3"
    /// 320k 是 actor 的最高档，比公司自建服务那条链路的 192k 高一档。
    var audioBitrate = "320k"
    /// ⚠️ **必须显式指定住宅代理，不能让它自动选。**
    /// actor 的自动选择会落到数据中心代理，而 YouTube 直接封数据中心 IP ——
    /// 症状是「下载失败」，看起来像视频有问题，其实是代理选错了。
    /// 代价：慢（单首 1~3 分钟）且贵（住宅流量占账单 68%，$8/GB）。
    var proxyGroup = "RESIDENTIAL"
    var requestTimeout: TimeInterval = 60
    /// 轮询间隔。住宅代理本来就慢，打太密只是白费请求。
    var pollInterval: TimeInterval = 8
    /// 单条的最长等待。实测一首 1~3 分钟，给足余量；真超时就报失败，让用户自己决定要不要重试。
    var maxWait: TimeInterval = 1800
    /// 认哪些域名为 YouTube 链接（`MediaSource` 的来源路由读它）。
    /// `www.youtube.com` / `m.youtube.com` 被后缀规则覆盖，短链与无 cookie 域要单独列。
    var youtubeHostSuffixes = ["youtube.com", "youtu.be", "youtube-nocookie.com"]

    /// 已知会被挡、不用在代码里预判的情况（skill 实测）：直播回放、年龄限制、私享或已删除。
    /// actor 自己会报错，照着它的报错显示就行。
}

/// YouTube 取流。跟 `DouyinExtractor` 一样是 actor：一次能提交多条，
/// 网络等待互相交错，token 与轮询状态也不用额外加锁。
actor YouTubeExtractor: MediaExtracting {
    private let config: YouTubeConfig

    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 300
        return URLSession(configuration: configuration)
    }()

    init(config: YouTubeConfig = YouTubeConfig()) {
        self.config = config
    }

    // MARK: - 主流程

    func fetch(
        url: URL,
        to destination: URL,
        onStage: @Sendable @escaping (String, FetchProgress) -> Void
    ) async throws -> ExtractedMedia {
        // token 每次现读钥匙串：用户在设置里换掉之后立刻生效，不用重启 App。
        guard let token = KeychainStore.string(forKey: KeychainStore.apifyTokenKey),
              !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { throw YouTubeError.missingToken }

        guard let videoID = Self.videoID(of: url) else { throw YouTubeError.videoID }

        onStage("提交 Apify 任务", .at(0.04))
        let run = try await startRun(videoID: videoID, token: token)
        MusicDebug.log("YouTube \(videoID) → Apify run \(run.id)")

        // 这一步是黑盒：actor 在里面用住宅代理抓流、转码、传到自己的存储。
        // 没有字节级进度可报，只能报「等了多久」，所以 `fraction` 留 nil 走不确定进度条。
        onStage(Self.waitStage, FetchProgress(fraction: nil, attempt: "住宅代理较慢"))
        let waited = Date()
        try await waitForRun(run, token: token) { [config] elapsed in
            guard elapsed >= config.pollInterval else { return }
            onStage(Self.waitStage, FetchProgress(fraction: nil, attempt: "已等 \(Int(elapsed))s"))
        }
        MusicDebug.log("Apify run \(run.id) 完成，等了 \(Int(Date().timeIntervalSince(waited)))s")

        onStage("取结果", .at(0.5))
        let item = try await resultItem(run: run, videoID: videoID, token: token)
        guard let audioURL = item.audioFileURL else {
            throw YouTubeError.noAudio(item.status ?? "actor 没有给出音频地址")
        }

        onStage("下载音频", .at(0.55))
        try await download(audioURL, to: destination, token: token) { progress in
            guard let fraction = progress.fraction else {
                onStage("下载音频", progress)
                return
            }
            onStage("下载音频", FetchProgress(
                fraction: 0.55 + fraction * 0.4,
                bytesWritten: progress.bytesWritten
            ))
        }

        // actor 的结果里带缩略图；顺手取下来交给入库层写封面。
        // 取不到不影响下载成功，界面继续用来源色块占位。
        onStage("获取封面", .at(0.96))
        let artwork = await artworkData(for: item, videoID: videoID, token: token)
        if artwork == nil {
            MusicDebug.log("YouTube \(videoID) 封面获取失败，入库用占位图")
        }

        onStage("保存到手机", .at(0.98))
        return ExtractedMedia(videoID: videoID, title: item.title, artworkData: artwork)
    }

    private static let waitStage = "等 Apify 取音频"

    // MARK: - 封面

    /// 给已有资料库条目补封面：用公开的 YouTube 缩略图，不需要 token。
    /// `sddefault` 是 640×480；个别老视频没有这一档，再退 `hqdefault`。
    func artworkData(forVideoID videoID: String) async -> Data? {
        guard videoID.range(of: "^[A-Za-z0-9_-]{11}$", options: .regularExpression) != nil else {
            return nil
        }
        let candidates = [
            "https://i.ytimg.com/vi/\(videoID)/sddefault.jpg",
            "https://i.ytimg.com/vi/\(videoID)/hqdefault.jpg",
        ]
        for raw in candidates {
            guard let url = URL(string: raw) else { continue }
            if let data = try? await fetchImage(url, token: nil) { return data }
        }
        MusicDebug.log("YouTube \(videoID) 公开缩略图也没有取到")
        return nil
    }

    /// 优先 actor 给的公开缩略图；它要凭证时再带 token 取 Apify 那档。
    /// 两条都失败再退回标准的 YouTube 缩略图地址，保证老 actor 结果也能有封面。
    private func artworkData(for item: ResultItem, videoID: String, token: String) async -> Data? {
        var candidates: [(url: URL, token: String?)] = []
        if let url = item.thumbnailYoutubeURL { candidates.append((url, nil)) }
        if let url = item.thumbnailFileURL { candidates.append((url, token)) }
        if let url = URL(string: "https://i.ytimg.com/vi/\(videoID)/sddefault.jpg") {
            candidates.append((url, nil))
        }
        for candidate in candidates {
            if let data = try? await fetchImage(candidate.url, token: candidate.token) {
                return data
            }
        }
        return nil
    }

    private func fetchImage(_ url: URL, token: String?) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await session.data(for: request)
        try Self.check(response)
        guard Self.looksLikeImage(data) else {
            throw YouTubeError.downloadRejected("封面不是图片")
        }
        return data
    }

    /// 纯函数，命令行也能直接测。只认 JPEG/PNG 头，避免把 HTML 错误页当封面存下来。
    static func looksLikeImage(_ data: Data) -> Bool {
        let bytes = [UInt8](data.prefix(8))
        if bytes.count >= 3, bytes[0] == 0xFF, bytes[1] == 0xD8, bytes[2] == 0xFF { return true }
        if bytes.count >= 4, bytes[0] == 0x89, bytes[1] == 0x50, bytes[2] == 0x4E, bytes[3] == 0x47 { return true }
        return false
    }

    // MARK: - 设置页的「验证」

    /// 拿 token 打一个只读接口，填错了当场知道，不用等一次下载失败才反应过来。
    /// 返回账号名，顺带让用户确认「是我那个账号」。
    func verify(token: String) async throws -> String {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw YouTubeError.missingToken }
        let json = try await getJSON(path: "users/me", token: trimmed)
        guard let username = (json["data"] as? [String: Any])?["username"] as? String else {
            throw YouTubeError.submitFailed("接口没返回账号名")
        }
        return username
    }

    // MARK: - Apify 三步

    private struct Run {
        let id: String
        let datasetID: String?
    }

    private func startRun(videoID: String, token: String) async throws -> Run {
        let payload: [String: Any] = [
            "videoUrls": ["https://www.youtube.com/watch?v=\(videoID)"],
            // 一条链接一次 run：进度各报各的、一条失败不牵连别的。
            // 不写成整个播放列表，免得一条链接展开成一堆。
            "maxVideosPerUrl": 1,
            "audioFormat": config.audioFormat,
            "audioBitrate": config.audioBitrate,
            "embedMetadata": true,
            "proxyConfiguration": [
                "useApifyProxy": true,
                "apifyProxyGroups": [config.proxyGroup],
            ],
        ]

        let json = try await requestJSON(
            path: "acts/\(config.actorID)/runs",
            method: "POST",
            body: payload,
            token: token
        )
        guard let data = json["data"] as? [String: Any],
              let id = data["id"] as? String
        else { throw YouTubeError.submitFailed("接口没返回 run id") }
        return Run(id: id, datasetID: data["defaultDatasetId"] as? String)
    }

    /// 轮询到终态。`onTick` 每轮报一次已等秒数，界面才不会看着不动的进度条以为卡死。
    private func waitForRun(
        _ run: Run,
        token: String,
        onTick: @Sendable (TimeInterval) -> Void
    ) async throws {
        let start = Date()
        while true {
            let json = try await getJSON(path: "actor-runs/\(run.id)", token: token)
            let data = json["data"] as? [String: Any]
            let status = data?["status"] as? String ?? ""

            if !Self.isRunning(status) {
                guard status == "SUCCEEDED" else {
                    // run 级别的报错信息通常在 statusMessage 里；没有就只说状态码
                    let detail = data?["statusMessage"] as? String
                    throw YouTubeError.runFailed(
                        detail?.isEmpty == false ? "\(status)：\(detail!)" : status
                    )
                }
                MusicDebug.log("Apify run \(run.id) 状态 \(status)")
                return
            }

            let elapsed = Date().timeIntervalSince(start)
            guard elapsed < config.maxWait else {
                // 本地放弃，但**不去中止远端 run**：它可能马上就成，下次同一条还能命中 Apify 侧的结果
                throw YouTubeError.runFailed("等了 \(Int(elapsed))s 还没好，先不等了")
            }
            onTick(elapsed)

            try? await Task.sleep(for: .seconds(config.pollInterval))
            if Task.isCancelled { throw CancellationError() }
        }
    }

    /// dataset 里的一条结果。字段名来自 actor 的输出，与 skill 的脚本一致。
    struct ResultItem {
        var title: String?
        var audioFileURL: URL?
        var thumbnailFileURL: URL?
        var thumbnailYoutubeURL: URL?
        /// 失败原因：actor 的 `status` 或 `error`，都没有就是 nil。
        var status: String?

        init(json: [String: Any]) {
            title = json["title"] as? String
            audioFileURL = ResultItem.httpURL(json["audioFileUrl"] as? String)
            thumbnailFileURL = ResultItem.httpURL(json["thumbnailFileUrl"] as? String)
            thumbnailYoutubeURL = ResultItem.httpURL(json["thumbnailYoutubeUrl"] as? String)
            let status = json["status"] as? String
            let error = json["error"] as? String
            self.status = status ?? error
        }

        /// 只认 http(s) 的绝对地址。`URL(string:)` 很宽容，空白串会变成一个相对 URL，
        /// 拿到下载器里只会报一句看不懂的错——不如在这里就当没给。
        static func httpURL(_ raw: String?) -> URL? {
            guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !trimmed.isEmpty,
                  let url = URL(string: trimmed),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https"
            else { return nil }
            return url
        }
    }

    private func resultItem(run: Run, videoID: String, token: String) async throws -> ResultItem {
        guard let datasetID = run.datasetID else {
            throw YouTubeError.noAudio("run 没有 dataset")
        }
        let items = try await getItems(datasetID: datasetID, token: token)
        // 一次 run 只提交一条，但 actor 可能产出多条（比如它把短链展开了），
        // 按 videoId 精确对上，对不上再退回第一条。
        let match = items.first { ($0["videoId"] as? String) == videoID } ?? items.first
        guard let match else { throw YouTubeError.noAudio("actor 没有产出任何结果") }
        return ResultItem(json: match)
    }

    private func getItems(datasetID: String, token: String) async throws -> [[String: Any]] {
        let url = try endpoint(
            path: "datasets/\(datasetID)/items",
            query: ["clean": "true", "format": "json", "limit": "1000"],
            token: token
        )
        let (data, response) = try await session.data(from: url)
        try Self.check(response)
        guard let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw YouTubeError.noAudio("结果不是预期的列表")
        }
        return list
    }

    // MARK: - 下载 mp3

    private func download(
        _ audioURL: URL,
        to destination: URL,
        token: String,
        onProgress: @Sendable @escaping (FetchProgress) -> Void
    ) async throws {
        do {
            try await fetchFile(audioURL, to: destination, onProgress: onProgress)
        } catch let error as DownloadError where error.isUnauthorized {
            // Apify 存音频的地址可能要带 token 才让读。先按无凭证试一次，
            // 401/403 再补 `?token=` 重试 —— 顺带避免把 token 塞进每一次请求的 URL。
            MusicDebug.log("音频地址要凭证，补 token 重试")
            let signed = Self.appendingToken(to: audioURL, token: token)
            try await fetchFile(signed, to: destination, onProgress: onProgress)
        }

        let size = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int) ?? nil
        guard let size, size > 1024 else {
            try? FileManager.default.removeItem(at: destination)
            throw YouTubeError.downloadRejected("文件过小")
        }
        guard try Self.looksLikeMP3(destination) else {
            try? FileManager.default.removeItem(at: destination)
            throw YouTubeError.downloadRejected("下载内容不是有效音频")
        }
    }

    private func fetchFile(
        _ url: URL,
        to destination: URL,
        onProgress: @Sendable @escaping (FetchProgress) -> Void
    ) async throws {
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        // 走后台会话：锁屏/切后台时下载继续，且会话级 delegate 才收得到进度
        try await MediaDownloader.shared.download(request, to: destination) { written, expected in
            onProgress(FetchProgress.fromBytes(totalWritten: written, expected: expected))
        }
    }

    /// 校验 MP3 头：ID3 标签、或 MPEG 帧同步。只读前 64 字节 ——
    /// 这一步是为了挡住「把 HTML 报错页当音频存下来」。
    static func looksLikeMP3(_ url: URL) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let head = try handle.read(upToCount: 64) ?? Data()
        if head.count >= 3, Array(head.prefix(3)) == Array("ID3".utf8) { return true }
        guard head.count >= 2 else { return false }
        let bytes = [UInt8](head)
        // 帧同步字：11 个 1（0xFF 后跟 0xE0 掩码）
        return bytes[0] == 0xFF && (bytes[1] & 0xE0) == 0xE0
    }

    // MARK: - 纯函数（可命令行单测，不联网）

    /// 从各种形态的 YouTube 链接里抠出 11 位视频 ID：
    /// `youtu.be/ID`、`/shorts/ID`、`/embed/ID`、`?v=ID`。
    ///
    /// 两处容易踩的：
    /// - `v=` **不一定是第一个参数**（手机上分享出来的是
    ///   `watch?app=desktop&v=ID&list=RD…&start_radio=1`），所以前缀要收 `&v=` 不只是 `?v=`；
    /// - ID 后面要有**边界**（`(?![A-Za-z0-9_-])`）。少了它，`{11}` 会把更长的串
    ///   直接截前 11 位 —— 短了认不出是安全的，长了悄悄截断则会把两条不同的视频认成同一条，
    ///   去重那关就跟着错（少下一首，或者更糟：拿错 ID 去提交）。
    static func videoID(of url: URL) -> String? {
        videoID(in: url.absoluteString)
    }

    static func videoID(in text: String) -> String? {
        let pattern = "(?:youtu\\.be/|/shorts/|/embed/|[?&]v=)([A-Za-z0-9_-]{11})(?![A-Za-z0-9_-])"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[range])
    }

    /// `READY` / `RUNNING` 是还没跑完；其余（`SUCCEEDED` / `FAILED` / `ABORTED` / `TIMED-OUT`）都是终态。
    static func isRunning(_ status: String) -> Bool {
        status == "READY" || status == "RUNNING"
    }

    static func appendingToken(to url: URL, token: String) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        var items = components.queryItems ?? []
        items.append(URLQueryItem(name: "token", value: token))
        components.queryItems = items
        return components.url ?? url
    }

    // MARK: - HTTP

    private func endpoint(path: String, query: [String: String] = [:], token: String) throws -> URL {
        guard var components = URLComponents(string: "\(config.apiBase)/\(path)") else {
            throw YouTubeError.submitFailed("地址拼装失败")
        }
        // token 走查询串而不是 `Authorization` 头：这是 skill 里脚本用着能通的那一种，
        // 换写法得重新验一遍。代价是 URL 本身带凭证，所以**别把完整 URL 打日志**。
        components.queryItems = (components.queryItems ?? [])
            + query.map { URLQueryItem(name: $0.key, value: $0.value) }
            + [URLQueryItem(name: "token", value: token)]
        guard let url = components.url else { throw YouTubeError.submitFailed("地址拼装失败") }
        return url
    }

    private func getJSON(path: String, token: String) async throws -> [String: Any] {
        try await requestJSON(path: path, method: "GET", body: nil, token: token)
    }

    private func requestJSON(
        path: String,
        method: String,
        body: [String: Any]?,
        token: String
    ) async throws -> [String: Any] {
        var request = URLRequest(url: try endpoint(path: path, token: token))
        request.httpMethod = method
        request.timeoutInterval = config.requestTimeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let (data, response) = try await session.data(for: request)
        try Self.check(response)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw YouTubeError.submitFailed("返回不是 JSON（\(data.count) 字节）")
        }
        return json
    }

    private static func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        switch http.statusCode {
        case 200..<300:
            return
        case 401, 403:
            throw YouTubeAuthError(statusCode: http.statusCode)
        default:
            throw YouTubeError.submitFailed("HTTP \(http.statusCode)")
        }
    }
}
