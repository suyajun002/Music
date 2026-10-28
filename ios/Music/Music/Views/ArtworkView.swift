// 用途：统一封面显示（列表缩略图、迷你条、全屏播放页共用），带一个小缓存避免滚动时反复读盘。
import MediaPlayer
import SwiftUI
import UIKit

enum ArtworkCache {
    private static let cache = NSCache<NSString, UIImage>()

    static func image(at url: URL?) -> UIImage? {
        guard let url else { return nil }
        let key = url.path as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let image = UIImage(contentsOfFile: url.path) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }
}

struct ArtworkView: View {
    let url: URL?
    var size: CGFloat
    var corner: CGFloat = 6

    var body: some View {
        Group {
            if let image = ArtworkCache.image(at: url) {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                LinearGradient(
                    colors: [Color(white: 0.30), Color(white: 0.15)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .overlay {
                    Image(systemName: "music.note")
                        .font(.system(size: size * 0.38))
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .strokeBorder(.white.opacity(0.10), lineWidth: 0.5)
        }
    }
}

/// 转换记录的封面：下好的用真实封面，还没下好的用来源色块占位。
/// 和 `ArtworkView` 分开，是因为占位色/图标属于「任务来源」，不是媒体封面本身。
struct JobArtworkView: View {
    let source: MediaSource
    let state: JobState
    var artworkURL: URL?
    var size: CGFloat = 52
    var corner: CGFloat = 5

    var body: some View {
        Group {
            if let image = ArtworkCache.image(at: artworkURL) {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .strokeBorder(.white.opacity(0.10), lineWidth: 0.5)
        }
    }

    private var placeholder: some View {
        ZStack(alignment: .bottomTrailing) {
            LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
                .overlay {
                    Image(systemName: sourceIcon)
                        .font(.system(size: size * 0.34, weight: .semibold))
                        .foregroundStyle(.white.opacity(state == .failed ? 0.55 : 0.92))
                }
                .saturation(state == .failed ? 0.35 : 1)

            if state == .failed {
                Image(systemName: "exclamationmark.circle.fill")
                    .symbolRenderingMode(.palette)
                    .font(.system(size: size * 0.25, weight: .semibold))
                    .foregroundStyle(.white, .red)
                    .padding(3)
            }
        }
    }

    private var sourceIcon: String {
        switch source {
        case .douyin: return "music.note"
        case .youtube: return "play.fill"
        }
    }

    private var colors: [Color] {
        switch source {
        case .douyin:
            return [Color(red: 0.24, green: 0.17, blue: 0.25), Color(red: 0.06, green: 0.06, blue: 0.08)]
        case .youtube:
            return [Color(red: 0.80, green: 0.14, blue: 0.18), Color(red: 0.34, green: 0.03, blue: 0.06)]
        }
    }
}

/// 系统音量条（顺带带出 AirPlay 路由按钮），和音乐 App 一致。
struct SystemVolumeView: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: .init(x: 0, y: 0, width: 200, height: 32))
        view.showsRouteButton = true
        view.showsVolumeSlider = true
        view.tintColor = .secondaryLabel
        return view
    }

    func updateUIView(_ uiView: MPVolumeView, context: Context) {}
}
