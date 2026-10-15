// 用途：常驻底部播放条，点一下进入全屏播放页。
import SwiftUI

struct PlayerBar: View {
    @EnvironmentObject private var service: ConversionService

    private var player: MediaPlayer { service.player }

    var body: some View {
        if player.currentID != nil {
            Button {
                player.isExpanded = true
            } label: {
                VStack(spacing: 6) {
                    HStack(spacing: 12) {
                        Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 34))
                            .onTapGesture { player.toggle() }

                        VStack(alignment: .leading, spacing: 2) {
                            Text(player.currentTitle)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                            Text("\(player.elapsedText) / \(player.durationText)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            player.stop()
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                    ProgressView(value: player.progress).progressViewStyle(.linear)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.bar)
            }
            .buttonStyle(.plain)
        }
    }
}
