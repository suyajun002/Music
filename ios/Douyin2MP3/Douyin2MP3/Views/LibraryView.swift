// 用途：本地媒体库。已下载的视频离线可播，与网络无关。
import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var service: ConversionService

    var body: some View {
        NavigationStack {
            Group {
                if service.library.items.isEmpty {
                    ContentUnavailableView(
                        "还没有视频",
                        systemImage: "film.stack",
                        description: Text("在「转视频」里贴一条抖音链接，下载好会自动出现在这里")
                    )
                } else {
                    List {
                        ForEach(service.library.items) { item in
                            Button {
                                service.play(item)
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: isPlaying(item) ? "pause.circle.fill" : "play.circle.fill")
                                        .font(.title2)
                                        .foregroundStyle(.tint)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(item.title)
                                            .font(.body)
                                            .foregroundStyle(.primary)
                                            .lineLimit(2)
                                        Text("\(item.durationText) · \(item.sizeText)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                }
                            }
                            .buttonStyle(.plain)
                        }
                        .onDelete { offsets in
                            for index in offsets { service.library.delete(service.library.items[index]) }
                        }
                    }
                }
            }
            .navigationTitle("音乐库")
        }
    }

    private func isPlaying(_ item: MediaItem) -> Bool {
        service.player.currentID == item.id && service.player.isPlaying
    }
}
