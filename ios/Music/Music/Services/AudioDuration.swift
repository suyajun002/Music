// 用途：量本地音频文件的真实时长，给取流链路做「文件到底是不是完整的」兜底。
//
// 为什么需要：YouTube 那边的 actor 偶尔会在断线重连后，只把开头几秒传上来，
// 却拿源视频的时长元数据判定「已到结尾」并报成功（2026-11 实测：199 秒的歌只落了 10 秒）。
// dataset 里的 `duration` 是源视频的，不是落盘文件的，所以只能自己量。
import Foundation
#if canImport(AVFoundation)
import AVFoundation
#endif

enum AudioDuration {
    /// 读容器时长（秒）。读不出来返回 nil —— 不等于「0 秒」，也不等于「完整」，
    /// 由调用方按 `AudioTruncation` 的规则决定怎么处理。
    static func seconds(at url: URL) async -> Double? {
        #if canImport(AVFoundation)
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration) else { return nil }
        let seconds = CMTimeGetSeconds(duration)
        guard seconds.isFinite, seconds > 0 else { return nil }
        return seconds
        #else
        return nil
        #endif
    }
}

/// 「落盘文件是否明显短于预期」的判定。纯函数，不碰 AVFoundation，命令行可直接单测。
enum AudioTruncation {
    /// 允许的绝对误差。两秒以内的差异来自编码器的收尾帧，不当成残文件。
    static let toleranceSeconds: Double = 5
    /// 允许的相对误差。短视频上 `toleranceSeconds` 占比过大，所以再压一道 90%。
    static let minimumRatio: Double = 0.9

    /// - Parameters:
    ///   - expected: 源视频时长；nil 表示 actor 没给，此时不做判断（老结果兼容）。
    ///   - actual: 落盘文件实测时长；nil/<=0 表示量不出来，按残文件处理。
    static func isTruncated(expected: Double?, actual: Double?) -> Bool {
        guard let expected, expected > 0 else { return false }
        guard let actual, actual > 0 else { return true }
        if expected - actual > toleranceSeconds { return true }
        return actual < expected * minimumRatio
    }
}
