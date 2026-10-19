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

    /// 把「哪一步断了」打出来。
    /// 这条链路全是**静默失败**：资源找不到、key 不被平台支持、比例不符 —— 系统都不报错，
    /// 现象一律是「封面没变」，不插日志根本无从下手。
    static func diagnoseIfNeeded() {
        guard DouyinDebug.enabled, !didDiagnose else { return }
        didDiagnose = true
        DouyinDebug.log("动画封面诊断：视频资源 = \(videoURL?.path ?? "未找到")")
        DouyinDebug.log("动画封面诊断：静态图 = \(stillImage == nil ? "未找到" : "OK")")
        if #available(iOS 26.0, *) {
            let supported = MPNowPlayingInfoCenter.supportedAnimatedArtworkKeys
            DouyinDebug.log("动画封面诊断：平台支持的 key = \(supported)")
            DouyinDebug.log("动画封面诊断：3x4 key 可用 = \(artworkKey != nil)")
        } else {
            DouyinDebug.log("动画封面诊断：系统低于 iOS 26，API 不可用")
        }
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
                stillImage
            },
            videoAssetFileURLRequestHandler: { _ in
                videoURL
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
