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
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                // 音频只出封面；视频回前台恢复画面
                player.showsVideo = player.currentHasPicture
                Task { await service.adoptExternalMedia() }
            case .background:
                // 摘掉视频图层，改为纯音频播放，避免被系统挂起
                player.showsVideo = false
            default:
                break
            }
        }
        // 启动时先把外部塞进来的媒体收进资料库（「文件」App 或 Mac 推过来的 MP3）。
        .task { await service.adoptExternalMedia() }
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
        }
    }
}
