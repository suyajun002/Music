// 用途：灵动岛 + 锁定屏幕的萌宠界面。住在 widget extension 里 —— Live Activity 的
// 界面**必须**是 WidgetKit 扩展，宿主 App 只负责启停和喂数据。
//
// 为什么动起来靠「翻页」而不是动画：
//   Apple 把 Live Activity 单帧的动画时长**限死在 2 秒**，并且明确说「不要把它
//   当成持续动画的 App 视图」。所以想让猫一直有呼吸感，只能由宿主 App 周期性地
//   `update()` 换一帧姿态，每帧自带一个短过渡（见 `PetActivity.minPushInterval`）。
//   这不是妥协出来的 hack，是这套 API 唯一允许的做法。
//
// ⚠️ 图是**头**不是整只：灵动岛的紧凑态/最小态只有指甲盖大，塞整只会缩成一粒。
//   裁图放在 `Shared/Pet/`（扩展读不到 App 的 `Resources/`，两个同步组是分开的）。
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
            // ---- 锁定屏幕卡片：面积大，质感主要在这里兑现 ----
            HStack(spacing: 14) {
                PetImage(name: "pet-head")

                VStack(alignment: .leading, spacing: 3) {
                    Text(context.state.title)
                        .font(.headline)
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        LiveGlyph(isPlaying: context.state.isPlaying)
                        Text(context.state.isPlaying ? "正在播放" : "已暂停")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .activityBackgroundTint(Color(red: 1.0, green: 0.95, blue: 0.97))
        } dynamicIsland: { context in
            DynamicIsland {
                // 展开态：**横向**排（这是灵动岛给的形状），所以用宽裁图 + 右侧文字
                DynamicIslandExpandedRegion(.leading) {
                    PetImage(name: "pet-head-wide", height: 46)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.title)
                        .font(.caption)
                        .lineLimit(2)
                        .frame(maxWidth: 120, alignment: .leading)
                }
                DynamicIslandExpandedRegion(.center) {
                    HStack(spacing: 4) {
                        LiveGlyph(isPlaying: context.state.isPlaying)
                        Text("耳机猫").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            } compactLeading: {
                PetImage(name: "pet-head", height: 20)
            } compactTrailing: {
                // 「动」交给**系统自己渲染**的波形符号，而不是 App 推帧。
                // 理由：Live Activity 的 `update()` 有预算，推得快会被系统静默丢弃
                // （实测推到第 5 帧就不动了）。`symbolEffect` 是系统侧的持续动画，
                // 不消耗更新预算，能一直动下去 —— 这是 Apple 允许的动效做法。
                LiveGlyph(isPlaying: context.state.isPlaying)
            } minimal: {
                PetImage(name: "pet-head", height: 18)
            }
            .keylineTint(Color(red: 0.49, green: 0.08, blue: 0.29))
        }
    }
}

/// 系统级律动符号：不靠 App 推帧，系统自己渲染，所以能持续动。
private struct LiveGlyph: View {
    let isPlaying: Bool

    var body: some View {
        // 💡 用 `waveform` + `variableColor.iterative`：这是 Apple 给「音频在动」
        // 的现成符号动画，暂停时切成静态的暂停图标。
        Image(systemName: isPlaying ? "waveform" : "pause.fill")
            .symbolEffect(.variableColor.iterative,
                          options: .repeating,
                          isActive: isPlaying)
            .foregroundStyle(Color(red: 0.49, green: 0.08, blue: 0.29))
    }
}

/// 灵动岛/锁屏里的猫头。
///
/// ⚠️ **故意不做逐帧动画**：早期版本让 App 每 2.5 秒推一帧、扩展侧用
/// `sin(frame)` 做点头，实测推几帧后系统就不再渲染（更新预算耗尽），
/// 观感是「动一下就永远不动」。Apple 也明确说不要把它当持续动画视图。
/// 现在猫是静止的，「在播放」的活气由 `LiveGlyph` 这种系统级动画承担。
private struct PetImage: View {
    let name: String
    var height: CGFloat = 64

    var body: some View {
        Image(name)
            .resizable()
            .scaledToFit()
            .frame(height: height)
    }
}
