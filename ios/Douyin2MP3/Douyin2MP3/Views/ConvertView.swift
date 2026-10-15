// 用途：主页面。粘贴 → 转换 → 播放；任务卡片只显示「当前结论 + 一句话原因 + 动作」。
import SwiftUI
import UIKit

struct ConvertView: View {
    @EnvironmentObject private var service: ConversionService
    @State private var input = ""
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
                                Text("粘贴抖音分享文本或链接（可一次粘多条，每行一条）")
                                    .foregroundStyle(.secondary)
                                    .padding(.top, 8)
                                    .padding(.leading, 5)
                                    .allowsHitTesting(false)
                            }
                        }

                    HStack {
                        Button("粘贴", systemImage: "doc.on.clipboard") {
                            if let text = UIPasteboard.general.string { input = text }
                        }
                        Spacer()
                        Button("清空") { input = "" }
                            .foregroundStyle(.secondary)
                    }
                    .font(.subheadline)

                    Button {
                        inputFocused = false
                        let text = input
                        Task {
                            await service.submit(text: text)
                            if service.lastError == nil { input = "" }
                        }
                    } label: {
                        HStack {
                            if service.isSubmitting { ProgressView().tint(.white) }
                            Text(service.isSubmitting ? "正在提交" : "下载到手机")
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(service.isSubmitting)
                } header: {
                    Text("抖音链接")
                } footer: {
                    Text("全程在手机上完成：解析、下载无水印视频、保存到本地。完成后会出现在「资料库」，锁屏和后台都能继续播放。")
                }

                if let error = service.lastError {
                    Section {
                        Text(error).foregroundStyle(.red).font(.subheadline)
                    }
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
}

private struct JobRow: View {
    @EnvironmentObject private var service: ConversionService
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
                            service.player.currentID == item.id && service.player.isPlaying ? "正在播放" : "播放",
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
