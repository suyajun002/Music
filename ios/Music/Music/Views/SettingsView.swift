// 用途：唯一的设置面板。从底部玩偶的菜单进，也从中途弹出的确认框进。
// 装两件事：Apify token（YouTube 取流要用）和同时下载数。
import SwiftUI

enum SettingsRoute: Hashable {
    case convert
}

struct SettingsView: View {
    @EnvironmentObject private var service: ConversionService
    @EnvironmentObject private var player: MediaPlayer
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var keyStore = ApifyKeyStore.shared
    @State private var path: [SettingsRoute]

    init(initialRoute: SettingsRoute? = nil) {
        _path = State(initialValue: initialRoute.map { [$0] } ?? [])
    }

    /// 输入框里的新 token。**不回填已保存的那份**：没必要让密钥进视图状态，
    /// 而且这一栏的语义本来就清楚 —— 「填了就追加，留空不动」。
    @State private var draft = ""
    @State private var verify = VerifyState.idle
    @State private var confirmsClear = false
    @AppStorage(LoudnessStore.enabledKey) private var loudnessNormalization = true

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
                audioEffectSection
                loudnessSection
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
            SecureField("粘贴 Apify token（可一次粘多个，用空格或换行分开）", text: $draft)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.callout.monospaced())

            HStack {
                Button("添加") { addTokens() }
                    .disabled(
                        draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || verify == .working
                    )

                Button("检查全部") { Task { await runVerify(ids: nil) } }
                    .disabled(!keyStore.hasAnyKey || verify == .working)

                Spacer()

                if keyStore.hasAnyKey {
                    Button("清除全部", role: .destructive) { confirmsClear = true }
                }
            }
            .font(.subheadline)

            ForEach(keyStore.keys) { key in
                keyRow(key)
            }
            .onDelete { offsets in
                for index in offsets {
                    guard keyStore.keys.indices.contains(index) else { continue }
                    keyStore.remove(keyStore.keys[index].id)
                }
                verify = .idle
            }

            verifyStatus
        } header: {
            Text("YouTube（Apify）")
        } footer: {
            Text("""
            手机上跑不了 yt-dlp，所以 YouTube 这条走 Apify 的现成 actor：你得有个 Apify 账号，
            在 Apify 控制台 → Settings → API & Integrations 里拿 token，粘到这里。

            可以加多个账号的 token。取流时优先用第一个「可用」的 key；遇到余额不足或额度用完，
            会自动切到下一个，不中断当前任务。全部都不可用时任务才会失败，并提示去充值或换 key。

            充值后点「检查全部」，验证通过会把 key 恢复为可用。

            token 存在这台手机的钥匙串里（不进 iCloud 备份、不进本机备份），列表只显示末 4 位。

            ⚠️ 这条路**按音频时长计费**：实测均值约 $0.068/首（≈¥0.5），单首 1~3 分钟；
            下载失败不收下载费。免费套餐每月 $5，大约够 73 首。
            """)
        }
        .alert("清除全部 Apify key？", isPresented: $confirmsClear) {
            Button("取消", role: .cancel) {}
            Button("清除", role: .destructive) {
                keyStore.removeAll()
                draft = ""
                verify = .idle
            }
        } message: {
            Text("这台手机上保存的所有 token 都会被删掉，已下载的歌不受影响。")
        }
    }

    private func keyRow(_ key: ApifyKeySummary) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(key.label ?? "未验证账号")
                        .font(.subheadline)
                    if key.isCurrent {
                        Text("当前")
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.15), in: Capsule())
                    }
                }
                Text(key.maskedToken)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                if let error = key.lastError, key.state != .active {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            Text(key.state.displayName)
                .font(.caption.weight(.medium))
                .foregroundStyle(stateColor(key.state))
        }
    }

    private func stateColor(_ state: ApifyKeyState) -> Color {
        switch state {
        case .active: return .green
        case .exhausted: return .orange
        case .invalid: return .red
        }
    }

    @ViewBuilder
    private var verifyStatus: some View {
        switch verify {
        case .idle:
            if keyStore.hasAnyKey {
                let active = keyStore.keys.filter { $0.state == .active }.count
                Label(
                    active > 0
                        ? "\(active) 个可用 / 共 \(keyStore.keys.count) 个"
                        : "没有可用 key，去充值或换一个",
                    systemImage: active > 0 ? "key.fill" : "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(active > 0 ? Color.secondary : Color.orange)
            }
        case .working:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("正在检查 key…").font(.caption).foregroundStyle(.secondary)
            }
        case .ok(let message):
            Label(message, systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "xmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    private func addTokens() {
        let raw = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        let ids = keyStore.add(tokens: raw)
        draft = ""
        guard !ids.isEmpty else {
            verify = .failed("这个 token 已经在列表里，而且当前可用")
            return
        }
        MusicDebug.log("已添加 Apify key \(ids.count) 个")
        Task { await runVerify(ids: Set(ids)) }
    }

    private func runVerify(ids: Set<UUID>?) async {
        verify = .working
        let report = await keyStore.verify(ids: ids) { token in
            try await service.verifyApifyToken(token)
        }
        if report.total == 0 {
            verify = .idle
        } else if report.failed == 0 {
            verify = .ok(report.summary)
        } else {
            verify = .failed(report.summary)
        }
    }

    // MARK: - 音效

    private var audioEffectSection: some View {
        Section {
            Picker("音效", selection: Binding(
                get: { player.audioEffectID ?? "" },
                set: { player.setAudioEffect(id: $0.isEmpty ? nil : $0) }
            )) {
                Text("关闭（原声）").tag("")
                ForEach(AudioEffectPresets.all) { preset in
                    Text(preset.name).tag(preset.id)
                }
            }
            if let current = AudioEffectPresets.preset(id: player.audioEffectID) {
                Text(current.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("音效")
        } footer: {
            Text("""
            在解码后的音频上做处理（MTAudioProcessingTap），视频画面、锁屏、后台播放都不受影响。

            预设是数据（Resources/effectPresets.json），引擎按配置组装模块：EQ → 谐波激励 → 饱和 → 展宽 → 环境声 → 低频限幅 → 响度护栏。
            """)
        }
    }

    // MARK: - 音量均衡

    private var loudnessSection: some View {
        Section {
            Toggle("音量均衡", isOn: $loudnessNormalization)
                .onChange(of: loudnessNormalization) { _ in
                    player.refreshLoudness()
                }
        } header: {
            Text("音量")
        } footer: {
            Text("""
            按每首歌实测的整曲响度（EBU R128）统一到 -14 LUFS，避免老歌、串烧和单曲之间差十几个 dB。

            只调整这一首的整体增益，不压缩动态；已下载的老歌会在后台补测。
            """)
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
