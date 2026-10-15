// 用途：主页面。粘贴即自动下载；任务卡片只显示「当前结论 + 一句话原因 + 动作」。
import SwiftUI
import UIKit

struct ConvertView: View {
    @EnvironmentObject private var service: ConversionService
    @State private var input = ""
    @State private var outcome: SubmitOutcome?
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
                                Text("粘贴分享文本或链接（可一次粘多条，每行一条）")
                                    .foregroundStyle(.secondary)
                                    .padding(.top, 8)
                                    .padding(.leading, 5)
                                    .allowsHitTesting(false)
                            }
                        }

                    HStack {
                        Button("粘贴链接", systemImage: "doc.on.clipboard") {
                            if let text = UIPasteboard.general.string { input = text }
                        }
                        Spacer()
                        Button("清空") {
                            input = ""
                            outcome = nil
                        }
                            .foregroundStyle(.secondary)
                    }
                    .font(.subheadline)

                    if let notice {
                        Text(notice)
                            .font(.caption)
                            .foregroundStyle(outcome?.hasLink == true ? Color.secondary : Color.red)
                    }
                } header: {
                    Text("链接")
                } footer: {
                    Text("粘贴后自动开始下载，全程在手机上完成，完成后会出现在「资料库」。已经在资料库里的不会重复下载，锁屏和后台都能继续播放。")
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
                    Menu {
                        Picker("同时下载", selection: Binding(
                            get: { service.maxConcurrent },
                            set: { service.maxConcurrent = $0 }
                        )) {
                            ForEach(ConversionService.concurrencyOptions, id: \.self) { count in
                                Text("\(count) 个").tag(count)
                            }
                        }
                    } label: {
                        Image(systemName: "square.stack.3d.down.right")
                    }
                }
            }
        }
    }

    /// 把结构化结果翻成一行结论，页面只展示结论、不做判断。
    private var notice: String? {
        guard let outcome else { return nil }
        guard outcome.hasLink else { return "没识别到链接，请粘贴完整的分享文本或链接" }
        var parts: [String] = []
        if outcome.queued > 0 { parts.append("已开始下载 \(outcome.queued) 条") }
        if outcome.downloaded > 0 { parts.append("\(outcome.downloaded) 条已在资料库") }
        if outcome.running > 0 { parts.append("\(outcome.running) 条正在下载") }
        return parts.isEmpty ? nil : parts.joined(separator: "，")
    }

    /// 粘贴即下载：`.task(id:)` 在输入变化时重跑，天然形成「等粘贴落定」的防抖。
    private func submitPasted() async {
        guard !input.isEmpty else { return }
        try? await Task.sleep(for: .milliseconds(450))
        guard !Task.isCancelled else { return }

        let result = await service.autoSubmit(from: input)
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
