// 用途：全局播放器（音乐 App 的「正在播放」内核）。队列、锁屏信息、封面、后台播放都在这里。
import AVFoundation
import MediaPlayer
import UIKit

/// 播放顺序。只做两态，对齐音乐 App 的随机开关（高亮=随机、灰=顺序）。
///
/// 不做「列表循环 / 单曲循环」：那两种是**循环**语义，跟「怎么排下一首」是两件事，
/// 掺进来会让按钮变成四态循环、按几下才知道自己在哪一档。等真需要了再加一排键，
/// 而不是塞进这一个开关里。
enum PlaybackMode: String, CaseIterable {
    /// 按资料库的顺序往下走，走到最后一首就停。
    case sequence
    /// 随机。洗完一轮之前**不会重复**同一首（见 `makeOrder(startingAt:)`）。
    case shuffle

    var label: String {
        switch self {
        case .sequence: return "顺序播放"
        case .shuffle: return "随机播放"
        }
    }
}

@MainActor
final class MediaPlayer: ObservableObject {
    @Published private(set) var currentID: String?
    @Published private(set) var currentTitle: String = ""
    @Published private(set) var isPlaying = false
    /// 播放顺序偏好。**存 UserDefaults**：这是播放器状态、跟资料库无关，
    /// 关掉 App 再回来还该是用户上次选的那一档。
    @Published private(set) var mode: PlaybackMode = .sequence
    @Published private(set) var elapsed: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var artwork: UIImage?
    /// 当前条目的媒体类型：决定播放页显示画面还是封面。
    @Published private(set) var currentKind: MediaKind = .video
    /// 后台播放时摘掉画面，避免 iOS 挂起视频渲染导致声音中断。
    @Published var showsVideo = true
    /// 是否展开全屏「正在播放」。
    @Published var isExpanded = false

    let player = AVPlayer()
    private var timeObserver: Any?
    /// 盯住 AVPlayer 的真实播放状态：暂停/播完/被系统中断都由它纠正按钮，避免图标和实际不符。
    private var statusObservation: NSKeyValueObservation?
    private var artworkLoader: @MainActor (MediaItem) -> URL? = { _ in nil }
    private var fileResolver: @MainActor (MediaItem) -> URL = { _ in URL(fileURLWithPath: "/dev/null") }

    /// 队列的**原始顺序**（就是资料库给的那份，不随随机播放变动）。
    private var queue: [MediaItem] = []
    /// 实际播放的顺序，是 `queue` 的下标排列。顺序播放时它就是 `0,1,2...`；
    /// 随机播放时是一份洗好的排列。`index` 是**它**的下标，不是 `queue` 的。
    private var order: [Int] = []
    /// 在 `order` 里的位置。
    private var index = 0
    /// 当前这首在 `queue` 里的下标。
    private var currentQueueIndex: Int? { order.indices.contains(index) ? order[index] : nil }

    init() {
        // ⚠️ `mode` 必须在 `registerRemoteCommands()` **之前**读出来：
        // 那里最后一句会 `syncSystemShuffle()`，把模式报给系统。
        // 反过来的话，报出去的是默认的 `.sequence`，而用户存的可能是随机 ——
        // 现象就是「关了 App 再开，锁屏上的随机是高亮的，但 App 里是顺序」，
        // 或者更糟：用户点了随机、锁屏却还显示顺序，看起来像「随机没生效」。
        mode = Self.loadMode()
        configureSession()
        addTimeObserver()
        observePlaybackStatus()
        registerRemoteCommands()
        migrateLegacySavePoint()
    }

    /// 顺序模式下「还有下一首」就是队列没见底；随机模式下由洗好的排列末尾决定。
    var hasNext: Bool { index + 1 < order.count }
    var hasPrevious: Bool { index > 0 }
    /// 当前这首有没有画面可看（音频只显示封面，切画面的按钮也不出现）。
    var currentHasPicture: Bool { currentKind.hasPicture }

    var progress: Double {
        // 用 `activeEnd`：设了跳过结尾时进度条该在「该结束的地方」就到底，
        // 而不是拖到真实末尾 —— 否则用户看到条还剩一截，歌却已经切走了。
        let end = activeEnd
        guard end > 0 else { return 0 }
        return min(1, max(0, elapsed / end))
    }

    var elapsedText: String { Self.format(elapsed) }
    var durationText: String { Self.format(duration) }

    /// 这首**实际会播到**的第几秒（设了跳过结尾就是这个提前量）。
    /// 没设过、或时长还不知道，就等于真实时长。
    ///
    /// 这是「跳过结尾」的唯一口径来源 —— 「放完了吗」「进度条拖到哪算尾」
    /// 「剩余时间显示多少」三处都必须用它，否则界面会自相矛盾：
    /// 比如进度条到底了但歌还在放，或者停在 0:00 却说「还剩 12 秒」。
    var effectiveEnd: Double {
        guard duration > 0 else { return duration }
        let trim = IntroSkip.shared.endTrim(for: currentID)
        // 跳过结尾比整首还长 → 当没设（不然这首直接没得放）
        guard trim > 0, trim < duration - 1 else { return duration }
        return duration - trim
    }

    /// 试听用：临时盖在这首头上的「从哪到哪」，放完这一段就恢复原设置。
    /// 只影响这一遍播放，**不写盘**（写盘的是 `IntroSkip`）。
    ///
    /// 为什么试听不新增一个播放器、直接把这段塞给 `MediaPlayer` 最省事：
    /// 1. 它就有一个 AVPlayer，音量、锁屏、动画封面全都已经挂在上面了 ——
    ///    再开一路 AVPlayer 就等于再养一套这些，还多一层「两路声音谁说了算」。
    /// 2. 用户要的是「改完立马切到这首歌听」：让它跳到这首、按试听区间放，
    ///    跟「点这首歌来听」走的是同一条路，手感一致。
    private struct PreviewRange {
        let from: Double
        let to: Double
        /// **同一首**上试听时，记下试听前播到哪、在不在放 ——
        /// 试听结束要还回去，用户只是"借这首听一下开头/结尾"，不该把播放头丢在别处。
        /// 换了一首来试听时是 nil：那种情况本来就没有"原位"可回（见 `endPreview`）。
        let origin: Double?
        let wasPlaying: Bool
    }

    private var previewRange: PreviewRange?

    /// 这首**现在实际会播到**的第几秒。试听区间优先于存档设置 ——
    /// 试听放的就是还没保存的数字，不该被存档里的旧值顶掉。
    private var activeEnd: Double {
        if let p = previewRange { return p.to }
        return effectiveEnd
    }

    /// 音乐 App 右端显示的是剩余时间。用 `activeEnd` —— 设了跳过结尾时
    /// 剩余时间该倒数到那个点为止，不然会显示成「还剩 12 秒」却永远到不了 0。
    /// 试听时也一样：倒数的终点就是试听那一段的结尾点。
    var remainingText: String { "-" + Self.format(max(0, activeEnd - elapsed)) }

    /// 正在试听（「跳过开头/结尾」编辑框里按了试听）。
    var isPreviewing: Bool { previewRange != nil }

    // MARK: - 播放控制

    /// 由上层注入「文件在哪、封面在哪」，播放器只负责播放本身。
    func configure(
        files: @escaping @MainActor (MediaItem) -> URL,
        artwork: @escaping @MainActor (MediaItem) -> URL?
    ) {
        fileResolver = files
        artworkLoader = artwork
    }

    /// 从资料库点某一首进来（以及冷启动续播）：这一首听过一半的话，接着上次的地方放。
    func play(items: [MediaItem], startIndex: Int) {
        queue = items
        let plan = makeOrder(startingAt: startIndex)
        order = plan.order
        index = plan.index
        startCurrent(restoringPosition: true)
    }

    /// 当前这首（`index` 指的是 `order`，真正的内容在 `queue`）。
    private var currentItem: MediaItem? {
        guard let qi = currentQueueIndex, queue.indices.contains(qi) else { return nil }
        return queue[qi]
    }

    /// 按当前模式排出一份播放顺序，外加「从哪一格开始放」。
    ///
    /// ⚠️ 返回值是 `(排列, 起点)` 而不是只给排列 —— 顺序模式下 `order` 就是
    /// `0,1,2...` 原样，起点靠 `index` 指，**不能**也把起点挪到队首。
    /// 早先的版本只返回排列、调用方一律 `index = 0`，结果在顺序模式下
    /// 「点第 5 首」会从第 1 首开始放（起点被 `0` 顶掉了）。
    ///
    /// 随机不是每次取下一首时现掷骰子，而是**先把整条排列洗好**。两个理由：
    /// 1. 掷骰子会重复 —— 同一首歌可能连着来三遍，那不是用户要的随机。
    /// 2. `hasNext` / 「下一首」按钮要知道后面还有没有，得有一份确定的序列。
    /// 洗完一轮之前不会重复（就是一次 `shuffled()`），跟音乐 App 的行为一致。
    private func makeOrder(startingAt start: Int) -> (order: [Int], index: Int) {
        let all = Array(queue.indices)
        // 空队列 / 越界起点：返回空排列、起点 0，后面 `currentItem` 自然取不到东西。
        guard all.contains(start) else { return ([], 0) }
        guard mode == .shuffle, all.count > 1 else {
            // 顺序播放：原样排，起点用 index 指过去。点第 5 首就从第 5 首放，
            // 往后接着第 6、第 7……（跟音乐 App 点列表里某一首的手感一致）
            return (all, start)
        }
        // 随机：点播的那首**先响**，其余洗一遍排在后面。否则「点了 A 却在放 B」。
        let rest = all.filter { $0 != start }.shuffled()
        return ([start] + rest, 0)
    }

    /// 切换顺序 / 随机。**不打断当前这首**：正在放的继续放，只改「下一首是谁」。
    func setMode(_ new: PlaybackMode) {
        guard new != mode else { return }
        mode = new
        Self.saveMode(new)
        syncSystemShuffle()
        guard let qi = currentQueueIndex else { return }
        let plan = makeOrder(startingAt: qi)
        order = plan.order
        index = plan.index
        DouyinDebug.log("播放模式：\(new.label)（当前《\(currentTitle)》不变，只重排后续）")
    }

    func toggleMode() {
        setMode(mode == .sequence ? .shuffle : .sequence)
    }

    private static let modeKey = "playback.mode"
    private static func loadMode() -> PlaybackMode {
        UserDefaults.standard.string(forKey: modeKey).flatMap(PlaybackMode.init(rawValue:)) ?? .sequence
    }
    private static func saveMode(_ mode: PlaybackMode) {
        UserDefaults.standard.set(mode.rawValue, forKey: modeKey)
    }

    /// 告诉系统「本 App 现在是不是随机」。
    ///
    /// 只设 `currentShuffleType` 不够 —— 这个命令**不注册 target，系统就不给按钮**，
    /// 锁屏/控制中心上那颗随机键根本不会出现。反过来，注册了却不更新类型，
    /// 系统显示的高亮状态就跟 App 里的对不上。
    private func syncSystemShuffle() {
        let command = MPRemoteCommandCenter.shared().changeShuffleModeCommand
        command.currentShuffleType = mode == .shuffle ? .items : .off
    }

    func play(item: MediaItem) {
        play(items: [item], startIndex: 0)
    }

    // MARK: - 收听位置存档

    /// 上次放的是哪首。放在 UserDefaults 而不是资料库里：这是「播放器状态」，跟媒体文件本身无关。
    private static let lastIDKey = "playback.lastItemID"
    /// 每一首各自听到哪（条目 id → 秒数）。**按条目分开存**，不是只存一个位置：
    /// 切走再切回来要接着听，只存「最后一首」的话回来就从头了。
    private static let positionsKey = "playback.positions"
    /// 旧版本的单条存档键，只为了让升级那一刻不白丢位置，见 `migrateLegacySavePoint()`。
    private static let lastElapsedKey = "playback.lastElapsed"

    private var savedPositions: [String: Double] {
        get { UserDefaults.standard.dictionary(forKey: Self.positionsKey) as? [String: Double] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: Self.positionsKey) }
    }

    /// 这一首听到哪了（没听过返回 nil）。
    func savedPosition(for id: String) -> Double? { savedPositions[id] }

    /// 旧版本只存「单独一个位置」，升级后并进按条目存的表里，免得上次听到的地方白丢一次。
    /// 迁完立刻删掉旧键，所以只可能跑一次。
    private func migrateLegacySavePoint() {
        let defaults = UserDefaults.standard
        guard let legacyID = defaults.string(forKey: Self.lastIDKey),
              defaults.object(forKey: Self.lastElapsedKey) != nil else { return }
        let legacy = defaults.double(forKey: Self.lastElapsedKey)
        if legacy > 1 {
            var map = savedPositions
            map[legacyID] = legacy
            savedPositions = map
        }
        defaults.removeObject(forKey: Self.lastElapsedKey)
    }

    // MARK: - 冷启动续播

    /// 续播入口：**只在冷启动调一次**（`RootView` 的 `.task`），切回前台不要调 ——
    /// 从后台回来时音频本来就在放，再调一次会把正在听的那首从头/从存档点打断。
    ///
    /// 队列口径 = 整个资料库，这样续播起来之后「上一首/下一首」和手动点播一致。
    func resumeLastPlayback(from items: [MediaItem]) {
        // 已经有东西在播就别抢（比如后台恢复场景），空库也没什么可放的
        guard currentID == nil, !items.isEmpty else { return }

        // 这里只读「上次放的是哪首」；「听到哪」由 `startCurrent` 里的 `restorePosition` 统一负责。
        // 不在这里自己 seek —— 两处都 seek 会互相打架，而且那时候 `duration` 还没加载出来。
        let savedID = UserDefaults.standard.string(forKey: Self.lastIDKey)
        // 上次那首被删了就退回第一首：用户要的是「打开就有声」，不是「精确回到某首」
        let start = savedID.flatMap { id in items.firstIndex { $0.id == id } } ?? 0

        DouyinDebug.log(savedID != nil && items[start].id == savedID
            ? "冷启动续播：接上次那首《\(items[start].title)》"
            : "冷启动续播：没有存档（或那首已被删），从第一首《\(items[start].title)》开始")
        play(items: items, startIndex: start)
    }

    /// 记下当前这首听到哪了。不逐帧写盘：切歌、暂停、进后台，以及播放中每 5 秒兜底一次。
    func savePosition() {
        guard let id = currentID, !isScrubbing else { return }
        // 试听期间不存档：试听是「借这首放一小段」，用户并没有真的听到这儿。
        // 存了的话下次续播会接到试听的那 3 秒上（试听结尾时就是那个结尾点），
        // 而试听结束本来就会把位置还原回 `origin`。
        guard previewRange == nil else { return }
        var map = savedPositions
        // 停在片尾就记 0：否则下次切回来一进去就是「已经放完」，直接跳下一首。
        // ⚠️ 「片尾」的判据是 `effectiveEnd`，不是 `duration` —— 设了跳过结尾的曲子
        // 会停在 `duration - 结尾秒数`，那一刻离真实末尾还差好几秒，
        // 用 `duration` 判的话会把「已播完」的位置原样存下来。
        let end = effectiveEnd > 0 ? effectiveEnd : duration
        let position = (end > 0 && elapsed >= end - 1) ? 0 : max(0, elapsed)
        map[id] = position
        savedPositions = map
        UserDefaults.standard.set(id, forKey: Self.lastIDKey)
        DouyinDebug.log("存档《\(currentTitle)》：\(Int(position))s / \(Int(duration))s")
    }

    func next() {
        guard hasNext else { return }
        index += 1
        startCurrent(restoringPosition: true)
    }

    func previous() {
        // 音乐 App 的习惯：播放 3 秒内按上一首才真的切歌，否则回到开头
        if elapsed > 3, currentID != nil {
            seek(toSeconds: 0)
            return
        }
        guard hasPrevious else {
            seek(toSeconds: 0)
            return
        }
        index -= 1
        startCurrent(restoringPosition: true)
    }

    /// - Parameter restoringPosition: 换成这一首后要不要接上它上次听到的地方。
    ///   手动切歌要接（「切走再切回来不用重听」）；**放完自动跳下一首要传 false** ——
    ///   一首歌唱完了自然想听下一首的开头，这时候把下一首拉到二十分钟处是惊吓不是贴心。
    private func startCurrent(restoringPosition: Bool) {
        guard let item = currentItem else { return }

        // 存档「正要离开的那首」，必须在 `currentID` 被改写**之前**：
        // 位置是挂在 currentID 上的，换掉之后就再也取不到了。
        savePosition()

        // 换歌就丢掉试听状态 —— 这里是「当前这首"变成别的"」的唯一入口，
        // 放在这儿就不必在 next/previous/自动切歌/手动点歌各处各防一次。
        // 不清的话 `activeEnd` 还锁在上一段的区间结尾上，新这首会被那个数字管着
        // （进度条画错、到头就切歌），`finishAtTrim` 也会把它的自然结束当成试听收尾。
        // `preview()` 是在 `play()` **之后**才挂上区间的，所以这里清不会误伤它。
        previewRange = nil

        player.replaceCurrentItem(with: AVPlayerItem(url: fileResolver(item)))
        currentID = item.id
        currentTitle = item.title
        elapsed = 0
        duration = item.durationSec ?? 0
        artwork = artworkLoader(item).flatMap { UIImage(contentsOfFile: $0.path) }
        currentKind = item.kind
        showsVideo = item.kind.hasPicture
        player.play()
        isPlaying = true
        updateNowPlaying()
        if restoringPosition { restorePosition(for: item) } else { applyIntroSkip(for: item) }
    }

    /// 跳到这首设好的起点（「跳过前奏」）。没设过就什么都不做。
    ///
    /// ⚠️ 只在**从头放**的时候调（`restoringPosition == false`）。两个机制会打架：
    /// 「续播」是「上次听到哪」，「跳过前奏」是「这首该从哪起」——
    /// 如果续播点（比如 1:30）比前奏起点（比如 0:12）更靠后，再跳回 0:12 是把用户往回拽；
    /// 反过来续播点还在前奏里（0:05）就该跳到 0:12。所以**取两者更靠后的那个**
    /// （这条路径由 `restorePosition` 负责，见那里）。
    ///
    /// 真机上「自动跳下一首」走的就是 `restoringPosition == false` 这条，
    /// 所以放完一首接下一首时前奏照样会被跳过 —— 这正是用户要的。
    private func applyIntroSkip(for item: MediaItem) {
        let skip = IntroSkip.shared.start(for: item.id)
        guard skip > 0 else { return }
        // 起点比整首还长当没设（`IntroSkip` 里已经挡了 6 小时以上的脏值，
        // 这里防的是「时长很短的歌设了一个较大的起点」这种合理但会跳过头的组合）
        if duration > 0, skip >= duration - 1 { return }
        // ⚠️ `duration` 是 `item.durationSec`（索引里记的），**可能为 nil/0**：
        // 那就落到一个「还没落到」的位置 —— 跟 `restorePosition` 同一个坑。
        // `seekDirectly` 用的正是「AVPlayer 会挂起这个 seek、等条目就绪后自己执行」，
        // 所以这里不需要等时长加载完，直接落即可。
        seekDirectly(toSeconds: skip)
        DouyinDebug.log("跳过前奏：《\(item.title)》从 \(Int(skip))s 起（省掉开头 \(Int(skip))s）")
    }

    /// 接上这一首上次听到的地方。门槛 1 秒：比这更短说明上次基本没听，从头放更符合直觉。
    private func restorePosition(for item: MediaItem) {
        // ⚠️ 起点要跟「跳过前奏」**取更靠后的那个**：续播点可能落在前奏里
        // （上次听了 5 秒就退出，而前奏起点是 12 秒），那时该往前跳到 12 秒，
        // 而不是从 5 秒接着听前奏。反过来续播点已经过了前奏（1:30）就别往回拽。
        let skip = IntroSkip.shared.start(for: item.id)
        var saved = savedPositions[item.id] ?? 0
        // 存档时停在片尾本来就记 0（见 `savePosition`），这里是防旧数据的第二道闸
        let total = item.durationSec ?? 0
        if total > 0, saved >= total - 1 { saved = 0 }

        let target = max(saved, skip)
        guard target > 1 else { return }
        // 夹到 `endTrim`：设了跳过结尾的曲子，存档点有可能落在剪掉的那一段里
        // （用户上一次拖到过末尾）。不夹的话这次会先落在那里，再被自动切歌。
        let end = IntroSkip.shared.endTrim(for: item.id)
        let ceiling = total > 0 && end > 0 && end < total - 1 ? total - end : target
        seekDirectly(toSeconds: min(target, max(ceiling, target)))
        if skip > saved {
            DouyinDebug.log("跳过前奏：《\(item.title)》从 \(Int(skip))s 起（续播点 \(Int(saved))s 还在前奏里）")
        } else {
            DouyinDebug.log("切歌续播：《\(item.title)》从 \(Int(saved))s 接上")
        }
    }

    /// 当前这首设的跳过起点（没设过返回 0）。
    var currentIntroSkip: Double {
        IntroSkip.shared.start(for: currentID)
    }

    /// 把「当前位置」设成这首的跳过起点 —— 这就是「听到开唱了，点一下」那个动作。
    /// 立刻生效（当前这首正在放，不重放），下次再放这首就从这里起。
    func markIntroEndHere() {
        guard let id = currentID, elapsed > 0 else { return }
        IntroSkip.shared.setStart(elapsed, for: id)
        DouyinDebug.log("设跳过前奏：《\(currentTitle)》起点 \(Int(elapsed))s")
    }

    /// 把这位置设成「跳过结尾」的提前量 —— 即「从这里开始就不要了」。
    /// 用时长减去当前位置得到提前量，存的是提前量而不是绝对秒数：
    /// 同一个文件重下、或时长有微小差异时，从末尾倒数的口径仍然成立。
    func markEndTrimHere() {
        guard let id = currentID, duration > 0, elapsed > 0 else { return }
        IntroSkip.shared.setEndTrim(duration - elapsed, for: id)
        DouyinDebug.log("设跳过结尾：《\(currentTitle)》从 \(Int(elapsed))s 起不要（末尾省 \(Int(duration - elapsed))s）")
    }

    /// 取消这首的跳过开头。
    func clearIntroSkip() {
        guard let id = currentID else { return }
        IntroSkip.shared.setStart(0, for: id)
        DouyinDebug.log("取消跳过前奏：《\(currentTitle)》")
    }

    /// 到了 `activeEnd` 之后的收尾。**三种情形全在这里判**（试听 / 有下一首 / 最后一首）——
/// 判据只有一处，别在调用点再分叉一次。
///
/// 为什么需要它：`elapsed` 会一路涨到 `activeEnd`，到了之后这个条件每 0.5 秒都成立。
/// 不在这里收掉就变成空转（而且每次都打日志）。
private func finishAtTrim() {
        // ⚠️ 试听结束**绝不能当成「这首放完了」**：那会切到下一首。
        // 用户点的是「试听一下开头/结尾这几秒」，不是「这首听完了，下一首吧」——
        // 试听一结束就被扔到别的歌上，比不放还糟。这里只收掉试听、回原位。
        // ⚠️ 这条必须排在 `hasNext` **前面**，而且调用点不能提前判 `hasNext`
        // （踩过：`hasNext` 为真时直接切歌，这条保护根本走不到）。
        if previewRange != nil {
            endPreview()
            return
        }
        if hasNext {
            index += 1
            startCurrent(restoringPosition: false)
            return
        }
        // 最后一首：停在 activeEnd，标记为「放完了」
        DouyinDebug.log("跳过结尾：《\(currentTitle)》在第 \(Int(effectiveEnd))s 结束（末尾省掉 \(Int(IntroSkip.shared.endTrim(for: currentID)))s）")
        player.pause()
    }

    // MARK: - 试听（「跳过开头/结尾」编辑框里用）

    /// 按**还没保存**的数字试听 `[from, to]`：跳到这首、放这一段、到点自己停。
    ///
    /// 能直接把区间盖在主播放器上，是因为它本来就有一条完整的播放链路
    /// （AVPlayer、锁屏、动画封面都在上面），试听要的正是「跟真放一样，只是区间不同」。
    /// 另开一路 AVPlayer 反而要再养一套这些东西，还要处理「两路声音谁说了算」。
    ///
    /// ⚠️ 换一首试听时**不还原回原来那首**。用户是从编辑框里点进来的，
    /// 意图就是「听这首改完什么样」—— 试听一结束把他扔回上一首，
    /// 那他想接着听这首还得再点一次，比不放还烦。这里就停在这首上。
    /// 同一首上试听则相反：要还回原位，因为那次点击完全没打算换歌。
    func preview(item: MediaItem, from: Double, to: Double, using items: [MediaItem]) {
        guard to > from else { return }
        let sameTrack = currentID == item.id

        // 已经在这首上试听：只换区间，**不要重头再来**，也别把 `origin` 覆盖成
        // 当前（已经被前一次试听拖走的）位置。否则连点几次试听，`origin` 会一路
        // 漂到试听区间里去，结束时「回到原位」就回不去了。
        if var existing = previewRange, sameTrack {
            existing = PreviewRange(from: from, to: to,
                                    origin: existing.origin,
                                    wasPlaying: existing.wasPlaying)
            previewRange = existing
            seekDirectly(toSeconds: from)
            if !isPlaying { play() }
            DouyinDebug.log("试听（改区间）：《\(item.title)》\(Self.format(from)) → \(Self.format(to))")
            return
        }

        // 同一首：记下原位。换一首：没有原位可回。
        let origin: Double? = sameTrack ? elapsed : nil
        let wasPlaying = sameTrack && isPlaying
        endPreview()

        let queueIndex = items.firstIndex { $0.id == item.id } ?? 0
        play(items: items, startIndex: queueIndex)
        // ⚠️ 顺序在 `play` **之后**：`play` 会走 `startCurrent`，那里按存档设置 seek
        // （跳过开头/结尾、续播位置）。先设试听区间的话那一步还得再判一次；
        // 放在后面，接着自己的 seek 就一步到位、也不会闪一下旧的位置。
        previewRange = PreviewRange(from: from, to: to, origin: origin, wasPlaying: wasPlaying)
        seekDirectly(toSeconds: from)
        // 起播失败（比如这首正好被删了）也别把试听状态留在那儿
        guard currentID == item.id else {
            previewRange = nil
            return
        }
        DouyinDebug.log("试听：《\(item.title)》\(Self.format(from)) → \(Self.format(to))"
                        + "（\(sameTrack ? "同一首，原位 \(Int(origin ?? 0))s" : "换了首歌，不还原")）")
    }

    /// 结束试听。同一首上试听就回到原位；换了一首就停在这首上（理由见 `preview`）。
    func endPreview() {
        guard let p = previewRange else { return }
        previewRange = nil
        guard let origin = p.origin else {
            // 换歌试听：不换回原曲，但**回到这首的开头**再停。
            // 不能把播放头留在试听区间的结尾点上 —— 用户再点一次试听时，
            // 那时的「原位」就取成这个结尾点，试听结束会被丢在曲子末尾，
            // 看着像"跳到这里就停了"，很怪。回到 0:00 是唯一稳定的落点。
            seekDirectly(toSeconds: 0)
            pause()
            DouyinDebug.log("试听结束：《\(currentTitle)》停在这首开头（未换回原曲）")
            return
        }
        seekDirectly(toSeconds: origin)
        if !p.wasPlaying { pause() }
        DouyinDebug.log("试听结束：《\(currentTitle)》回到 \(Int(origin))s")
    }

    // MARK: - 真机自检（`D2M_*` 环境变量触发）

    /// 调试用：`D2M_JUMP_DEMO=1` 时自动「听 6 秒 → 下一首 → 再 6 秒 → 切回来」。
    /// 手机没法从命令行点按钮，「切走再切回来接上位置」这条路径在真机上就没法验，
    /// 只能让代码自己走一遍、把结论打进日志。链路（存档 → 切歌 → 接位置）全走真实实现，不造假数据。
    func runJumpDemoIfRequested() async {
        guard ProcessInfo.processInfo.environment["D2M_JUMP_DEMO"] == "1" else { return }
        guard currentID != nil else {
            DouyinDebug.log("跳转演示：没有在放的东西，跳过")
            return
        }
        try? await Task.sleep(for: .seconds(6))
        DouyinDebug.log("跳转演示：切下一首")
        next()
        try? await Task.sleep(for: .seconds(6))
        DouyinDebug.log("跳转演示：切回上一首（应该接上刚才离开的位置）")
        // 不走 `previous()`：那里有「播放 3 秒内按上一首才真切歌」的规矩，
        // 而这里已经听了 6 秒，会被它当成「回到本首开头」而不是切回去。
        guard hasPrevious else { return }
        index -= 1
        startCurrent(restoringPosition: true)
    }

    /// 调试用：`D2M_MODE_DEMO=1` 时把两种播放模式各走一遍，把「下一首到底跳到哪」
    /// 打进日志。真机上点不了那枚按钮（没法从命令行敲 UI），所以让代码自己走真实链路
    /// （`setMode` → `next`），不造假数据。
    ///
    /// 判据：顺序模式下第 N 首的下一首必须是第 N+1 首；随机模式下连切若干首
    /// 不该出现重复（洗完一轮才重复），而且**起点那首必须真的在放**。
    func runModeDemoIfRequested() async {
        guard ProcessInfo.processInfo.environment["D2M_MODE_DEMO"] == "1" else { return }
        guard !queue.isEmpty else {
            DouyinDebug.log("模式演示：队列为空，跳过")
            return
        }
        func report(_ tag: String) {
            // 只打**顺序号**不打歌名：名字里带括号和中文，读日志时反而看不清是不是同一首。
            let seq = order.enumerated().map { $0.offset == index ? "[\($0.element)]" : "\($0.element)" }
            DouyinDebug.log("模式演示 \(tag)：模式=\(mode.label) 位置=\(index)/\(order.count) 排列=\(seq.joined(separator: ",")) 在放《\(currentTitle)》")
        }
        report("起点")

        setMode(.sequence)
        report("切到顺序")

        // 顺序模式连切 3 首，应当规规矩矩往后走
        for i in 1...3 {
            guard hasNext else { DouyinDebug.log("模式演示：顺序模式已到队尾，停"); break }
            next()
            DouyinDebug.log("模式演示 顺序第\(i)次下一首 → 《\(currentTitle)》")
        }

        setMode(.shuffle)
        report("切到随机")

        // 随机模式连切，检查一轮内不重复
        var seen: [String] = [currentID ?? "?"]
        for _ in 1...min(8, max(1, order.count - 1)) {
            guard hasNext else { break }
            next()
            let id = currentID ?? "?"
            if seen.contains(id) {
                DouyinDebug.log("模式演示 ⚠️ 随机一轮内出现重复：\(seen.count) 次后撞上同一首")
            }
            seen.append(id)
        }
        DouyinDebug.log("模式演示 随机连切 \(seen.count - 1) 首，去重后 \(Set(seen).count) 首（相等=没重复）")

        setMode(.sequence)
        report("切回顺序")
    }

    /// 调试用：`D2M_PREVIEW_DEMO=1` 时走一遍「试听」这条真实链路。
    ///
    /// 这条链路最要紧的两条不变量，恰恰是命令行点不到 UI 就验不了的：
    /// 1. **试听区间压过存档设置** —— 编辑框里填的还没保存，试听必须先认填的那个；
    /// 2. **试听到点不能当成「这首放完了」** —— 那会切下一首，用户点的是试听，
    ///    结果被扔到别的歌上。收尾必须是「停在这首」。
    func runPreviewDemoIfRequested() async {
        guard ProcessInfo.processInfo.environment["D2M_PREVIEW_DEMO"] == "1" else { return }
        guard queue.count >= 2 else {
            DouyinDebug.log("试听演示：队列不足 2 首，跳过")
            return
        }
        // 拿第二首试听：它会顺带验「试听会把播放切到这首」。
        let target = queue[1]

        setMode(.sequence)
        play(items: queue, startIndex: 0)
        try? await Task.sleep(for: .seconds(2))
        let beforeID = currentID
        let beforeElapsed = elapsed

        // 区间取开头 4 秒 → 第 7 秒。够短，能等到它自然收尾。
        let from = min(4.0, max(0, duration - 1))
        let to = max(from + 3, from + 1)
        preview(item: target, from: from, to: to, using: queue)
        DouyinDebug.log("试听演示 起播：《\(currentTitle)》elapsed=\(Int(elapsed))s 区间=\(Int(from))→\(Int(to))s"
                        + " activeEnd=\(Int(activeEnd))s 在放=\(isPlaying) 试听中=\(isPreviewing)")

        // 等这一段放完 + 2 秒余量（周期观察者是 0.5 秒一轮）
        try? await Task.sleep(for: .seconds(max(1, to - from) + 3))

        // 判据给成**明白的是/否**，别只打事实让读日志的人自己比对 ——
        // 这条正是最容易错的地方，错了要一眼看出来。
        let stayed = currentID == target.id
        let ended = !isPreviewing
        DouyinDebug.log("试听演示 收尾：还在《\(currentTitle)》上=\(stayed)"
                        + " 试听已结束=\(ended) elapsed=\(Int(elapsed))s")
        if stayed, ended {
            DouyinDebug.log("试听演示 ✅ 通过：到点自己停了，没被切到下一首")
        } else if !stayed {
            DouyinDebug.log("试听演示 ❌ 失败：试听到点被切到了《\(currentTitle)》（应当停在试听那首）")
        } else {
            DouyinDebug.log("试听演示 ❌ 失败：试听状态没在到点时收掉（isPreviewing 仍为 true）")
        }
        DouyinDebug.log("试听演示 比对：试听前在《\(beforeID ?? "nil")》第 \(Int(beforeElapsed))s；"
                        + "现在 currentID=\(currentID ?? "nil")")
    }

    func toggle() {
        guard currentID != nil else { return }
        // 以播放器的真实状态为准，不看界面上的图标
        if player.timeControlStatus == .playing {
            player.pause()
        } else {
            player.play()
        }
    }

    /// 暂停。给「跳过开头/结尾」编辑框里的试听用：试听期间不能让两边同时出声。
    func pause() {
        guard player.timeControlStatus == .playing else { return }
        toggle()
    }

    /// 继续放。跟 `pause()` 配对，是试听结束后还原「刚才本来就在放」的状态。
    func play() {
        guard currentID != nil, player.timeControlStatus != .playing else { return }
        toggle()
    }

    /// 直接落到 AVPlayer（进度条松手、遥控快进快退都走这里）。
    /// 三处都不能省：
    /// 1. `elapsed` 乐观更新 —— `player.seek` 是异步的，不等它回来就写，
    ///    否则周期观察者下一次回写的是**旧**位置，进度条松手就弹回去。
    /// 2. `toleranceBefore/After: .zero` —— 默认容差是 `.positiveInfinity`，语义上是「就近落点」（视频可能落到关键帧）。
    ///    实测本机这些 mp3/mp4 默认容差也精确落点，所以它**不是**「拖不动」的原因；
    ///    零容差只是把落点钉死、手感可预期，代价实测可忽略（2 小时 MP3 单次 seek ~0ms）。
    /// 3. 立刻 `updateNowPlaying()` —— 锁屏/控制中心的进度要跟着走，不然得等 0.5s。
    func seek(to ratio: Double) {
        // 分母用 `activeEnd` —— 跟 `progress` 是同一个刻度。用 `duration` 的话，
        // 设了跳过结尾（比如提前 12 秒）进度条拖到最右会落到真实末尾，
        // 也就是**跳进那段本该剪掉的部分**，然后立刻被切歌。
        let end = activeEnd
        guard end > 0 else { return }
        let target = CMTime(seconds: end * min(max(ratio, 0), 1), preferredTimescale: 600)
        elapsed = target.seconds
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        updateNowPlaying()
    }

    /// 按绝对秒数跳（锁屏进度条、遥控命令用）。
    /// 也夹到 `activeEnd`：锁屏上拖到最右同样是「落到该结束的地方」，不是真实末尾。
    func seek(toSeconds seconds: Double) {
        let end = activeEnd
        guard end > 0 else { return }
        seek(to: min(seconds, end) / end)
    }

    /// 直接落一个绝对秒数，不经过 `progress`。
    /// 续播要用它：那一刻 `duration` 可能还是 0（`MediaItem.durationSec` 是可选的，
    /// 真实时长要等 AVPlayerItem 加载完才知道），走 `seek(toSeconds:)` 会因为 `duration == 0` 直接返回、落不下去。
    /// AVPlayer 会把这个 seek 挂起，等条目就绪后自己执行。
    private func seekDirectly(toSeconds seconds: Double) {
        let target = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        elapsed = target.seconds
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        updateNowPlaying()
    }

    // MARK: - 拖动进度条

    /// 拖动期间为 true：UI 上的位置改由手指决定，周期观察者让位。
    private var isScrubbing = false

    /// 上次写续播存档的时间，用来把播放中的兜底存档节流到 5 秒一次。
    private var lastSavedAt = Date.distantPast

    /// 手指按住进度条。
    func beginScrubbing() {
        guard duration > 0 else { return }
        isScrubbing = true
    }

    /// 手指移动：只改界面（进度条 + 时间标签），不碰 AVPlayer。
    /// 逐帧 seek 会把播放器打成一串互相取消的请求，也没必要 —— 松手一次落到位。
    func scrub(to ratio: Double) {
        let end = activeEnd
        guard end > 0 else { return }
        // 刻度跟 `seek(to:)` 一致（都用 `activeEnd`），否则松手那一下会跳。
        elapsed = end * min(max(ratio, 0), 1)
    }

    /// 松手：落到真实位置。
    func endScrubbing() {
        guard isScrubbing else { return }
        isScrubbing = false
        seek(to: progress)
    }

    func stop() {
        // 试听状态一并清掉：播放器都要停了，没有"这一段"可言了
        previewRange = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        queue = []
        order = []
        index = 0
        isPlaying = false
        currentID = nil
        currentTitle = ""
        currentKind = .video
        artwork = nil
        elapsed = 0
        duration = 0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    // MARK: - 内部

    private func configureSession() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback)
        try? session.setActive(true)
    }

    private func addTimeObserver() {
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            Task { @MainActor in
                guard let self else { return }
                // 正在拖进度条：这一轮的位置由手指说了算，别回写（回写就把进度条拽回去了），
                // 也别在这里判「播完了」—— 拖到末尾不等于这首放完了。
                guard !self.isScrubbing else { return }
                self.elapsed = time.seconds.isFinite ? time.seconds : 0
                if let itemDuration = self.player.currentItem?.duration.seconds,
                   itemDuration.isFinite, itemDuration > 0 {
                    self.duration = itemDuration
                }
                // 播完自动下一首。**不接上次位置**（见 `startCurrent(restoringPosition:)`）：
                // 一首刚放完，下一首该从开头起，而不是跳到它上次被听到一半的地方。
                //
                // ⚠️ 判据用 `activeEnd` 而不是 `duration`：设了「跳过结尾」的歌
                // 该在 `activeEnd` 处就切走，而不是放到真实末尾（那正是用户要剪掉的部分）。
                // 试听时 `activeEnd` 就是试听区间的结尾点，所以试听到点会自己收尾。
                let end = self.activeEnd
                if self.isPlaying, end > 0, self.elapsed >= end - 0.25 {
                    // ⚠️ **无条件交给 `finishAtTrim()` 决定**，别在这里先判 `hasNext`。
                    // 这里曾经写的是 `if self.hasNext { 切下一首 } else { finishAtTrim() }`，
                    // 而「试听不能切歌」那条保护在 `finishAtTrim()` 里 —— 于是
                    // `hasNext` 为真时**根本走不到**那个保护，试听一放完就跳到下一首。
                    // 实测就是这么暴露的（`D2M_PREVIEW_DEMO=1`）：
                    //   试听演示 起播：《安靜》区间=4→7s activeEnd=7s 试听中=true
                    //   试听演示 收尾：还在《茄子蛋 浪子回頭》上=false   ← 被切走了
                    // 收尾的三种情形（试听结束 / 有下一首 / 最后一首）现在都只在
                    // `finishAtTrim()` 一个地方判，**判据只有一处**，不会再分叉。
                    self.finishAtTrim()
                }
                // 播放中兜底存档：进程被系统直接杀掉（没走到暂停/进后台）时靠它。
                // 不必每 0.5 秒都写盘，5 秒的粒度对这个用途足够。
                if Date().timeIntervalSince(self.lastSavedAt) > 5 {
                    self.lastSavedAt = Date()
                    self.savePosition()
                }
                self.updateNowPlaying()
            }
        }
    }

    private func observePlaybackStatus() {
        statusObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            Task { @MainActor in
                guard let self else { return }
                switch player.timeControlStatus {
                case .playing:
                    self.isPlaying = true
                case .paused:
                    self.isPlaying = false
                    // 暂停是最容易「一停就是几小时、然后进程被杀掉」的时刻，这里必须存
                    self.savePosition()
                default:
                    // waitingToPlayAtSpecifiedRate：只是在等待缓冲，先保持现状
                    break
                }
                self.updateNowPlaying()
            }
        }
    }

    private func registerRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.isPlaying else { return }
                self.toggle()
            }
            return .success
        }
        center.pauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isPlaying else { return }
                self.toggle()
            }
            return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.toggle() }
            return .success
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.next() }
            return .success
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            Task { @MainActor in self?.previous() }
            return .success
        }
        // 锁屏 / 控制中心的**进度条**：不注册这个命令，系统就不会把拖动接进来 ——
        // 表现为「锁屏上进度条根本拖不动」。
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let position = (event as? MPChangePlaybackPositionCommandEvent)?.positionTime else {
                return .commandFailed
            }
            Task { @MainActor in self?.seek(toSeconds: position) }
            return .success
        }
        // 锁屏 / 控制中心的**随机键**。注册了它，系统才会在「正在播放」里给出随机按钮；
        // 不注册就只有一个顺序播放的界面，用户得打开 App 才能切。
        // 事件带的是「系统认为该切到哪种模式」，直接照办即可。
        center.changeShuffleModeCommand.addTarget { [weak self] event in
            guard let type = (event as? MPChangeShuffleModeCommandEvent)?.shuffleType else {
                return .commandFailed
            }
            Task { @MainActor in self?.setMode(type == .off ? .sequence : .shuffle) }
            return .success
        }
        center.changeShuffleModeCommand.isEnabled = true

        // ⚠️ 这里**只启用** play/pause、next/previous、changePlaybackPosition，**刻意不启用**
        // skipForward/Backward（±15 秒）：锁屏那块「正在播放」小组件只有三个按钮位，系统在
        // 「启用了 skip」时会用 ±15 顶掉 ⏮/⏭，两组不会同时出现 —— 切歌就从锁屏上消失了。
        // 取舍：切歌是锁屏上更高频的操作，而「跳一段」有上面那条进度条兜着（能落任意位置）。
        // 不启用时系统也会自己禁用按钮，所以必须 `isEnabled = false` 显式关掉。
        // 若哪天改回 ±15，`preferredIntervals` 是 [NSNumber]：Double 字面量不能隐式桥接，
        // 要写 [NSNumber(value: 15.0)]。
        center.skipForwardCommand.isEnabled = false
        center.skipBackwardCommand.isEnabled = false
        // 开局把系统那边的随机状态对齐到本 App 存的偏好，不然锁屏上的高亮是默认的「关」，
        // 跟 App 里显示的模式可能相反。
        syncSystemShuffle()
    }

    private func updateNowPlaying() {
        guard currentID != nil else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: currentTitle,
            MPMediaItemPropertyArtist: "Music",
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
        if duration > 0 {
            // ⚠️ 交的必须是 `effectiveEnd`，不是 `duration`。锁屏/控制中心那条进度条
            // 是按这个数画的：给真实时长，设了跳过结尾的歌在系统那条进度条上
            // 就永远走不到头（到 App 里该结束的地方时还差一截）。
            info[MPMediaItemPropertyPlaybackDuration] = activeEnd
        }
        // 动画封面（萌宠）：播放时系统会在灵动岛/锁屏的「正在播放」里**播这段循环视频**。
        // 只在播放中给 —— 暂停时给一段还在动的封面会很怪，静态图反而对。
        //
        // ⚠️ 实例**复用**，不是每次都 new。`make()` 造出来的对象里握着两个
        // async handler，`artworkID` 是它的身份 —— 每 0.5 秒塞一个全新实例进
        // nowPlayingInfo，系统看到的是一份「换了身份的封面」，很可能每次都被
        // 当成新封面重新解析，循环播放就永远起不来。
        let animated = isPlaying ? AnimatedArtwork.sharedIfAvailable() : nil
        let animatedKey = animated == nil ? nil : AnimatedArtwork.artworkKey

        // 用户定的是「封面**只要萌宠**」——那就别再把真封面同时交上去。
        // 两个都在时系统会自己挑一个（实测挑的是真封面那张静态图），
        // 把静态那份拿掉，能交的就只剩动画封面了。
        if animatedKey == nil {
            if let artwork {
                info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: artwork.size) { _ in artwork }
            }
            AnimatedArtwork.diagnoseIfNeeded()
        }
        if let animated, let animatedKey {
            info[animatedKey] = animated
        }
        AnimatedArtwork.logWrite(animatedKey)

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        // ⚠️ 必须设 `playbackState`。头文件的注释点名了它：
        // 「App 开始或停止播放时必须设置，否则遥控功能可能不按预期工作」。
        // 实测：只给 `nowPlayingInfo` 里的 `PlaybackRate` 是不够的 ——
        // 系统不认这是「正在播放」，动画封面**一次都不会来取**（handler 不调用）。
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
    }

    private static func format(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
