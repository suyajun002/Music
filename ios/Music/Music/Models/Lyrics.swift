// 用途：歌词的数据形状和 LRC 解析。
//
// 只做两件事：把带时间轴的 LRC 变成「时间 + 一行字」，以及给播放进度算出当前行。
// 取歌词（联网、缓存、匹配）在 `LyricsProvider`；渲染在 `LyricsView`。
import Foundation

struct LyricLine: Codable, Identifiable, Equatable {
    let id: Int
    let time: TimeInterval
    let text: String
}

struct Lyrics: Codable, Equatable {
    let lines: [LyricLine]
    /// 有逐行时间轴才能跟着进度高亮；纯文本歌词只能静态展示。
    let isSynced: Bool
    /// 这份歌词自己对应的音频长度（LRCLIB 行里的 `duration`）。
    /// 和本机音频差得多，就说明拿到的是另一版（MV / 现场 / 加长版）的时间轴。
    /// 老缓存没有这个字段，解码为 nil，界面上就不提示。
    var sourceDuration: Double?

    init(lines: [LyricLine], isSynced: Bool, sourceDuration: Double? = nil) {
        self.lines = lines
        self.isSynced = isSynced
        self.sourceDuration = sourceDuration
    }
    /// 当前该高亮第几行：取「最后一个时间 <= 播放进度」的行。
    ///
    /// 留 0.12 秒提前量：人耳听到一句和眼睛看到高亮之间，提前一点点更自然；
    /// 卡在 0 会让高亮总像慢半拍。
    ///
    /// `delay` 是自动算出来的版本差（正数 = 歌词整行再晚一点出现），
    /// 由 `LyricsStore` 按「本机音频长度 - 歌词自带版本长度」得出，界面不提供手动微调。
    func index(at time: TimeInterval, delay: TimeInterval = 0) -> Int? {
        guard isSynced, !lines.isEmpty else { return nil }
        let adjusted = time + 0.12 - delay
        var result: Int?
        for (index, line) in lines.enumerated() {
            if line.time <= adjusted { result = index } else { break }
        }
        // 第一句之前返回 nil：MV 版前奏可能有几十秒，提前把首句点亮会让人以为已经开唱。
        return result
    }
}

extension Lyrics {
    /// 优先用 `syncedLyrics`（LRC），没有就退回 `plainLyrics`（一行一句、无时间轴）。
    /// 两边都空返回 nil —— 让上层显示「没找到歌词」，而不是一张空列表。
    static func parse(synced: String?, plain: String?, sourceDuration: Double? = nil) -> Lyrics? {
        if let synced, !synced.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let lines = parseLRC(synced), !lines.isEmpty {
            return Lyrics(lines: lines, isSynced: true, sourceDuration: sourceDuration)
        }
        if let plain {
            let texts = plain
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            if !texts.isEmpty {
                return Lyrics(
                    lines: texts.enumerated().map { LyricLine(id: $0.offset, time: 0, text: $0.element) },
                    isSynced: false
                )
            }
        }
        return nil
    }

    /// LRC 的 `[offset:±毫秒]` 元信息；没有就是 0。正负号可省略。
    private static func lrcOffset(in text: String) -> TimeInterval {
        let pattern = #"\[offset:\s*([+-]?\d+)\s*\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)),
              let raw = Double((text as NSString).substring(with: match.range(at: 1)))
        else { return 0 }
        return raw / 1000
    }

    /// LRC 里一行可能挂多个时间戳（副歌复用同一句），每个时间戳都要展开成一行。
    /// `[ti:]` `[ar:]` 这类元信息直接忽略。
    private static func parseLRC(_ text: String) -> [LyricLine]? {
        let pattern = #"\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }

        var entries: [(time: TimeInterval, text: String)] = []
        for rawLine in text.components(separatedBy: .newlines) {
            let ns = rawLine as NSString
            let matches = regex.matches(in: rawLine, range: NSRange(location: 0, length: ns.length))
            guard !matches.isEmpty else { continue }

            // 一行挂了多个时间戳时，要把**所有**时间戳都从正文里去掉，
            // 只删最后一个会剩下 "[00:12.00]" 这种残渣。
            let body = regex.stringByReplacingMatches(
                in: rawLine,
                range: NSRange(location: 0, length: ns.length),
                withTemplate: ""
            ).trimmingCharacters(in: .whitespaces)
            for match in matches {
                guard
                    let minute = Double(ns.substring(with: match.range(at: 1))),
                    let second = Double(ns.substring(with: match.range(at: 2)))
                else { continue }
                var fraction = 0.0
                if match.range(at: 3).location != NSNotFound {
                    let digits = ns.substring(with: match.range(at: 3))
                    if let value = Double(digits) {
                        fraction = value / pow(10, Double(digits.count))
                    }
                }
                entries.append((minute * 60 + second + fraction, body))
            }
        }

        guard !entries.isEmpty else { return nil }
        // `[offset:+500]` 按 LRC 约定是「歌词提前 500ms」，与本 App 的 delay 正负相反。
        let metadataDelay = -lrcOffset(in: text)
        entries = entries.map { ($0.time + metadataDelay, $0.text) }.filter { $0.0 >= 0 }
        guard !entries.isEmpty else { return nil }
        entries.sort { $0.time < $1.time }
        return entries.enumerated().map { LyricLine(id: $0.offset, time: $0.element.time, text: $0.element.text) }
    }
}
