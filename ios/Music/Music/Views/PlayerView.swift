// 用途：全屏「正在播放」（对齐音乐 App：大封面、剩余时间、上一首/下一首、音量与 AirPlay）。
import SwiftUI

struct PlayerView: View {
    @EnvironmentObject private var service: ConversionService
    @EnvironmentObject private var player: MediaPlayer
    @Environment(\.dismiss) private var dismiss

    private var item: MediaItem? {
        guard let id = player.currentID else { return nil }
        return service.library.items.first { $0.id == id }
    }

    var body: some View {
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
            // 音频没有画面可切，留个等宽占位保持标题居中。
            if item?.isAudio != true {
                Button {
                    player.showsVideo.toggle()
                } label: {
                    Image(systemName: player.showsVideo ? "music.note" : "play.rectangle")
                        .font(.body)
                        .frame(width: 32, height: 32)
                }
                .disabled(item == nil)
            } else {
                Color.clear.frame(width: 32, height: 32)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
    }

    @ViewBuilder
    private var stage: some View {
        if player.showsVideo {
            VideoSurface(player: player.player)
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        } else {
            ArtworkView(url: item.flatMap { service.library.artworkURL(for: $0) }, size: 300, corner: 12)
                .frame(maxWidth: .infinity)
                .shadow(color: .black.opacity(0.25), radius: 18, y: 8)
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
