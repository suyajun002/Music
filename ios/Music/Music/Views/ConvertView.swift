// 用途：转视频子页（从「设置 → 转视频」进入）。粘贴即自动下载；任务行只显示结论、原因和动作。
import SwiftUI

struct ConvertView: View {
    @EnvironmentObject private var service: ConversionService
    @State private var input = ""
    @State private var outcome: SubmitOutcome?
    @State private var confirmsClearRecords = false
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
                }

                // 标题常驻：没有记录时这一节也留着，下面就是空的。
                Section {
                    ForEach(service.jobs) { job in
                        JobRow(job: job)
                    }
                    .onDelete { offsets in
                        for index in offsets { service.remove(jobID: service.jobs[index].id) }
                    }

                    // 纯列表样式下「只有标题没有行」的 Section 会被折叠，
                    // 用一个看不见的 1pt 行把标题撑住；视觉上仍是空的。
                    if service.jobs.isEmpty {
                        Color.clear
                            .frame(height: 1)
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
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
                        if hasClearableRecords {
                            Button("清空") { confirmsClearRecords = true }
                                .font(.caption)
                                .textCase(nil)
                                .buttonStyle(.borderless)
                        }
                    }
                }

                // 放在转换记录之后：「正在发生/刚跑过的事」在上，历史删除的链接在下。
                // 默认不自动重下（YouTube 一条一钱），但删过的条目要一直能找回来；
                // 重下成功后由入库流程清掉这条记录，失败则原样留着，可以再点。
                DeletedLinksSection(library: service.library)
        }
        .listStyle(.plain)
        .animation(.snappy, value: service.jobs.count)
        .animation(.snappy, value: service.jobs.map(\.state))
        .navigationTitle("转视频")
        .confirmationDialog(
            "清空转换记录？已保存和失败的记录都会消失，资料库里的歌不受影响，正在下载的不动。",
            isPresented: $confirmsClearRecords,
            titleVisibility: .visible
        ) {
            Button("清空", role: .destructive) { service.clearHistory() }
            Button("取消", role: .cancel) {}
        }
        // 点空白/滚动就收起键盘，不该把人一直困在键盘页
        .scrollDismissesKeyboard(.immediately)
        .task(id: input) { await submitPasted() }
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

    /// 有没有可以清掉的记录。正在下载/排队的任务不算 —— 清空不该把它们从页面上抹掉。
    private var hasClearableRecords: Bool {
        service.jobs.contains { !$0.state.isActive }
    }

    /// 转换记录的一句话概况。只在页头出现，不占用每行的位置。
    private var recordSummary: String {
        var parts: [String] = []
        if service.activeCount > 0 {
            parts.append("进行中 \(service.runningCount) · 等待 \(service.waitingCount)")
        }
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

/// 单独观察 `MediaLibrary`：`service` 发布的是任务状态，删歌记录挂在 library 上；
/// 不在这里直接观察它，重下成功清掉记录后这一节不会立刻从页面消失。
private struct DeletedLinksSection: View {
    @ObservedObject var library: MediaLibrary
    @EnvironmentObject private var service: ConversionService
    @State private var confirmsClear = false

    var body: some View {
        if !library.deletedLinks.isEmpty {
            Section {
                ForEach(library.deletedLinks) { link in
                    DeletedLinkRow(link: link)
                }
                .onDelete { offsets in
                    // 先取出快照再删：边删边按下标取会越界（集合已经变短了）。
                    let links = offsets.map { library.deletedLinks[$0] }
                    // 单条删除走 service：删记录的同时把它的转换记录也带走，
                    // 否则下次启动 `backfillDeletedLinks` 会照着旧记录再补一条回来。
                    for link in links { service.forgetDeletedLink(link) }
                }
            } header: {
                HStack(alignment: .firstTextBaseline) {
                    Text("下过又删了")
                    Spacer()
                    Button("清空（\(library.deletedLinks.count)）") { confirmsClear = true }
                        .font(.caption)
                        .textCase(nil)
                        .buttonStyle(.borderless)
                }
            }
            .confirmationDialog(
                "清空后这些链接会被当成没下过：再贴进来会直接重新下载，YouTube 会重新计费。",
                isPresented: $confirmsClear,
                titleVisibility: .visible
            ) {
                Button("清空", role: .destructive) { service.clearDeletedLinks() }
                Button("取消", role: .cancel) {}
            }
        }
    }
}

private struct DeletedLinkRow: View {
    @EnvironmentObject private var service: ConversionService
    let link: DeletedLink
    @State private var confirmsRedownload = false

    private var url: URL? { URL(string: link.sourceURL) }

    private var source: MediaSource? {
        guard let url else { return nil }
        return MediaSource.of(url)
    }

    private var title: String {
        link.title.isEmpty ? "未命名" : link.title
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.body)
                    .lineLimit(1)

                Text(source?.displayName ?? "未知来源")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Button {
                if source?.isPaid == true {
                    confirmsRedownload = true
                } else {
                    redownload()
                }
            } label: {
                Label("重新下载", systemImage: "arrow.clockwise")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tint)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.accentColor.opacity(0.12), in: Capsule())
                    .contentShape(Capsule())
            }
            .buttonStyle(.borderless)
            .disabled(url == nil)
            .accessibilityLabel("重新下载 \(title)")
            .confirmationDialog(
                "重新下载会再调用一次 Apify，可能再花约 ¥0.5。",
                isPresented: $confirmsRedownload,
                titleVisibility: .visible
            ) {
                Button("重新下载", role: .destructive) { redownload() }
                Button("取消", role: .cancel) {}
            }
        }
        .padding(.vertical, 2)
    }

    private func redownload() {
        guard let url else { return }
        Task { await service.redownload([url]) }
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
