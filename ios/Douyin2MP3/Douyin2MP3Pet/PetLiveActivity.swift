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
    /// 每帧的姿态。**幅度要小** —— 灵动岛里 2.5 秒才换一帧，
    /// 位移大了不是「呼吸」是「抽搐」。
    private func pose(_ frame: Int) -> (scale: CGFloat, dy: CGFloat) {
        // 6 帧一个循环，用正弦保证首尾接得上，不会跳。
        let t = Double(frame % 6) / 6.0
        return (1 + 0.03 * sin(2 * .pi * t), -3 * sin(2 * .pi * t))
    }

    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PetAttributes.self) { context in
            // ---- 锁定屏幕卡片：面积大，质感主要在这里兑现 ----
            HStack(spacing: 14) {
                PetImage(name: "pet-head", frame: context.state.frame)

                VStack(alignment: .leading, spacing: 3) {
                    Text(context.state.title)
                        .font(.headline)
                        .lineLimit(1)
                    Label(context.state.isPlaying ? "正在播放" : "已暂停",
                          systemImage: context.state.isPlaying ? "waveform" : "pause.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .symbolEffect(.variableColor.iterative,
                                      options: .repeating,
                                      isActive: context.state.isPlaying)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .activityBackgroundTint(Color(red: 1.0, green: 0.95, blue: 0.97))
        } dynamicIsland: { context in
            DynamicIsland {
                // 展开态：**横向**排（这是灵动岛给的形状），所以用宽裁图 + 右侧文字
                DynamicIslandExpandedRegion(.leading) {
                    PetImage(name: "pet-head-wide", frame: context.state.frame, height: 46)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.title)
                        .font(.caption)
                        .lineLimit(2)
                        .frame(maxWidth: 120, alignment: .leading)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text("🎧 耳机猫")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } compactLeading: {
                PetImage(name: "pet-head", frame: context.state.frame, height: 20)
            } compactTrailing: {
                // 紧凑态右侧这颗之前是律动波浪图标，但**那一格太小**：
                // 猫的耳朵会和波浪叠在一起（截图为证）。用户定的是「只留猫」，
                // 所以这里把右侧整个让出来，猫独占紧凑态。
                //
                // 留一个**极窄的透明占位**而不是彻底删掉 `compactTrailing`：
                // 两个闭包都在时灵动岛才知道要画「左右两块」，全删了会变成
                // 单块布局，猫会被系统重新居中、和左侧的住宿相机挤在一起。
                Color.clear.frame(width: 1)
            } minimal: {
                PetImage(name: "pet-head", frame: context.state.frame, height: 18)
            }
            .keylineTint(Color(red: 0.49, green: 0.08, blue: 0.29))
        }
    }
}

/// 带「翻页呼吸」的猫。
private struct PetImage: View {
    let name: String
    let frame: Int
    var height: CGFloat = 64

    var body: some View {
        Image(name)
            .resizable()
            .scaledToFit()
            .frame(height: height)
            // 呼吸靠 scale/offset 的短过渡；真正的「动」是 App 每 2.5 秒推一帧。
            .scaleEffect(1 + 0.03 * sin(2 * .pi * Double(frame % 6) / 6.0))
            .offset(y: -2 * sin(2 * .pi * Double(frame % 6) / 6.0))
            .animation(.easeInOut(duration: 0.8), value: frame)
    }
}
