// 用途：全局播放器。锁屏与后台播放靠 audio 会话 + Now Playing；视频画面在后台时主动摘除，保证声音不中断。
import AVFoundation
import MediaPlayer

@MainActor
final class MediaPlayer: ObservableObject {
    @Published private(set) var currentID: String?
    @Published private(set) var currentTitle: String = ""
    @Published private(set) var isPlaying = false
    @Published private(set) var elapsed: Double = 0
    @Published private(set) var duration: Double = 0
    /// 后台播放时摘掉画面，避免 iOS 暂停视频渲染导致声音中断。
    @Published var showsVideo = true
    /// 是否展开全屏播放页。
    @Published var isExpanded = false

    let player = AVPlayer()
    private var timeObserver: Any?

    init() {
        configureSession()
        addTimeObserver()
        registerRemoteCommands()
    }

    var progress: Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, elapsed / duration))
    }

    var elapsedText: String { Self.format(elapsed) }
    var durationText: String { Self.format(duration) }

    func play(item: MediaItem, url: URL) {
        if currentID != item.id {
            player.replaceCurrentItem(with: AVPlayerItem(url: url))
            currentID = item.id
            currentTitle = item.title
            elapsed = 0
            duration = item.durationSec ?? 0
        }
        showsVideo = true
        player.play()
        isPlaying = true
        updateNowPlaying()
    }

    func toggle() {
        guard currentID != nil else { return }
        if isPlaying {
            player.pause()
        } else {
            player.play()
        }
        isPlaying.toggle()
        updateNowPlaying()
    }

    func seek(to ratio: Double) {
        guard duration > 0 else { return }
        player.seek(to: CMTime(seconds: duration * min(max(ratio, 0), 1), preferredTimescale: 600))
    }

    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        isPlaying = false
        currentID = nil
        currentTitle = ""
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
    }

    private func updateNowPlaying() {
        guard currentID != nil else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: currentTitle,
            MPMediaItemPropertyArtist: "抖音",
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
        if duration > 0 {
            info[MPMediaItemPropertyPlaybackDuration] = duration
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private static func format(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
