// 用途：App 状态中枢。把「提交链接 → 取流 → 存到手机」串成一条顺序执行的确定性流程。
import Foundation

@MainActor
final class ConversionService: ObservableObject {
    @Published private(set) var jobs: [Job] = []
    @Published var lastError: String?
    @Published var isSubmitting = false

    let library = MediaLibrary()
    let player = MediaPlayer()

    private let extractor = DouyinExtractor()
    private var isProcessing = false

    var activeCount: Int { jobs.filter { $0.state.isActive }.count }

    func submit(text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            lastError = "先粘贴抖音分享文本或链接"
            return
        }

        isSubmitting = true
        lastError = nil
        defer { isSubmitting = false }

        var job = Job(id: UUID().uuidString, sourceText: trimmed)
        job.fileName = "\(job.id).mp4"
        jobs.insert(job, at: 0)

        await process(job.id)
    }

    func remove(jobID: String) {
        jobs.removeAll { $0.id == jobID }
    }

    func play(_ item: MediaItem) {
        player.play(item: item, url: library.fileURL(for: item))
        player.isExpanded = true
    }

    // MARK: - 流水线

    /// 逐个处理：抖音对并发请求敏感，顺序执行最稳。
    private func process(_ jobID: String) async {
        while isProcessing {
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        isProcessing = true
        defer { isProcessing = false }

        guard let index = jobs.firstIndex(where: { $0.id == jobID }), let fileName = jobs[index].fileName else { return }
        update(jobID) { job in
            job.state = .running
            job.stage = "解析链接"
            job.progress = 0.02
        }

        let destination = library.destination(for: jobID)
        do {
            let result = try await extractor.fetchVideo(
                shareText: jobs[index].sourceText,
                to: destination
            ) { [weak self] stage, progress in
                Task { @MainActor in
                    self?.update(jobID) { job in
                        job.stage = stage
                        job.progress = progress
                    }
                }
            }

            if library.contains(videoID: result.videoID) {
                // 同一个作品已存在：丢掉本次重复文件，指向已有条目
                try? FileManager.default.removeItem(at: destination)
            } else {
                await library.register(videoID: result.videoID, title: result.title, fileName: fileName)
            }

            let item = library.items.first { $0.id == result.videoID }
            update(jobID) { job in
                job.state = .ready
                job.stage = "已保存到手机"
                job.progress = 1
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
