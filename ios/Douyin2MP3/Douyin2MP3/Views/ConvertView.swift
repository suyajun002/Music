// 用途：转视频子页（从「设置 → 转视频」进入）。粘贴即自动下载；任务行只显示结论、原因和动作。
import SwiftUI

struct ConvertView: View {
    @EnvironmentObject private var service: ConversionService
    @State private var input = ""
    @State private var outcome: SubmitOutcome?
    @FocusState private var inputFocused: Bool

    var body: some View {
        List {
                Section {
                    composer
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 6, trailing: 16))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)

                    if let notice {
                        noticeRow(notice)
                            .listRowInsets(EdgeInsets(top: 0, leading: 18, bottom: 8, trailing: 18))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                    }

                    // 「下过又删了」的链接默认不重下（YouTube 一条一钱），所以得给个明确的门：
                    // 用户点这里才真下。不点就什么都不发生，也不会花钱。
                    if let deleted = shownOutcome?.deleted, !deleted.isEmpty {
                        Button {
                            Task {
                                let result = await service.redownload(deleted)
                                outcome = result
                            }
                        } label: {
                            Label("重新下载这 \(deleted.count) 条", systemImage: "arrow.clockwise")
                                .font(.footnote.weight(.medium))
                        }
                        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 10, trailing: 16))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                    }
                }

                if service.jobs.isEmpty {
                    Section {
                        emptyState
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                    }
                } else {
                    Section {
                        ForEach(service.jobs) { job in
                            JobRow(job: job)
                        }
                        .onDelete { offsets in
                            for index in offsets { service.remove(jobID: service.jobs[index].id) }
                        }
                    } header: {
                        HStack(alignment: .firstTextBaseline) {
                            Text("转换记录")
                            Spacer()
                            if !recordSummary.isEmpty {
                                Text(recordSummary)
                                    .font(.caption)
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                                    .contentTransition(.numericText())
                            }
                        }
                    }
                }
        }
        .listStyle(.plain)
        .animation(.snappy, value: service.jobs.count)
        .animation(.snappy, value: service.jobs.map(\.state))
        .navigationTitle("转视频")
        // 点空白/滚动就收起键盘，不该把人一直困在键盘页
        .scrollDismissesKeyboard(.immediately)
        .task(id: input) { await submitPasted() }
        .toolbar {
            // 清除入口放在常驻工具栏：以前藏在整张列表末尾，任务一多就永远看不到。
            if service.completedCount + service.failedCount > 0 {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu("清除") {
                        if service.completedCount > 0 {
                            Button("清除已完成（\(service.completedCount)）") {
                                service.clearCompleted()
                            }
                        }
                        if service.failedCount > 0 {
                            Button("清除失败（\(service.failedCount)）") {
                                service.clearFailed()
                            }
                        }
                    }
                }
            }
        }
    }

    /// 输入条。做成音乐 App 搜索框的样子：灰色圆角、左侧图标、聚焦后直接粘贴。
    /// 比原来 80pt 高的 TextEditor 少占一屏，列表才是这个页面的主角。
    private var composer: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "link")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 1)

            TextField("粘贴分享文本或链接", text: $input, axis: .vertical)
                .lineLimit(1...3)
                .focused($inputFocused)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            if !input.isEmpty {
                Button {
                    input = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.body)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清空输入")
                .transition(.scale.combined(with: .opacity))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(.secondarySystemFill), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .animation(.snappy, value: input.isEmpty)
    }

    private func noticeRow(_ notice: (text: String, isWarning: Bool)) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: notice.isWarning ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(notice.isWarning ? Color.red : Color.green)
            Text(notice.text)
                .font(.footnote)
                .foregroundStyle(notice.isWarning ? Color.red : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text("还没有转换记录")
                .font(.headline)
            Text("粘贴链接后，下载进度和失败原因会出现在这里")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
    }

    /// 转换记录的一句话概况。只在页头出现，不占用每行的位置。
    private var recordSummary: String {
        var parts: [String] = []
        if service.activeCount > 0 {
            parts.append("进行中 \(service.runningCount) · 等待 \(service.waitingCount)")
        }
        if service.completedCount > 0 { parts.append("已完成 \(service.completedCount)") }
        if service.failedCount > 0 { parts.append("失败 \(service.failedCount)") }
        return parts.joined(separator: " · ")
    }

    /// 结论和「重新下载」按钮都看它：手输优先，没有就用剪贴板确认框那次的。
    private var shownOutcome: SubmitOutcome? {
        outcome ?? service.clipboardOutcome
    }

    /// 把结构化结果翻成一行结论，页面只展示结论、不做判断。
    private var notice: (text: String, isWarning: Bool)? {
        guard let shown = shownOutcome else { return nil }
        if outcome != nil { return (text(for: shown), !shown.hasLink) }
        return ("剪贴板链接：" + text(for: shown), !shown.hasLink)
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
        // 这条要说清「没做什么」：不然用户会以为已经在下，等半天等不到
        if !outcome.deleted.isEmpty { parts.append("\(outcome.deleted.count) 条下过又删了，没重下") }
        if outcome.unsupported > 0 { parts.append("\(outcome.unsupported) 条不支持") }
        return parts.joined(separator: "，")
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
    @State private var confirmsRetry = false

    var body: some View {
        HStack(spacing: 12) {
            JobArtworkView(
                source: job.source,
                state: job.state,
                artworkURL: readyItem.flatMap { service.library.artworkURL(for: $0) },
                size: 52
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(job.displayTitle)
                    .font(.body)
                    .foregroundStyle(isCurrent ? Color.accentColor : .primary)
                    .lineLimit(1)

                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(job.state == .failed ? .red : .secondary)
                    .lineLimit(1)

                if job.state.isActive {
                    Group {
                        if job.progressUnknown {
                            // 服务器没给总大小：走不确定进度条，避免停在某个假百分比
                            ProgressView()
                        } else {
                            ProgressView(value: job.progress)
                        }
                    }
                    .progressViewStyle(.linear)
                    .tint(.accentColor)
                    .padding(.top, 2)
                    .animation(.linear(duration: 0.25), value: job.progress)
                }
            }

            Spacer(minLength: 8)

            trailing
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            if let item = readyItem { play(item) }
        }
    }

    private var readyItem: MediaItem? {
        guard job.state == .ready, let videoID = job.videoID else { return nil }
        return service.library.items.first { $0.id == videoID }
    }

    private var isCurrent: Bool {
        guard let item = readyItem else { return false }
        return player.currentID == item.id
    }

    private var isPlaying: Bool {
        isCurrent && player.isPlaying
    }

    private func play(_ item: MediaItem) {
        if player.currentID == item.id {
            player.toggle()
        } else {
            service.play(item)
        }
    }

    private var subtitle: String {
        switch job.state {
        case .ready:
            var parts = ["已保存", job.source.displayName]
            if !job.sizeText.isEmpty { parts.append(job.sizeText) }
            return parts.joined(separator: " · ")
        case .failed:
            return job.error ?? "下载失败"
        case .running:
            if job.progressUnknown {
                guard job.downloadedBytes > 0 else { return job.stage }
                return "\(job.stage) · 已下载 \(job.downloadedText)"
            }
            if let attempt = job.attempt { return "\(job.stage) · \(attempt)" }
            return job.stage
        case .queued:
            return "排队中"
        }
    }

    @ViewBuilder private var trailing: some View {
        switch job.state {
        case .ready:
            if isPlaying {
                Image(systemName: "waveform")
                    .font(.body)
                    .foregroundStyle(.tint)
            }
        case .failed:
            Button {
                if job.source.isPaid {
                    confirmsRetry = true
                } else {
                    service.retry(jobID: job.id)
                }
            } label: {
                Label("重试", systemImage: "arrow.clockwise")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tint)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.accentColor.opacity(0.12), in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("重试")
            .confirmationDialog(
                "重新下载会再调用一次 Apify，可能再花约 ¥0.5。",
                isPresented: $confirmsRetry,
                titleVisibility: .visible
            ) {
                Button("重试", role: .destructive) { service.retry(jobID: job.id) }
                Button("取消", role: .cancel) {}
            }
        case .running:
            if job.progressUnknown {
                Image(systemName: "arrow.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            } else {
                Text("\(Int(job.progress * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
        case .queued:
            Image(systemName: "clock")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}
