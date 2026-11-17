// 用途：Apify 多 key 池。一个 key 余额不足或失效时自动切到下一个，
// 避免单条 token 用完就把整条付费取流链路拖停。
//
// 设计边界：
// - `ApifyKeyRing` 只做纯状态：选当前、标记、增删、重置，不碰网络、不碰钥匙串。
// - `ApifyKeyStore` 负责持久化与给 UI 的摘要；token 原文只在这个文件里流转，
//   视图拿到的只有掩码和状态。
// - 网络错误怎么归类由 `ApifyErrorClassifier` 决定，取流层只负责在拿到
//   `ApifyKeyRejection` 时通知 store 轮转。
import Foundation
import Combine

enum ApifyKeyState: String, Codable, CaseIterable {
    case active
    case exhausted
    case invalid

    var displayName: String {
        switch self {
        case .active: return "可用"
        case .exhausted: return "余额不足"
        case .invalid: return "无效"
        }
    }
}

struct ApifyKey: Codable, Identifiable, Equatable {
    let id: UUID
    var token: String
    var label: String?
    var state: ApifyKeyState
    var lastError: String?
    var updatedAt: Date
}

/// 给视图看的摘要：不含 token 原文。
struct ApifyKeySummary: Identifiable, Equatable {
    let id: UUID
    let maskedToken: String
    let label: String?
    let state: ApifyKeyState
    let lastError: String?
    /// 是不是当前会优先使用的那个 key。
    let isCurrent: Bool
}

/// 取流层每次尝试需要的凭证。只在内存里短暂存在，不进日志。
struct ApifyKeyCredential: Equatable {
    let id: UUID
    let token: String
    let label: String?
}

struct ApifyVerifyReport: Equatable {
    var total = 0
    var usable = 0
    var failed = 0
    var firstError: String?

    var summary: String {
        if total == 0 { return "还没有 key" }
        if failed == 0 { return "\(usable) 个 key 都可用" }
        if usable == 0 { return "\(failed) 个 key 都不可用\(firstError.map { "：\($0)" } ?? "")" }
        return "\(usable) 个可用，\(failed) 个不可用\(firstError.map { "：\($0)" } ?? "")"
    }
}

/// 纯状态机。测试可以直接构造它，不需要钥匙串或网络。
struct ApifyKeyRing {
    private(set) var keys: [ApifyKey]

    init(keys: [ApifyKey] = []) {
        self.keys = keys
    }

    /// 一次粘贴多个 token 时按空白、逗号、分号拆开；空串直接忽略。
    static func splitTokens(_ raw: String) -> [String] {
        raw.components(separatedBy: CharacterSet.whitespacesAndNewlines
            .union(CharacterSet(charactersIn: ",;"))
        )
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    }

    var hasAnyKey: Bool { !keys.isEmpty }
    var activeCount: Int { keys.filter { $0.state == .active }.count }

    /// 第一条可用 key。顺序就是用户添加的顺序。
    var current: ApifyKey? {
        keys.first { $0.state == .active }
    }

    /// 本轮还没试过的下一条可用 key。`attempted` 防止同一轮里反复撞同一个 key。
    func credential(excluding attempted: Set<UUID>) -> ApifyKeyCredential? {
        guard let key = keys.first(where: {
            $0.state == .active && !attempted.contains($0.id)
        }) else { return nil }
        return ApifyKeyCredential(id: key.id, token: key.token, label: key.label)
    }

    /// 追加一条 key。重复 token 不新增；如果它之前被标记为不可用，则顺手恢复成可用。
    /// 返回 nil 表示这条 token 已经在列表里且本来就可用于是没改动。
    @discardableResult
    mutating func add(token raw: String, label: String? = nil) -> UUID? {
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return nil }
        if let index = keys.firstIndex(where: { $0.token == token }) {
            guard keys[index].state != .active else { return nil }
            keys[index].state = .active
            keys[index].lastError = nil
            keys[index].updatedAt = Date()
            if let label { keys[index].label = label }
            return keys[index].id
        }
        let key = ApifyKey(
            id: UUID(),
            token: token,
            label: label,
            state: .active,
            lastError: nil,
            updatedAt: Date()
        )
        keys.append(key)
        return key.id
    }

    mutating func mark(_ id: UUID, state: ApifyKeyState, reason: String?) {
        guard let index = keys.firstIndex(where: { $0.id == id }) else { return }
        keys[index].state = state
        keys[index].lastError = state == .active ? nil : reason
        keys[index].updatedAt = Date()
    }

    mutating func setLabel(_ label: String, for id: UUID) {
        guard let index = keys.firstIndex(where: { $0.id == id }) else { return }
        keys[index].label = label
        keys[index].updatedAt = Date()
    }

    mutating func setError(_ reason: String?, for id: UUID) {
        guard let index = keys.firstIndex(where: { $0.id == id }) else { return }
        keys[index].lastError = reason
        keys[index].updatedAt = Date()
    }

    mutating func resetAll() {
        for index in keys.indices {
            keys[index].state = .active
            keys[index].lastError = nil
            keys[index].updatedAt = Date()
        }
    }

    mutating func remove(_ id: UUID) {
        keys.removeAll { $0.id == id }
    }

    /// 只留末 4 位。token 很短时干脆全遮住，避免「掩码」反而漏出大半。
    static func mask(_ token: String) -> String {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 4 else { return "••••" }
        return "••••" + trimmed.suffix(4)
    }
}

/// Apify 的 key 级失败。取流层遇到它就知道「这个 key 不能再用，换下一个」。
struct ApifyKeyRejection: Error, LocalizedError, Equatable {
    enum Kind: Equatable {
        case invalid
        case exhausted
        case rateLimited
    }

    let kind: Kind
    let statusCode: Int?
    let detail: String?

    /// 429 只是暂时限流，不把 key 永久判死。
    var keyState: ApifyKeyState? {
        switch kind {
        case .invalid: return .invalid
        case .exhausted: return .exhausted
        case .rateLimited: return nil
        }
    }

    var errorDescription: String? {
        let suffix = detail.map { "：\($0)" } ?? ""
        switch kind {
        case .invalid:
            let code = statusCode.map { "（HTTP \($0)）" } ?? ""
            return "Apify key 无效或没权限\(code)\(suffix)"
        case .exhausted:
            return "Apify key 余额不足或额度用完\(suffix)"
        case .rateLimited:
            let code = statusCode.map { "（HTTP \($0)）" } ?? ""
            return "Apify 限流\(code)，稍后再试\(suffix)"
        }
    }
}

/// 把 Apify 的 HTTP 状态码和响应体翻译成「换 key」还是「普通失败」。
/// 纯函数，命令行可单测。
enum ApifyErrorClassifier {
    private static let rateKeywords = [
        "rate limit", "too many requests", "requests per second", "requests per minute",
    ]

    private static let balanceKeywords = [
        "insufficient", "not enough", "no funds", "out of credit", "out of funds",
        "out of balance", "balance", "credit", "payment", "billing",
        "quota", "usage limit", "monthly limit", "credit limit", "spending limit",
        "limit exceeded", "limit reached", "reached the limit", "exceeded your",
        "top up", "recharge",
    ]

    static func looksLikeRateLimit(_ text: String) -> Bool {
        let lower = text.lowercased()
        return rateKeywords.contains { lower.contains($0) }
    }

    static func looksLikeBalanceIssue(_ text: String) -> Bool {
        let lower = text.lowercased()
        // 先排除限流，否则 "rate limit" 里的 "limit" 会被误判成额度问题。
        guard !looksLikeRateLimit(lower) else { return false }
        return balanceKeywords.contains { lower.contains($0) }
    }

    /// 从 Apify 的 JSON 错误体里取一句人能看的话；取不到就返回 nil。
    /// 不把 HTML 错误页整段塞进界面。
    static func message(from data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = object["error"] as? String {
                return clean(error)
            }
            if let error = object["error"] as? [String: Any] {
                if let message = error["message"] as? String { return clean(message) }
                if let type = error["type"] as? String { return clean(type) }
            }
            if let message = object["message"] as? String { return clean(message) }
        }
        guard let text = String(data: data.prefix(512), encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.lowercased().hasPrefix("<") else { return nil }
        return clean(trimmed)
    }

    /// HTTP 层失败。返回 nil 表示不是 key 级问题，交给调用方报普通失败。
    static func rejection(statusCode: Int, body: Data) -> ApifyKeyRejection? {
        let detail = message(from: body)
        switch statusCode {
        case 401:
            return ApifyKeyRejection(kind: .invalid, statusCode: statusCode, detail: detail)
        case 402:
            return ApifyKeyRejection(kind: .exhausted, statusCode: statusCode, detail: detail)
        case 403:
            if let detail, looksLikeRateLimit(detail) {
                return ApifyKeyRejection(kind: .rateLimited, statusCode: statusCode, detail: detail)
            }
            if let detail, looksLikeBalanceIssue(detail) {
                return ApifyKeyRejection(kind: .exhausted, statusCode: statusCode, detail: detail)
            }
            return ApifyKeyRejection(kind: .invalid, statusCode: statusCode, detail: detail)
        case 429:
            return ApifyKeyRejection(kind: .rateLimited, statusCode: statusCode, detail: detail)
        default:
            // 个别网关会把余额问题包成 400。只要 4xx 的正文明确说余额/额度，
            // 仍然按「换 key」处理；5xx 和网络问题不碰。
            guard (400..<500).contains(statusCode), let detail else { return nil }
            if looksLikeRateLimit(detail) {
                return ApifyKeyRejection(kind: .rateLimited, statusCode: statusCode, detail: detail)
            }
            if looksLikeBalanceIssue(detail) {
                return ApifyKeyRejection(kind: .exhausted, statusCode: statusCode, detail: detail)
            }
            return nil
        }
    }

    /// run 已创建后 actor 自己报的失败。只有明确是余额/额度才轮转；
    /// 私享视频、年龄限制、直播回放这类普通失败不换 key，避免重复计费。
    static func rejection(runMessage: String?) -> ApifyKeyRejection? {
        guard let runMessage, !runMessage.isEmpty,
              looksLikeBalanceIssue(runMessage)
        else { return nil }
        return ApifyKeyRejection(kind: .exhausted, statusCode: nil, detail: runMessage)
    }

    private static func clean(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        return String(text.prefix(300))
    }
}

/// App 里唯一的 key 池。token 存在钥匙串，UI 只拿摘要。
@MainActor
final class ApifyKeyStore: ObservableObject {
    static let shared = ApifyKeyStore()

    /// 新的多 key 存储键。旧的单条 `apify.token` 只用于首次迁移。
    static let storageKey = "apify.keys.v2"

    @Published private(set) var ring: ApifyKeyRing

    private init() {
        let loaded = Self.load()
        if !loaded.isEmpty {
            ring = ApifyKeyRing(keys: loaded)
            return
        }

        // 老版本只存了一条 apify.token。第一次启动顺手迁进数组并删掉旧条目，
        // 避免同一份凭证在钥匙串里留两个来源。
        if let legacy = KeychainStore.string(forKey: KeychainStore.apifyTokenKey) {
            var migrated = ApifyKeyRing()
            for token in ApifyKeyRing.splitTokens(legacy) {
                _ = migrated.add(token: token)
            }
            if !migrated.keys.isEmpty {
                ring = migrated
                if Self.save(migrated.keys) {
                    KeychainStore.set(nil, forKey: KeychainStore.apifyTokenKey)
                    MusicDebug.log("Apify key 已从旧版单 token 迁移 \(migrated.keys.count) 个")
                } else {
                    MusicDebug.log("Apify key 迁移写入失败，保留旧条目")
                }
                return
            }
        }

        ring = ApifyKeyRing()
    }

    var hasAnyKey: Bool { ring.hasAnyKey }
    var hasUsableKey: Bool { ring.activeCount > 0 }

    /// 当前优先使用的 key。全部不可用时返回 nil。
    var currentKeyID: UUID? { ring.current?.id }

    /// 视图专用摘要：不含 token 原文。
    var keys: [ApifyKeySummary] {
        let currentID = currentKeyID
        return ring.keys.map { key in
            ApifyKeySummary(
                id: key.id,
                maskedToken: ApifyKeyRing.mask(key.token),
                label: key.label,
                state: key.state,
                lastError: key.lastError,
                isCurrent: key.id == currentID
            )
        }
    }

    /// 本轮还没试过的下一条可用 key。取流失败后调用它就能自然切到下一条。
    func nextCredential(excluding attempted: Set<UUID>) -> ApifyKeyCredential? {
        ring.credential(excluding: attempted)
    }

    /// 添加一条或多条 token。返回这次真正新增/恢复的 key id，重复且可用的不返回。
    @discardableResult
    func add(tokens raw: String) -> [UUID] {
        var changed: [UUID] = []
        for token in ApifyKeyRing.splitTokens(raw) {
            if let id = ring.add(token: token) { changed.append(id) }
        }
        if !changed.isEmpty { persist() }
        return changed
    }

    func mark(_ id: UUID, state: ApifyKeyState, reason: String?) {
        ring.mark(id, state: state, reason: reason)
        persist()
    }

    /// 限流、网络故障这类「这次不行但 key 没坏」的情况只记原因，不改可用状态。
    func noteFailure(_ id: UUID, reason: String?) {
        ring.setError(reason, for: id)
        persist()
    }

    func remove(_ id: UUID) {
        ring.remove(id)
        persist()
    }

    func removeAll() {
        ring = ApifyKeyRing()
        persist()
    }

    /// 用户充值后点「检查全部」：验证成功就恢复为可用，失败按错误类型标记。
    /// 网络错误不动可用状态，避免一次断网把整池 key 判死。
    func verify(
        ids: Set<UUID>? = nil,
        using verify: (String) async throws -> String
    ) async -> ApifyVerifyReport {
        let targets = ring.keys.filter { ids?.contains($0.id) ?? true }
        var report = ApifyVerifyReport(total: targets.count)

        for key in targets {
            if Task.isCancelled { break }
            do {
                let username = try await verify(key.token)
                ring.setLabel(username, for: key.id)
                ring.mark(key.id, state: .active, reason: nil)
                report.usable += 1
            } catch let rejection as ApifyKeyRejection {
                if let state = rejection.keyState {
                    ring.mark(key.id, state: state, reason: rejection.errorDescription)
                } else {
                    ring.setError(rejection.errorDescription, for: key.id)
                }
                report.failed += 1
                if report.firstError == nil { report.firstError = rejection.errorDescription }
                if rejection.kind == .rateLimited { break }
            } catch {
                if error is CancellationError { break }
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                ring.setError(message, for: key.id)
                report.failed += 1
                if report.firstError == nil { report.firstError = message }
            }
        }

        persist()
        return report
    }

    // MARK: - 持久化

    /// 钥匙串里存 JSON 数组。与单 token 一样是 ThisDeviceOnly，不进备份。
    private func persist() {
        if !Self.save(ring.keys) {
            MusicDebug.log("Apify key 写入钥匙串失败（\(ring.keys.count) 个）")
        }
    }

    private static func save(_ keys: [ApifyKey]) -> Bool {
        guard let data = try? JSONEncoder().encode(keys),
              let json = String(data: data, encoding: .utf8)
        else { return false }
        return KeychainStore.set(json, forKey: storageKey)
    }

    private static func load() -> [ApifyKey] {
        guard let raw = KeychainStore.string(forKey: storageKey),
              let data = raw.data(using: .utf8),
              let keys = try? JSONDecoder().decode([ApifyKey].self, from: data)
        else { return [] }
        return keys
    }
}
