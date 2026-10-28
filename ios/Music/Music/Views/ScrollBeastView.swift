// 用途：资料库底部的「吞金兽」播放控制：轻点暂停/播放，左右拳切歌，滚动时挥拳互动。
import SwiftUI

enum ScrollBeastDirection: Equatable {
    case idle
    case swallow
    case spit
}

enum ScrollBeastAction: Equatable {
    case swallow
    case spit
}

/// 只把「方向变化」和「每滚过一段距离的一次动作」发布给视图。
/// 滚动中的累计值留在对象内部，避免每一帧都让整个资料库重算。
@MainActor
final class ScrollBeastController: ObservableObject {
    @Published private(set) var direction: ScrollBeastDirection = .idle
    @Published private(set) var action: ScrollBeastAction = .swallow
    @Published private(set) var actionToken = 0

    private var lastOffset: CGFloat?
    private var accumulatedDistance: CGFloat = 0
    private var idleTask: Task<Void, Never>?
    private var lastActivity = Date.distantPast

    func consume(offset: CGFloat) {
        guard let lastOffset else {
            self.lastOffset = offset
            return
        }
        self.lastOffset = offset

        let delta = offset - lastOffset
        guard abs(delta) > 0.4 else { return }
        // 排序或列表重建会直接跳 offset，不把它当成一次猛甩。
        guard abs(delta) < 120 else {
            accumulatedDistance = 0
            return
        }

        let nextDirection: ScrollBeastDirection = delta > 0 ? .swallow : .spit
        if direction != nextDirection {
            direction = nextDirection
            accumulatedDistance = 0
        }
        accumulatedDistance += abs(delta)
        noteActivity()

        guard accumulatedDistance >= 42 else { return }
        accumulatedDistance = 0
        action = nextDirection == .swallow ? .swallow : .spit
        actionToken &+= 1
    }

#if DEBUG
    func runDemo(_ action: ScrollBeastAction) {
        direction = action == .swallow ? .swallow : .spit
        self.action = action
        actionToken &+= 1
        noteActivity()
    }
#endif

    private func noteActivity() {
        lastActivity = Date()
        guard idleTask == nil else { return }
        idleTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(320))
                guard let self else { return }
                guard Date().timeIntervalSince(self.lastActivity) >= 0.32 else { continue }
                self.direction = .idle
                self.idleTask = nil
                return
            }
        }
    }
}

/// 资料库整页共用的暖色画布。
struct TopBackdrop: View {
    static let bottomColor = Color(red: 0.99, green: 0.95, blue: 0.84)

    var body: some View {
        LinearGradient(
            colors: [
                Color(red: 1.00, green: 0.96, blue: 0.88),
                Self.bottomColor,
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

struct ScrollBeastView: View {
    static let barHeight: CGFloat = 52

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var controller: ScrollBeastController
    @Binding var sort: LibrarySortOrder
    let isPlaying: Bool
    let canSort: Bool
    let canPrevious: Bool
    let canNext: Bool
    let onPrevious: () -> Void
    let onNext: () -> Void
    let onTogglePlayback: () -> Void
    let onSettings: () -> Void
    let onShuffle: () -> Void
    let onSequence: () -> Void
    let onConvert: () -> Void

    @State private var mouthOpen: CGFloat = 0.2
    @State private var bodyScaleX: CGFloat = 1
    @State private var bodyScaleY: CGFloat = 1
    @State private var bodyShiftX: CGFloat = 0
    @State private var bodyTilt: Double = 0
    @State private var eyeScaleY: CGFloat = 1
    @State private var leftPunch: CGFloat = 0
    @State private var rightPunch: CGFloat = 0
    @State private var treatOffsetY: CGFloat = 32
    @State private var treatOpacity: Double = 0
    @State private var treatScale: CGFloat = 0.45
    @State private var treatRotation: Double = 0
    @State private var animationTask: Task<Void, Never>?
    @State private var punchTask: Task<Void, Never>?
    @State private var modeNotice: String?
    @State private var modeNoticeTask: Task<Void, Never>?
    @State private var danceTilt: Double = 0
    @State private var danceTurn: Double = 0
    @State private var danceShiftX: CGFloat = 0
    @State private var danceLift: CGFloat = 0
    @State private var danceScale: CGFloat = 1
    @State private var danceSpin: Double = 0

    private let contentScale: CGFloat = 0.64
    private let fistHitSize = CGSize(width: 68, height: 52)
    private let creatureHitSize = CGSize(width: 68, height: 52)

    var body: some View {
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    previousFist
                    creatureButton
                    nextFist
                }
                .frame(maxWidth: .infinity)
                .frame(height: Self.barHeight)
            }

            if let modeNotice {
                Text(modeNotice)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color(red: 0.42, green: 0.22, blue: 0.02))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.regularMaterial, in: Capsule())
                    .offset(y: 0)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: Self.barHeight)
        .onChange(of: controller.actionToken) { _, _ in
            perform(controller.action)
        }
        .onChange(of: controller.direction) { _, direction in
            settleMood(direction)
        }
        .onDisappear {
            animationTask?.cancel()
            punchTask?.cancel()
            modeNoticeTask?.cancel()
        }
        .task(id: "\(isPlaying)-\(reduceMotion)") {
            guard isPlaying, !reduceMotion else {
                settleDance()
                return
            }
            await runDanceLoop()
        }
    }

    private var previousFist: some View {
        BeastFistButtonLabel(side: .left, progress: leftPunch)
            .scaleEffect(contentScale)
            .frame(width: fistHitSize.width, height: fistHitSize.height)
            .contentShape(Rectangle())
            .opacity(canPrevious ? 1 : 0.62)
            .gesture(
                LongPressGesture(minimumDuration: 0.45)
                    .onEnded { _ in
                        throwPunch(.left)
                        onShuffle()
                        showModeNotice("随机播放")
                    }
                    .exclusively(
                        before: TapGesture().onEnded {
                            throwPunch(.left)
                            onPrevious()
                        }
                    )
            )
        .accessibilityLabel("上一首")
        .accessibilityHint("长按切换随机播放")
    }

    private var nextFist: some View {
        BeastFistButtonLabel(side: .right, progress: rightPunch)
            .scaleEffect(contentScale)
            .frame(width: fistHitSize.width, height: fistHitSize.height)
            .contentShape(Rectangle())
            .opacity(canNext ? 1 : 0.62)
            .gesture(
                LongPressGesture(minimumDuration: 0.45)
                    .onEnded { _ in
                        throwPunch(.right)
                        onSequence()
                        showModeNotice("顺序播放")
                    }
                    .exclusively(
                        before: TapGesture().onEnded {
                            throwPunch(.right)
                            onNext()
                        }
                    )
            )
        .accessibilityLabel("下一首")
        .accessibilityHint("长按切换顺序播放")
    }

    private var creatureButton: some View {
        Button(action: onTogglePlayback) {
            creature
                .scaleEffect(contentScale)
                .frame(width: creatureHitSize.width, height: creatureHitSize.height)
                .contentShape(Rectangle())
        }
        .buttonStyle(BeastPressStyle())
        .accessibilityLabel("播放或暂停")
        .accessibilityHint("轻点切换播放，长按打开排序和设置")
        .contextMenu {
            if canSort {
                Section("排序") {
                    Picker("排序方式", selection: $sort) {
                        ForEach(LibrarySortOrder.allCases) { order in
                            Text(order.rawValue).tag(order)
                        }
                    }
                }
            }

            Button(action: onSettings) {
                Label("设置", systemImage: "gearshape")
            }

            Button(action: onConvert) {
                Label("转视频", systemImage: "arrow.down.circle")
            }
        }
    }

    private var creature: some View {
        ZStack {
            Capsule()
                .fill(goldGradient)
                .frame(width: 76, height: 58)
                .overlay(alignment: .top) { horns }
                .overlay { face }
                .overlay(alignment: .bottom) { paws }
                .shadow(color: Color.orange.opacity(0.20), radius: 7, y: 3)

            treat
        }
        .frame(width: 92, height: 78)
        .scaleEffect(x: bodyScaleX, y: bodyScaleY, anchor: .top)
        .scaleEffect(danceScale, anchor: .bottom)
        .offset(x: bodyShiftX + danceShiftX, y: danceLift)
        .rotationEffect(.degrees(bodyTilt), anchor: .top)
        .rotationEffect(.degrees(danceTilt), anchor: .bottom)
        .rotation3DEffect(
            .degrees(danceTurn + danceSpin),
            axis: (x: 0, y: 1, z: 0),
            anchor: .bottom,
            perspective: 0.55
        )
    }

    /// 播放时的轻微律动：重心左右换、身体小幅转身、偶尔弹一下。
    /// 暂停时由 `settleDance()` 收回静止姿态，不再持续耗动画。
    /// 幅度刻意克制，既不盖到上下两首歌，也不影响玩偶和拳头本身的点击。
    private func runDanceLoop() async {
        try? await Task.sleep(for: .milliseconds(650))
        guard !Task.isCancelled else { return }

        var cycle = 0
        while !Task.isCancelled {
            withAnimation(.easeInOut(duration: 0.52)) {
                danceTilt = 6
                danceTurn = 16
                danceShiftX = 2
                danceLift = -1.5
                danceScale = 1.035
            }
            try? await Task.sleep(for: .milliseconds(540))
            guard !Task.isCancelled else { return }

            withAnimation(.easeInOut(duration: 0.50)) {
                danceTilt = -5.5
                danceTurn = -16
                danceShiftX = -2
                danceLift = 0
                danceScale = 0.985
            }
            try? await Task.sleep(for: .milliseconds(520))
            guard !Task.isCancelled else { return }

            withAnimation(.easeInOut(duration: 0.44)) {
                danceTilt = 3
                danceTurn = 8
                danceShiftX = 1
                danceLift = -1
                danceScale = 1.015
            }
            try? await Task.sleep(for: .milliseconds(460))
            guard !Task.isCancelled else { return }

            withAnimation(.spring(response: 0.48, dampingFraction: 0.72)) {
                danceTilt = 0
                danceTurn = 0
                danceShiftX = 0
                danceLift = 0
                danceScale = 1
            }
            try? await Task.sleep(for: .milliseconds(1_050))
            guard !Task.isCancelled else { return }

            cycle += 1
            if cycle.isMultiple(of: 5) {
                await spin360()
            }
        }
    }

    /// 偶尔转身一圈：持续整圈转在 52pt 控制条里太吵，所以每 5 轮律动才来一次。
    /// 360° 与 0° 视觉一致，转完直接复位，不会看到回弹。
    private func spin360() async {
        withAnimation(.easeInOut(duration: 0.9)) {
            danceSpin = 360
            danceLift = -2.5
            danceScale = 1.04
        }
        try? await Task.sleep(for: .milliseconds(920))
        guard !Task.isCancelled else { return }

        danceSpin = 0
        withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) {
            danceLift = 0
            danceScale = 1
        }
    }

    /// 暂停/开启减弱动态效果时，收回静止姿态。
    private func settleDance() {
        withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
            danceTilt = 0
            danceTurn = 0
            danceShiftX = 0
            danceLift = 0
            danceScale = 1
            danceSpin = 0
        }
    }

    private var horns: some View {
        HStack(spacing: 32) {
            Capsule()
                .fill(darkGold)
                .frame(width: 10, height: 18)
                .rotationEffect(.degrees(-18))
            Capsule()
                .fill(darkGold)
                .frame(width: 10, height: 18)
                .rotationEffect(.degrees(18))
        }
        .offset(y: -10)
    }

    private var face: some View {
        VStack(spacing: 4) {
            HStack(spacing: 19) {
                eye
                eye
            }

            mouth
        }
        .offset(y: 2)
        .overlay {
            HStack(spacing: 53) {
                cheek
                cheek
            }
            .offset(y: 8)
        }
    }

    private var eye: some View {
        Circle()
            .fill(Color(red: 0.22, green: 0.11, blue: 0.03))
            .frame(width: 6, height: 6)
            .overlay(alignment: .topLeading) {
                Circle()
                    .fill(Color.white.opacity(0.75))
                    .frame(width: 2, height: 2)
                    .offset(x: 1, y: 1)
            }
            .scaleEffect(x: 1, y: eyeScaleY)
    }

    private var cheek: some View {
        Circle()
            .fill(Color.orange.opacity(0.24))
            .frame(width: 12, height: 8)
    }

    private var mouth: some View {
        ZStack(alignment: .top) {
            Capsule()
                .fill(Color(red: 0.25, green: 0.10, blue: 0.03))
                .frame(width: 19 + mouthOpen * 6, height: 4 + mouthOpen * 15)

            if mouthOpen > 0.42 {
                HStack(spacing: 10) {
                    tooth
                    tooth
                }
                .offset(y: 1)
                .opacity(Double((mouthOpen - 0.42) / 0.58))
            }
        }
        .offset(y: 4)
        .animation(.spring(response: 0.22, dampingFraction: 0.72), value: mouthOpen)
    }

    private var tooth: some View {
        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
            .fill(Color(red: 1.0, green: 0.96, blue: 0.84))
            .frame(width: 4, height: 5)
    }

    private var paws: some View {
        HStack(spacing: 38) {
            Capsule().fill(darkGold).frame(width: 13, height: 7)
            Capsule().fill(darkGold).frame(width: 13, height: 7)
        }
        .offset(y: 5)
    }

    private var treat: some View {
        Text("¥")
            .font(.system(size: 11, weight: .black, design: .rounded))
            .foregroundStyle(Color(red: 0.42, green: 0.22, blue: 0.02))
            .frame(width: 22, height: 22)
            .background(
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 1.0, green: 0.92, blue: 0.46),
                                Color(red: 0.95, green: 0.62, blue: 0.12),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
            .overlay {
                Circle().strokeBorder(Color.white.opacity(0.65), lineWidth: 1)
            }
            .shadow(color: Color.orange.opacity(0.35), radius: 4, y: 1)
            .offset(y: treatOffsetY)
            .scaleEffect(treatScale)
            .rotationEffect(.degrees(treatRotation))
            .opacity(treatOpacity)
    }

    private var goldGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 1.0, green: 0.84, blue: 0.36),
                Color(red: 0.86, green: 0.52, blue: 0.13),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var darkGold: Color {
        Color(red: 0.66, green: 0.35, blue: 0.08)
    }

    private func settleMood(_ direction: ScrollBeastDirection) {
        withAnimation(.easeOut(duration: 0.20)) {
            switch direction {
            case .idle:
                eyeScaleY = 1
                mouthOpen = 0.2
                if animationTask == nil {
                    bodyScaleY = 1
                    bodyTilt = 0
                }
            case .swallow:
                eyeScaleY = 0.55
                mouthOpen = max(mouthOpen, 0.55)
                bodyTilt = 2
            case .spit:
                eyeScaleY = 1.2
                mouthOpen = max(mouthOpen, 0.55)
                bodyTilt = -2
            }
        }
    }

    private func perform(_ action: ScrollBeastAction) {
        animationTask?.cancel()
        throwPunch(action == .swallow ? .left : .right)

        switch action {
        case .swallow:
            treatOpacity = 1
            treatOffsetY = 32
            treatScale = 0.48
            treatRotation = -8
            withAnimation(.spring(response: 0.22, dampingFraction: 0.68)) {
                mouthOpen = 1
                bodyScaleY = 1.06
                eyeScaleY = 0.42
            }
            withAnimation(.easeOut(duration: 0.22)) {
                treatOffsetY = 13
                treatScale = 0.92
                treatRotation = 8
            }
            animationTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(230))
                guard !Task.isCancelled else { return }
                withAnimation(.easeIn(duration: 0.14)) {
                    treatOffsetY = 8
                    treatScale = 0.12
                    treatOpacity = 0
                }
                withAnimation(.spring(response: 0.22, dampingFraction: 0.52)) {
                    mouthOpen = 0.12
                    bodyScaleY = 1.10
                }
                try? await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled else { return }
                withAnimation(.spring(response: 0.30, dampingFraction: 0.72)) {
                    mouthOpen = 0.2
                    bodyScaleY = 1
                    eyeScaleY = 0.8
                }
            }

        case .spit:
            treatOpacity = 1
            treatOffsetY = 13
            treatScale = 0.92
            treatRotation = 0
            withAnimation(.spring(response: 0.20, dampingFraction: 0.65)) {
                mouthOpen = 1
                bodyScaleY = 0.94
                eyeScaleY = 1.24
            }
            withAnimation(.easeIn(duration: 0.24)) {
                treatOffsetY = 44
                treatScale = 0.72
                treatRotation = 30
                treatOpacity = 0
            }
            animationTask = Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(260))
                guard !Task.isCancelled else { return }
                withAnimation(.spring(response: 0.30, dampingFraction: 0.72)) {
                    mouthOpen = 0.2
                    bodyScaleY = 1
                    eyeScaleY = 1
                }
            }
        }
    }

    private func throwPunch(_ side: PunchSide) {
        punchTask?.cancel()
        let inward = side.inwardSign

        withAnimation(.easeIn(duration: 0.08)) {
            if side == .left {
                leftPunch = 1
            } else {
                rightPunch = 1
            }
            bodyScaleX = 0.93
            bodyShiftX = inward * 4
            bodyTilt = Double(inward * 6)
            eyeScaleY = 0.35
        }

        punchTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(90))
            guard !Task.isCancelled else { return }

            withAnimation(.spring(response: 0.26, dampingFraction: 0.48)) {
                if side == .left {
                    leftPunch = 0
                } else {
                    rightPunch = 0
                }
                bodyScaleX = 1.07
                bodyShiftX = inward * 1.5
            }

            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }

            withAnimation(.spring(response: 0.34, dampingFraction: 0.66)) {
                bodyScaleX = 1
                bodyShiftX = 0
                bodyTilt = 0
                eyeScaleY = 1
            }
        }
    }

    private func showModeNotice(_ text: String) {
        modeNoticeTask?.cancel()
        withAnimation(.snappy(duration: 0.16)) {
            modeNotice = text
        }
        modeNoticeTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1_100))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.20)) {
                modeNotice = nil
            }
        }
    }
}

private struct BeastPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

private enum PunchSide {
    case left
    case right

    var inwardSign: CGFloat {
        switch self {
        case .left: return 1
        case .right: return -1
        }
    }
}

private struct BeastFistButtonLabel: View {
    let side: PunchSide
    let progress: CGFloat

    var body: some View {
        FistGraphic()
            .scaleEffect(x: side == .left ? 1.20 : -1.20, y: 1.20)
            .frame(width: 54, height: 54)
            .contentShape(Circle())
            .scaleEffect(1 + progress * 0.06)
            .offset(x: side.inwardSign * progress * 18)
            .rotationEffect(.degrees(Double(side.inwardSign * progress * 5)))
            .shadow(color: Color.brown.opacity(0.14), radius: 6, y: 3)
    }

}

private struct FistGraphic: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(Color(red: 0.49, green: 0.28, blue: 0.10))
                .frame(width: 10, height: 20)
                .offset(x: -15)
                .overlay(alignment: .top) {
                    Capsule()
                        .fill(Color(red: 0.67, green: 0.43, blue: 0.20).opacity(0.8))
                        .frame(width: 7, height: 1)
                        .offset(x: -15, y: 3)
                }

            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(skinGradient)
                .frame(width: 30, height: 25)
                .offset(x: -3)

            VStack(spacing: 1.2) {
                ForEach(0..<4, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                        .fill(skinGradient)
                        .frame(width: 7.5, height: 6)
                        .overlay {
                            RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                                .stroke(Color(red: 0.58, green: 0.32, blue: 0.11).opacity(0.32), lineWidth: 0.65)
                        }
                }
            }
            .offset(x: 13)

            Capsule()
                .fill(skinGradient)
                .frame(width: 13, height: 8)
                .overlay {
                    Capsule()
                        .stroke(Color(red: 0.58, green: 0.32, blue: 0.11).opacity(0.24), lineWidth: 0.7)
                }
                .rotationEffect(.degrees(28))
                .offset(x: -1, y: 10)
        }
        .frame(width: 44, height: 34)
        .shadow(color: Color.brown.opacity(0.12), radius: 1, y: 1)
    }

    private var skinGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color(red: 0.98, green: 0.78, blue: 0.51),
                Color(red: 0.88, green: 0.58, blue: 0.27),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}
