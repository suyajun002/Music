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

    /// 入库：抽首帧做封面，读时长，写索引。
    func register(videoID: String, title: String?, fileName: String) async {
        if contains(videoID: videoID) { return }
        let url = directory.appendingPathComponent(fileName)
        let artworkName = await Self.makeArtwork(from: url, directory: directory, id: videoID)
        let size = (try? fileManager.attributesOfItem(atPath: url.path))?[.size] as? Int

        let item = MediaItem(
            id: videoID,
            title: title?.isEmpty == false ? title! : "抖音视频",
            fileName: fileName,
            artworkFileName: artworkName,
            sizeBytes: size,
            durationSec: await Self.duration(of: url),
            savedAt: Date()
        )
        items.insert(item, at: 0)
        persist()
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

    /// 抽视频首帧当封面（音乐 App 的专辑图位置）。失败返回 nil，界面用占位图。
    private static func makeArtwork(from videoURL: URL, directory: URL, id: String) async -> String? {
        let asset = AVURLAsset(url: videoURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 900, height: 900)

        guard
            let cgImage = try? await generator.image(at: CMTime(seconds: 1, preferredTimescale: 600)).image,
            let data = UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.9)
        else { return nil }

        let name = "\(id).jpg"
        try? data.write(to: directory.appendingPathComponent(name), options: .atomic)
        return name
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
