// 用途：根视图。资料库（音乐 App 形态）+ 转视频两个页签，迷你播放条常驻，进后台摘画面保证声音继续。
import SwiftUI

struct RootView: View {
    @EnvironmentObject private var service: ConversionService
    @EnvironmentObject private var player: MediaPlayer
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        tabs
        .sheet(isPresented: Binding(
            get: { player.isExpanded },
            set: { player.isExpanded = $0 }
        )) {
            PlayerView().environmentObject(service)
                .environmentObject(player)
        }
        .overlay { clipboardConfirm }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                // 音频只出封面；视频回前台恢复画面
                player.showsVideo = player.currentHasPicture
                Task { await service.adoptExternalMedia() }
                // 从抖音复制完链接切回来，正是「识别剪贴板」最自然的时机。
                // 剪贴板没换过内容就不会读、也不会弹系统授权框（见 ClipboardReader）。
                Task { await service.checkClipboard() }
            case .background:
                // 摘掉视频图层，改为纯音频播放，避免被系统挂起
                player.showsVideo = false
                // 进后台是最后的存档机会：被系统回收时不会再有别的回调
                player.savePosition()
            default:
                break
            }
        }
        // 启动时先把外部塞进来的媒体收进资料库（「文件」App 或 Mac 推过来的 MP3），
        // 再续播上次那首 —— 顺序不能反，不然刚收进来的文件还不在 `items` 里，续播会找不到。
        // 只在这里调（`.task` 一个视图生命周期只跑一次 = 冷启动）；切回前台不续播，
        // 否则暂停着切走再回来会被强行放起来，正在放的那首也会被打断。
        .task {
            await service.adoptExternalMedia()
            player.resumeLastPlayback(from: service.library.items)
            await player.runJumpDemoIfRequested()
        }
        // 启动时识别一次剪贴板：确认框挂在这里，用户停在哪个页签都能看到。
        .task { await service.checkClipboard() }
    }

    /// 剪贴板确认框：挂成 overlay 而不是 `.alert`——
    /// 系统弹窗只能横排按钮、按钮标题也不会实时刷新，撑不住「外圈倒计时环 + 圈里一个按钮」。
    @ViewBuilder
    private var clipboardConfirm: some View {
        if let prompt = service.clipboardPrompt {
            ClipboardConfirmView(
                prompt: prompt,
                onIgnore: { service.dismissClipboardPrompt() },
                // 点下载和倒计时到点都走这里，提交的是传进来的这份 prompt 本身，
                // 不读 service.clipboardPrompt——confirm 会先把它置空，读当前状态等于把这次提交丢掉。
                onConfirm: { Task { await service.confirm(prompt) } }
            )
            // 换了 prompt（又复制了新链接）就重新开一轮倒计时，别沿用上一轮的剩余秒数
            .id(prompt.id)
        }
    }

    /// 有下载在跑时在「转视频」页签上挂个角标：
    /// 从别的页签看到「有东西在下载」，不用去猜刚才那个确认框干了什么。
    /// 用 `Text?` 而不是 `Int?`——`.badge` 没有接 `Int?` 的重载，`nil` 才会真正不显示角标。
    private var downloadBadge: Text? {
        service.activeCount > 0 ? Text("\(service.activeCount)") : nil
    }

    /// 迷你播放条挂在「每个页面的底部安全区」里：
    /// 位置正好在页签栏上方（不会盖住页签栏），没有播放内容时高度自动塌成 0。
    /// 注意不要用 tabViewBottomAccessory——即使内容为空，它也会留一条空白槽。
    private var tabs: some View {
        TabView {
            Tab("资料库", systemImage: "music.note.list") {
                LibraryView().miniPlayerInset()
            }
            Tab("转视频", systemImage: "arrow.down.circle") {
                ConvertView().miniPlayerInset()
            }
            .badge(downloadBadge)
        }
    }
}
