// 用途：唯一的设置面板。从底部玩偶的菜单进，也从中途弹出的确认框进。
// 装两件事：Apify token（YouTube 取流要用）和同时下载数。
import SwiftUI

enum SettingsRoute: Hashable {
    case convert
}

struct SettingsView: View {
    @EnvironmentObject private var service: ConversionService
    @Environment(\.dismiss) private var dismiss
    @State private var path: [SettingsRoute]

    init(initialRoute: SettingsRoute? = nil) {
        _path = State(initialValue: initialRoute.map { [$0] } ?? [])
    }

    /// 输入框里的新 token。**不回填已保存的那份**：没必要让密钥进视图状态，
    /// 而且这一栏的语义本来就清楚 —— 「填了就覆盖，留空不动」。
    @State private var draft = ""
    @State private var verify = VerifyState.idle

    private enum VerifyState: Equatable {
        case idle
        case working
        case ok(String)
        case failed(String)
    }

    var body: some View {
        NavigationStack(path: $path) {
            Form {
                youtubeSection
                downloadSection
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .navigationDestination(for: SettingsRoute.self) { route in
                switch route {
                case .convert:
                    ConvertView()
                }
            }
        }
    }

    // MARK: - YouTube

    private var youtubeSection: some View {
        Section {
            SecureField("粘贴 Apify token", text: $draft)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.callout.monospaced())

            HStack {
                Button("保存") { save() }
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button("验证") { Task { await runVerify() } }
                    .disabled(verify == .working)

                Spacer()

                if service.hasApifyToken {
                    Button("清除", role: .destructive) {
                        service.setApifyToken(nil)
                        draft = ""
                        verify = .idle
                    }
                }
            }
            .font(.subheadline)

            verifyStatus
        } header: {
            Text("YouTube（Apify）")
        } footer: {
            Text("""
            手机上跑不了 yt-dlp，所以 YouTube 这条走 Apify 的现成 actor：你得有个 Apify 账号，
            在 Apify 控制台 → Settings → API & Integrations 里拿 token，粘到这里。

            token 存在这台手机的钥匙串里（不进 iCloud 备份、不进本机备份），换一个存一个，存完立刻生效。

            ⚠️ 这条路**按音频时长计费**：实测均值约 $0.068/首（≈¥0.5），单首 1~3 分钟；
            下载失败不收下载费。免费套餐每月 $5，大约够 73 首。
            """)
        }
    }

    @ViewBuilder
    private var verifyStatus: some View {
        switch verify {
        case .idle:
            if service.hasApifyToken {
                Label("已保存", systemImage: "checkmark.seal")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .working:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("正在验证…").font(.caption).foregroundStyle(.secondary)
            }
        case .ok(let username):
            Label("token 可用，账号 \(username)", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "xmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    private func save() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        service.setApifyToken(trimmed)
        draft = ""
        verify = .idle
        DouyinDebug.log("已保存 Apify token（\(trimmed.count) 字符）")
    }

    private func runVerify() async {
        verify = .working
        do {
            // 输入框里有新的就验新的，没填就验已保存的那份 —— 两种意图都自然。
            let username = try await service.verifyApifyToken(draft)
            verify = .ok(username)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            verify = .failed(message)
        }
    }

    // MARK: - 下载

    private var downloadSection: some View {
        Section {
            Picker("同时下载", selection: Binding(
                get: { service.maxConcurrent },
                set: { service.maxConcurrent = $0 }
            )) {
                ForEach(ConversionService.concurrencyOptions, id: \.self) { count in
                    Text("\(count) 个").tag(count)
                }
            }
        } header: {
            Text("下载")
        } footer: {
            Text("同时下载几条。YouTube 那条链路单首本来就要 1~3 分钟，一次粘多条时并行才有意义。")
        }
    }
}
