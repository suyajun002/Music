// 用途：播放页的歌词列表 —— 当前行高亮、自动居中，点一行跳到那句。
import SwiftUI

struct LyricsView: View {
    let lyrics: Lyrics
    let elapsed: Double
    let delay: TimeInterval
    let onSeek: (TimeInterval) -> Void

    private var currentIndex: Int? { lyrics.index(at: elapsed, delay: delay) }

    var body: some View {
        scroll
    }

    private var scroll: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 14) {
                    ForEach(Array(lyrics.lines.enumerated()), id: \.element.id) { index, line in
                        Text(line.text.isEmpty ? " " : line.text)
                            .font(.system(size: index == currentIndex ? 20 : 17,
                                          weight: index == currentIndex ? .semibold : .regular))
                            .foregroundStyle(index == currentIndex ? Color.primary : Color.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .id(line.id)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                guard lyrics.isSynced else { return }
                                // 歌词时间轴是「原版」的，本机音频前面多出来的那段也要算上，
                                // 否则点一句会跳到比这句话早 offset 的位置。
                                onSeek(line.time + delay)
                            }
                    }
                }
                .padding(.vertical, 60)
                .padding(.horizontal, 4)
            }
            .scrollIndicators(.hidden)
            // 上下淡出，避免第一行/最后一行被硬切在边缘。
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black, location: 0.12),
                        .init(color: .black, location: 0.88),
                        .init(color: .clear, location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .onAppear {
                guard let currentIndex else { return }
                proxy.scrollTo(lyrics.lines[currentIndex].id, anchor: .center)
            }
            .onChange(of: currentIndex) { index in
                guard let index else { return }
                withAnimation(.easeInOut(duration: 0.35)) {
                    proxy.scrollTo(lyrics.lines[index].id, anchor: .center)
                }
            }
        }
    }

}
