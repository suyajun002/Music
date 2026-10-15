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
                                Text("粘贴抖音分享文本或链接")
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
                            if service.jobs.first?.state == .ready { input = "" }
                        }
                    } label: {
                        HStack {
                            if service.isSubmitting { ProgressView().tint(.white) }
                            Text(service.isSubmitting ? "正在处理" : "下载到手机")
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(service.isSubmitting)
                } header: {
                    Text("抖音链接")
                } footer: {
                    Text("全程在手机上完成：解析、下载无水印视频、保存到本地。锁屏和后台都能继续播放。")
                }

                if let error = service.lastError {
                    Section {
                        Text(error).foregroundStyle(.red).font(.subheadline)
                    }
                }

                if !service.jobs.isEmpty {
                    Section("任务") {
                        ForEach(service.jobs) { job in
                            JobRow(job: job)
                        }
                        .onDelete { offsets in
                            for index in offsets { service.remove(jobID: service.jobs[index].id) }
                        }
                    }
                }
            }
            .navigationTitle("抖音转视频")
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
                ProgressView(value: job.progress)
                    .progressViewStyle(.linear)
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
        if job.state == .running { return "\(job.stage) \(Int(job.progress * 100))%" }
        return job.stage
    }
}
