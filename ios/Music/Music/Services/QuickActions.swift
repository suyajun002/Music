// 用途：主屏长按图标的快捷操作。菜单项由 Info.plist 静态声明，
// 这里接住系统回调，并复用快捷指令的随机播放逻辑。
import UIKit

enum MusicQuickAction {
    static let shuffle = "com.yajun.douyin2mp3.shuffle"

    /// 快捷指令和主屏长按共用：切随机模式，有当前歌曲就续播，否则从曲库起播。
    @MainActor
    static func shufflePlay() {
        let service = ConversionService.current ?? ConversionService.shared
        let player = service.player
        let items = service.library.items
        PlayIntentLog.write("shuffle items=\(items.count)")
        guard !items.isEmpty else { return }

        player.setMode(.shuffle)
        if player.currentID == nil {
            player.play(items: items, startIndex: 0)
        } else {
            PlayIntentLog.write("shuffle resume")
            player.play()
        }
    }

    @MainActor
    @discardableResult
    static func handle(_ item: UIApplicationShortcutItem) -> Bool {
        guard item.type == shuffle else { return false }
        shufflePlay()
        return true
    }
}

/// SwiftUI 会创建并管理这个 delegate 实例；我们只提供类，不接管窗口创建。
final class MusicSceneDelegate: NSObject, UIWindowSceneDelegate {
    /// 冷启动：快捷操作在场景连接时送到这里。
    func scene(
        _ scene: UIScene,
        willConnectTo session: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions
    ) {
        if let item = connectionOptions.shortcutItem {
            _ = MusicQuickAction.handle(item)
        }
    }

    /// 已运行/后台：点快捷操作时走这里。
    func windowScene(
        _ windowScene: UIWindowScene,
        performActionFor shortcutItem: UIApplicationShortcutItem,
        completionHandler: @escaping (Bool) -> Void
    ) {
        completionHandler(MusicQuickAction.handle(shortcutItem))
    }
}

extension AppDelegate {
    /// 有场景时，让 SwiftUI 使用能接快捷操作的 SceneDelegate。
    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(
            name: "Default Configuration",
            sessionRole: connectingSceneSession.role
        )
        configuration.delegateClass = MusicSceneDelegate.self
        return configuration
    }
}
