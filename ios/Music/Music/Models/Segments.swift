// 用途：解析「分段音频」的文件名（<标题>.partNN.mp3），并把同一合集的分段标成「P2/4」。
// 几段标题一模一样、被截断后根本分不清哪段是哪段，副标题口径统一放在这里，
// 列表、迷你播放条、全屏播放页都读同一份，避免三处各写一份漂移。
import Foundation

enum Segments {
    /// 与 `scripts/phonemusic` 的产物对齐：它用 `ffmpeg -f segment` 切分，段号**默认 0 起**，
    /// 所以手机里看到的是 `<标题>.part00.mp3`、`part03.mp3`……（实测确认）。
    /// 而它写进 ID3 的 `track`/`title` 是 `P1/4`…`P4/4`（1 起）。
    /// 两者差一：`parse` 出的是文件名里的原始段号，显示时要 +1，别把它当成品号。
    private static let regex = try! NSRegularExpression(pattern: #"^(.*)\.part(\d+)$"#)

    /// 文件名形如 `标题.part03.mp3` 时返回（合集前缀, 文件名里的原始段号）；整轨返回 nil。
    static func parse(_ fileName: String) -> (key: String, index: Int)? {
        let stem = (fileName as NSString).deletingPathExtension
        guard
            let match = regex.firstMatch(in: stem, range: NSRange(stem.startIndex..., in: stem)),
            match.numberOfRanges == 3,
            let keyRange = Range(match.range(at: 1), in: stem),
            let indexRange = Range(match.range(at: 2), in: stem),
            let index = Int(stem[indexRange])
        else { return nil }
        return (String(stem[keyRange]), index)
    }

    /// ID3 的 `title` 里带段号：phonemusic 写的是 `<标题> (P1/4)`。
    /// 界面副标题自己就会拼「P1/4」，标题里再留一份就是重复（实测：标题 `… #车载音乐 (P1/2)` + 副标题 `18:44 · P1/2`）。
    /// 所以分段文件入库时把标题末尾的段号去掉，段号只由副标题负责。
    static func stripPartSuffix(from title: String) -> String {
        let range = NSRange(title.startIndex..., in: title)
        guard
            let match = partSuffixRegex.firstMatch(in: title, range: range),
            let kept = Range(match.range(at: 1), in: title)
        else { return title }
        let trimmed = title[kept].trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? title : trimmed
    }

    /// 结尾允许带空白（库里真出现过 `标题 (P3/4) ` 这种带尾空格的）。
    private static let partSuffixRegex = try! NSRegularExpression(pattern: #"^(.*?)\s*\(P\d+/\d+\)\s*$"#)
}

extension MediaItem {
    /// 分段文件所属的合集前缀（用来统计同合集一共有几段）；整轨为 nil。
    var segmentKey: String? { Segments.parse(fileName)?.key }

    /// 分段文件的品号 `P1…PN`，从 1 起（= 文件名原始段号 + 1，对齐 phonemusic 写的 ID3 标签）；整轨为 nil。
    var segmentIndex: Int? { Segments.parse(fileName).map { $0.index + 1 } }
}

extension MediaLibrary {
    /// 每个合集一共有几段，按文件名前缀统计。
    /// 只数**本地已有**的分段：所以「P2/4」的含义是「这个合集在库里一共 4 段」，
    /// 而不是「源文件一共切了多少段」（那要看 phonemusic 的 state.json）。
    var partTotals: [String: Int] {
        var counts: [String: Int] = [:]
        for item in items {
            guard let key = item.segmentKey else { continue }
            counts[key, default: 0] += 1
        }
        return counts
    }

    /// 副标题：时长；分段再补一个「P2/4」，好一眼认出是哪一段。
    /// 单段（合集里只有一段）不必标，标了反而多噪音。
    func subtitle(for item: MediaItem) -> String {
        guard
            let index = item.segmentIndex,
            let key = item.segmentKey,
            let total = partTotals[key],
            total > 1
        else { return item.durationText }
        return "\(item.durationText) · P\(index)/\(total)"
    }
}