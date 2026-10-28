// 用途：把「耳机猫」作为**动画封面**送给系统（iOS 26 的 `MPMediaItemAnimatedArtwork`）。
//
// 为什么走封面、而不是自建 Live Activity：
//   播放音频时灵动岛/锁屏的「正在播放」界面由系统渲染，内容来自 `MPNowPlayingInfoCenter`。
//   Live Activity 单帧动画被 Apple 限死 2 秒（明确说「不要当成持续动画的 App 视图」），
//   宠物只能靠翻页假装在动；而动画封面是**系统真的在播一段循环视频**，连续动画免费。
//   实测（iPhone Air / iOS 27.2）：Live Activity 那条路本身能跑通、也能与系统正在播放共存，
//   但观感上限差一档，所以选了这条。
//
// ⚠️ 三条硬约束（来自 `MPMediaItemAnimatedArtwork` 头文件，写错就退回静态图）：
//   1. 必须是**本地**文件 URL（不能是网络流）
//   2. 宽高比必须和 key 匹配 —— 写错比例**不报错**，只是悄悄退回静态图
//   3. 视频要能无缝循环，建议 <30 秒、≤60fps
//   另外：低电量模式 / 减弱动态效果 / 低数据模式时，系统会**自动退回静态图** ——
//   这是设计如此，不是坏了，所以静态封面也必须好看（`cat-still.png`）。
//
// ⚠️ 比例这条真机上踩过：`supportedAnimatedArtworkKeys` 在 iPhone Air / iOS 27.2 上
//   只返回 `MPNowPlayingInfoProperty3x4AnimatedArtwork`，**没有 1x1**。
//   原来按 1:1 出资源、按 1x1 查 key，于是 `artworkKey` 返回 nil、整段被跳过，
//   现象就是「封面根本没换」。所以资源是竖版 3:4（1080×1440），key 也按 3x4 取。
//   这里的 key 名（3x4）指的是**宽:高 = 3:4 的竖版**，即高比宽大。
import MediaPlayer
import UIKit

enum AnimatedArtwork {
    /// 资源在 App bundle 里（`Resources/` 经同步组自动进包）。
    private static let videoName = "cat-anim"
    private static let stillName = "cat-still"

    private static let videoURL: URL? = Bundle.main.url(forResource: videoName, withExtension: "mp4")
    private static let stillImage: UIImage? = Bundle.main
        .url(forResource: stillName, withExtension: "png")
        .flatMap { UIImage(contentsOfFile: $0.path) }

    /// 只打一次诊断，避免 0.5 秒一轮的 `updateNowPlaying` 把日志刷爆。
    private static var didDiagnose = false

    /// handler 里各打一次就够 —— 系统会反复要，日志刷爆就看不出别的了。
    private static var didLogPreview = false
    private static var didLogVideo = false

    /// 每轮 `updateNowPlaying` 都打，但只在 `D2M_DEBUG=1` 下。
    /// 不节流是**故意**的：0.5 秒一轮正好能看出「封面实例是不是每轮都被换掉」，
    /// 那正是「动画起不来」的头号嫌疑。
    static func logWrite(_ key: String?) {
        guard MusicDebug.enabled else { return }
        guard let key else {
            MusicDebug.log("动画封面：这一轮**没写**动画封面（资源缺 / key 不支持 / 已暂停）")
            return
        }
        MusicDebug.log("动画封面写入 key=\(key)"
                        + " preview=\(stillImage == nil ? "无" : "有")"
                        + " video=\(videoURL == nil ? "无" : "有")"
                        + " 省电=\(ProcessInfo.processInfo.isLowPowerModeEnabled)"
                        + " 减弱动态=\(UIAccessibility.isReduceMotionEnabled)")
    }

    /// 把「哪一步断了」打出来。
    /// 这条链路全是**静默失败**：资源找不到、key 不被平台支持、比例不符、被省电模式挡掉 ——
    /// 系统一律不报错，现象都是「封面没换」，不插日志根本无从下手。
    ///
    /// ⚠️ 分两个层面查，别混在一起：
    ///   · **handler 有没有被调用** —— 没调用 = 系统压根没采用我们的封面（key/比例/资源问题）
    ///   · 调用了却还显示静态图 = 被**运行时条件**挡掉（省电模式、减弱动态效果……）
    /// 两者的修法完全不同，混在一起查会往错的方向改。
    static func diagnoseIfNeeded() {
        guard MusicDebug.enabled, !didDiagnose else { return }
        didDiagnose = true
        MusicDebug.log("动画封面诊断：视频资源 = \(videoURL?.path ?? "未找到")")
        MusicDebug.log("动画封面诊断：静态图 = \(stillImage == nil ? "未找到" : "OK")")
        if #available(iOS 26.0, *) {
            let supported = MPNowPlayingInfoCenter.supportedAnimatedArtworkKeys
            MusicDebug.log("动画封面诊断：平台支持的 key = \(supported)")
            MusicDebug.log("动画封面诊断：3x4 key 可用 = \(artworkKey != nil)")
        } else {
            MusicDebug.log("动画封面诊断：系统低于 iOS 26，API 不可用")
        }
        // 这两条是文档里点名的「自动退回静态图」的触发条件。
        // 省电模式最容易被忽略 —— 它不影响别的任何功能，只悄悄关掉动画封面。
        MusicDebug.log("动画封面诊断：省电模式 = \(ProcessInfo.processInfo.isLowPowerModeEnabled)"
                        + "，减弱动态效果 = \(UIAccessibility.isReduceMotionEnabled)")
    }

    /// **整个 App 只造一个**，反复复用。
    ///
    /// `updateNowPlaying()` 是 0.5 秒跑一轮的，如果每轮都 `make()` 一个新实例，
    /// 塞进 nowPlayingInfo 的就是一份「每 0.5 秒换一次身份」的封面 ——
    /// 系统会当成新封面重新解析，循环播放根本起不来。
    /// 头文件说 `artworkID` 就是这份封面的身份，所以身份必须**稳定**。
    private static var cached: Any?

    /// 不带 `@available` 的入口：调用点（`updateNowPlaying`）在 iOS 18 下也要能编译，
    /// 版本判断收在这里做。返回 `Any?` 是因为调用点不能出现 iOS 26 的类型名。
    static func sharedIfAvailable() -> Any? {
        guard #available(iOS 26.0, *) else { return nil }
        return shared()
    }

    @available(iOS 26.0, *)
    static func shared() -> MPMediaItemAnimatedArtwork? {
        if let cached = cached as? MPMediaItemAnimatedArtwork { return cached }
        let art = make()
        cached = art
        return art
    }

    /// 给 `nowPlayingInfo` 用的动画封面。
    ///
    /// `artworkID` 要唯一标识「这段预览图 + 这段视频」。换了任何一个资源就换 ID，
    /// 否则系统会继续用缓存里的旧图。v2 = 竖版耳机猫。
    @available(iOS 26.0, *)
    static func make() -> MPMediaItemAnimatedArtwork? {
        guard let videoURL else { return nil }
        return MPMediaItemAnimatedArtwork(
            artworkID: "d2m.cat.v2",
            previewImageRequestHandler: { size in
                // 预览图要尽快返回（头文件建议「理想情况下同步返回」），所以直接给缓存好的静帧，
                // 让系统按需要缩放。
                if MusicDebug.enabled, !didLogPreview {
                    didLogPreview = true
                    MusicDebug.log("动画封面：系统要预览图 \(Int(size.width))×\(Int(size.height))，"
                                    + (stillImage == nil ? "我们给不出" : "已给"))
                }
                return stillImage
            },
            videoAssetFileURLRequestHandler: { size in
                // 这一行是**分水岭**：打出来了，说明系统真的采用了我们的封面；
                // 一声不吭，说明是 key/资源没被接受，得回头查那两处。
                if MusicDebug.enabled, !didLogVideo {
                    didLogVideo = true
                    MusicDebug.log("动画封面：系统要视频 \(Int(size.width))×\(Int(size.height))，"
                                    + "我们给 1080×1440")
                }
                return videoURL
            }
        )
    }

    /// 支持的 key 随平台不同，要现查 —— 用不支持的 key 会被系统**静默忽略**。
    /// 资源是 1080×1440（3:4 竖版），所以取 3x4 那个 key。
    ///
    /// 仍然保留「先查再取」而不是直接写死：万一以后在只支持 1x1 的机型上跑，
    /// 这里返回 nil 会走静态封面，比写死一个不被支持的 key 让系统默默忽略要好排查。
    static var artworkKey: String? {
        guard #available(iOS 26.0, *) else { return nil }
        let supported = MPNowPlayingInfoCenter.supportedAnimatedArtworkKeys
        guard supported.contains(MPNowPlayingInfoProperty3x4AnimatedArtwork) else { return nil }
        return MPNowPlayingInfoProperty3x4AnimatedArtwork
    }
}
