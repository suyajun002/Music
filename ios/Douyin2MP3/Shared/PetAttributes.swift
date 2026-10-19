// 用途：灵动岛萌宠的数据契约。App 与 widget extension 两个 target 都要编译这个文件，
// 所以它单独放在 Shared/（在 App 的同步组之外，两个 target 各自显式挂一份）。
import ActivityKit
import Foundation

/// Live Activity 的数据模型。
///
/// 只放**能跨进程共享**的东西：曲名、播放状态、动画帧号。
/// ⚠️ 不要往里塞 `UIImage`/封面 —— 类型过不了进程边界，硬塞要落盘再让扩展读，
/// 复杂且易错。扩展侧自己画猫就够。
struct PetAttributes: ActivityAttributes {
    /// 动态部分：随播放状态变化，每次 `update()` 换一份。
    struct ContentState: Codable, Hashable {
        /// 当前曲名（扩展的紧凑态/展开态要显示）。
        var title: String
        var isPlaying: Bool
        /// 动画帧号。Live Activity 单帧的动画**不能超过 2 秒**（Apple 明确说
        /// 「不要把它当成持续动画的 App 视图」），所以持续动感只能靠 App 周期性
        /// `update()` 翻页：扩展侧按这个帧号切换姿态，每帧自带一个短过渡。
        var frame: Int
    }

    /// 静态部分：活动开始后不再变。
    var petName: String
}