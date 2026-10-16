// 用途：主页面。粘贴即自动下载；任务卡片只显示「当前结论 + 一句话原因 + 动作」。
import SwiftUI
import UIKit

struct ConvertView: View {
    @EnvironmentObject private var service: ConversionService
    /// 设置面板由根视图持有（确认框里的「去设置」也要开同一个），这里只借用一下开关。
    @Binding var showsSettings: Bool
    @State private var input = ""
    @State private var outcome: SubmitOutcome?
    /// 「粘贴链接」按钮的失败原因。空着就是没出问题。
    @State private var pasteNote: String?
    @FocusState private var inputFocused: Bool

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextEditor(text: $input)
                        .frame(minHeight: 80)
                        .focused($inputFocused)
                        .overlay(alignment: .topLeading) {
                            if input.isEmpty {
                                Text("粘贴分享文本或链接（抖音 / YouTube，可一次粘多条，每行一条）")
                                    .foregroundStyle(.secondary)
                                    .padding(.top, 8)
                                    .padding(.leading, 5)
                                    .allowsHitTesting(false)
                            }
                        }

                    HStack {
                        Button("粘贴链接", systemImage: "doc.on.clipboard") {
                            paste()
                        }
                        Spacer()
                        Button("清空") {
                            input = ""
                            outcome = nil
                            pasteNote = nil
                            service.clearClipboardOutcome()
                        }
                            .foregroundStyle(.secondary)
                    }
                    .font(.subheadline)

                    // 「点了没反应」是这类按钮最容易招人骂的地方，所以每一种「什么也没发生」
                    // 都要说一句为什么 —— 要么读不到剪贴板，要么读到了但一条链接都没认出来。
                    if let pasteNote {
                        Text(pasteNote)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    if let notice {
                        Text(notice.text)
                            .font(.caption)
                            .foregroundStyle(notice.isWarning ? Color.red : Color.secondary)
                    }
                } header: {
                    Text("链接")
                } footer: {
                    Text(footerText)
                }

                if !service.jobs.isEmpty {
                    Section {
                        ForEach(service.jobs) { job in
                            JobRow(job: job)
                        }
                        .onDelete { offsets in
                            for index in offsets { service.remove(jobID: service.jobs[index].id) }
                        }
                    } header: {
                        HStack {
                            Text("转换记录")
                            Spacer()
                            if service.activeCount > 0 {
                                Text("进行中 \(service.runningCount) · 等待 \(service.waitingCount)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } footer: {
                        if !service.jobs.contains(where: { !$0.state.isActive }) {
                            EmptyView()
                        } else {
                            Button("清除已完成") { service.clearFinished() }
                                .font(.caption)
                        }
                    }
                }
            }
            .navigationTitle("转视频")
            // 点空白/滚动就收起键盘，不该把人一直困在键盘页
            .scrollDismissesKeyboard(.immediately)
            .task(id: input) { await submitPasted() }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showsSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .badge(service.hasApifyToken ? nil : "1")
                }
            }
        }
    }

    /// 页面底部那段说明。两条链路差别够大，值得在这儿说清楚，而不是等用户自己发现。
    private var footerText: String {
        var text = "粘贴后自动开始下载。打开 App（或从抖音、YouTube 切回来）时会自动识别剪贴板里的链接，识别到会先弹框让你确认。完成后会出现在「资料库」；已经在资料库里的不会重复下载，锁屏和后台都能继续播放。"
        text += "\n\n抖音：在手机上直接解析，不花钱。"
        if service.hasApifyToken {
            text += "YouTube：走 Apify，每首约 ¥0.5，一首 1~3 分钟。"
        } else {
            text += "YouTube：还没填 Apify token，点右上角齿轮填一次。"
        }
        return text
    }

    /// 把结构化结果翻成一行结论，页面只展示结论、不做判断。
    /// 手动粘贴的结论优先；没有就显示「剪贴板确认框里点了下载」那次的结果。
    private var notice: (text: String, isWarning: Bool)? {
        if let outcome { return (text(for: outcome), !outcome.hasLink) }
        if let confirmed = service.clipboardOutcome {
            return ("剪贴板链接：" + text(for: confirmed), !confirmed.hasLink)
        }
        return nil
    }

    private func text(for outcome: SubmitOutcome) -> String {
        guard outcome.hasLink else {
            // 认出来是链接、但来源不认识，和「压根没抠出链接」是两回事，分开说
            guard outcome.unsupported > 0 else {
                return "没识别到链接，请粘贴完整的分享文本或链接"
            }
            return "\(outcome.unsupported) 条链接不支持，目前只认抖音和 YouTube"
        }
        var parts: [String] = []
        if outcome.queued > 0 { parts.append("已开始下载 \(outcome.queued) 条") }
        // 「跳过」两个字要写出来：只说「N 条已在资料库」像是陈述事实，
        // 而用户真正想知道的是「我这次没重复提交吧」。
        if outcome.downloaded > 0 { parts.append("\(outcome.downloaded) 条已在资料库，跳过") }
        if outcome.running > 0 { parts.append("\(outcome.running) 条正在下载，跳过") }
        if outcome.unsupported > 0 { parts.append("\(outcome.unsupported) 条不支持") }
        return parts.joined(separator: "，")
    }

    /// 「粘贴链接」按钮。
    ///
    /// ⚠️ 三个坑都在这一个按钮上，历史上它「点了没反应」就是踩了这三个：
    /// 1. `UIPasteboard.general.string` 在**用户拒绝过系统粘贴授权**之后会一直返回 nil
    ///    （iOS 16 起的系统框点过「不允许」就记住了），不能默默什么都不做；
    /// 2. 剪贴板里不是文本（图片、文件）时同样是 nil；
    /// 3. 粘进来的内容**和输入框里现有的完全一样**时，`input` 没变 →
    ///    `.task(id: input)` 不触发 → 看着就像按钮坏了。所以这种情况要自己提交一次。
    private func paste() {
        guard let text = UIPasteboard.general.string?
            .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
        else {
            DouyinDebug.log("点「粘贴链接」：没读到剪贴板文本")
            pasteNote = "没读到剪贴板内容：可能被系统拒绝了粘贴授权（设置 → Music → 从其他 App 粘贴 → 允许），或者剪贴板里不是文字。"
            return
        }

        pasteNote = nil
        if text == input {
            DouyinDebug.log("点「粘贴链接」：内容和输入框一样，直接提交一次")
            Task { await submit(text) }
        } else {
            DouyinDebug.log("点「粘贴链接」：填入 \(text.count) 个字符")
            input = text
        }
    }

    /// 粘贴即下载：`.task(id:)` 在输入变化时重跑，天然形成「等粘贴落定」的防抖。
    private func submitPasted() async {
        guard !input.isEmpty else { return }
        try? await Task.sleep(for: .milliseconds(450))
        guard !Task.isCancelled else { return }
        await submit(input)
    }

    /// 真正的提交。手输、自动识别、按钮重复粘贴都走这里，结论口径只有一套。
    private func submit(_ text: String) async {
        let result = await service.autoSubmit(from: text)
        guard !Task.isCancelled else { return }
        outcome = result

        // 识别到链接就把输入框清掉，让用户直接看到下面开始跑的任务
        guard result.hasLink else { return }
        inputFocused = false
        input = ""
    }
}

private struct JobRow: View {
    @EnvironmentObject private var service: ConversionService
    @EnvironmentObject private var player: MediaPlayer
    let job: Job

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(job.displayTitle)
                .font(.body.weight(.medium))
                .lineLimit(2)

            HStack(spacing: 8) {
                Image(systemName: statusIcon)
                    .font(.caption)
                    .foregroundStyle(statusColor)
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(job.state == .failed ? .red : .secondary)
                Spacer()
                // 混着粘两边的链接时，得一眼看出这条走的是哪条链路 —— 失败原因只有配上来历才读得懂
                Text(job.source.displayName)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                if job.state == .ready {
                    Text(job.sizeText).font(.caption).foregroundStyle(.secondary)
                }
            }

            if job.state.isActive {
                if job.progressUnknown {
                    // 服务器没给总大小：走不确定进度条，避免停在某个假百分比
                    ProgressView()
                        .progressViewStyle(.linear)
                } else {
                    ProgressView(value: job.progress)
                        .progressViewStyle(.linear)
                }
            }

            if job.state == .ready, let videoID = job.videoID,
               let item = service.library.items.first(where: { $0.id == videoID }) {
                HStack(spacing: 14) {
                    Button {
                        service.play(item)
                    } label: {
                        Label(
                            player.currentID == item.id && player.isPlaying ? "正在播放" : "播放",
                            systemImage: "play.fill"
                        )
                    }
                    .font(.subheadline)

                    Label("已存到手机", systemImage: "checkmark.circle")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var statusIcon: String {
        switch job.state {
        case .queued: return "clock"
        case .running: return "arrow.down.circle"
        case .ready: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        }
    }

    private var statusColor: Color {
        switch job.state {
        case .ready: return .green
        case .failed: return .red
        default: return .secondary
        }
    }

    private var statusText: String {
        if job.state == .failed { return job.error ?? "下载失败" }
        if job.state == .running {
            var parts = [job.stage]
            if let attempt = job.attempt { parts.append(attempt) }
            if job.progressUnknown {
                parts.append("已下载 \(job.downloadedText)")
            } else {
                parts.append("\(Int(job.progress * 100))%")
            }
            return parts.joined(separator: " · ")
        }
        return job.stage
    }
}
