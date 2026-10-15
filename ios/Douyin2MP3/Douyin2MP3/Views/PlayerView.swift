// 用途：全屏「正在播放」（对齐音乐 App：大封面、剩余时间、上一首/下一首、音量与 AirPlay）。
import SwiftUI

struct PlayerView: View {
    @EnvironmentObject private var service: ConversionService
    @Environment(\.dismiss) private var dismiss

    private var player: MediaPlayer { service.player }

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
            Button {
                player.showsVideo.toggle()
            } label: {
                Image(systemName: player.showsVideo ? "music.note" : "play.rectangle")
                    .font(.body)
                    .frame(width: 32, height: 32)
            }
            .disabled(item == nil)
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
            Text("抖音")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 14)
    }

    private var scrubber: some View {
        VStack(spacing: 2) {
            Slider(
                value: Binding(get: { player.progress }, set: { player.seek(to: $0) }),
                in: 0...1
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

    private var volumeRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "speaker.fill").font(.caption).foregroundStyle(.secondary)
            SystemVolumeView().frame(height: 32)
            Image(systemName: "speaker.wave.3.fill").font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 24)
    }
}
