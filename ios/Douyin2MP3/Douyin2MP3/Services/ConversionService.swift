// 用途：App 状态中枢。一次可提交多条链接，按可配置的并发数并行下载，逐条落库。
import Foundation

@MainActor
final class ConversionService: ObservableObject {
    static let concurrencyOptions = [1, 2, 3, 4, 6]
    private static let concurrencyKey = "conversion.maxConcurrent"

    @Published private(set) var jobs: [Job] = []
    @Published var lastError: String?
    @Published var isSubmitting = false

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

    /// 支持一次粘贴多条分享文本：每行一条、或一整段里含多个链接都行。
    func submit(text: String) async {
        let urls = DouyinExtractor.allURLs(in: text)
        guard !urls.isEmpty else {
            lastError = "没找到链接，请粘贴抖音分享文本或链接"
            return
        }

        isSubmitting = true
        lastError = nil
        defer { isSubmitting = false }

        // 已在处理中的同一链接不再重复提交，避免并发下重复下载
        var inFlight = Set(jobs.filter { $0.state.isActive }.map(\.sourceURL))
        var added = 0

        for url in urls {
            let key = url.absoluteString
            guard !inFlight.contains(key) else { continue }
            inFlight.insert(key)

            var job = Job(id: UUID().uuidString, sourceURL: key)
            job.fileName = "\(job.id).mp4"
            jobs.insert(job, at: 0)
            gate.enqueue(job.id)
            added += 1
        }

        if added == 0 {
            lastError = "这些链接已经在处理中了"
        }
        pump()
    }

    func remove(jobID: String) {
        gate.cancel(jobID)
        jobs.removeAll { $0.id == jobID }
    }

    func clearFinished() {
        jobs.removeAll { !$0.state.isActive }
    }

    /// 从资料库点某一首：以整库为队列，从这首开始播。
    func play(_ item: MediaItem) {
        let items = library.items
        let index = items.firstIndex { $0.id == item.id } ?? 0
        player.play(items: items, startIndex: index)
        player.isExpanded = true
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
        }

        let destination = library.destination(for: jobID)
        do {
            let result = try await extractor.fetchVideo(url: url, to: destination) { [weak self] stage, progress in
                Task { @MainActor in
                    self?.update(jobID) { job in
                        job.stage = stage
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
                await library.register(videoID: result.videoID, title: result.title, fileName: fileName)
            }

            let item = library.items.first { $0.id == result.videoID }
            update(jobID) { job in
                job.state = .ready
                job.stage = "已保存到手机"
                job.progress = 1
                job.progressUnknown = false
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
                job.error = message
            }
        }
    }

    private func update(_ jobID: String, _ mutate: (inout Job) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else { return }
        mutate(&jobs[index])
    }
}
