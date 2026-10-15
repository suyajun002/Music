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

    /// 文本里是否识别到了链接（全为 0 表示没识别到）。
    var hasLink: Bool { queued + downloaded + running > 0 }
}

@MainActor
final class ConversionService: ObservableObject {
    static let concurrencyOptions = [1, 2, 3, 4, 6]
    private static let concurrencyKey = "conversion.maxConcurrent"

    @Published private(set) var jobs: [Job] = []

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

    private let extractor = DouyinExtractor()
    private var gate = ConcurrencyGate()

    init() {
        // 上次被掐断的半截下载会堆在 tmp 里（实测到过 1GB+），启动先清干净
        let purged = MediaDownloader.purgeOrphanedTempFiles()
        if purged > 0 { DouyinDebug.log("清理残留下载文件 \(purged) 个") }

        let library = MediaLibrary()
        let player = MediaPlayer()
        player.configure(
            files: { media in library.fileURL(for: media) },
            artwork: { media in library.artworkURL(for: media) }
        )
        self.library = library
        self.player = player

        let stored = UserDefaults.standard.integer(forKey: Self.concurrencyKey)
        let initial = Self.concurrencyOptions.contains(stored) ? stored : 3
        // init 里赋值不会触发 didSet，所以闸门上限要显式对齐一次。
        self.maxConcurrent = initial
        self.gate.limit = initial
    }

    var activeCount: Int { jobs.filter { $0.state.isActive }.count }
    var runningCount: Int { gate.running }
    var waitingCount: Int { gate.waitingCount }

    // MARK: - 提交

    /// 「粘贴即自动下载」入口：界面把文本原样交进来，识别与去重都在这里判断。
    @discardableResult
    func autoSubmit(from text: String) async -> SubmitOutcome {
        await enqueue(from: text)
    }

    /// 解析文本里的链接并入队。支持一次粘多条：每行一条、或一整段里含多个链接都行。
    /// 已经在下载中、或已经下过的链接直接跳过，不重复下载。
    private func enqueue(from text: String) async -> SubmitOutcome {
        let urls = DouyinExtractor.allURLs(in: text)
        guard !urls.isEmpty else { return SubmitOutcome() }

        // 已在处理中的同一链接不再重复提交，避免并发下重复下载
        var inFlight = Set(jobs.filter { $0.state.isActive }.map(\.sourceURL))
        var seenInBatch = Set<String>()
        var outcome = SubmitOutcome()

        for url in urls {
            let key = url.absoluteString
            // 同一批里重复粘贴的同一条链接，静默去重
            guard seenInBatch.insert(key).inserted else { continue }

            if inFlight.contains(key) {
                outcome.running += 1
                continue
            }
            // 已经下载并入库的不再重复下载
            if library.contains(sourceURL: key) {
                outcome.downloaded += 1
                continue
            }
            inFlight.insert(key)

            var job = Job(id: UUID().uuidString, sourceURL: key)
            job.fileName = "\(job.id).mp4"
            jobs.insert(job, at: 0)
            gate.enqueue(job.id)
            outcome.queued += 1
        }

        pump()
        return outcome
    }

    func remove(jobID: String) {
        gate.cancel(jobID)
        jobs.removeAll { $0.id == jobID }
    }

    func clearFinished() {
        jobs.removeAll { !$0.state.isActive }
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
        guard
            let index = jobs.firstIndex(where: { $0.id == jobID }),
            let fileName = jobs[index].fileName,
            let url = URL(string: jobs[index].sourceURL)
        else { return }

        update(jobID) { job in
            job.state = .running
            job.stage = "解析链接"
            job.progress = 0.02
            job.progressUnknown = false
            job.downloadedBytes = 0
            job.attempt = nil
        }

        let destination = library.destination(for: jobID)
        do {
            let result = try await extractor.fetchVideo(url: url, to: destination) { [weak self] stage, progress in
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
                    sourceURL: url.absoluteString
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
        } catch {
            try? FileManager.default.removeItem(at: destination)
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            update(jobID) { job in
                job.state = .failed
                job.stage = "失败"
                job.attempt = nil
                job.error = message
            }
        }
    }

    private func update(_ jobID: String, _ mutate: (inout Job) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        mutate(&jobs[index])
    }
}
