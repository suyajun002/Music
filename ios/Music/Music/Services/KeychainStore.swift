// 用途：钥匙串存取。token 这类凭证放这里，不放 UserDefaults
// —— UserDefaults 落在沙盒里的明文 plist，会进 Finder/iTunes 备份，肉眼也能翻到。
import Foundation
import Security

enum KeychainStore {
    /// Apify token 在钥匙串里的条目名。
    static let apifyTokenKey = "apify.token"

    static func string(forKey key: String) -> String? {
        var query = baseQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 存或清（传 nil / 空串即删除）。返回是否成功。
    @discardableResult
    static func set(_ value: String?, forKey key: String) -> Bool {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else {
            let status = SecItemDelete(baseQuery(key) as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }

        let data = Data(trimmed.utf8)
        // 先试更新、不成就新增：比「先查再写」少一次竞态窗口，代码也更短。
        let update = SecItemUpdate(
            baseQuery(key) as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if update == errSecSuccess { return true }
        guard update == errSecItemNotFound else { return false }

        var query = baseQuery(key)
        query[kSecValueData as String] = data
        // 首次解锁后即可读（后台下载也会用到），但**不跟着备份跑**：
        // 凭证只该留在这台设备上。
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    private static func baseQuery(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }

    /// 服务名用 bundle id，同一台设备上不会和别的 App 的条目撞名。
    private static var service: String {
        Bundle.main.bundleIdentifier ?? "com.yajun.douyin2mp3"
    }
}
