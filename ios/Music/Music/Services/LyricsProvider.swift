// 用途：按歌名去 LRCLIB 找歌词，并落盘缓存。
//
// 为什么是 LRCLIB：免费、不用 key、中文歌覆盖够用，而且直接给逐行时间轴（LRC）。
// 库里的标题是抖音/YouTube 原标题（带「(Official Music Video)」这类噪声），
// 所以先把噪声削掉再搜，否则同一个歌名会被拼成匹配不上的长串。
import CryptoKit
import Foundation

enum LyricsProvider {
    private static let endpoint = URL(string: "https://lrclib.net/api/search")!
    private static let cacheFolder = "Lyrics"
    /// 换过选词规则就要 +1：缓存按歌名存，不带上版本会把「旧规则挑错的歌词」一直读回来。
    private static let cacheVersion = "v3"

    private struct Row: Decodable {
        let trackName: String
        let artistName: String
        let duration: Double?
        let instrumental: Bool
        let plainLyrics: String?
        let syncedLyrics: String?
    }

    /// 找歌词。失败/没找到都返回 nil —— 调用方只关心「有没有得显示」。
    static func fetch(title: String, duration: Double) async -> Lyrics? {
        let query = Query(rawTitle: title)
        guard !query.candidates.isEmpty else { return nil }
        if let cached = readCache(query) { return cached }
        for candidate in query.candidates {
            let rows: [Row]
            switch await search(candidate) {
            case .rows(let value):
                rows = value
            case .notFound:
                continue
            case .unavailable:
                return await plainFallback(query)
            }
            guard let best = pick(rows, duration: duration, rawTitle: title) else { continue }
            // 版本对不上时，靠这条日志能直接看出「选中的是哪个时长的 LRC」。
            // 这里不平移：同一份 LRC 可能被多首歌复用；平移放在播放页按本曲音频时长算。
            MusicDebug.log("歌词：选中 \(best.trackName) 时长 \(best.duration.map { String(format: "%.0f", $0) } ?? "?")s / 本曲 \(String(format: "%.0f", duration))s")
            guard let lyrics = Lyrics.parse(synced: best.syncedLyrics, plain: best.plainLyrics,
                                       sourceDuration: best.duration) else { continue }
            writeCache(lyrics, for: query)
            return lyrics
        }
        return await plainFallback(query)
    }

    /// 从标题里识别「歌手 + 歌名」。
    ///
    /// 复用 `Query` 已经做过的那套切分：`歌手 - 歌名`、`歌手：歌名`、
    /// `歌手【歌名 English】` 都能落到 `plainCandidates.first`。
    /// 识别不出来时至少把噪声削掉，歌名仍可用。
    static func identify(_ rawTitle: String) -> (artist: String?, track: String) {
        let query = Query(rawTitle: rawTitle)
        if let first = query.plainCandidates.first {
            return (cleanName(first.artist), cleanName(first.title))
        }
        return (nil, cleanName(Query.stripNoise(rawTitle)))
    }

    /// 去掉歌名里「『副歌歌词』」「完整版」这类不属于检索词的尾巴。
    /// 中文歌词频道的标题常写成「歌名『副歌』【動態歌詞】」，整串拿去搜会匹配不到。
    private static func cleanName(_ text: String) -> String {
        var value = text
        // 引号里的副歌、方括号里的「動態歌詞/高音質」都不是歌名，整段删掉。
        // 注意 `（）` 只在识别阶段删，因为「(Live)」这类信息有时是版本线索。
        for pattern in ["『[^』]*』", "「[^」]*」", "“.*?”", "【[^】]*】", "\\[[^\\]]*\\]"] {
            value = value.replacingOccurrences(of: pattern, with: " ",
                                               options: [.regularExpression, .caseInsensitive])
        }
        for word in ["完整版", "官方", "原唱", "高音質", "高音质", "動態歌詞", "动态歌词",
                     "歌詞版", "歌词版", "Official", "Lyrics", "MV"] {
            value = value.replacingOccurrences(of: word, with: " ", options: .caseInsensitive)
        }
        value = value.replacingOccurrences(of: "《", with: " ")
            .replacingOccurrences(of: "》", with: " ")
        // 清掉只剩装饰符号的碎片（♪ ♫ | ·），再把连续空白压成一个。
        value = value.replacingOccurrences(of: "[♪♫|｜·•]+", with: " ", options: .regularExpression)
        value = value.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return value.trimmingCharacters(in: CharacterSet(charactersIn: " -—|：:")).trimmingCharacters(in: .whitespaces)
    }

    // MARK: - 查询

    /// 把库里的标题变成「可以拿去搜的几个候选词」。
    ///
    /// 库里混着两种命名：
    ///   - YouTube：「B.o.B - Nothin' On You (feat. Bruno Mars) (Official Music Video)」
    ///   - 抖音：「#音乐 #音乐分享 #周杰伦：七里香（周杰伦）」
    /// 没有一种规则能同时削干净，所以按「从精确到宽松」排好几个候选，逐个试到有结果为止。
    struct Query {
        let candidates: [String]
        let plainCandidates: [(artist: String, title: String)]
        let key: String

        init(rawTitle: String) {
            let cleaned = Query.stripNoise(rawTitle)
            var list: [String] = []
            var pairs: [(artist: String, title: String)] = []

            // 「歌手 - 歌名」
            let parts = cleaned.components(separatedBy: " - ")
            if parts.count > 1 {
                let artist = parts[0].trimmingCharacters(in: .whitespaces)
                let track = parts.dropFirst().joined(separator: " - ").trimmingCharacters(in: .whitespaces)
                list.append([artist, track].filter { !$0.isEmpty }.joined(separator: " "))
                list.append(track)
                pairs.append((artist, track))
            }

            // 「歌手：歌名」（抖音常用）
            if let colon = cleaned.lastIndex(where: { $0 == "：" || $0 == ":" }) {
                let artist = cleaned[..<colon].split(separator: " ").last.map(String.init) ?? ""
                let track = String(cleaned[cleaned.index(after: colon)...])
                list.append([artist, track].filter { !$0.isEmpty }.joined(separator: " "))
                let cleanTrack = Query.stripTrailingDuplicate(track, of: artist)
                list.append(cleanTrack)
                pairs.append((artist, cleanTrack))
            }

            // 「周杰伦 Jay Chou【千里之外 Far Away】」：真正的歌名在括号里，括号外只是
            // 中英文双写的歌手名。整串拿去搜会把英文别名也当成歌名的一部分，匹配不到。
            // 拆出括号里的中文部分，再分别配「括号外的第一个中文词」和单独歌名。
            //
            // 抖音那种「歌手：歌名（歌手）」不在这里拆：尾巴的括号是重复的歌手名，
            // 上面「歌手：歌名」那条已经处理过，再拆只会多出「歌手」这种无效检索词。
            let outside = Query.removingBrackets(cleaned)
            let hasSeparator = ["：", ":", " - "].contains { outside.contains($0) }
            if !hasSeparator {
                for inner in Query.bracketContents(cleaned) {
                    // 取括号里**第一段**汉字：`【千里之外 Far Away (feat.費玉清)】`
                    // 的歌名是千里之外，后面的 feat 是合作歌手，不能拼进检索词。
                    guard let track = Query.cjkRuns(inner).first(where: { $0.count >= 2 }) else { continue }
                    for artist in Query.artistGuesses(outside) where artist != track {
                        list.append("\(artist) \(track)")
                        pairs.append((artist, track))
                    }
                    list.append(track)
                }
            }

            // 抖音/翻唱标题常把真歌名放在《》里，前面一堆情绪文案和话题标签：
            // 「花田里犯了错。王力宏《花田错》#8090后」。整串搜必然搜不到，
            // 先把书名号里的短标题排到候选最前面。
            if let bookTitle = Query.bookTitle(cleaned) {
                list.insert(bookTitle, at: 0)
            }

            list.append(cleaned)
            list.append(Query.stripTrailingDuplicate(cleaned, of: ""))

            var seen = Set<String>()
            candidates = list
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && seen.insert($0).inserted }
            var seenPairs = Set<String>()
            plainCandidates = pairs.filter { pair in
                let artist = pair.artist.trimmingCharacters(in: .whitespaces)
                let title = pair.title.trimmingCharacters(in: .whitespaces)
                guard !artist.isEmpty, !title.isEmpty else { return false }
                return seenPairs.insert("\(artist)\u{1F}\(title)".lowercased()).inserted
            }
            key = Query.hash((candidates.first ?? cleaned).lowercased())
        }

        /// 括号里带这些词的整段删掉（连括号一起）；话题标签只去掉 `#`，文字保留。
        private static let noiseWords = [
            "official", "music video", "video", "mv", "m/v", "audio", "lyric", "lyrics",
            "高清", "完整版", "现场版", "原唱", "无损", "动态歌词", "中文字幕", "字幕",
            "1080p", "4k", "hq", "音乐", "音乐分享", "音乐推荐", "热门", "推荐", "抖音", "神曲",
        ]

        static func stripNoise(_ raw: String) -> String {
            var text = raw
            let bracketPattern = #"[\(（\[【]([^\)）\]】]*)[\)）\]】]"#
            if let regex = try? NSRegularExpression(pattern: bracketPattern) {
                let ns = text as NSString
                let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
                // 从后往前删，range 才不会因为前面的删除而错位。
                for match in matches.reversed() {
                    let inner = ns.substring(with: match.range(at: 1)).lowercased()
                    if noiseWords.contains(where: { inner.contains($0) }),
                       Query.noiseRemainder(inner).isEmpty {
                        text = (text as NSString).replacingCharacters(in: match.range, with: "")
                    }
                }
            }

            // 话题标签：`#周杰伦：七里香` 里的 `#` 去掉但保留正文，
            // 否则整条最关键的「歌手：歌名」会被当成噪声丢掉。
            let tokens = text.split(whereSeparator: { $0 == " " || $0 == "\t" })
                .map { token -> String in
                    var value = String(token).trimmingCharacters(in: CharacterSet(charactersIn: "#＃"))
                    let lower = value.lowercased()
                    if noiseWords.contains(where: { lower == $0 }) { value = "" }
                    return value
                }
                .filter { !$0.isEmpty }
            text = tokens.joined(separator: " ")

            for word in noiseWords where text.lowercased().hasSuffix(word) {
                text = String(text.dropLast(word.count))
            }
            return text
                .replacingOccurrences(of: "官方", with: "")
                .trimmingCharacters(in: CharacterSet(charactersIn: " -–—·|"))
                .trimmingCharacters(in: .whitespaces)
        }

        /// 括号内容去掉噪声词后还剩什么。只剩空白的才算「整个括号都是噪声」；
        /// 「千里之外 官方MV」这种括号里有真正歌名的必须留下，否则会把歌名一起删掉。
        private static func noiseRemainder(_ text: String) -> String {
            var lower = text.lowercased()
            for word in noiseWords {
                lower = lower.replacingOccurrences(of: word, with: "")
            }
            lower = lower.replacingOccurrences(of: "官方", with: "")
            return lower.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        }

        /// 「七里香（周杰伦）」这种尾部重复歌手的括号，去掉更好搜。
        static func stripTrailingDuplicate(_ text: String, of artist: String) -> String {
            guard let open = text.lastIndex(where: { $0 == "（" || $0 == "(" }),
                  let close = text.lastIndex(where: { $0 == "）" || $0 == ")" }),
                  open < close else { return text }
            let inner = String(text[text.index(after: open)..<close])
                .trimmingCharacters(in: .whitespaces)
            guard !artist.isEmpty ? inner == artist : inner.count <= 12 else { return text }
            let head = String(text[..<open]).trimmingCharacters(in: .whitespaces)
            return head.isEmpty ? text : head
        }

        /// 最外层括号里的内容（`【】` / `[]` / `（）` / `()`），支持嵌套。
        ///
        /// 不能用正则：`【千里之外 (feat.費玉清)】` 里还有一层圆括号，正则会停在
        /// 内层的 `)`，把歌名和歌手粘成「千里之外費玉清」。
        static func bracketContents(_ text: String) -> [String] {
            outerBrackets(text).map(\.inner)
        }

        /// 去掉括号及其中内容，留下「歌手 - 歌名」这层主干。
        static func removingBrackets(_ text: String) -> String {
            var result = text
            for bracket in outerBrackets(text).reversed() {
                result.replaceSubrange(bracket.range, with: " ")
            }
            return result.trimmingCharacters(in: .whitespaces)
        }

        private static func outerBrackets(_ text: String) -> [(range: Range<String.Index>, inner: String)] {
            let pairs: [Character: Character] = ["【": "】", "[": "]", "（": "）", "(": ")"]
            var stack: [(close: Character, start: String.Index)] = []
            var result: [(range: Range<String.Index>, inner: String)] = []
            var index = text.startIndex

            while index < text.endIndex {
                let character = text[index]
                if let close = pairs[character] {
                    stack.append((close, index))
                } else if let top = stack.last, character == top.close {
                    stack.removeLast()
                    if stack.isEmpty {
                        let innerStart = text.index(after: top.start)
                        let end = text.index(after: index)
                        result.append((top.start..<end, String(text[innerStart..<index])))
                    }
                }
                index = text.index(after: index)
            }
            return result
        }

        /// 按非汉字切开的连续汉字段。
        static func cjkRuns(_ text: String) -> [String] {
            var runs: [String] = []
            var current = ""
            for character in text {
                if let scalar = character.unicodeScalars.first, isCJK(scalar) {
                    current.append(character)
                } else if !current.isEmpty {
                    runs.append(current)
                    current = ""
                }
            }
            if !current.isEmpty { runs.append(current) }
            return runs
        }

        /// 只保留汉字，用来从「千里之外 Far Away」里抠出可检索的歌名。
        static func cjkOnly(_ text: String) -> String {
            String(text.unicodeScalars.filter(isCJK))
        }

        private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
            (0x3400...0x4DBF).contains(scalar.value)
                || (0x4E00...0x9FFF).contains(scalar.value)
                || (0xF900...0xFAFF).contains(scalar.value)
        }

        /// 从括号外的主干里猜歌手：优先第一个含汉字的词（「周杰伦 Jay Chou」→「周杰伦」）；
        /// 全是英文姓名时取前两个词（「Jay Chou」）。
        static func artistGuesses(_ text: String) -> [String] {
            let tokens = text.split(whereSeparator: { $0 == " " || $0 == "\t" })
                .map(String.init)
                .filter { !$0.isEmpty }
            guard !tokens.isEmpty else { return [] }
            var list: [String] = []
            if let firstCJK = tokens.first(where: { !cjkOnly($0).isEmpty }) {
                list.append(firstCJK)
            }
            if tokens.count >= 2, tokens.prefix(2).allSatisfy({ cjkOnly($0).isEmpty }) {
                list.append(tokens.prefix(2).joined(separator: " "))
            }
            return list
        }

        /// 第一个书名号里的歌名（2–20 字），没有就返回 nil。
        static func bookTitle(_ text: String) -> String? {
            guard let open = text.firstIndex(of: "《"),
                  let close = text[text.index(after: open)...].firstIndex(of: "》") else { return nil }
            let value = String(text[text.index(after: open)..<close])
                .trimmingCharacters(in: .whitespaces)
            return (2...20).contains(value.count) ? value : nil
        }

        private static func hash(_ text: String) -> String {
            SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
        }
    }

    private enum SearchOutcome {
        case rows([Row])
        case notFound
        case unavailable
    }

    private static func search(_ text: String) async -> SearchOutcome {
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else { return .notFound }
        components.queryItems = [URLQueryItem(name: "q", value: text)]
        guard let url = components.url else { return .notFound }

        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        // LRCLIB 要求带能识别调用方的 UA，裸 URLSession 默认 UA 会被限流。
        request.setValue("MusicApp/1.0 (iOS)", forHTTPHeaderField: "User-Agent")

        // LRCLIB 免费接口在高频请求时会回 503/429。失败就换下一个候选词会让
        // 「服务过载」被误判成「这首歌没歌词」，还会继续加压；所以这里先退避重试，
        // 仍不可用就交给纯文本回退源。
        for attempt in 0..<3 {
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse {
                    if http.statusCode == 429 || (500...599).contains(http.statusCode) {
                        guard attempt < 2 else {
                            MusicDebug.log("歌词：搜索持续 \(http.statusCode)，改用回退源")
                            return .unavailable
                        }
                        MusicDebug.log("歌词：搜索 \(http.statusCode)，重试")
                        try? await Task.sleep(nanoseconds: attempt == 0 ? 700_000_000 : 1_800_000_000)
                        continue
                    }
                    guard (200..<300).contains(http.statusCode) else {
                        MusicDebug.log("歌词：搜索返回 \(http.statusCode)")
                        return .notFound
                    }
                }
                return .rows(try JSONDecoder().decode([Row].self, from: data))
            } catch {
                MusicDebug.log("歌词：搜索失败 \(error.localizedDescription)")
                return .unavailable
            }
        }
        return .unavailable
    }

    private struct PlainResponse: Decodable {
        let lyrics: String
    }

    /// LRCLIB 过载或确实没有记录时的回退：纯文本歌词，没有逐行时间轴。
    /// 宁可显示不带高亮的歌词，也比整块空白好；能拿到逐行时间轴时不会走这里。
    private static func plainFallback(_ query: Query) async -> Lyrics? {
        for candidate in query.plainCandidates.prefix(3) {
            var components = URLComponents()
            components.scheme = "https"
            components.host = "api.lyrics.ovh"
            components.path = "/v1/\(candidate.artist)/\(candidate.title)"
            guard let url = components.url else { continue }

            var request = URLRequest(url: url)
            request.timeoutInterval = 8
            request.setValue("MusicApp/1.0 (iOS)", forHTTPHeaderField: "User-Agent")

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { continue }
                let row = try JSONDecoder().decode(PlainResponse.self, from: data)
                guard let lyrics = Lyrics.parse(synced: nil, plain: row.lyrics) else { continue }
                MusicDebug.log("歌词：LRCLIB 无结果，使用纯文本回退")
                return lyrics
            } catch {
                MusicDebug.log("歌词：回退源失败 \(error.localizedDescription)")
            }
        }
        return nil
    }

    /// 挑一条最像「这首」的，而不是只看时长。
    ///
    /// 只看时长会出事：`空心` 的 MV 是 296s，LRCLIB 上正好有一版 **296s 的他人现场翻唱**，
    /// 于是「时长完全一致」反而选中了别人的编曲，整首歌词自然对不上。
    /// 所以再加一档「原曲标题里是否出现这条候选的歌手名」——标题里本来就带着歌手，
    /// 只是从「歌手 - 歌名」这种格式里不一定切得出来。
    private static func pick(_ rows: [Row], duration: Double, rawTitle: String) -> Row? {
        let candidates = rows.filter { !$0.instrumental && $0.syncedLyrics?.isEmpty == false }
        let pool = candidates.isEmpty ? rows.filter { !$0.instrumental && $0.plainLyrics?.isEmpty == false } : candidates
        guard !pool.isEmpty else { return nil }

        let haystack = normalized(rawTitle)
        // 标题里一个歌手名都对不上时（比如纯歌名），就别用这条规则惩罚所有人。
        let canCheckArtist = pool.contains { !normalized($0.artistName).isEmpty && haystack.contains(normalized($0.artistName)) }

        func score(_ row: Row) -> Double {
            var value = 0.0
            if duration > 0 {
                // 封顶 120s：两个都差很多时，差别不再重要，交给歌手名决定。
                value += min(abs((row.duration ?? duration) - duration), 120)
            }
            // LRCLIB 有的行没写 duration，光凭它挑等于瞎猜；同分时优先有元数据的。
            if row.duration == nil { value += 10 }
            if canCheckArtist {
                let artist = normalized(row.artistName)
                if artist.isEmpty || !haystack.contains(artist) { value += 60 }
            }
            return value
        }

        return pool.min { score($0) < score($1) }
    }

    /// 只留字母和数字：`B.o.B` 与 `bob`、`G.Z` 与 `gz` 视为同一个词。
    private static func normalized(_ text: String) -> String {
        text.lowercased().unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
    }

    // MARK: - 缓存

    private static var folderURL: URL? {
        guard let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let folder = base.appendingPathComponent(cacheFolder, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private static func readCache(_ query: Query) -> Lyrics? {
        guard let url = folderURL?.appendingPathComponent("\(query.key)-\(cacheVersion).json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Lyrics.self, from: data)
    }

    private static func writeCache(_ lyrics: Lyrics, for query: Query) {
        guard let url = folderURL?.appendingPathComponent("\(query.key)-\(cacheVersion).json"),
              let data = try? JSONEncoder().encode(lyrics) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
