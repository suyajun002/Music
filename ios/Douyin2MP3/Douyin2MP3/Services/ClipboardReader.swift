// 用途：打开 App / 切回前台时自动识别剪贴板里的抖音链接，交给界面弹确认框。
//
// ⚠️ iOS 16 起，读剪贴板内容（`UIPasteboard.general.string`）**必然弹系统授权框**
// （「Music」想从「抖音」粘贴 → 允许粘贴 / 不允许粘贴），没有静默读的 API。
// 所以这里先用**不需要授权**的元数据决定「值不值得读」：
//   - `changeCount`：系统全局计数器，剪贴板每写一次 +1，读它不弹框；
//   - `hasStrings` / `hasURLs`：类型判断，也不弹框。
// 只有「计数器变了 且 里面确实像文本/链接」才真去读内容、才弹那一次系统框。
// 用户可以在 设置 → Music → 从其他 App 粘贴 → 允许，之后就彻底不弹了。
import UIKit

@MainActor
enum ClipboardReader {
    /// 上次读过时的剪贴板位置（系统全局计数器，重启会归零；只做「不等」判断，不受影响）。
    private static let changeCountKey = "clipboard.lastReadChangeCount"

    /// 调试用假剪贴板内容（`D2M_CLIPBOARD_DEMO=1`）：
    /// 手机剪贴板没法从命令行写、系统粘贴框也只能人工点，想看一眼确认框长什么样就只能喂假数据。
    ///
    /// 这里返回的是**一段真实的分享文本**而不是解析结果，所以后面的抠链接、去重、弹框全走真实代码路径。
    /// 链接故意用不存在的短链：万一倒计时真自动下载了，也只会失败，不会往资料库里塞东西。
    /// 用法：`devicectl device process launch --environment-variables '{"D2M_CLIPBOARD_DEMO":"1"}' com.yajun.douyin2mp3`
    static var demoText: String? {
        guard ProcessInfo.processInfo.environment["D2M_CLIPBOARD_DEMO"] == "1" else { return nil }
        return """
        7.43 复制打开抖音，看看【演示作品】 https://v.douyin.com/D2M-DEMO-1/ 复制此链接，打开Dou音搜索
        https://www.douyin.com/video/7300000000000000000。
        https://v.douyin.com/D2M-DEMO-3/
        """
    }

    /// 剪贴板自上次读过之后有没有变过。变了才值得去读内容（也就才会弹系统框）。
    static var hasNewContent: Bool {
        if demoText != nil { return true }
        return UIPasteboard.general.changeCount != UserDefaults.standard.integer(forKey: changeCountKey)
    }

    /// 读剪贴板文本；没有文本类内容、或用户拒绝授权时返回 nil（静默跳过）。
    ///
    /// 不论读没读到都**先记下当前位置**：授权被拒时若不留记号，下次开 App 还会再弹一次，
    /// 变成每次启动都骚扰。记下之后只有「又复制了新东西」才会再问。
    /// 手动兜底一直在：「转视频」页签的「粘贴链接」按钮是显式意图，随时可用。
    static func takeText() -> String? {
        if let demo = demoText { return demo }
        let board = UIPasteboard.general
        UserDefaults.standard.set(board.changeCount, forKey: changeCountKey)
        // 元数据先筛一道：里面没有文本/链接就连读都不读（不弹框）
        guard board.hasStrings || board.hasURLs else { return nil }
        let text = board.string?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (text?.isEmpty ?? true) ? nil : text
    }
}
