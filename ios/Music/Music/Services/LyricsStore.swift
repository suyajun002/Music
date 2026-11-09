// 用途：当前这首歌的歌词状态（加载中 / 有 / 没有）。
//
// 一个实例同时喂两个消费者：
//   - 播放页：整段歌词滚动；
//   - `MediaPlayer.updateNowPlaying()`：只取「当前这一句」塞进系统正在播放卡的副标题位
//     （锁屏卡片和灵动岛展开态都只有这一个副标题位，系统卡不支持多行歌词）。
import Combine
import Foundation

@MainActor
final class LyricsStore: ObservableObject {
    enum State: Equatable {
        case idle
        case loading
        case ready(Lyrics)
        case unavailable
    }

    @Published private(set) var state: State = .idle
    /// 自动算出来的歌词偏移（正数 = 歌词延后）。不用用户调。
    @Published private(set) var delay: TimeInterval = 0

    /// 用「代数」而不是 `Task.isCancelled` 判新旧：同一首歌可能被重复触发加载
    /// （恢复播放、重播、从锁屏点进来），只靠取消标志会让旧请求覆盖新状态。
    private var generation = 0

    var lyrics: Lyrics? {
        if case .ready(let value) = state { return value }
        return nil
    }

    /// 当前该显示的那句歌词；没有歌词时返回 nil，调用方自己决定回退成什么。
    func line(at time: TimeInterval) -> String? {
        guard let lyrics, let index = lyrics.index(at: time, delay: delay) else { return nil }
        let text = lyrics.lines[index].text.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }

    func load(id: String?, title: String, duration: Double) async {
        generation += 1
        let current = generation
        delay = 0

        guard !title.isEmpty else {
            state = .idle
            return
        }
        state = .loading
        // 下载时已经备好的歌词直接从本地读；老条目/上次失败的才走网络。
        let result = await LyricsSync.lyrics(id: id, title: title, duration: duration)
        guard current == generation else { return }
        if let result {
            delay = Self.autoDelay(result, audioDuration: duration)
            if delay != 0 {
                MusicDebug.log("歌词：版本差 \(Int(delay.rounded()))s，已自动对齐")
            }
        }
        state = result.map(State.ready) ?? .unavailable
    }

    /// MV 版和录音室版差的那段，基本都是加在前面的前奏/对白。
    /// 差多少就把整条歌词延后多少，不需要用户再点 ±。
    /// 只认「音频更长」这一种：歌词比音频还长说明选错了版本，重取由 `LyricsSync` 负责。
    private static func autoDelay(_ lyrics: Lyrics, audioDuration: Double) -> TimeInterval {
        guard lyrics.isSynced,
              let source = lyrics.sourceDuration, source > 0,
              audioDuration > 0 else { return 0 }
        let gap = audioDuration - source
        guard gap > 8 else { return 0 }
        return min(gap, 60)
    }

}
