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
    }

    var hasNext: Bool { index + 1 < queue.count }
    var hasPrevious: Bool { index > 0 }

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

    func play(items: [MediaItem], startIndex: Int) {
        queue = items
        index = max(0, min(startIndex, max(0, items.count - 1)))
        startCurrent()
    }

    func play(item: MediaItem) {
        play(items: [item], startIndex: 0)
    }

    func next() {
        guard hasNext else { return }
        index += 1
        startCurrent()
    }

    func previous() {
        // 音乐 App 的习惯：播放 3 秒内按上一首才真的切歌，否则回到开头
        if elapsed > 3, currentID != nil {
            player.seek(to: .zero)
            return
        }
        guard hasPrevious else {
            player.seek(to: .zero)
            return
        }
        index -= 1
        startCurrent()
    }

    private func startCurrent() {
        guard queue.indices.contains(index) else { return }
        let item = queue[index]

        player.replaceCurrentItem(with: AVPlayerItem(url: fileResolver(item)))
        currentID = item.id
        currentTitle = item.title
        elapsed = 0
        duration = item.durationSec ?? 0
        artwork = artworkLoader(item).flatMap { UIImage(contentsOfFile: $0.path) }
        showsVideo = true
        player.play()
        isPlaying = true
        updateNowPlaying()
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

    func seek(to ratio: Double) {
        guard duration > 0 else { return }
        player.seek(to: CMTime(seconds: duration * min(max(ratio, 0), 1), preferredTimescale: 600))
    }

    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        queue = []
        index = 0
        isPlaying = false
        currentID = nil
        currentTitle = ""
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
                self.elapsed = time.seconds.isFinite ? time.seconds : 0
                if let itemDuration = self.player.currentItem?.duration.seconds,
                   itemDuration.isFinite, itemDuration > 0 {
                    self.duration = itemDuration
                }
                // 播完自动下一首
                if self.isPlaying, self.duration > 0, self.elapsed >= self.duration - 0.25 {
                    if self.hasNext { self.next() }
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
        if let artwork {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: artwork.size) { _ in artwork }
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private static func format(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
