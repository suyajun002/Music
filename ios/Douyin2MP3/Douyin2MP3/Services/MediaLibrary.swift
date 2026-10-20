// 用途：本地媒体库（音乐 App 的「资料库」）。视频存沙盒，封面抽首帧，索引落 JSON 以便离线展示。
import AVFoundation
import Foundation
import UIKit

@MainActor
final class MediaLibrary: ObservableObject {
    @Published private(set) var items: [MediaItem] = []
    /// 「下过、后来被删掉」的链接。默认不再自动重下，只在提示里点名。
    @Published private(set) var deletedLinks: [DeletedLink] = []

    /// 记录条数上限。这只是提醒用的，不是账本。
    private static let maxDeletedLinks = 200

    private let fileManager = FileManager.default
    private let directory: URL
    private let indexURL: URL
    private let historyURL: URL
    /// 上次能正常读的索引留档（每次启动刷新一次），出事了手工改回去就能救回记录。
    private var backupURL: URL { indexURL.appendingPathExtension("bak") }
    /// 索引读成功了没有。见 `persist()` 的闸门：没读成功就不许把索引写成空的。
    private var indexLoadedOK = false

    init() {
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        directory = documents.appendingPathComponent("Video", isDirectory: true)
        indexURL = documents.appendingPathComponent("library.json")
        historyURL = documents.appendingPathComponent("library-history.json")
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        load()
        loadDeletedLinks()
    }

    func fileURL(for item: MediaItem) -> URL {
        directory.appendingPathComponent(item.fileName)
    }

    func artworkURL(for item: MediaItem) -> URL? {
        guard let name = item.artworkFileName else { return nil }
        let url = directory.appendingPathComponent(name)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    /// 下载落点。扩展名由来源决定（抖音 mp4 / YouTube mp3）—— 入库后是「有画面」
    /// 还是「只有封面」，只看这个名字（`MediaKind`）。
    func destination(for jobID: String, source: MediaSource) -> URL {
        directory.appendingPathComponent("\(jobID).\(source.fileExtension)")
    }

    func contains(videoID: String) -> Bool {
        items.contains { $0.id == videoID }
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
        // 又下回来了：这条链接的「下过又删了」记录就没用了，留着反而会让下次贴它被多挡一次
        forgetDeletedLinks(matching: sourceURL)
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
        // 顺带清掉这首的「跳过前奏」记录：条目都没了，留着那个秒数只会让 plist 越攒越长，
        // 而且同一 id 哪天又下回来会莫名其妙带着一个旧的起点。
        Task { @MainActor in IntroSkip.shared.forget(item.id) }
        // 删掉不等于「当没下过」：YouTube 是按首花钱的，留个记录好在下一次贴同一条链接时
        // 明确告诉用户「这条下过又删了」，由他决定要不要再花一次，而不是默默重下。
        if let raw = item.sourceURL { remember(deleted: raw, title: item.title) }
        persist()
    }

    // MARK: - 「下过又删了」的记录

    /// 只记链接和标题，落在 `Documents/library-history.json`。
    /// **和 `library.json` 分开存**：那个是 `[MediaItem]` 的数组，往里塞别的结构会改变格式，
    /// 老版本解不动 —— 而解不动就等于把去重记忆全丢了（见 `load()` 的注释）。
    private func remember(deleted sourceURL: String, title: String) {
        forgetDeletedLinks(matching: sourceURL)
        deletedLinks.insert(DeletedLink(sourceURL: sourceURL, title: title, deletedAt: Date()), at: 0)
        // 只留最近这些。这只是「提醒一下」用的，不是账本，没必要无限长。
        if deletedLinks.count > Self.maxDeletedLinks {
            deletedLinks.removeLast(deletedLinks.count - Self.maxDeletedLinks)
        }
        persistDeletedLinks()
    }

    /// 把与 `sourceURL` 指向**同一条内容**的记录去掉（认同一个视频的不同链接写法）。
    /// 指到 nil 就整条不清 —— 本地导入的文件没有链接，不该顺手清掉别的记录。
    func forgetDeletedLinks(matching sourceURL: String?) {
        guard let key = Self.dedupeKey(of: sourceURL) else { return }
        let before = deletedLinks.count
        deletedLinks.removeAll { Self.dedupeKey(of: $0.sourceURL) == key }
        if deletedLinks.count != before { persistDeletedLinks() }
    }

    private static func dedupeKey(of sourceURL: String?) -> String? {
        guard let sourceURL, let url = URL(string: sourceURL), let source = MediaSource.of(url) else { return nil }
        return source.dedupeKey(for: url)
    }

    private func loadDeletedLinks() {
        guard
            let data = try? Data(contentsOf: historyURL),
            let decoded = try? JSONDecoder().decode([DeletedLink].self, from: data)
        else { return }
        deletedLinks = decoded
    }

    private func persistDeletedLinks() {
        guard let data = try? JSONEncoder().encode(deletedLinks) else { return }
        try? data.write(to: historyURL, options: .atomic)
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

    func load() {
        // 索引不存在 = 全新安装（或刚被删过），空库是合法状态，可以随便写。
        guard fileManager.fileExists(atPath: indexURL.path) else {
            indexLoadedOK = true
            return
        }
        guard
            let data = try? Data(contentsOf: indexURL),
            let decoded = try? JSONDecoder().decode([MediaItem].self, from: data)
        else {
            // ⚠️ 解不出来（比如以后给 `MediaItem` 加了个非可选字段，旧索引解不动）时，
            // **绝不能就这么当空库继续跑**：`items` 会变成 []，之后任意一次 `persist()`
            // 就把整份索引覆盖没了。文件还躺在 `Documents/Video` 里、`adoptExternalFiles`
            // 也能把它们重新收进来，但 **`sourceURL` 是 nil —— 去重记忆全丢**，
            // 重贴同一条链接要重新下载，YouTube 那边就是重新花钱。
            // 所以先把这份索引原样留档，再由 `persist()` 的闸门决定能不能写空。
            let stamp = Int(Date().timeIntervalSince1970)
            let backup = indexURL.appendingPathExtension("corrupt-\(stamp)")
            try? fileManager.moveItem(at: indexURL, to: backup)
            DouyinDebug.log("索引解码失败，已留档 \(backup.lastPathComponent)，这次启动不写空索引")
            return
        }
        items = decoded.filter { fileManager.fileExists(atPath: fileURL(for: $0).path) }
        indexLoadedOK = true
        // 留一份「上次能正常读的索引」。4 KB 的东西，换一个手工回滚的机会：
        // 万一以后某个版本写坏了索引，把 `.bak` 改回 `library.json` 就能救回全部「下过没有」的记录。
        try? data.write(to: backupURL, options: .atomic)
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
        // 闸门：索引没读成功、而现在要写一份空的 —— 那多半是「解码失败后 items 被清空」
        // 的样子，不是用户真的把歌删光了，写下去就是抹记录。宁可这次不写（下次有内容了再写）。
        guard indexLoadedOK || !items.isEmpty else {
            DouyinDebug.log("索引没读成功，且当前为空 —— 拒绝覆盖，保住磁盘上那份记录")
            return
        }
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }
}
