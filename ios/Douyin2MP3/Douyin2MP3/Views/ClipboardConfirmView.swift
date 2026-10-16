// 用途：剪贴板确认框。列出从剪贴板识别到的链接，**不点任何东西**，倒计时走完自动入队；
// 不想下就点中间的「忽略」。复制完链接就去忙别的，回来不该白跑一趟。
//
// 为什么不用 `.alert`：系统弹窗只有一排按钮，塞不下「外圈倒计时环 + 圈里一个按钮」，
// 按钮标题也不能跟着秒数实时变。所以自己搭一个。
import SwiftUI

struct ClipboardConfirmView: View {
    let prompt: ClipboardPrompt
    /// 用户点了圈里的「忽略」——具体做什么由调用方决定。
    let onIgnore: () -> Void
    let onConfirm: () -> Void
    /// 这批链接**当前下不了**时的原因（比如 YouTube 链接但还没填 Apify token）。
    /// 非空就不倒计时自动入队 —— 走下不去也只会白跑一趟，还得让用户自己发现是缺 token。
    /// 圈里的按钮改成「去设置」，把人送到能解决问题的地方。
    let blockedReason: String?
    /// 这批链接的处境：几条已经下过、几条正在下。框上先说清楚，别等扣了钱才发现是重复的。
    let status: ClipboardPromptStatus
    let onFix: () -> Void

    /// 倒计时总秒数。这是产品节奏，不是取流参数，所以留在视图里（对齐 MediaPlayer.skipInterval 的做法）。
    private static let countdownSeconds = 5

    private static let ringDiameter: CGFloat = 112
    private static let ringWidth: CGFloat = 6

    /// 还剩几秒自动下载。0 表示已经触发过了，不会再触发。
    @State private var remaining = Self.countdownSeconds

    var body: some View {
        ZStack {
            // 蒙层：挡住底下的页签交互，避免倒计时期间误触到别的按钮
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { /* 有意什么都不做：关框只能走「忽略」 */ }

            card
                .padding(.horizontal, 32)
                .frame(maxWidth: 420)
        }
        // 用任务而不是 Timer：视图消失（用户点了忽略/下载）时 sleep 会自动抛错退出，
        // 不会留下一个还在跑的定时器去调已经过期的 prompt。
        //
        // `id:` 挂 prompt.id，且进任务先把秒数复位——同一个 prompt 被重新推上来时（比如
        // 切回前台又识别了一遍剪贴板），倒计时从头开始，而不是拿着上一轮的 0 秒立刻重复下载。
        .task(id: prompt.id) {
            remaining = Self.countdownSeconds
            guard blockedReason == nil else {
                DouyinDebug.log("确认框：这批下不了（\(blockedReason ?? "")），不自动下载")
                return
            }
            // 全都下过/正在下：倒计时走完也只会什么都不做，那就别数了。
            // 5 秒后「自动下载」一次、结果一条没动，比直接说明白更让人犯嘀咕。
            guard !status.nothingNew else {
                DouyinDebug.log("确认框：\(status.total) 条都已在库或正在下载，不倒计时")
                return
            }
            DouyinDebug.log("确认框出现，开始 \(Self.countdownSeconds)s 倒计时（已在库 \(status.downloaded)，正在下 \(status.running)）")
            while remaining > 0 {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
                remaining -= 1
            }
            DouyinDebug.log("剪贴板确认框倒计时到点，自动下载 \(prompt.urls.count) 条")
            onConfirm()
        }
    }

    private var card: some View {
        VStack(spacing: 16) {
            VStack(spacing: 8) {
                Text(title)
                    .font(.headline)
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            VStack(spacing: 8) {
                // 一个圆圈：外圈是倒计时（随秒数一圈圈退掉），圈里就是那个按钮。
                ZStack {
                    // 底环：画满一圈，让「还剩多少」有个参照，不然弧短了像渲染坏了
                    Circle()
                        .stroke(Color.secondary.opacity(0.25), lineWidth: Self.ringWidth)

                    // 倒计时弧：从 12 点方向顺时针，秒数越少弧越短。
                    // 被挡住时画满一圈且不动 —— 它不是「还剩 0 秒」，而是「还没开始数」。
                    Circle()
                        .trim(from: 0, to: fraction)
                        .stroke(ringColor, style: StrokeStyle(lineWidth: Self.ringWidth, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        // 每秒跳一格太生硬，补一段线性动画让它匀速退
                        .animation(.linear(duration: 1), value: remaining)

                    // 不要给它加 `role: .cancel`：那个角色会接系统的「取消」动作，
                    // 而这里唯一该发生的取消就是用户亲手点这个圈。
                    Button {
                        switch ringState {
                        case .blocked:
                            DouyinDebug.log("确认框：点「去设置」，转去填 token")
                            onFix()
                        case .nothingNew:
                            DouyinDebug.log("确认框：点「知道了」（这批都下过了）")
                            onIgnore()
                        case .counting:
                            DouyinDebug.log("忽略按钮被触发")
                            onIgnore()
                        }
                    } label: {
                        Text(ringButtonTitle)
                            .font(.headline)
                            .frame(width: Self.ringDiameter - 22, height: Self.ringDiameter - 22)
                            .background(Circle().fill(.quaternary))
                    }
                    .buttonStyle(.plain)
                }
                .frame(width: Self.ringDiameter, height: Self.ringDiameter)

                Text(footnote)
                    .font(.footnote)
                    .foregroundStyle(ringState == .counting ? Color.secondary : Color.orange)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(20)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(radius: 24, y: 8)
    }

    /// 圈里那个按钮现在是什么处境。三种都只在「点下去会发生什么」上有区别，
    /// 所以集中成一个值判断，别在各处散着比 `blockedReason == nil`。
    private enum RingState { case counting, blocked, nothingNew }

    private var ringState: RingState {
        if blockedReason != nil { return .blocked }
        if status.nothingNew { return .nothingNew }
        return .counting
    }

    private var ringButtonTitle: String {
        switch ringState {
        case .blocked: return "去设置"
        case .nothingNew: return "知道了"
        case .counting: return "忽略"
        }
    }

    private var ringColor: Color {
        switch ringState {
        case .blocked, .nothingNew: return .orange
        case .counting: return .accentColor
        }
    }

    /// 倒计时环已画出的比例：1 = 满圈，0 = 退没了。不数的时候恒为满圈。
    private var fraction: CGFloat {
        guard ringState == .counting else { return 1 }
        return CGFloat(remaining) / CGFloat(Self.countdownSeconds)
    }

    private var title: String {
        let count = prompt.urls.count
        return count <= 1 ? "剪贴板里有 1 个链接" : "剪贴板里有 \(count) 个链接"
    }

    /// 圈下面那行字：说清楚现在是什么处境（为什么下不了 / 为什么没什么可下 / 还剩几秒）。
    private var footnote: String {
        switch ringState {
        case .blocked:
            return blockedReason ?? ""
        case .nothingNew:
            // 「正在下」和「下过了」都要说，不然用户看着一个不动的倒计时环以为自己点坏了
            var parts: [String] = []
            if status.downloaded > 0 { parts.append("\(status.downloaded) 条已在资料库") }
            if status.running > 0 { parts.append("\(status.running) 条正在下载") }
            return "\(parts.joined(separator: "，"))，不会重复下载"
        case .counting:
            var text = "\(remaining) 秒后自动下载"
            if prompt.isPaid { text += "（要花钱）" }
            return text
        }
    }

    /// 正文：列出识别到的链接（最多 4 条，再多就报个数），并说明去重规则。
    /// YouTube 那条要**把费用写在框上** —— 倒计时走完就真扣钱，不该扣得不明不白。
    private var message: String {
        let shown = prompt.urls.prefix(4).map(\.absoluteString)
        var lines = shown.map { "· \($0)" }
        if prompt.urls.count > shown.count {
            lines.append("…等 \(prompt.urls.count) 个")
        }
        lines.append("")
        // 去重按「同一条内容」算：同一个 YouTube 视频贴成短链还是长链都只算一条，
        // 所以这里得说清口径，免得用户以为换个写法就能再下一遍。
        if status.skipped > 0 {
            var parts: [String] = []
            if status.downloaded > 0 { parts.append("\(status.downloaded) 条已在资料库") }
            if status.running > 0 { parts.append("\(status.running) 条正在下载") }
            lines.append("\(parts.joined(separator: "，"))，会自动跳过，不会重复下载。")
            if !status.nothingNew {
                lines.append("这次实际新下 \(status.total - status.skipped) 条。")
            }
        } else {
            lines.append("已经在资料库里、或正在下载的会自动跳过（同一个视频换个链接写法也算同一条）。")
        }
        if prompt.isPaid {
            lines.append("含 YouTube：每首约 ¥0.5（Apify 按音频时长计费，失败不计费），一首 1~3 分钟。")
        }
        return lines.joined(separator: "\n")
    }
}
