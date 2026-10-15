// 用途：全屏播放页（视频画面 + 控制条）。
import SwiftUI

struct PlayerView: View {
    @EnvironmentObject private var service: ConversionService
    @Environment(\.dismiss) private var dismiss

    private var player: MediaPlayer { service.player }

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Button {
                    player.isExpanded = false
                    dismiss()
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.title3)
                }
                Spacer()
                Text("正在播放")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
                Color.clear.frame(width: 24, height: 24)
            }
            .padding(.horizontal)

            Group {
                if player.showsVideo {
                    VideoSurface(player: player.player)
                } else {
                    RoundedRectangle(cornerRadius: 16)
                        .fill(.quaternary)
                        .overlay {
                            Image(systemName: "waveform")
                                .font(.system(size: 48))
                                .foregroundStyle(.secondary)
                        }
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)
            .padding(.horizontal)

            VStack(alignment: .leading, spacing: 10) {
                Text(player.currentTitle)
                    .font(.headline)
                    .lineLimit(2)

                HStack {
                    Text(player.elapsedText)
                    Slider(
                        value: Binding(
                            get: { player.progress },
                            set: { player.seek(to: $0) }
                        ),
                        in: 0...1
                    )
                    Text(player.durationText)
                }
                .font(.caption)
                .monospacedDigit()

                HStack(spacing: 40) {
                    Button {
                        player.seek(to: max(0, player.progress - 0.05))
                    } label: {
                        Image(systemName: "gobackward.10").font(.title2)
                    }
                    Button {
                        player.toggle()
                    } label: {
                        Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 56))
                    }
                    Button {
                        player.seek(to: min(1, player.progress + 0.05))
                    } label: {
                        Image(systemName: "goforward.10").font(.title2)
                    }
                }
                .frame(maxWidth: .infinity)
                .buttonStyle(.plain)
            }
            .padding(.horizontal)

            Spacer()
        }
        .padding(.top, 8)
    }
}
