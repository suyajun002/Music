// 用途：解 JSON 字符串转义。分享页和本地索引里的文本常带 \uXXXX、\/ 这类序列，需要统一解码。
import Foundation

enum JSONEscapes {
    /// 把一段 JSON 字符串字面量的内容解成真实文本。
    /// 必须带 .fragmentsAllowed：JSONSerialization 默认不接受顶层是字符串片段，
    /// 少了这个参数会永远返回 nil，文本就一直显示成未解码的样子。
    static func unescape(_ raw: String) -> String? {
        guard let data = "\"\(raw)\"".data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? String
    }

    /// 文本有时被转义了两层：解一层后仍残留 `\u002F` 这类序列，最多再解两层。
    /// 解不动就停下，本来正常的文本原样返回。
    static func decode(_ raw: String) -> String {
        var text = raw
        var passes = 0
        while passes < 3, let next = unescape(text), next != text {
            text = next
            passes += 1
        }
        return text
    }
}
