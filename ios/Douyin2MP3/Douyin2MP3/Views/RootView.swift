// 用途：根视图。两个页签 + 常驻播放条 + 全屏播放页；进入后台时摘掉画面保证声音继续。
import SwiftUI

struct RootView: View {
    @EnvironmentObject private var service: ConversionService
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView {
            ConvertView()
                .tabItem { Label("转视频", systemImage: "arrow.down.circle") }
            LibraryView()
                .tabItem { Label("音乐库", systemImage: "music.note.list") }
        }
        .safeAreaInset(edge: .bottom) {
            PlayerBar()
        }
        .sheet(isPresented: Binding(
            get: { service.player.isExpanded },
            set: { service.player.isExpanded = $0 }
        )) {
            PlayerView().environmentObject(service)
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                service.player.showsVideo = true
            case .background:
                // 摘掉视频图层，改为纯音频播放，避免被系统挂起
                service.player.showsVideo = false
            default:
                break
            }
        }
    }
}
