// 用途：App 状态中枢。一次可提交多条链接，按可配置的并发数并行下载，逐条落库。
import Foundation

/// 一次提交的结构化结果。界面只据此显示一行结论，不自己解析文本、不做判断。
struct SubmitOutcome: Equatable {
    /// 新入队、开始下载的条数。
    var queued = 0
    /// 已经在资料库里、这次跳过的条数。
    var downloaded = 0
    /// 已经在下载中、这次跳过的条数。
    var running = 0
    /// 认不出来源的链接数（只认抖音和 YouTube）。跟「没识别到链接」分开报：
    /// 粘了一条 B站链接进来还说「没识别到链接」，会让人以为是自己没粘对。
    var unsupported = 0
    /// 下过、后来被删掉的链接。**这次没有重下** —— 重下要花钱，得用户明确点一下。
    /// 单独拎出来，界面才能给一个「重新下载」的按钮，而不是让用户自己琢磨怎么办。
    var deleted: [URL] = []

    /// 文本里是否识别到了链接（全为 0 表示没识别到）。
    var hasLink: Bool { queued + downloaded + running + deleted.count > 0 }
}

/// 一批链接**在提交之前**就能算出来的处境：给确认框提前说明白，
/// 而不是等倒计时走完、扣了钱（YouTube）才发现「这条我早就下过了」。
///
/// 和 `SubmitOutcome` 分开：那个是「提交之后」的结论，这个是「提交之前」的预告。
struct ClipboardPromptStatus: Equatable {
    /// 这批里已经在资料库里的条数。
    var downloaded = 0
    /// 这批里已经在下载中的条数。
    var running = 0
    /// 这批里「下过、后来被删掉」的条数。默认不重下 —— 重下要花钱。
    var deleted = 0
    /// 这批一共几条链接。
    var total = 0

    /// 这一下点了也不会新下任何东西（YouTube 那边就是「不用花钱」）。
    var nothingNew: Bool { total > 0 && downloaded + running + deleted == total }
    var skipped: Int { downloaded + running + deleted }
}

/// 从剪贴板里识别到的、**等用户确认**的一批链接。
/// 自动下载会让人莫名其妙多出一首歌，所以识别到之后只弹确认框，用户点了才入队。
struct ClipboardPrompt: Equatable, Identifiable {
    var id: String { urls.map(\.absoluteString).joined(separator: "\n") }
    /// 从剪贴板里抠出来的链接（已滤掉其它域名）。确认后下载的就是这些，不多不少。
    let urls: [URL]

    /// 这批里出现的来源，按第一次出现的顺序。确认框据此说清「这一下要花什么」。
    var sources: [MediaSource] {
        urls.compactMap(MediaSource.of).reduce(into: []) { result, source in
            if !result.contains(source) { result.append(source) }
        }
    }

    /// 这批里有没有按首计费的来源（YouTube 走 Apify，确认一次就是真花钱）。
    var isPaid: Bool { sources.contains { $0.isPaid } }
}

@MainActor
final class ConversionService: ObservableObject {
    static let concurrencyOptions = [1, 2, 3, 4, 6]
    private static let concurrencyKey = "conversion.maxConcurrent"

    @Published private(set) var jobs: [Job] = []

    /// 剪贴板里识别到、等用户确认的链接。非空时界面弹确认框。
    @Published private(set) var clipboardPrompt: ClipboardPrompt?

    /// 用户确认过剪贴板链接后的结论（转视频页那行提示用）。
    @Published private(set) var clipboardOutcome: SubmitOutcome?

    /// 并行下载数：用户可调并持久化，改完立刻重新调度。
    @Published var maxConcurrent: Int {
        didSet {
            UserDefaults.standard.set(maxConcurrent, forKey: Self.concurrencyKey)
            gate.limit = maxConcurrent
            pump()
        }
    }

    let library: MediaLibrary
    let player: MediaPlayer

    /// 两个来源，两条完全不同的链路：抖音在手机上自己抓，YouTube 把活外包给 Apify。
    private let douyin = DouyinExtractor()
    private let youtube = YouTubeExtractor()
    private var gate = ConcurrencyGate()
    private let history = ConversionHistoryStore()
    /// 本次启动已经尝试补过封面的条目，避免同一首在一次会话里反复打网络。
    private var artworkBackfillAttempted = Set<String>()

    /// 有没有配 Apify token。界面靠它决定「要不要提示先去设置里填一个」——
    /// 不把 token 本身发布出去，视图没有任何理由拿到那个值。
    @Published private(set) var hasApifyToken: Bool

    init() {
        // 上次被掐断的半截下载会堆在 tmp 里（实测到过 1GB+），启动先清干净
        let purged = MediaDownloader.purgeOrphanedTempFiles()
        if purged > 0 { MusicDebug.log("清理残留下载文件 \(purged) 个") }

        let library = MediaLibrary()
        let player = MediaPlayer()
        player.configure(
            files: { media in library.fileURL(for: media) },
            artwork: { media in library.artworkURL(for: media) }
        )
        self.library = library
        self.player = player
        self.hasApifyToken = KeychainStore.string(forKey: KeychainStore.apifyTokenKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false

        let stored = UserDefaults.standard.integer(forKey: Self.concurrencyKey)
        let initial = Self.concurrencyOptions.contains(stored) ? stored : 3
        // init 里赋值不会触发 didSet，所以闸门上限要显式对齐一次。
        self.maxConcurrent = initial
        self.gate.limit = initial
        restoreHistory()
        // 删除记录功能上线前删掉的条目没有 DeletedLink；能从完成态任务里补回来。
        library.backfillDeletedLinks(from: jobs)
    }

    /// 换 Apify token。存钥匙串、立刻生效，不用重启 —— 取流那边每次调用现读。
    func setApifyToken(_ token: String?) {
        let trimmed = token?.trimmingCharacters(in: .whitespacesAndNewlines)
        let changed = KeychainStore.set(trimmed, forKey: KeychainStore.apifyTokenKey)
        if !changed { MusicDebug.log("Apify token 写入钥匙串失败") }
        hasApifyToken = !(trimmed?.isEmpty ?? true)
    }

    /// 验证 token：优先验输入框里那份，没填就验已保存的 —— 两种意图都自然。
    /// 拿它打一个只读接口，填错了当场知道，不用等一次下载失败。返回账号名。
    func verifyApifyToken(_ draft: String?) async throws -> String {
        let trimmed = draft?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let token = trimmed.isEmpty
            ? (KeychainStore.string(forKey: KeychainStore.apifyTokenKey) ?? "")
            : trimmed
        return try await youtube.verify(token: token)
    }

    var activeCount: Int { jobs.filter { $0.state.isActive }.count }
    var runningCount: Int { gate.running }
    var waitingCount: Int { gate.waitingCount }
    var completedCount: Int { jobs.filter { $0.state == .ready }.count }
    var failedCount: Int { jobs.filter { $0.state == .failed }.count }

    /// 收录外部放进 Documents 的媒体文件（「文件」App 拖入、或 Mac 用 devicectl 推入）。
    /// 只登记本地文件，不联网、不下载。
    func adoptExternalMedia() async {
        // 下载器先落到最终文件名、再由 `register` 入库。若 App 在这中间被打断，
        // 下次启动时文件已经在 `Documents/Video` 里但还没有索引记录；直接当外部
        // 文件收进来，稍后自动重试完成又会登记同一文件，于是同一首歌出现两条、
        // 占位那条标题还是 UUID。所有转换任务名下的文件都不参与外部收录。
        let reserved = Set(jobs.compactMap(\.fileName))
        let adopted = await library.adoptExternalFiles(excluding: reserved)
        if adopted > 0 { MusicDebug.log("资料库收录外部文件 \(adopted) 个") }
    }

    /// 给老 YouTube 条目补封面。之前入库只读 mp3 内嵌图，而 actor 的 mp3 没有内嵌图，
    /// 所以那一批全是占位图；这里用视频 ID 去取公开缩略图。
    ///
    /// 串行补、连续失败三次就停：网络不通时不要在后台把 36 首各等一轮超时。
    func backfillArtworkIfNeeded() async {
        let missing = library.items.filter {
            $0.artworkFileName == nil
                && !artworkBackfillAttempted.contains($0.id)
                && isYouTube($0)
        }
        guard !missing.isEmpty else { return }
        MusicDebug.log("补封面：\(missing.count) 首 YouTube 缺封面")

        var consecutiveFailures = 0
        var fixed = 0
        for item in missing {
            artworkBackfillAttempted.insert(item.id)
            guard let data = await youtube.artworkData(forVideoID: item.id) else {
                consecutiveFailures += 1
                if consecutiveFailures >= 3 {
                    MusicDebug.log("补封面：连续 3 首失败，先停下")
                    break
                }
                continue
            }
            consecutiveFailures = 0
            if library.setArtwork(data, for: item.id) {
                fixed += 1
                if player.currentID == item.id { player.refreshArtwork() }
            }
        }
        if fixed > 0 { MusicDebug.log("补封面完成：\(fixed) 首") }
    }

    private func isYouTube(_ item: MediaItem) -> Bool {
        guard let raw = item.sourceURL, let url = URL(string: raw) else { return false }
        return MediaSource.of(url) == .youtube
    }

    // MARK: - 剪贴板

    /// 打开 App / 切回前台时调用：剪贴板换过内容才去读（读会弹系统授权框），
    /// 读到认得的链接也**只记下来等确认**、不自动下载。
    /// 读完就记下位置，所以「忽略」之后不会每次启动都再问一遍。
    @discardableResult
    func checkClipboard() async -> ClipboardPrompt? {
        guard ClipboardReader.hasNewContent else { return nil }
        guard let text = ClipboardReader.takeText() else { return nil }
        // 只是复制了一段无关文字就不打扰：抠不出认得的链接就静默跳过，连确认框都不弹
        let urls = LinkScanner.recognizableURLs(in: text)
        guard !urls.isEmpty else { return nil }
        let prompt = ClipboardPrompt(urls: urls)
        // 启动时 `.task` 和 scenePhase 转 active 会各调一次；内容一样就别重弹，
        // 否则确认框会被推第二次、倒计时也跟着重来一遍。
        guard prompt.id != clipboardPrompt?.id else { return clipboardPrompt }
        MusicDebug.log("剪贴板识别到 \(urls.count) 条链接（\(prompt.sources.map(\.displayName).joined(separator: "、"))），弹确认框")
        clipboardPrompt = prompt
        return prompt
    }

    /// 用户在确认框里点了「下载」。确认框已经把 prompt 交到手里，这里不再读 `clipboardPrompt`
    /// —— SwiftUI 关框时会先把它置空，读当前状态会拿到 nil、白白丢掉这次提交。
    /// 下载的就是框里列出的那些链接，口径一致。
    @discardableResult
    func confirm(_ prompt: ClipboardPrompt) async -> SubmitOutcome {
        if clipboardPrompt?.id == prompt.id { clipboardPrompt = nil }
        let outcome = await enqueue(urls: prompt.urls)
        MusicDebug.log("确认框点下载：新入队 \(outcome.queued)，已在库 \(outcome.downloaded)，进行中 \(outcome.running)")
        clipboardOutcome = outcome
        return outcome
    }

    /// 用户在确认框里点了「忽略」。
    func dismissClipboardPrompt() {
        MusicDebug.log("确认框点忽略")
        clipboardPrompt = nil
    }

    func clearClipboardOutcome() {
        clipboardOutcome = nil
    }

    /// 确认框要显示的那批链接的处境：几条已经在库里、几条正在下、一共几条。
    /// 和入队走的是**同一套去重键**，所以预告的数字和点下去之后的结论必然一致 ——
    /// 两边各算一套的话，就会出现「框上说不会重复下，点完却真的又下了一遍」。
    func status(for prompt: ClipboardPrompt) -> ClipboardPromptStatus {
        var occupied = occupiedKeys()
        var status = ClipboardPromptStatus(total: prompt.urls.count)
        var seen = Set<String>()
        for url in prompt.urls {
            let key = key(of: url)
            guard seen.insert(key).inserted else { continue }   // 同一批里重复的算一条
            switch occupied[key] {
            case .running: status.running += 1
            case .downloaded: status.downloaded += 1
            case .deleted: status.deleted += 1
            case nil:
                occupied[key] = .running                        // 同一批里后面的重复项按「正在下」算
            }
        }
        return status
    }

    /// 调试用：`D2M_YT_URL=<链接>` 时把这条链接直接入队。
    /// 手机没法从命令行点按钮，而 YouTube 这条链路要等 1~3 分钟、还真的花钱，
    /// 想验一次就只能让代码自己把整条路走完、把结论打进日志。
    /// 走的是完整真实链路（提交 → 轮询 → 下载 → 入库），不造假数据。
    ///
    /// **同一条链接连交两次**（第二次是故意的）：去重是「不会重复扣钱」的唯一保证，
    /// 光看代码说「应该不会重复」不算数，得让真机自己报出第二次被挡下来了。
    /// 想验这条就传一条**抖音**链接（不花钱）：YouTube 那种第二次真被挡住才重要、
    /// 但万一没挡住就是真扣一次钱，不适合当回归检查。
    ///
    /// 如果第一次捞回来的结果是「下过又删了」（事先往 `library-history.json` 里塞一条
    /// 对应记录就能造出这个局面），再顺手把「重新下载」那条路也走一遍 —— 那条路同样
    /// 只在用户点了按钮才走，命令行点不了按钮，只能让代码自己验。
    func submitDemoLinkIfRequested() async {
        guard let raw = ProcessInfo.processInfo.environment["D2M_YT_URL"],
              !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return }
        MusicDebug.log("演示链接入队：\(raw)")
        let first = await enqueue(from: raw)
        MusicDebug.log("演示链接第 1 次：新入队 \(first.queued)，已在库 \(first.downloaded)，正在下 \(first.running)，下过又删了 \(first.deleted.count)，不支持 \(first.unsupported)")

        let second = await enqueue(from: raw)
        MusicDebug.log("演示链接第 2 次（同一条，应全部被挡）：新入队 \(second.queued)，已在库 \(second.downloaded)，正在下 \(second.running)，下过又删了 \(second.deleted.count)，不支持 \(second.unsupported)")
        guard second.queued == 0 else {
            MusicDebug.log("去重自检：**失败**，同一条被重复提交了")
            return
        }
        MusicDebug.log("去重自检：通过，同一条没有重复提交")

        guard !first.deleted.isEmpty else { return }
        let forced = await redownload(first.deleted)
        MusicDebug.log("重下自检：要求重下 \(first.deleted.count) 条 → 新入队 \(forced.queued)"
            + (forced.queued == first.deleted.count ? "，通过" : "，**失败**（该下起来的没下）"))
    }

    // MARK: - 提交

    /// 「粘贴即自动下载」入口：界面把文本原样交进来，识别与去重都在这里判断。
    @discardableResult
    func autoSubmit(from text: String) async -> SubmitOutcome {
        await enqueue(from: text)
    }

    /// 解析文本里的链接并入队。支持一次粘多条：每行一条、或一整段里含多个链接都行。
    private func enqueue(from text: String) async -> SubmitOutcome {
        await enqueue(urls: LinkScanner.allURLs(in: text))
    }

    /// 把一批链接入队。已经在下载中、或已经下过的直接跳过，不重复下载。
    ///
    /// 去重按 `MediaSource.dedupeKey` 算，不按 URL 原串：同一个 YouTube 视频换个写法
    /// （`youtu.be/ID` ↔ `watch?v=ID&si=…`）必须算同一条，否则会重复开 run、重复扣钱。
    ///
    /// `redownloading` 是「用户明确说了要重下」（点了「重新下载」按钮）：
    /// 只多放行 `.deleted` 那一类，「正在下」和「已在库」照样挡——那两类没有重复花钱的问题。
    private func enqueue(urls: [URL], redownloading: Bool = false) async -> SubmitOutcome {
        guard !urls.isEmpty else { return SubmitOutcome() }

        var existing = occupiedKeys()
        var seenInBatch = Set<String>()
        var outcome = SubmitOutcome()

        for url in urls {
            let key = key(of: url)
            // 同一批里重复粘贴的同一条链接，静默去重
            guard seenInBatch.insert(key).inserted else { continue }

            // 认不出来源的链接直接挡在门外：以前只有抖音，任何 https 都会进队列、然后下失败；
            // 现在来源多了，认不出来就是「不支持」，跟没识别到一样对待，但单独计数好说实话。
            guard let source = MediaSource.of(url) else {
                outcome.unsupported += 1
                continue
            }

            // 三种「已经有了」分开报：用户需要知道是「别急，正在下」、「已经有了」，
            // 还是「你以前下过、后来删了」——最后一种要给他一个决定的机会。
            switch existing[key] {
            case .running:
                outcome.running += 1
                continue
            case .downloaded:
                outcome.downloaded += 1
                continue
            case .deleted where !redownloading:
                // 默认不重下：YouTube 一条就是一钱，不该因为「又贴了一次」就悄悄再花一次。
                outcome.deleted.append(url)
                continue
            case .deleted, nil:
                break   // 该下：库里没有，或者是用户明确要求重下
            }
            // 同一批里的后来者按「正在下载」算，跟下一批再贴这条链接的说法一致
            existing[key] = .running

            var job = Job(id: UUID().uuidString, source: source, sourceURL: url.absoluteString)
            job.fileName = "\(job.id).\(source.fileExtension)"
            jobs.insert(job, at: 0)
            gate.enqueue(job.id)
            outcome.queued += 1
        }

        persistJobs()
        pump()
        return outcome
    }

    /// 用户点了「重新下载」：把刚才因为「下过又删了」被挡下的链接真正下起来。
    /// 会重新问一次默认的那些规矩（正在下、已在库的照样挡），只是不再把 `.deleted` 当障碍。
    @discardableResult
    func redownload(_ urls: [URL]) async -> SubmitOutcome {
        MusicDebug.log("用户要求重下 \(urls.count) 条（下过又删了的那批）")
        let outcome = await enqueue(urls: urls, redownloading: true)
        MusicDebug.log("重下结果：新入队 \(outcome.queued)，已在库 \(outcome.downloaded)，正在下 \(outcome.running)，不支持 \(outcome.unsupported)")
        return outcome
    }

    private enum ExistingState { case running, downloaded, deleted }

    /// 当前已经被占用的去重键 → 状态。队列（正在跑的）、资料库（下过的）、
    /// 「下过又删了」的记录，三处都算。
    /// 顺序就是优先级：**正在下 > 已在库 > 下过又删了** —— 同一键多处都占着时，
    /// 报用户更需要的那个说法（「别急」比「你以前删过」有用；「库里就有」比「你删过」有用）。
    private func occupiedKeys() -> [String: ExistingState] {
        var states: [String: ExistingState] = [:]
        for link in library.deletedLinks {
            guard let url = URL(string: link.sourceURL) else { continue }
            states[key(of: url)] = .deleted
        }
        for item in library.items {
            guard let raw = item.sourceURL, let url = URL(string: raw) else { continue }
            states[key(of: url)] = .downloaded
        }
        for job in jobs where job.state.isActive {
            guard let url = URL(string: job.sourceURL) else { continue }
            states[key(of: url)] = .running
        }
        return states
    }

    /// 一条链接的去重键。认不出来源的用原串兜底 —— 兜底成空串的话，
    /// 所有不认识的链接会共用一个键、被当成同一条。
    private func key(of url: URL) -> String {
        MediaSource.of(url)?.dedupeKey(for: url) ?? "raw:" + url.absoluteString
    }

    func remove(jobID: String) {
        gate.cancel(jobID)
        jobs.removeAll { $0.id == jobID }
        persistJobs()
    }

    /// 只清成功记录。失败记录留着 —— 它是一句话原因，用户可能还要看或重试。
    func clearCompleted() {
        jobs.removeAll { $0.state == .ready }
        persistJobs()
    }

    /// 只清失败记录。和「清除已完成」分开，避免用户点一个按钮却顺手丢掉失败原因。
    func clearFailed() {
        jobs.removeAll { $0.state == .failed }
        persistJobs()
    }

    /// 原地重试一条失败任务：不另生成记录，也不绕过并发闸门。
    func retry(jobID: String) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }),
              jobs[index].state == .failed else { return }
        jobs[index].state = .queued
        jobs[index].stage = "排队中"
        jobs[index].progress = 0
        jobs[index].progressUnknown = false
        jobs[index].downloadedBytes = 0
        jobs[index].attempt = nil
        jobs[index].error = nil
        gate.enqueue(jobID)
        persistJobs()
        pump()
    }

    /// 从资料库点某一首：以整库为队列，从这首开始播。
    /// 不自动展开全屏播放页——保持列表可见，只在底部出现迷你播放条；
    /// 想看大封面/视频画面时再点迷你条展开（和音乐 App 的手感一致）。
    func play(_ item: MediaItem) {
        let items = library.items
        let index = items.firstIndex { $0.id == item.id } ?? 0
        player.play(items: items, startIndex: index)
    }

    // MARK: - 并发调度

    private func pump() {
        for jobID in gate.takeStartable() {
            guard let index = jobs.firstIndex(where: { $0.id == jobID }), jobs[index].state == .queued else {
                gate.finish()
                continue
            }
            Task { [weak self] in
                guard let self else { return }
                await self.process(jobID)
                self.gate.finish()
                self.pump()
            }
        }
    }

    private func process(_ jobID: String) async {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        guard let url = URL(string: jobs[index].sourceURL) else {
            update(jobID) { job in
                job.state = .failed
                job.stage = "失败"
                job.error = "任务数据不完整，请重新粘贴链接"
            }
            persistJobs()
            return
        }
        let fileName = jobs[index].fileName ?? "\(jobID).\(jobs[index].source.fileExtension)"
        let source = jobs[index].source

        if jobs[index].fileName == nil {
            update(jobID) { $0.fileName = fileName }
        }

        update(jobID) { job in
            job.state = .running
            job.stage = "解析链接"
            job.progress = 0.02
            job.progressUnknown = false
            job.downloadedBytes = 0
            job.attempt = nil
        }
        persistJobs()

        let destination = library.destination(for: jobID, source: source)
        do {
            let result = try await extractor(for: source).fetch(url: url, to: destination) { [weak self] stage, progress in
                Task { @MainActor in
                    self?.update(jobID) { job in
                        job.stage = stage
                        job.attempt = progress.attempt
                        if let fraction = progress.fraction {
                            job.progress = fraction
                            job.progressUnknown = false
                        } else {
                            job.progressUnknown = true
                        }
                        if progress.bytesWritten > 0 {
                            job.downloadedBytes = progress.bytesWritten
                        }
                    }
                }
            }

            if library.contains(videoID: result.videoID) {
                try? FileManager.default.removeItem(at: destination)
            } else {
                await library.register(
                    videoID: result.videoID,
                    title: result.title,
                    fileName: fileName,
                    sourceURL: url.absoluteString,
                    artworkData: result.artworkData
                )
            }

            let item = library.items.first { $0.id == result.videoID }
            update(jobID) { job in
                job.state = .ready
                job.stage = "已保存到手机"
                job.progress = 1
                job.progressUnknown = false
                job.attempt = nil
                job.title = result.title
                job.videoID = result.videoID
                job.sizeBytes = item?.sizeBytes
                job.durationSec = item?.durationSec
                job.error = nil
            }
            persistJobs()
        } catch {
            try? FileManager.default.removeItem(at: destination)
            let message = userFacingMessage(for: error)
            MusicDebug.log("任务失败：\(message)")
            update(jobID) { job in
                job.state = .failed
                job.stage = "失败"
                job.attempt = nil
                job.error = message
            }
            persistJobs()
        }
    }

    private func restoreHistory() {
        let loaded = history.load()
        guard !loaded.isEmpty else { return }
        let autoRetryIDs = ConversionHistoryStore.interruptedJobsToAutoRetry(loaded)
        let autoRetrySet = Set(autoRetryIDs)
        var restored = ConversionHistoryStore.restoredForLaunch(loaded)
        for index in restored.indices where autoRetrySet.contains(restored[index].id) {
            // 先落标记再启动任务：即使这次自动重试又被系统掐断，下次启动也不会再自动重跑。
            restored[index].autoRetried = true
        }
        jobs = restored
        if restored != loaded { history.save(restored) }
        MusicDebug.log("恢复转换记录 \(restored.count) 条（其中可重试失败 \(restored.filter { $0.state == .failed }.count) 条）")
        guard !autoRetryIDs.isEmpty else { return }
        MusicDebug.log("自动重试上次中断的任务 \(autoRetryIDs.count) 条")
        for jobID in autoRetryIDs {
            retry(jobID: jobID)
        }
    }

    private func persistJobs() {
        history.save(jobs)
    }

    /// 系统错误默认是英文（真机上常见的 `The request timed out.`），
    /// 页面只该给用户一句能行动的中文原因；原始 code 留给日志。
    private func userFacingMessage(for error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut: return "请求超时，请重试"
            case .networkConnectionLost: return "网络连接中断，请重试"
            case .notConnectedToInternet: return "没有网络连接，请检查后重试"
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                return "网络连不上，请检查后重试"
            case .cancelled: return "已取消"
            default: return "网络错误（\(urlError.code.rawValue)），请重试"
            }
        }
        if let localized = error as? LocalizedError,
           let message = localized.errorDescription,
           !message.isEmpty {
            return message
        }
        return error.localizedDescription
    }

    /// 按来源挑取流实现。新增来源时只在这里加一个 case。
    private func extractor(for source: MediaSource) -> any MediaExtracting {
        switch source {
        case .douyin: return douyin
        case .youtube: return youtube
        }
    }

    private func update(_ jobID: String, _ mutate: (inout Job) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        mutate(&jobs[index])
    }
}
