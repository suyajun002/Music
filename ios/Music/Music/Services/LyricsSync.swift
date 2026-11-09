// 用途：把「歌词同步」前移到下载/入库这一步 —— 识别歌手+歌名，抓一次，按曲落盘。
//
// 为什么不在播放时现抓：
//   - 播放页要等网络，第一句经常是空的；
//   - 下载时已经知道时长，正好可以挑「和这个音频同一版本」的歌词；
//   - 落到 Documents 旁边的持久目录，断网、清缓存之后仍然在。
// 播放页仍然会兜底现抓一次（老条目、之前失败过的），抓到后同样落盘。
// 版本对不齐时由播放页按「音频时长 - 歌词版本时长」自动整条平移，不提供手动微调。
import Foundation

enum LyricsSync {
    private static let folderName = "Lyrics"

    /// 每首歌的歌词和「当初是按什么识别出来的」放一起，
    /// 之后想核对「这歌词哪来的」不用再猜。
    private struct Stored: Codable {
        let lyrics: Lyrics
        let artist: String?
        let track: String
        let duration: Double
        let savedAt: Date
    }

    /// 读本地歌词。`duration` 用来做完整性校验：歌词最后一行明显超出音频长度时，
    /// 说明当初存的是另一版（加长版 / 现场版）的时间轴，宁可丢掉重取。
    static func load(id: String, duration: Double) -> Lyrics? {
        guard let url = fileURL(for: id),
              let data = try? Data(contentsOf: url),
              let stored = try? JSONDecoder().decode(Stored.self, from: data)
        else { return nil }
        let lyrics = stored.lyrics
        if duration > 0, lyrics.isSynced, let last = lyrics.lines.last,
           last.time > duration + 10 {
            // 刚重取过还是超长，说明这一版 LRC 本身就带长尾（LRCLIB 元数据缺时长时常见）。
            // 先用着，别再每次播放都打一次接口；一天后批量修复再试。
            if let modified = modifiedAt(id: id),
               Date().timeIntervalSince(modified) < 24 * 3600 {
                return lyrics
            }
            MusicDebug.log("歌词：本地时间轴比音频长 \(Int(last.time - duration))s，重新匹配")
            return nil
        }
        return lyrics
    }

    static func save(_ lyrics: Lyrics, id: String, artist: String?, track: String, duration: Double) {
        guard let url = fileURL(for: id) else { return }
        let stored = Stored(lyrics: lyrics, artist: artist, track: track, duration: duration, savedAt: Date())
        guard let data = try? JSONEncoder().encode(stored) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// 播放页和老条目用：本地有就直接给，没有就现抓并落盘。
    static func lyrics(id: String?, title: String, duration: Double, force: Bool = false) async -> Lyrics? {
        if !force, let id, let local = load(id: id, duration: duration) {
            MusicDebug.log("歌词：本地已有《\(title)》 synced=\(local.isSynced)，不再联网")
            return local
        }
        guard !title.isEmpty else { return nil }

        let identity = LyricsProvider.identify(title)
        // 已经识别出歌手时，用「歌手 - 歌名」去搜：比拿整条带「官方 MV」的标题搜更准，
        // 也能让 LRCLIB 的候选排序更靠前。
        let searchTitle = identity.artist.map { "\($0) - \(identity.track)" } ?? title
        MusicDebug.log("歌词：识别为《\(identity.track)》/ \(identity.artist ?? "未知歌手")")
        guard let lyrics = await LyricsProvider.fetch(title: searchTitle, duration: duration) else {
            return nil
        }
        if let id {
            save(lyrics, id: id, artist: identity.artist, track: identity.track, duration: duration)
            MusicDebug.log("歌词：已落盘《\(identity.track)》 synced=\(lyrics.isSynced)")
        }
        return lyrics
    }

    /// 这份歌词对应的音频长度和本机音频差多少秒（没有版本信息就返回 nil）。
    static func versionGap(_ lyrics: Lyrics, audioDuration: Double) -> Double? {
        guard lyrics.isSynced,
              let source = lyrics.sourceDuration, source > 0,
              audioDuration > 0 else { return nil }
        return abs(source - audioDuration)
    }

    /// 统一修复已有歌曲：缺歌词的补，纯文本的升级，时间轴明显错的重取。
    ///
    /// 已经同步且版本差 ≤8s 的直接跳过，不重复联网。
    /// 24 小时内只跑一次；如果这一轮大半都失败（LRCLIB 503 之类），不记账，下次启动再试。
    static func repairAll(items: [MediaItem]) async {
        let key = "lyrics.repair.lastRun.v7"
        let defaults = UserDefaults.standard
        let lastRun = defaults.object(forKey: key) as? Date
        if let lastRun, Date().timeIntervalSince(lastRun) < 24 * 3600 { return }
        // 第一次跑新版本全量复核：跳过「文件很新」的节流，让上一轮选错的歌有机会重取。
        let fullPass = lastRun == nil

        var attempted = 0
        var fixed = 0
        var failed = 0
        for item in items {
            let audio = item.durationSec ?? 0
            if let local = load(id: item.id, duration: audio), local.isSynced,
               local.sourceDuration != nil {
                let gap = versionGap(local, audioDuration: audio) ?? 0
                // 8s 以内算同版本；再大是 MV/现场版差异，播放时会按版本时长差自动平移。
                if gap <= 20 { continue }
                // 超过 20s 基本是选错歌，重取；但一天最多一次，避免一直打接口。
                if !fullPass, let modified = modifiedAt(id: item.id),
                   Date().timeIntervalSince(modified) < 24 * 3600 { continue }
            }
            attempted += 1
            if let lyrics = await lyrics(id: item.id, title: item.title, duration: audio, force: true) {
                fixed += 1
                if let gap = versionGap(lyrics, audioDuration: audio), gap > 8 {
                    MusicDebug.log("歌词：版本差 \(Int(gap))s《\(item.title.prefix(20))》，播放时自动平移")
                }
            } else {
                failed += 1
                MusicDebug.log("歌词：没找到《\(item.title.prefix(24))》，下次启动再试")
            }
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        if attempted > 0 {
            MusicDebug.log("歌词：批量修复结束，检查 \(attempted) 首，成功 \(fixed) 首，失败 \(failed) 首")
        }
        // 只有「这一轮没有失败」才记账。失败的多半是 503/超时，不是真的没歌词；
        // 记账了就要等 24 小时，反而把可修的歌拖住。下一轮会跳过已经修好的，成本有界。
        if attempted == 0 || failed == 0 {
            defaults.set(Date(), forKey: key)
        }
    }

    /// 下载入库后调用：不阻塞「已保存」，在后台把歌词备好。
    static func prepare(for item: MediaItem) async {
        guard load(id: item.id, duration: item.durationSec ?? 0) == nil else { return }
        guard await lyrics(id: item.id, title: item.title, duration: item.durationSec ?? 0) != nil else {
            MusicDebug.log("歌词：入库时没找到《\(item.title)》，播放时会再试一次")
            return
        }
        MusicDebug.log("歌词：入库时已同步《\(item.title)》")
    }

    private static func modifiedAt(id: String) -> Date? {
        guard let url = fileURL(for: id) else { return nil }
        return (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    private static var folderURL: URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let folder = base.appendingPathComponent(folderName, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private static func fileURL(for id: String) -> URL? {
        // id 可能带 `/` 之类不适合做文件名的字符，用 URL 安全的 base64 兜一层。
        guard !id.isEmpty else { return nil }
        let name = Data(id.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
        return folderURL?.appendingPathComponent("\(name).json")
    }
}
