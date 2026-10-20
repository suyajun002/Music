// 用途：灵动岛 + 锁定屏幕的界面。住在 widget extension 里 —— Live Activity 的
// 界面**必须**是 WidgetKit 扩展，宿主 App 只负责启停和喂数据。
//
// 设计取向（演进结论，别再退回老路）：
//   1. 灵动岛展开态是**很宽很扁**的一条（实测约 150×40pt）。早期版本在里面放
//      一张写实猫头 PNG，结果是「一个粉色小方块贴在黑底上」—— 那张图的背景是
//      粉色的、不是透明的，贴到纯黑岛上就是一块贴纸；而且细节在 40pt 高里全糊了。
//      **写实插画不适合这个体量**，Apple 自己在灵动岛里也只用极简符号。
//   2. 所以改成**纯 SwiftUI 绘制**的一排律动条。好处：不依赖任何图片素材
//      （绕开「扩展读不到图就静默留白」那一整类坑），系统渲染、天然铺满，
//      在纯黑底上有很好的质感。
//   3. 条的高低是**静态**的（正弦取绝对值，两头低中间高）。**故意不做逐帧动画**：
//      Live Activity 里唯一能长期动的机制是 `symbolEffect`；`TimelineView` 的
//      周期刷新在这里会被系统节流、`update()` 推帧会耗尽预算（都实测过，
//      现象都是「动几下就永远停住」）。静态的高低条本身就是成熟做法，不冒险。
import ActivityKit
import SwiftUI
import WidgetKit

@main
struct Douyin2MP3PetBundle: WidgetBundle {
    var body: some Widget {
        PetLiveActivity()
    }
}

struct PetLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PetAttributes.self) { context in
            // ---- 锁定屏幕卡片：面积大，波形 + 歌名横向排布 ----
            HStack(spacing: 16) {
                PetWave(isPlaying: context.state.isPlaying, bars: 7, barWidth: 4, maxHeight: 36)

                VStack(alignment: .leading, spacing: 4) {
                    Text(context.state.title)
                        .font(.headline)
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        LiveGlyph(isPlaying: context.state.isPlaying, size: 12)
                        Text(context.state.isPlaying ? "正在播放" : "已暂停")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(16)
            .activityBackgroundTint(Color(red: 0.99, green: 0.96, blue: 0.97))
        } dynamicIsland: { context in
            DynamicIsland {
                // 展开态：波形铺在左侧、歌名在右侧。两块都是宽度自适应的，
                // 不像固定尺寸图片那样在宽岛里缩成一小粒。
                DynamicIslandExpandedRegion(.leading) {
                    PetWave(isPlaying: context.state.isPlaying, bars: 7, barWidth: 5, maxHeight: 32)
                        .padding(.leading, 8)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.title)
                        .font(.caption)
                        .lineLimit(2)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: 150, alignment: .trailing)
                        .padding(.trailing, 8)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 5) {
                        LiveGlyph(isPlaying: context.state.isPlaying, size: 11)
                        Text(context.state.isPlaying ? "耳机猫 · 正在播放" : "耳机猫 · 已暂停")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            } compactLeading: {
                // ⚠️ 紧凑态实测**总宽能到 206pt**，而左右两块各自只拿到一部分。
                // 之前只在 `compactLeading` 放 3 根细条 + `compactTrailing` 放一个
                // 小符号，结果是「左边 13pt 有点东西、右边 190pt 全空」—— 岛又宽又空。
                // 现在**左右两块都铺波形**，`fill: true` 各自撑满可用宽度，
                // 从左到右都是内容，不再是「左边一小撮、右边一片黑」。
                PetWave(isPlaying: context.state.isPlaying,
                        bars: 5, barWidth: 3, maxHeight: 16, fill: true)
            } compactTrailing: {
                PetWave(isPlaying: context.state.isPlaying,
                        bars: 6, barWidth: 3, maxHeight: 16, fill: true)
            } minimal: {
                Image(systemName: context.state.isPlaying ? "waveform" : "pause.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(PetPalette.bright)
            }
            .keylineTint(PetPalette.bright)
        }
    }
}

/// 统一配色。放一处，改色只动这里。
enum PetPalette {
    /// 主色：亮莓粉。纯黑底上要够亮才「跳」得出来。
    static let bright = Color(red: 0.98, green: 0.45, blue: 0.68)
    static let top = Color(red: 1.0, green: 0.64, blue: 0.80)
    static let bottom = Color(red: 0.92, green: 0.30, blue: 0.58)
}

/// 律动波形：一排高低不同的圆角条。
///
/// 高度用「正弦取绝对值」分布 —— 两头低、中间高，像一段声浪。
/// **静态**，理由见文件头注释第 3 条。
///
/// ⚠️ 尺寸不要写死：紧凑态/展开态/锁屏三处的可用宽度差很多，写死尺寸的结果
/// 就是「岛很宽、内容缩在左边一小块」。这里用 `maxWidth: .infinity` + 条数
/// 控制密度，让它在任何一态都自己铺满。
struct PetWave: View {
    let isPlaying: Bool
    var bars: Int = 6
    var barWidth: CGFloat = 4
    var maxHeight: CGFloat = 28
    /// 是否横向撑满可用宽度（紧凑态/展开态要，锁屏卡片不要）。
    var fill: Bool = false

    var body: some View {
        HStack(alignment: .center, spacing: barWidth * 0.75) {
            ForEach(0..<bars, id: \.self) { i in
                let t = bars <= 1 ? 0.5 : Double(i) / Double(bars - 1)
                let ratio = 0.34 + 0.66 * abs(sin(Double.pi * t))
                Capsule()
                    .fill(
                        LinearGradient(colors: [PetPalette.top, PetPalette.bottom],
                                       startPoint: .top, endPoint: .bottom)
                    )
                    .frame(maxWidth: fill ? .infinity : barWidth,
                           minHeight: 0, maxHeight: max(3, maxHeight * ratio))
                    // 暂停时压暗：一眼能看出「没在放」，不用读文字。
                    .opacity(isPlaying ? 1.0 : 0.4)
            }
        }
    }
}

/// 会动的那个符号：`symbolEffect` 是系统侧渲染的持续动画，
/// **不消耗** Live Activity 的更新预算，所以能一直动 —— 这是 Apple 允许的动效做法。
private struct LiveGlyph: View {
    let isPlaying: Bool
    var size: CGFloat = 14

    var body: some View {
        Image(systemName: isPlaying ? "waveform" : "pause.fill")
            .font(.system(size: size))
            .symbolEffect(.variableColor.iterative,
                          options: .repeating,
                          isActive: isPlaying)
            .foregroundStyle(PetPalette.bright)
    }
}