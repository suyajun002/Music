// 用途：本地媒体库（音乐 App 的「资料库」）。视频存沙盒，封面抽首帧，索引落 JSON 以便离线展示。
import AVFoundation
import Foundation
import UIKit

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

    func artworkURL(for item: MediaItem) -> URL? {
        guard let name = item.artworkFileName else { return nil }
        let url = directory.appendingPathComponent(name)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    func destination(for jobID: String) -> URL {
        directory.appendingPathComponent("\(jobID).mp4")
    }

    func contains(videoID: String) -> Bool {
        items.contains { $0.id == videoID }
    }

    /// 这条来源链接是否已经下载入库（「粘贴即下载」用它跳过重复）。
    func contains(sourceURL: String) -> Bool {
        items.contains { $0.sourceURL == sourceURL }
    }

    /// 入库：按类型取封面（视频抽首帧、音频读内嵌图），读时长，写索引。
    /// 标题优先用显式传入的（抖音取流结果），其次文件自身元数据，最后退回文件名。
    func register(videoID: String, title: String?, fileName: String, sourceURL: String?) async {
        if contains(videoID: videoID) { return }
        let url = directory.appendingPathComponent(fileName)
        let artworkName = await Self.makeArtwork(from: url, directory: directory, id: videoID)
        let size = (try? fileManager.attributesOfItem(atPath: url.path))?[.size] as? Int

        let item = MediaItem(
            id: videoID,
            title: await Self.resolvedTitle(explicit: title, fileName: fileName, url: url),
            fileName: fileName,
            artworkFileName: artworkName,
            sizeBytes: size,
            durationSec: await Self.duration(of: url),
            savedAt: Date(),
            sourceURL: sourceURL
        )
        items.insert(item, at: 0)
        persist()
    }

    // MARK: - 外部文件收录

    /// 把 Documents/Video 下还没入库的媒体文件补进资料库。
    /// 「文件」App 拖进来的、或由 Mac 用 devicectl 推进来的 MP3/MP4 都靠这一步出现在列表里。
    @discardableResult
    func adoptExternalFiles() async -> Int {
        let known = Set(items.map(\.fileName))
        let files = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let pending = files
            .filter { MediaKind.isSupported(fileName: $0.lastPathComponent) }
            .filter { !known.contains($0.lastPathComponent) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for url in pending {
            let name = url.lastPathComponent
            await register(videoID: uniqueID(for: name), title: nil, fileName: name, sourceURL: nil)
        }
        return pending.count
    }

    /// 入库 id 兼作封面文件名，这里统一净化并保证唯一（文件名本身可以带任意字符）。
    private func uniqueID(for fileName: String) -> String {
        let stem = (fileName as NSString).deletingPathExtension
        let cleaned = stem
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ":", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let base = cleaned.isEmpty ? UUID().uuidString : String(cleaned.prefix(60))
        var candidate = base
        var suffix = 2
        while items.contains(where: { $0.id == candidate }) {
            candidate = "\(base) \(suffix)"
            suffix += 1
        }
        return candidate
    }

    func delete(_ item: MediaItem) {
        try? fileManager.removeItem(at: fileURL(for: item))
        if let artwork = artworkURL(for: item) {
            try? fileManager.removeItem(at: artwork)
        }
        items.removeAll { $0.id == item.id }
        persist()
    }

    func totalBytes() -> Int { items.compactMap(\.sizeBytes).reduce(0, +) }

    // MARK: - 元数据

    private static func duration(of url: URL) async -> Double? {
        let asset = AVURLAsset(url: url)
        guard
            let duration = try? await asset.load(.duration),
            duration.seconds.isFinite,
            duration.seconds > 0
        else { return nil }
        return duration.seconds
    }

    /// 入库用的标题：解析一层之后，分段文件还要去掉 ID3 里带的段号后缀
    /// （`<标题> (P1/4)`），段号交给副标题，标题里不重复出现。
    private static func resolvedTitle(explicit: String?, fileName: String, url: URL) async -> String {
        let title = await resolveTitle(explicit: explicit, url: url)
        guard Segments.parse(fileName) != nil else { return title }
        return Segments.stripPartSuffix(from: title)
    }

    /// 标题优先级：显式标题 → 文件内嵌元数据标题 → 文件名（去扩展名）。
    private static func resolveTitle(explicit: String?, url: URL) async -> String {
        if let explicit, !explicit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return explicit
        }
        if let embedded = await metadataTitle(of: url), !embedded.isEmpty {
            return embedded
        }
        let stem = url.deletingPathExtension().lastPathComponent
        return stem.isEmpty ? "未命名音频" : stem
    }

    private static func metadataTitle(of url: URL) async -> String? {
        let asset = AVURLAsset(url: url)
        guard
            let metadata = try? await asset.load(.commonMetadata),
            let item = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .commonIdentifierTitle).first,
            let value = try? await item.load(.stringValue)
        else { return nil }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 音频的内嵌专辑图（转码时写进去的 ID3 封面）。
    private static func embeddedArtwork(of url: URL) async -> CGImage? {
        let asset = AVURLAsset(url: url)
        guard
            let metadata = try? await asset.load(.commonMetadata),
            let item = AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .commonIdentifierArtwork).first,
            let data = try? await item.load(.dataValue),
            let image = UIImage(data: data)
        else { return nil }
        return image.cgImage
    }

    /// 封面（音乐 App 的专辑图位置）：视频抽第 1 秒画面，音频读内嵌专辑图。
    /// 都没有则返回 nil，界面用占位图，不阻塞入库。
    private static func makeArtwork(from videoURL: URL, directory: URL, id: String) async -> String? {
        let cgImage: CGImage?
        if MediaKind(fileName: videoURL.lastPathComponent).hasPicture {
            let asset = AVURLAsset(url: videoURL)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 900, height: 900)
            cgImage = (try? await generator.image(at: CMTime(seconds: 1, preferredTimescale: 600)).image) ?? nil
        } else {
            cgImage = await embeddedArtwork(of: videoURL)
        }

        guard let cgImage, let data = UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.9) else {
            return nil
        }

        let name = "\(id.replacingOccurrences(of: "/", with: "_")).jpg"
        try? data.write(to: directory.appendingPathComponent(name), options: .atomic)
        return name
    }

    private func load() {
        guard
            let data = try? Data(contentsOf: indexURL),
            let decoded = try? JSONDecoder().decode([MediaItem].self, from: data)
        else { return }
        items = decoded.filter { fileManager.fileExists(atPath: fileURL(for: $0).path) }
        migrateTitles()
    }

    /// 老版本取流时标题没解转义（会显示成「开车\u002F健身」），这里就地修一次并回写，
    /// 省得为了一个标题去重下整条视频。修不动就原样保留。
    /// 另外把分段条目标题里 ID3 遗留的「(P1/4)」去掉 —— 现在段号由副标题负责，标题里重复。
    private func migrateTitles() {
        var changed = false
        for index in items.indices {
            var title = JSONEscapes.decode(items[index].title)
            if items[index].segmentKey != nil {
                title = Segments.stripPartSuffix(from: title)
            }
            guard title != items[index].title else { continue }
            items[index].title = title
            changed = true
        }
        if changed { persist() }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }
}
