// 用途：剪贴板确认框。列出从剪贴板识别到的抖音链接，**不点任何东西**，倒计时走完自动入队；
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
            DouyinDebug.log("确认框出现，开始 \(Self.countdownSeconds)s 倒计时")
            remaining = Self.countdownSeconds
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
                // 一个圆圈：外圈是倒计时（随秒数一圈圈退掉），圈里就是「忽略」。
                ZStack {
                    // 底环：画满一圈，让「还剩多少」有个参照，不然弧短了像渲染坏了
                    Circle()
                        .stroke(Color.secondary.opacity(0.25), lineWidth: Self.ringWidth)

                    // 倒计时弧：从 12 点方向顺时针，秒数越少弧越短
                    Circle()
                        .trim(from: 0, to: fraction)
                        .stroke(
                            Color.accentColor,
                            style: StrokeStyle(lineWidth: Self.ringWidth, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                        // 每秒跳一格太生硬，补一段线性动画让它匀速退
                        .animation(.linear(duration: 1), value: remaining)

                    // 不要给它加 `role: .cancel`：那个角色会接系统的「取消」动作，
                    // 而这里唯一该发生的取消就是用户亲手点这个圈。
                    Button {
                        DouyinDebug.log("忽略按钮被触发")
                        onIgnore()
                    } label: {
                        Text("忽略")
                            .font(.headline)
                            .frame(width: Self.ringDiameter - 22, height: Self.ringDiameter - 22)
                            .background(Circle().fill(.quaternary))
                    }
                    .buttonStyle(.plain)
                }
                .frame(width: Self.ringDiameter, height: Self.ringDiameter)

                Text("\(remaining) 秒后自动下载")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(radius: 24, y: 8)
    }

    /// 倒计时环已画出的比例：1 = 满圈，0 = 退没了。
    private var fraction: CGFloat {
        CGFloat(remaining) / CGFloat(Self.countdownSeconds)
    }

    private var title: String {
        let count = prompt.urls.count
        return count <= 1 ? "剪贴板里有 1 个链接" : "剪贴板里有 \(count) 个链接"
    }

    /// 正文：列出识别到的链接（最多 4 条，再多就报个数），并说明去重规则。
    private var message: String {
        let shown = prompt.urls.prefix(4).map(\.absoluteString)
        var lines = shown.map { "· \($0)" }
        if prompt.urls.count > shown.count {
            lines.append("…等 \(prompt.urls.count) 个")
        }
        lines.append("")
        lines.append("已经在资料库里、或正在下载的会自动跳过。")
        return lines.joined(separator: "\n")
    }
}
