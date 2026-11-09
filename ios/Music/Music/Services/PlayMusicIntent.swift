// 用途：把「播放」注册成系统媒体 Intent。Siri / 快捷指令 / 健身 可以后台触发它，
// 不需要把 App 拉到前台；执行体统一落到已有的 MediaPlayer，避免另起一个播放器。
import AppIntents

/// `AudioStartingIntent` 是「我会启动音频播放」的显式声明。
/// 系统据此判断这个 App 能承接不带具体曲目的播放请求，也不用为它切前台。
struct PlayMusicIntent: AudioStartingIntent {
    static var title: LocalizedStringResource = "播放音乐"
    static var description = IntentDescription("在 Music 中播放资料库里的音乐")

    @MainActor
    func perform() async throws -> some IntentResult {
        PlayIntentLog.write("intent enter")
        let service = ConversionService.current ?? ConversionService.shared
        PlayIntentLog.write("intent service ready")

        let player = service.player
        if player.currentID == nil {
            let items = service.library.items
            PlayIntentLog.write("intent items=\(items.count)")
            guard !items.isEmpty else { return .result() }
            player.play(items: items, startIndex: 0)
        } else {
            PlayIntentLog.write("intent resume")
            player.play()
        }
        return .result()
    }
}

/// 让这个 Intent 出现在快捷指令和 Siri 的 App 快捷操作里。
struct MusicShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: PlayMusicIntent(),
            phrases: ["用\(.applicationName)播放音乐", "在\(.applicationName)里播放"],
            shortTitle: "播放",
            systemImageName: "play.fill"
        )
    }
}
