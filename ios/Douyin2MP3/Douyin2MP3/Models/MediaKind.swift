// 用途：媒体类型判定（视频/音频）。类型只由文件扩展名推导，不在索引里新增必填字段，
// 老 library.json 不需要迁移。
import Foundation

enum MediaKind: String {
    case video
    case audio

    /// 播放时有没有画面：视频走 AVPlayerLayer，音频走封面。
    var hasPicture: Bool { self == .video }

    private static let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "webm", "mkv"]
    private static let audioExtensions: Set<String> = ["mp3", "m4a", "aac", "wav", "aif", "aiff", "caf", "flac", "opus"]

    init(fileName: String) {
        let ext = (fileName as NSString).pathExtension.lowercased()
        if Self.audioExtensions.contains(ext) {
            self = .audio
        } else {
            self = .video
        }
    }

    /// 资料库收录外部文件时判断这个文件能不能入库。
    static func isSupported(fileName: String) -> Bool {
        let ext = (fileName as NSString).pathExtension.lowercased()
        return audioExtensions.contains(ext) || videoExtensions.contains(ext)
    }
}

extension MediaItem {
    var kind: MediaKind { MediaKind(fileName: fileName) }
    var isAudio: Bool { kind == .audio }
}
