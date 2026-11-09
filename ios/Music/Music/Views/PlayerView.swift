// 用途：全屏「正在播放」：歌词为主体，底色跟随封面着色，保留进度与播放控件。
import Combine
import SwiftUI

struct PlayerView: View {
    @EnvironmentObject private var service: ConversionService
    @EnvironmentObject private var player: MediaPlayer
    @Environment(\.dismiss) private var dismiss
    @State private var showsLyrics = true
    @State private var palette = ArtworkPalette.fallback

    private var item: MediaItem? {
        guard let id = player.currentID else { return nil }
        return service.library.items.first { $0.id == id }
    }

    var body: some View {
        ZStack {
            PlayerBackdrop(palette: palette)

            VStack(spacing: 0) {
                header

                Spacer(minLength: 8)

                stage
                    .padding(.horizontal, 28)

                Spacer(minLength: 16)

                titleBlock
                scrubber
                transport
                modeRow
                volumeRow

                Spacer(minLength: 12)
            }
            .padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onReceive(player.$artwork) { artwork in
            guard let artwork else { return }
            withAnimation(.easeInOut(duration: 0.45)) {
                palette = ArtworkPalette.from(artwork)
            }
        }
        .onChange(of: player.currentID) { _ in
            showsLyrics = true
        }
    }

    // MARK: - 区块

    private var header: some View {
        HStack {
            Button {
                player.isExpanded = false
                dismiss()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.body.weight(.semibold))
                    .frame(width: 32, height: 32)
            }
            Spacer()
            Text("正在播放")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if player.currentHasPicture {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        if showsLyrics {
                            player.showsVideo = true
                            showsLyrics = false
                        } else {
                            showsLyrics = true
                        }
                    }
                } label: {
                    Image(systemName: showsLyrics ? "play.rectangle" : "quote.bubble")
                        .font(.body)
                        .frame(width: 32, height: 32)
                }
                .disabled(item == nil)
                .accessibilityLabel(showsLyrics ? "显示视频" : "显示歌词")
            } else {
                Color.clear.frame(width: 32, height: 32)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
    }

    @ViewBuilder
    private var stage: some View {
        if showsLyrics || !player.currentHasPicture {
            lyricsStage
        } else {
            VideoSurface(player: player.player)
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    /// 歌词占满主区域。加载中和「没找到」都在这块里说清楚，
    /// 不弹窗、不占额外区域。
    @ViewBuilder
    private var lyricsStage: some View {
        LyricsStage(store: player.lyrics, elapsed: player.elapsed) { time in
            player.seek(toSeconds: time)
        }
    }

    /// 单独一层是为了用 `@ObservedObject` 盯住 `player.lyrics`。`LyricsStore` 是
    /// `MediaPlayer` 的嵌套对象，外层 `player` 发通知不会带上它，直接在 `PlayerView`
    /// 里读状态会停在「加载中」直到下一次 `elapsed` 变化。
    private struct LyricsStage: View {
        @ObservedObject var store: LyricsStore
        let elapsed: TimeInterval
        let seek: (TimeInterval) -> Void

        var body: some View {
            Group {
                switch store.state {
                case .idle, .loading:
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                case .ready(let value):
                    LyricsView(
                        lyrics: value,
                        elapsed: elapsed,
                        delay: store.delay,
                        onSeek: seek
                    )
                case .unavailable:
                    VStack(spacing: 10) {
                        Image(systemName: "quote.bubble")
                            .font(.largeTitle)
                            .foregroundStyle(.tertiary)
                        Text("没有找到这首歌的歌词")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var titleBlock: some View {
        VStack(spacing: 3) {
            Text(player.currentTitle)
                .font(.title3.weight(.semibold))
                .lineLimit(1)
            Text(item.map { service.library.subtitle(for: $0) } ?? "")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 14)
    }

    private var scrubber: some View {
        VStack(spacing: 2) {
            // 拖动只改界面（`scrub`），松手才落到播放器（`endScrubbing`）。
            // 按住期间周期观察者不写 `elapsed`，进度条才会跟着手指走、松手不弹回。
            Slider(
                value: Binding(get: { player.progress }, set: { player.scrub(to: $0) }),
                in: 0...1,
                onEditingChanged: { editing in
                    if editing { player.beginScrubbing() } else { player.endScrubbing() }
                }
            )
            HStack {
                Text(player.elapsedText)
                Spacer()
                Text(player.remainingText)
            }
            .font(.caption2)
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 24)
    }

    private var transport: some View {
        HStack(spacing: 56) {
            Button {
                player.previous()
            } label: {
                Image(systemName: "backward.fill").font(.system(size: 30))
            }
            .buttonStyle(.plain)

            Button {
                player.toggle()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 34))
                    .frame(width: 64, height: 64)
            }
            .buttonStyle(.plain)

            Button {
                player.next()
            } label: {
                Image(systemName: "forward.fill").font(.system(size: 30))
            }
            .buttonStyle(.plain)
            .disabled(!player.hasNext)
        }
        .foregroundStyle(.primary)
        .padding(.top, 18)
        .padding(.bottom, 14)
    }

    /// 播放模式（顺序 / 随机）。对齐音乐 App：**就一颗开关**，亮着=随机、灰着=顺序，
    /// 位置在传输键下面、音量上面。用 `Button` 而不是 `Toggle`：音乐 App 那颗键
    /// 是按一下切换、并用**高亮**表示状态，不是开关那种滑块样式。
    /// 图标沿用音乐 App 的 `shuffle` / `list.bullet`（顺序播放那一档）。
    private var modeRow: some View {
        HStack {
            Button {
                player.toggleMode()
            } label: {
                Image(systemName: player.mode == .shuffle ? "shuffle" : "list.bullet")
                    .font(.system(size: 17))
                    // 随机态高亮成主题色，顺序态压成灰色 —— 一眼看出现在哪一档
                    .foregroundStyle(player.mode == .shuffle ? Color.accentColor : Color.secondary)
                    .frame(width: 44, height: 32)
            }
            .buttonStyle(.plain)
            // 无障碍：光看图标说不出「现在是哪一档」，把当前模式念出来
            .accessibilityLabel(player.mode.label)
            .accessibilityHint("双击切换顺序播放或随机播放")

            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 6)
    }

    private var volumeRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "speaker.fill").font(.caption).foregroundStyle(.secondary)
            SystemVolumeView().frame(height: 32)
            Image(systemName: "speaker.wave.3.fill").font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 24)
    }
}
