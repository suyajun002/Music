// 用途：全局播放器（音乐 App 的「正在播放」内核）。队列、锁屏信息、封面、后台播放都在这里。
import AVFoundation
import MediaPlayer
import UIKit

@MainActor
final class MediaPlayer: ObservableObject {
    @Published private(set) var currentID: String?
    @Published private(set) var currentTitle: String = ""
    @Published private(set) var isPlaying = false
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
    private var queue: [MediaItem] = []
    private var index = 0
    private var artworkLoader: @MainActor (MediaItem) -> URL? = { _ in nil }
    private var fileResolver: @MainActor (MediaItem) -> URL = { _ in URL(fileURLWithPath: "/dev/null") }

    init() {
        configureSession()
        addTimeObserver()
        observePlaybackStatus()
        registerRemoteCommands()
        migrateLegacySavePoint()
    }

    var hasNext: Bool { index + 1 < queue.count }
    var hasPrevious: Bool { index > 0 }
    /// 当前这首有没有画面可看（音频只显示封面，切画面的按钮也不出现）。
    var currentHasPicture: Bool { currentKind.hasPicture }

    var progress: Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, elapsed / duration))
    }

    var elapsedText: String { Self.format(elapsed) }
    var durationText: String { Self.format(duration) }
    /// 音乐 App 右端显示的是剩余时间。
    var remainingText: String { "-" + Self.format(max(0, duration - elapsed)) }

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
        index = max(0, min(startIndex, max(0, items.count - 1)))
        startCurrent(restoringPosition: true)
        // 起萌宠。放在 `startCurrent` 之后：那时 `currentTitle` 才有值。
        // 起失败不致命（用户可能在系统设置里关了 Live Activities），播放不受影响。
        if let title = queue.indices.contains(index) ? queue[index].title : nil {
            PetActivity.shared.start(title: title)
        }
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
        var map = savedPositions
        // 停在片尾就记 0：否则下次切回来一进去就是「已经放完」，直接跳下一首
        let position = (duration > 0 && elapsed >= duration - 1) ? 0 : max(0, elapsed)
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
        guard queue.indices.contains(index) else { return }
        let item = queue[index]

        // 存档「正要离开的那首」，必须在 `currentID` 被改写**之前**：
        // 位置是挂在 currentID 上的，换掉之后就再也取不到了。
        savePosition()

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
        // 换歌即刷新萌宠（`force` 绕过节流：换歌必须立刻反映，不然标题会停在上一首）
        PetActivity.shared.update(title: item.title, isPlaying: true, force: true)
        if restoringPosition { restorePosition(for: item) }
    }

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

    /// 接上这一首上次听到的地方。门槛 1 秒：比这更短说明上次基本没听，从头放更符合直觉。
    private func restorePosition(for item: MediaItem) {
        guard let saved = savedPositions[item.id], saved > 1 else { return }
        // 存档时停在片尾本来就记 0（见 `savePosition`），这里是防旧数据的第二道闸
        let total = item.durationSec ?? 0
        guard total <= 0 || saved < total - 1 else { return }
        seekDirectly(toSeconds: saved)
        DouyinDebug.log("切歌续播：《\(item.title)》从 \(Int(saved))s 接上")
    }

    func toggle() {
        guard currentID != nil else { return }
        // 以播放器的真实状态为准，不看界面上的图标
        if player.timeControlStatus == .playing {
            player.pause()
        } else {
            player.play()
        }
        // 暂停/继续要立刻反映到萌宠上（绕过节流），不然锁屏上的状态会滞后
        PetActivity.shared.update(title: currentTitle, isPlaying: player.timeControlStatus == .playing, force: true)
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
        guard duration > 0 else { return }
        let target = CMTime(seconds: duration * min(max(ratio, 0), 1), preferredTimescale: 600)
        elapsed = target.seconds
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        updateNowPlaying()
    }

    /// 按绝对秒数跳（锁屏进度条、遥控命令用）。
    func seek(toSeconds seconds: Double) {
        seek(to: duration > 0 ? seconds / duration : 0)
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
        guard duration > 0 else { return }
        elapsed = duration * min(max(ratio, 0), 1)
    }

    /// 松手：落到真实位置。
    func endScrubbing() {
        guard isScrubbing else { return }
        isScrubbing = false
        seek(to: progress)
    }

    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        // 收掉萌宠：音乐停了不该留一张僵尸卡片在锁屏上
        PetActivity.shared.end()
        queue = []
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
                if self.isPlaying, self.duration > 0, self.elapsed >= self.duration - 0.25 {
                    if self.hasNext {
                        self.index += 1
                        self.startCurrent(restoringPosition: false)
                    }
                }
                // 播放中兜底存档：进程被系统直接杀掉（没走到暂停/进后台）时靠它。
                // 不必每 0.5 秒都写盘，5 秒的粒度对这个用途足够。
                if Date().timeIntervalSince(self.lastSavedAt) > 5 {
                    self.lastSavedAt = Date()
                    self.savePosition()
                }
                self.updateNowPlaying()
                // 这里**故意不**碰 Live Activity：它只在歌名/播放状态真的变化时
                // 才需要更新（见 `PetActivity.update` 的注释）。以前这里每 0.5 秒
                // 推一帧想做点头动画，很快耗尽系统更新预算，猫动几下就永远不动了。
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
        // ⚠️ 这里**只启用** play/pause、next/previous、changePlaybackPosition，**刻意不启用**
        // skipForward/Backward（±15 秒）：锁屏那块「正在播放」小组件只有三个按钮位，系统在
        // 「启用了 skip」时会用 ±15 顶掉 ⏮/⏭，两组不会同时出现 —— 切歌就从锁屏上消失了。
        // 取舍：切歌是锁屏上更高频的操作，而「跳一段」有上面那条进度条兜着（能落任意位置）。
        // 不启用时系统也会自己禁用按钮，所以必须 `isEnabled = false` 显式关掉。
        // 若哪天改回 ±15，`preferredIntervals` 是 [NSNumber]：Double 字面量不能隐式桥接，
        // 要写 [NSNumber(value: 15.0)]。
        center.skipForwardCommand.isEnabled = false
        center.skipBackwardCommand.isEnabled = false
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
            info[MPMediaItemPropertyPlaybackDuration] = duration
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
