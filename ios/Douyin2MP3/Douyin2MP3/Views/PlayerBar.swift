// 用途：迷你播放条（音乐 App 样式），固定在页签栏上方，点一下进全屏播放页。
import SwiftUI

struct PlayerBar: View {
    @EnvironmentObject private var service: ConversionService
    @EnvironmentObject private var player: MediaPlayer

    var body: some View {
        if let id = player.currentID, let item = service.library.items.first(where: { $0.id == id }) {
            VStack(spacing: 0) {
                Divider()
                HStack(spacing: 12) {
                    ArtworkView(url: service.library.artworkURL(for: item), size: 42, corner: 5)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(player.currentTitle)
                            .font(.subheadline)
                            .lineLimit(1)
                        Text(service.library.subtitle(for: item))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 8)

                    Button {
                        player.toggle()
                    } label: {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.title3)
                            .frame(width: 36, height: 36)
                    }
                    .buttonStyle(.plain)

                    Button {
                        player.next()
                    } label: {
                        Image(systemName: "forward.fill")
                            .font(.title3)
                            .frame(width: 36, height: 36)
                    }
                    .buttonStyle(.plain)
                    .disabled(!player.hasNext)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
                .onTapGesture { player.isExpanded = true }
            }
            .background(.bar)
        }
    }
}

extension View {
    /// 把迷你播放条钉在页签栏上方；无播放内容时不占高度。
    func miniPlayerInset() -> some View {
        safeAreaInset(edge: .bottom) { PlayerBar() }
    }
}
