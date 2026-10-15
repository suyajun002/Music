// 用途：资料库（对齐音乐 App 的「歌曲」列表）：封面缩略图、可搜索、可排序、可滑动删除。
import SwiftUI

struct LibraryView: View {
    enum SortOrder: String, CaseIterable, Identifiable {
        case recent = "最近添加"
        case title = "标题"

        var id: String { rawValue }
    }

    @EnvironmentObject private var service: ConversionService
    @EnvironmentObject private var player: MediaPlayer
    @State private var query = ""
    @State private var sort: SortOrder = .recent

    private var items: [MediaItem] {
        let base = service.library.items
        let filtered = query.isEmpty
            ? base
            : base.filter { $0.title.localizedCaseInsensitiveContains(query) }
        switch sort {
        case .recent: return filtered.sorted { $0.savedAt > $1.savedAt }
        case .title: return filtered.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if service.library.items.isEmpty {
                    ContentUnavailableView(
                        "资料库是空的",
                        systemImage: "music.note.list",
                        description: Text("到「转视频」里贴一条链接，下载好会自动出现在这里")
                    )
                } else {
                    List {
                        Section {
                            ForEach(items) { item in
                                row(item)
                            }
                            .onDelete { offsets in
                                for index in offsets { service.library.delete(items[index]) }
                            }
                        } footer: {
                            Text("\(service.library.items.count) 首 · 共 \(totalText)")
                        }
                    }
                    .searchable(text: $query, prompt: "搜索标题")
                }
            }
            .navigationTitle("资料库")
            .toolbar {
                if !service.library.items.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Picker("排序方式", selection: $sort) {
                                ForEach(SortOrder.allCases) { order in
                                    Text(order.rawValue).tag(order)
                                }
                            }
                        } label: {
                            Image(systemName: "arrow.up.arrow.down")
                        }
                    }
                }
            }
        }
    }

    private func row(_ item: MediaItem) -> some View {
        Button {
            service.play(item)
        } label: {
            HStack(spacing: 12) {
                ArtworkView(url: service.library.artworkURL(for: item), size: 52, corner: 5)

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.body)
                        .foregroundStyle(isCurrent(item) ? Color.accentColor : .primary)
                        .lineLimit(1)
                    Text(item.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                if isCurrent(item), player.isPlaying {
                    Image(systemName: "waveform")
                        .foregroundStyle(.tint)
                        .symbolEffect(.variableColor.iterative, options: .repeating)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func isCurrent(_ item: MediaItem) -> Bool {
        player.currentID == item.id
    }

    private var totalText: String {
        let bytes = service.library.totalBytes()
        return bytes > 1024 * 1024 * 1024
            ? String(format: "%.2f GB", Double(bytes) / 1024 / 1024 / 1024)
            : String(format: "%.0f MB", Double(bytes) / 1024 / 1024)
    }
}
