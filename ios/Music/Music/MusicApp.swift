// 用途：App 入口 + 后台下载事件入口。业务都在 Services 层。
import Intents
import SwiftUI
import UIKit

/// 后台会话事件：App 被系统拉起收取下载结果时，必须把 completionHandler 交回 URLSession，
/// 否则后台下载任务不会被正确收尾（锁屏下的下载依赖这条路径）。
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        handleEventsForBackgroundURLSession identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        MediaDownloader.shared.setBackgroundCompletion(completionHandler)
    }
}

extension AppDelegate: INPlayMediaIntentHandling {
    /// Siri / Shortcuts / Fitness 的播放请求会走这里。
    /// 播放必须交给 App 内已有的 MediaPlayer：Intent 处理进程可能很快就结束，
    /// 现开一个播放器既拿不到队列，也接不上锁屏和后台播放。
    func handle(intent: INPlayMediaIntent, completion: @escaping (INPlayMediaIntentResponse) -> Void) {
        Task { @MainActor in
            guard let service = ConversionService.current else {
                completion(INPlayMediaIntentResponse(code: .continueInApp, userActivity: nil))
                return
            }

            let player = service.player
            if player.currentID == nil {
                let items = service.library.items
                guard !items.isEmpty else {
                    completion(INPlayMediaIntentResponse(code: .failureNoUnplayedContent, userActivity: nil))
                    return
                }
                player.play(items: items, startIndex: 0)
            } else {
                player.play()
            }
            completion(INPlayMediaIntentResponse(code: .success, userActivity: nil))
        }
    }
}

@main
struct MusicApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var service = ConversionService.shared

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(service)
                // 播放器单独注入：视图要观察播放状态本身，只观察 ConversionService 时
                // 播放/暂停图标不会随播放器状态刷新。
                .environmentObject(service.player)
        }
    }
}
