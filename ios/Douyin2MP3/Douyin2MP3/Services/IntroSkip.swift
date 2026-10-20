// 用途：「跳过前奏 / 跳过结尾」的持久化。按条目 id 记住每首歌从第几秒听到第几秒。
//
// 为什么不改文件、只在播放时 seek：
//   实测（macOS/iOS 同一套 AVFoundation）：把 mp3 裁掉前 10 秒**无法无损**做到 ——
//   `AVAssetExportPresetPassthrough` 的 `supportedFileTypes` 里**根本没有 mp3**
//   （只有 mov/m4a/mp4/wav/caf 等），所以裁剪 mp3 只能重编码成 AAC（2.8 秒/首，有损），
//   或者自己去解析 MP3 帧头（有实现风险）。而「播放时跳过」完全不碰文件：
//   零耗时、mp3/mp4 一视同仁、随时能改能撤销。痛点（前奏太长、结尾拖沓）用这个就解决了。
//
// 两头是一份数据、一个对象：用户心里的模型是「这首我从哪听到哪」，
// 拆成两个单例只会让「取消整首的跳过」变得别扭。
import Foundation

/// 一首歌的「有效区间」：从 `start` 秒听到离末尾 `endTrim` 秒处。
///
/// ⚠️ 别把它理解成「文件被裁了」—— **文件一个字节都没动**，这只是播放时的
/// 起止点。要真裁文件是另一个功能（见文件头注释）。
struct SkipRange: Equatable {
    /// 从第几秒开始听。
    var start: Double = 0
    /// 结尾提前多少秒结束。
    var endTrim: Double = 0

    /// 完全没设过。
    var isEmpty: Bool { start <= 0 && endTrim <= 0 }

    /// 能不能用（两个值都得有限、非负）。
    var isUsable: Bool {
        (start.isFinite && start >= 0) && (endTrim.isFinite && endTrim >= 0)
    }
}

/// 每首歌的起止点。两份字典分开存，读的时候合成 `SkipRange`。
///
/// `ObservableObject` 而不是普通单例：列表行上那个「跳过 12s」小标记要跟着改，
/// 界面得能观察到。之前试过「改完手动 bump 一个计数器、给列表换 identity」，
/// 那会把搜索框和滚动位置一起重置掉 —— 观察对象才是对的做法。
@MainActor
final class IntroSkip: ObservableObject {
    static let shared = IntroSkip()

    /// 条目 id → 起点秒数。**只存非 0 的**：取消就把键删掉，
    /// 不留一堆 0，也没法从「有没有这个键」看出用户到底设过没设。
    ///
    /// `private(set)` + `@Published`：外面只能读，改动一律走下面那几个方法，
    /// 免得绕过闸门往字典里塞脏值。
    @Published private(set) var starts: [String: Double] = [:]
    /// 条目 id → 结尾提前结束的秒数。口径同 `starts`。
    @Published private(set) var endTrims: [String: Double] = [:]

    private static let key = "playback.introStarts"
    private static let endKey = "playback.endTrims"
    /// 上限 6 小时：真有人拿它跳掉整首歌的话，那是误操作不是需求；
    /// 超过就当成没设，免得一进歌就直接跳下一首。
    private static let maxTrim: Double = 6 * 3600

    private init() {
        starts = Self.load(Self.key)
        endTrims = Self.load(Self.endKey)
    }

    /// 读一份、顺手过一遍闸：老数据 / 手改过的 plist 里可能有脏值。
    private static func load(_ key: String) -> [String: Double] {
        let raw = UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:]
        return raw.filter { $0.value > 0 && $0.value < maxTrim }
    }

    // MARK: - 读

    /// 这首的起止点。没设过就是 `SkipRange()`（两头都是 0）。
    func range(for id: String?) -> SkipRange {
        guard let id else { return SkipRange() }
        return SkipRange(start: starts[id] ?? 0, endTrim: endTrims[id] ?? 0)
    }

    /// 这首从第几秒开始听（没设过返回 0）。
    func start(for id: String?) -> Double { range(for: id).start }

    /// 这首结尾提前几秒结束（没设过返回 0）。
    func endTrim(for id: String?) -> Double { range(for: id).endTrim }

    /// 有没有为这首设过（任意一头）。
    func hasAny(for id: String?) -> Bool { !range(for: id).isEmpty }

    /// 有没有设过跳过前奏。
    func hasStart(for id: String?) -> Bool { start(for: id) > 0 }

    /// 有没有设过跳过结尾。
    func hasEndTrim(for id: String?) -> Bool { endTrim(for: id) > 0 }

    // MARK: - 写

    /// 设起点。传 0 或负数 = 取消（把键删掉，不留 0）。
    func setStart(_ seconds: Double, for id: String) {
        starts = Self.updated(starts, key: id, value: seconds)
        persist()
    }

    /// 设结尾提前量。传 0 或负数 = 取消。
    func setEndTrim(_ seconds: Double, for id: String) {
        endTrims = Self.updated(endTrims, key: id, value: seconds)
        persist()
    }

    /// 还没播过、或者跳过区间没有落在文件外面 —— 这时候「两头的和」还不到文件长度，
    /// 分段拖拽是安全的。一旦超过就等于整首都被剪掉了，不允许拖成那样。
    func fitsWithin(duration: Double, of id: String) -> Bool {
        guard duration > 0 else { return true }
        let r = range(for: id)
        // 留 1 秒：`effectiveEnd` 自己的闸门也是「区间吃掉整首就不认」，保持一致
        return r.start + r.endTrim < duration - 1
    }

    /// 一次改两头。编辑框里两个输入框是同一张表单，分开调会写两次盘、发两次通知。
    func setRange(start: Double, endTrim: Double, for id: String) {
        var s = starts, e = endTrims
        Self.apply(&s, key: id, value: start)
        Self.apply(&e, key: id, value: endTrim)
        starts = s
        endTrims = e
        persist()
    }

    /// 取消这首的全部跳过（两头都清）。
    func clear(_ id: String) {
        var s = starts, e = endTrims
        let a = s.removeValue(forKey: id) != nil
        let b = e.removeValue(forKey: id) != nil
        guard a || b else { return }
        starts = s
        endTrims = e
        persist()
    }

    /// 条目被删时清掉它的记录，别让 plist 无限长。
    func forget(_ id: String) {
        clear(id)
    }

    private static func updated(_ map: [String: Double], key id: String, value: Double) -> [String: Double] {
        var next = map
        apply(&next, key: id, value: value)
        return next
    }

    /// 统一的闸门：非有限、<=0、>= 上限 一律当取消。
    private static func apply(_ map: inout [String: Double], key id: String, value: Double) {
        let v = value.isFinite ? value : 0
        if v <= 0 || v >= maxTrim {
            map.removeValue(forKey: id)
        } else {
            map[id] = v
        }
    }

    private func persist() {
        UserDefaults.standard.set(starts, forKey: Self.key)
        UserDefaults.standard.set(endTrims, forKey: Self.endKey)
    }
}