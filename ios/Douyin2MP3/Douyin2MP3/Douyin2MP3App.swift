// 用途：App 入口 + 后台下载事件入口。业务都在 Services 层。
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

@main
struct Douyin2MP3App: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var service = ConversionService()

    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(service)
        }
    }
}
