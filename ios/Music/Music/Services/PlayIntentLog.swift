// 用途：把播放链路的执行痕迹落到 Documents 下的文件里。
// 系统在后台唤起 App 执行 Intent 时，devicectl --console 抓不到 stdout，
// 只能靠文件留证，再用 devicectl 把 appDataContainer 拉回来。
import Foundation

enum PlayIntentLog {
    private static let url: URL = {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("play-intent.log")
    }()

    static func write(_ message: String) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let line = "\(formatter.string(from: Date())) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }

        // 只留最近一段：日志是排障用的，不能无限增长。
        if let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int, size > 64_000 {
            try? FileManager.default.removeItem(at: url)
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
        NSLog("[PlayIntentLog] %@", message)
    }
}
