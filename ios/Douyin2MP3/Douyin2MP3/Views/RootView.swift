// 用途：根视图。资料库（音乐 App 形态）+ 转视频两个页签，迷你播放条常驻，进后台摘画面保证声音继续。
import SwiftUI

struct RootView: View {
    @EnvironmentObject private var service: ConversionService
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView {
            LibraryView()
                .tabItem { Label("资料库", systemImage: "music.note.list") }
            ConvertView()
                .tabItem { Label("转视频", systemImage: "arrow.down.circle") }
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
