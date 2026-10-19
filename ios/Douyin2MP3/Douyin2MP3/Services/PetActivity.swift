// 用途：宿主 App 侧的 Live Activity 生命周期（请求 / 更新 / 结束）。
// 界面在 widget extension 里（`Douyin2MP3Pet/PetLiveActivity.swift`），这里只管喂数据。
import ActivityKit
import Foundation
import UIKit

@MainActor
final class PetActivity {
    static let shared = PetActivity()

    private var activity: Activity<PetAttributes>?

    /// 上次真正推给系统的时间，用于节流。
    private var lastPushedAt = Date.distantPast
    /// 两次更新之间的最小间隔。
    ///
    /// 不是性能考量，是**内容**考量：Live Activity 单帧动画上限 2 秒，而持续动感
    /// 只能靠翻页。翻太快会被系统节流、看着像闪屏；2.5 秒一帧的点头反而自然。
    private let minPushInterval: TimeInterval = 2.5

    private init() {}

    /// 用户在系统设置里能整体关掉 Live Activities，所以每次都要现查，不能假设可用。
    /// 部署目标是 iOS 18，`ActivityAuthorizationInfo` 无需版本判断。
    private var available: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    /// 开始播放时起一个活动（已经有了就只更新）。
    func start(title: String) {
        // ⚠️ 这里必须打日志：`areActivitiesEnabled` 为 false 时是**静默**的
        // （系统设置里关了 Live Activities，或系统尚未允许），
        // 现象是「播放了但什么都没发生、日志里一行都没有」，很容易误判成「代码没执行」。
        guard available else {
            DouyinDebug.log("萌宠 Live Activity：系统未允许（areActivitiesEnabled = false），跳过")
            return
        }
        guard activity == nil else {
            update(title: title, isPlaying: true, force: true)
            return
        }
        // 部署目标 iOS 18：直接用 `ActivityContent` 这个新接口。
        // ⚠️ 不能传裸 `ContentState` —— 那是已废弃的旧签名，会报
        // 「cannot convert value of type 'ContentState' to expected argument type ...」。
        let content = ActivityContent(state: PetAttributes.ContentState(title: title, isPlaying: true, frame: 0), staleDate: nil)
        do {
            activity = try Activity.request(attributes: PetAttributes(petName: "耳机猫"), content: content, pushType: nil)
            DouyinDebug.log("萌宠 Live Activity：已请求成功")
        } catch {
            // 起不来不算致命：锁屏信息、后台播放都不依赖它，别把播放搞挂
            DouyinDebug.log("萌宠 Live Activity：请求失败 \(error)")
        }
    }

    /// 播放状态变化时更新。`force` 用于暂停/换歌这类必须立刻反映的事件，绕过节流。
    func update(title: String, isPlaying: Bool, frame: Int? = nil, force: Bool = false) {
        guard available, let activity else { return }
        let now = Date()
        if !force, now.timeIntervalSince(lastPushedAt) < minPushInterval { return }
        lastPushedAt = now

        // 帧号自增，扩展侧据此切换姿态（翻页动画）
        let nextFrame = frame ?? (activity.content.state.frame + 1)
        let state = PetAttributes.ContentState(title: title, isPlaying: isPlaying, frame: nextFrame)
        // 验「翻页到底推没推」。后台时周期观察者如果不回调，这里就停了 ——
        // 现象是锁屏上的猫一动不动，光看锁屏截屏分辨不出「没动」和「动得小」。
        DouyinDebug.log("萌宠推帧：frame=\(nextFrame)"
                        + " 应用状态=\(UIApplication.shared.applicationState == .background ? "后台" : "前台")")
        Task {
            await activity.update(ActivityContent(state: state, staleDate: nil))
        }
    }

    /// 停止播放 / 退出时收尾。
    ///
    /// `dismissalPolicy: .immediate` —— 音乐一停就收掉，不留一张僵尸卡片在锁屏上。
    func end() {
        guard let activity else { return }
        self.activity = nil
        Task {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }
}