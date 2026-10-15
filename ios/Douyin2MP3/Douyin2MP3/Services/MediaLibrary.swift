// 用途：手机本地媒体库。下载好的视频存沙盒，索引落 JSON，离线可播。
import AVFoundation
import Foundation

@MainActor
final class MediaLibrary: ObservableObject {
    @Published private(set) var items: [MediaItem] = []

    private let fileManager = FileManager.default
    private let directory: URL
    private let indexURL: URL

    init() {
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        directory = documents.appendingPathComponent("Video", isDirectory: true)
        indexURL = documents.appendingPathComponent("library.json")
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        load()
    }

    func fileURL(for item: MediaItem) -> URL {
        directory.appendingPathComponent(item.fileName)
    }

    func destination(for videoID: String) -> URL {
        directory.appendingPathComponent("\(videoID).mp4")
    }

    func contains(videoID: String) -> Bool {
        items.contains { $0.id == videoID }
    }

    /// 下载完成后登记入库；重复登记直接复用已有条目。
    func register(videoID: String, title: String?, fileName: String) async {
        if contains(videoID: videoID) { return }
        let url = directory.appendingPathComponent(fileName)
        let size = (try? fileManager.attributesOfItem(atPath: url.path))?[.size] as? Int
        let item = MediaItem(
            id: videoID,
            title: title?.isEmpty == false ? title! : "抖音视频",
            fileName: fileName,
            sizeBytes: size,
            durationSec: await Self.duration(of: url),
            savedAt: Date()
        )
        items.insert(item, at: 0)
        persist()
    }

    func delete(_ item: MediaItem) {
        try? fileManager.removeItem(at: fileURL(for: item))
        items.removeAll { $0.id == item.id }
        persist()
    }

    func totalBytes() -> Int {
        items.compactMap(\.sizeBytes).reduce(0, +)
    }

    /// 用播放器能力读取时长；失败则留空，列表显示 --:--。
    private static func duration(of url: URL) async -> Double? {
        let asset = AVURLAsset(url: url)
        guard
            let duration = try? await asset.load(.duration),
            duration.seconds.isFinite,
            duration.seconds > 0
        else { return nil }
        return duration.seconds
    }

    private func load() {
        guard
            let data = try? Data(contentsOf: indexURL),
            let decoded = try? JSONDecoder().decode([MediaItem].self, from: data)
        else { return }
        items = decoded.filter { fileManager.fileExists(atPath: fileURL(for: $0).path) }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }
}
