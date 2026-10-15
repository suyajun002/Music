// 用途：App 入口。只负责创建状态中枢，业务都在 Services 层。
import SwiftUI

@main
struct Douyin2MP3App: App {
    @StateObject private var service = ConversionService()

    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(service)
        }
    }
}
