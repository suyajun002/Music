// 用途：灵动岛 + 锁定屏幕的萌宠界面。住在 widget extension 里 —— Live Activity 的
// 界面**必须**是 WidgetKit 扩展，宿主 App 只负责启停和喂数据。
//
// ⚠️ 当前是「第 0 步可行性探针」版本：界面故意只用最朴素的 `Text`。
// 目的是先把两个可能直接卡死的未知数验掉（免费团队能不能签 extension、
// 系统「正在播放」会不会把自建的顶掉），视觉确认可行之后再上猫。
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
            // 锁定屏幕卡片。面积大、可上彩色 —— 质感主要在这里兑现。
            VStack(spacing: 6) {
                Text("探针 \(context.state.frame)")
                    .font(.title2.weight(.bold))
                Text(context.state.title)
                    .font(.caption)
                    .lineLimit(1)
            }
            .padding()
            .activityBackgroundTint(Color(red: 1.0, green: 0.95, blue: 0.97))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.center) {
                    Text("探针 \(context.state.frame)")
                }
            } compactLeading: {
                Text("猫")
            } compactTrailing: {
                Text("♪")
            } minimal: {
                Text("猫")
            }
        }
    }
}