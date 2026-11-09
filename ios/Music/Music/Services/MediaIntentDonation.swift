// 用途：把「我在播什么」和「我有多大曲库」捐给系统。App Selection / Siri 建议靠
// donation 学习哪些 App 是真正的媒体 App；不捐的话系统只知道我们能响应 intent，
// 不知道我们真的在播东西。
import Foundation
import Intents

enum MediaIntentDonation {
    /// 每开始播一首捐一次。Apple 建议放单曲而不是整个播放列表时捐单曲；
    /// 这里没有播放列表概念，曲子就是最小单位。
    static func donatePlayback(of item: MediaItem) {
        let mediaItem = INMediaItem(
            identifier: item.id,
            title: item.title,
            type: .song,
            artwork: nil
        )
        let intent = INPlayMediaIntent(
            mediaItems: [mediaItem],
            mediaContainer: nil,
            playShuffled: nil
        )
        intent.suggestedInvocationPhrase = "播放\(item.title)"

        let interaction = INInteraction(intent: intent, response: nil)
        interaction.donate { error in
            if let error {
                NSLog("MediaIntentDonation donate failed: %@", error.localizedDescription)
            }
        }
    }

    /// 曲库规模 + 订阅状态。系统用它给 App Selection 排序，缺了会被当成空库 App。
    static func reportLibraryContext(itemCount: Int) {
        let context = INMediaUserContext()
        context.numberOfLibraryItems = itemCount
        context.subscriptionStatus = .unknown
        context.becomeCurrent()
    }
}
