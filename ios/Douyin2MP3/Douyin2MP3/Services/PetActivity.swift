// 用途：宿主 App 侧的 Live Activity 生命周期（请求 / 更新 / 结束）。
// 界面在 widget extension 里（`Douyin2MP3Pet/PetLiveActivity.swift`），这里只管喂数据。
import ActivityKit
import Foundation
import UIKit

@MainActor
final class PetActivity {
    static let shared = PetActivity()

    private var activity: Activity<PetAttributes>?

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
        // ⚠️ 新建之前先清掉本 App 遗留的活动。`Activity<PetAttributes>.activities`
        // 里可能有上次进程留下的僵尸：进程被强杀（重装、`--terminate-existing`、
        // 系统回收）时走不到 `end()`。系统对每个 App 的**活动数量有上限**，
        // 攒够了新活动一律请求失败 `targetMaximumExceeded` —— 现象极具误导性：
        // 代码没错、日志会说"请求失败"，而屏幕上那条"不动的猫"其实是僵尸活动的画面。
        reapOrphans()
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

    /// 收掉本 App 所有已存在的活动（僵尸清理）。新建前调一次。
    private func reapOrphans() {
        let orphans = Activity<PetAttributes>.activities
        guard !orphans.isEmpty else { return }
        DouyinDebug.log("萌宠 Live Activity：清理遗留活动 \(orphans.count) 个")
        for orphan in orphans {
            Task { await orphan.end(nil, dismissalPolicy: .immediate) }
        }
    }

    /// 播放状态/歌曲变化时更新。
    ///
    /// ⚠️ **只在真的变了的时候才推**。早期版本每 2.5 秒推一帧想做点头动画，
    /// 结果 iOS 的更新预算很快耗尽、系统开始静默丢弃更新 —— 现象是「猫动几下
    /// 就永远不动」，而日志还在刷（App 以为推成功了）。Live Activity 本来就不是
    /// 持续动画视图，Apple 明说不要这么做。现在「在播放」的活气交给扩展里的
    /// `symbolEffect`（系统自己渲染，不花预算）。
    ///
    /// `force` 用于暂停/换歌这类必须立刻反映的事件，绕过节流。
    func update(title: String, isPlaying: Bool, force: Bool = false) {
        guard available, let activity else { return }

        // 内容没变就别打扰系统 —— 每次 update 都花预算，白推会加速耗尽。
        let current = activity.content.state
        guard force || current.title != title || current.isPlaying != isPlaying else { return }

        let state = PetAttributes.ContentState(title: title, isPlaying: isPlaying, frame: 0)
        DouyinDebug.log("萌宠更新：《\(title)》 \(isPlaying ? "播放中" : "已暂停")")
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