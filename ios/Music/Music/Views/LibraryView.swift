// 用途：资料库主页（对齐音乐 App 的「歌曲」列表）：封面缩略图、可排序、可滑动删除。
import SwiftUI

enum LibrarySortOrder: String, CaseIterable, Identifiable {
    case recent = "最近添加"
    case title = "标题"

    var id: String { rawValue }
}

private enum LibraryLayout {
    static let rowContentTop: CGFloat = 12.8
    static let artworkSize: CGFloat = 52
}

struct LibraryView: View {
    @EnvironmentObject private var service: ConversionService
    @EnvironmentObject private var player: MediaPlayer
    @Binding var showsSettings: Bool
    @State private var sort: LibrarySortOrder = .recent
    /// 「转视频」从底部玩偶的菜单直接打开，和「设置」同级。
    @State private var showsConvert = false
    /// 正在设跳过的那首。非 nil 时弹编辑框。
    @State private var skipEditing: MediaItem?
    /// 编辑框里的起点秒数（文本）。用文本而不是数字：用户可能想打「12」「12.5」，
    /// 数字键盘 + 文本中间态才好处理清空、小数点的输入过程。
    @State private var skipDraft = ""
    /// 编辑框里的结尾提前量（文本），含义同上。
    @State private var endDraft = ""
    /// `IntroSkip` 是 `ObservableObject`，改完这里会自己重画 ——
    /// 不再需要「手动 bump 一个计数器、给列表换 identity」那种会让搜索框被重置的写法。
    @ObservedObject private var introSkip = IntroSkip.shared
    @StateObject private var beast = ScrollBeastController()
    /// 编辑框里正在试听的那一组的区间，用来画进度、判断按钮该显示「试听」还是「停止」。
    /// **播放本身走 `MediaPlayer`**：它已经有一条完整的链路（AVPlayer、锁屏、灵动岛、
    /// 萌宠），试听要的就是「跟真放一样，只是区间不同」。另开一路 AVPlayer 要多养一套，
    /// 还得处理「两路声音谁说了算」—— 见 `MediaPlayer.preview`。
    @State private var previewing: (from: Double, to: Double)?
    /// 模拟器验收用：不用真的放一首歌，也能让玩偶进入「播放中」。
    private var beastIsPlaying: Bool {
#if DEBUG
        if ProcessInfo.processInfo.environment["D2M_BEAST_PLAY"] == "1" {
            return true
        }
#endif
        return player.isPlaying
    }

    private var items: [MediaItem] {
        let base = service.library.items
        switch sort {
        case .recent: return base.sorted { $0.savedAt > $1.savedAt }
        case .title: return base.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
                Group {
                    if service.library.items.isEmpty {
                        ContentUnavailableView(
                            "资料库是空的",
                            systemImage: "music.note.list",
                            description: Text("点底部玩偶打开「转视频」贴一条链接下载，或把音频/视频文件放进 App 的「文件」目录，都会自动出现在这里")
                        )
                    } else {
                        List {
                        Section {
                            ForEach(items) { item in
                                row(item)
                                    // 首屏 10 首。底部控制条占 52pt，行高保持约 78pt。
                                    .listRowInsets(EdgeInsets(top: LibraryLayout.rowContentTop, leading: 16, bottom: LibraryLayout.rowContentTop, trailing: 16))
                                    // 左滑：跳过前奏 + 删除。用 `swipeActions` 而不是原来的
                                    // `.onDelete` —— `.onDelete` 只能出「删除」一个动作，
                                    // 加不了第二项。
                                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                        Button(role: .destructive) {
                                            service.library.delete(item)
                                        } label: {
                                            Label("删除", systemImage: "trash")
                                        }
                                        Button {
                                            beginSkipEdit(item)
                                        } label: {
                                            Label(
                                                skipActionLabel(item),
                                                systemImage: IntroSkip.shared.hasAny(for: item.id)
                                                    ? "scissors.badge.ellipsis" : "scissors"
                                            )
                                        }
                                        .tint(.orange)
                                    }
                            }
                        } footer: {
                            Text("\(service.library.items.count) 首 · 共 \(totalText)")
                        }
                        .listRowBackground(Color.clear)
                        }
                        // 歌单容器铺满屏幕宽度：不做 iOS 26 inset-grouped 的圆角卡片，列表直接内嵌在页面里。
                        .listStyle(.plain)
                        // 去掉 List 默认的内容上边距；顶部只留安全区，也就是灵动岛本身的距离。
                        .contentMargins(.top, -20, for: .scrollContent)
                        .listSectionSpacing(0)
                        .scrollContentBackground(.hidden)
                        .background {
                            TopBackdrop()
                                .ignoresSafeArea()
                        }
                        // 首屏只露 10 首。列表滚到可视区底部时，第 11 行的封面顶边会露出
                        // 一条；用同色遮罩切掉，不改变前 10 行的行高。
                        .overlay(alignment: .bottom) {
                            TopBackdrop.bottomColor
                                .frame(height: 10)
                                .allowsHitTesting(false)
                        }
                        .onScrollGeometryChange(for: CGFloat.self) { geometry in
                            geometry.contentOffset.y
                        } action: { _, offset in
                            beast.consume(offset: offset)
                        }
                    }
                }
            }
            .background {
                TopBackdrop()
                    .ignoresSafeArea()
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                beastControls
                    .frame(height: ScrollBeastView.barHeight)
                    .background {
                        TopBackdrop.bottomColor
                            .ignoresSafeArea(edges: .bottom)
                    }
            }
#if DEBUG
            .task {
                guard let demo = ProcessInfo.processInfo.environment["D2M_BEAST_DEMO"] else { return }
                let action: ScrollBeastAction = demo == "spit" ? .spit : .swallow
                while !Task.isCancelled {
                    beast.runDemo(action)
                    try? await Task.sleep(for: .milliseconds(350))
                }
            }
#endif
            // 左滑「跳过前奏」弹的编辑框。用 `sheet(item:)` 而不是 `.alert`：
            // alert 里塞 TextField 是能塞，但布局被系统框死、也放不下「试听一下」这类按钮。
            .sheet(item: $skipEditing) { item in
                skipEditor(item)
                    // 两张输入框 + 试听 + 预览 + 按钮，320 放不下（会被压成滚动条挤在一起）
                    .presentationDetents([.medium, .large])
                    // 关掉编辑框就收掉试听状态。**必须显式收**：不收的话
                    // `MediaPlayer` 会一直以为自己在试听 —— 进度条刻度、剩余时间、
                    // 到点不切歌都还按试听区间算，退出编辑框后播放就"卡"在那个区间里。
                    .onDisappear {
                        player.endPreview()
                        previewing = nil
                    }
            }
            .sheet(isPresented: $showsConvert) {
                NavigationStack {
                    ConvertView()
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("完成") { showsConvert = false }
                            }
                        }
                }
                .environmentObject(service)
                .environmentObject(player)
        }
    }

    private var beastControls: some View {
        ScrollBeastView(
            controller: beast,
            sort: $sort,
            isPlaying: beastIsPlaying,
            canSort: !service.library.items.isEmpty,
            canPrevious: player.currentID != nil,
            canNext: player.hasNext,
            onPrevious: { player.previous() },
            onNext: { player.next() },
            onTogglePlayback: { player.toggle() },
            onSettings: { showsSettings = true },
            onShuffle: { player.setMode(.shuffle) },
            onSequence: { player.setMode(.sequence) },
            onConvert: { showsConvert = true }
        )
    }

    // MARK: - 跳过开头 / 结尾

    /// 左滑块上的标题：设过的直接写秒数，一眼能看出「这首跳 12 秒」。
    /// 两头都设了就把两个数都带上 —— 只写一头会让人以为另一头没生效。
    private func skipActionLabel(_ item: MediaItem) -> String {
        let r = IntroSkip.shared.range(for: item.id)
        switch (r.start > 0, r.endTrim > 0) {
        case (true, true): return "跳过 \(Int(r.start))/\(Int(r.endTrim))s"
        case (true, false): return "跳过 \(Int(r.start))s"
        case (false, true): return "跳过结尾 \(Int(r.endTrim))s"
        case (false, false): return "跳过开头/结尾"
        }
    }

    /// 列表行上的小标记。两头都没设返回 nil（不占位）。
    private func skipBadge(_ item: MediaItem) -> String? {
        let r = IntroSkip.shared.range(for: item.id)
        switch (r.start > 0, r.endTrim > 0) {
        case (true, true): return "头 \(Int(r.start))s · 尾 \(Int(r.endTrim))s"
        case (true, false): return "跳过 \(Int(r.start))s"
        case (false, true): return "跳过结尾 \(Int(r.endTrim))s"
        case (false, false): return nil
        }
    }

    private func beginSkipEdit(_ item: MediaItem) {
        let r = IntroSkip.shared.range(for: item.id)
        // 有设过就带出原值好微调；没设过留空，占位提示语里说明怎么填
        skipDraft = r.start > 0 ? String(Int(r.start)) : ""
        endDraft = r.endTrim > 0 ? String(Int(r.endTrim)) : ""
        skipEditing = item
    }

    /// 正在编辑的这首的时长（秒）。没播过就取库里记的时长，都没有则 0。
    private func knownDuration(_ item: MediaItem) -> Double {
        if player.currentID == item.id, player.duration > 0 { return player.duration }
        return item.durationSec ?? 0
    }

    private func skipEditor(_ item: MediaItem) -> some View {
        NavigationStack {
            Form {
                Section {
                    TextField("秒数，例如 12", text: $skipDraft)
                        .keyboardType(.decimalPad)
                } header: {
                    Text("跳过开头 · 从第几秒开始播放")
                }

                Section {
                    TextField("秒数，例如 15", text: $endDraft)
                        .keyboardType(.decimalPad)
                } header: {
                    Text("跳过结尾 · 提前多少秒结束")
                } footer: {
                    // 如实说明这跟「下载时裁剪」的区别，免得用户以为文件被改了
                    Text("两项都只是**播放时跳过，不会改动文件**。歌还在，随时可以取消。")
                }

                // 设完能立刻看到「实际会放哪一段」，不用来回试听。
                // 只在拿得到时长时显示 —— 没时长还要编一个区间出来是骗人。
                if let preview = trimPreview(item) {
                    Section {
                        Text(preview)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } header: {
                        Text("实际播放")
                    }
                }

                // 设完能立刻听一遍「开头那一下 / 结尾那一下」，不用切到播放器来回试。
                // 放在两个输入框下面：改完数字顺手就能听，这就是「改完之后马上试听」。
                Section {
                    Button {
                        audition(item)
                    } label: {
                        Label(isAuditioning(item) ? "停止试听" : auditionLabel(item),
                              systemImage: isAuditioning(item) ? "stop.fill" : "play.circle")
                    }
                    .disabled(previewSegment(item) == nil && !isAuditioning(item))

                    // 正在试听时把播放头画出来：不然只有一个「停止试听」按钮，
                    // 看不出这一段多长、放到哪了。
                    if let seg = previewing, previewingTrackID == item.id, seg.to > seg.from {
                        HStack(spacing: 8) {
                            Text(Self.clock(player.elapsed))
                            ProgressView(value: min(1, max(0, (player.elapsed - seg.from) / (seg.to - seg.from))))
                            Text(Self.clock(seg.to))
                        }
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("试听")
                } footer: {
                    if isAuditioning(item) {
                        Text("正在放这一段，到结尾点自动停。**试听用的是上面填的数字，不用先保存。**")
                    } else {
                        Text("按**上面填的数字**试听，**不听整首**。试听会切到这首歌上放；"
                             + "在**同一首**上试听会回到原来的位置，换一首试听就停在那首。")
                    }
                }

                Section {
                    if player.currentID == item.id {
                        Button {
                            skipDraft = String(Int(player.elapsed.rounded()))
                        } label: {
                            Label("用当前播放位置作开头（\(Int(player.elapsed))s）", systemImage: "target")
                        }
                    }
                }

                if IntroSkip.shared.hasAny(for: item.id) {
                    Section {
                        Button(role: .destructive) {
                            IntroSkip.shared.clear(item.id)
                            skipEditing = nil
                        } label: {
                            Label("取消全部跳过", systemImage: "arrow.uturn.backward")
                        }
                    }
                }
            }
            .navigationTitle("跳过开头 / 结尾")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { skipEditing = nil }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        // 解析失败（空串、只有小数点）当 0 = 取消，不会误设一个奇怪的值
                        let start = Double(skipDraft.trimmingCharacters(in: .whitespaces)) ?? 0
                        let end = Double(endDraft.trimmingCharacters(in: .whitespaces)) ?? 0
                        IntroSkip.shared.setRange(start: start, endTrim: end, for: item.id)
                        skipEditing = nil
                    }
                }
            }
        }
    }

    /// 「实际会放 0:12 – 3:28（共 3:16）」。时长未知时返回 nil ——
    /// 没时长还要编一个区间出来是骗人。
    private func trimPreview(_ item: MediaItem) -> String? {
        let total = knownDuration(item)
        guard total > 0 else { return nil }
        // 还没保存的输入框内容也算进去，不然预览跟用户正在打的数字对不上。
        // 注意空串要按 0 算（保存时也是这么解析的），不能回退到已存的值 ——
        // 用户清空输入框就是想取消，预览再显示旧值会让人以为没清掉。
        let start = Double(skipDraft.trimmingCharacters(in: .whitespaces)) ?? 0
        let endInput = Double(endDraft.trimmingCharacters(in: .whitespaces)) ?? 0
        // 闸门照抄 `MediaPlayer.effectiveEnd`：结尾提前量吃掉整首就不认这一项。
        // 预览必须跟真实行为同源，否则「预览说 3:28 结束、实际放到 4:00」。
        let endTrim = endInput > 0 && endInput < total - 1 ? endInput : 0

        let from = min(max(0, start), total)
        let to = total - endTrim
        guard from < to else {
            return "开头点在 \(Self.clock(from))，已经越过「结尾点」，实际会一路播到文件末尾"
        }
        return "实际会放 \(Self.clock(from)) – \(Self.clock(to))（共 \(Self.clock(to - from))）"
    }

    private static func clock(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    /// 正在试听的曲子 id。试听一定是在某一首上进行的，用它判断按钮的标题该是
    /// 「试听」还是「停止试听」、以及这条进度该不该画在这个编辑框里。
    @State private var previewingTrackID: String?

    private func isAuditioning(_ item: MediaItem) -> Bool {
        previewingTrackID == item.id && player.isPreviewing
    }

    /// 按钮上的文案。写清要放哪一段，"从哪到哪"，比一个光秃秃的"试听"有用 ——
    /// 用户改的就是那两个数字，按钮上直接把结果念出来，一眼能看出填错了没有。
    private func auditionLabel(_ item: MediaItem) -> String {
        guard let seg = previewSegment(item) else { return "没法试听（还不知道时长）" }
        let length = seg.to - seg.from
        return "试听 \(Self.clock(seg.from)) → \(Self.clock(seg.to))（\(Self.clock(length))）"
    }

    /// 草稿值算出来的试听区间。`nil` = 没法听（时长未知）。
    ///
    /// ⚠️ 跟 `trimPreview` 的算法必须一致 —— 两处都读同一对草稿。区别只在
    /// **两头都没设**的时候：那时没有"要校验的那一下"可听，干放整首毫无意义
    /// （用户点"试听 0:00 → 4:12"什么也验不到），所以取开头 15 秒听个响，
    /// 让用户至少确认"这歌能放、是它"。设了一头就老老实实放 [开头点, 结尾点]。
    private func previewSegment(_ item: MediaItem) -> (from: Double, to: Double)? {
        let total = knownDuration(item)
        guard total > 0 else { return nil }
        let r = IntroSkip.shared.range(for: item.id)
        let start = Double(skipDraft.trimmingCharacters(in: .whitespaces)) ?? 0
        let endInput = Double(endDraft.trimmingCharacters(in: .whitespaces)) ?? 0
        let endTrim = endInput > 0 && endInput < total - 1 ? endInput : 0

        let from = min(max(0, start), total)
        let to = total - endTrim
        // 区间不成立（开头点越过了结尾点）就当成"这设置本来就无效"，给个开头 15 秒。
        guard from < to else { return (0, min(total, 15)) }
        if from <= 0, endTrim <= 0 {
            // 还没设任何跳过：放开头 15 秒，够听出"开头是不是要剪的那段"
            return (0, min(total, 15))
        }
        // 设了跳过结尾但没设开头：从末尾往前听 15 秒 —— 要验的是"结尾那时候是不是已经唱完了"，
        // 从 0:00 放一遍等于要等整首。这是这里最要紧的一条：**别让人为了听 3 秒结尾等 4 分钟**。
        if from <= 0, endTrim > 0 {
            return (max(0, to - 15), to)
        }
        // 只设了跳过开头：从起点往后听 15 秒，验"是不是正好接到人声"
        if endTrim <= 0 {
            return (from, min(total, from + 15))
        }
        return (from, to)
    }

    /// 点「试听 / 停止试听」。
    private func audition(_ item: MediaItem) {
        if isAuditioning(item) {
            player.endPreview()
            previewing = nil
            previewingTrackID = nil
            return
        }
        guard let seg = previewSegment(item) else { return }
        guard service.library.items.contains(where: { $0.id == item.id }) else { return }
        previewing = seg
        previewingTrackID = item.id
        // 队列给整个资料库（跟从列表点这首一样），试听结束后「下一首」也能接着走。
        player.preview(item: item, from: seg.from, to: seg.to, using: service.library.items)
    }

    private func row(_ item: MediaItem) -> some View {
        Button {
            service.play(item)
        } label: {
            HStack(spacing: 12) {
                ArtworkView(
                    url: service.library.artworkURL(for: item),
                    size: LibraryLayout.artworkSize,
                    corner: 5
                )

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.body)
                        .foregroundStyle(isCurrent(item) ? Color.accentColor : .primary)
                        .lineLimit(1)
                    Text(service.library.subtitle(for: item))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                // 设了跳过的歌标一下：不然用户会以为「怎么这首开头没了」是文件坏了。
                // 只读状态、不占交互 —— 左边划一下才是改它的入口。
                if let skip = skipBadge(item) {
                    Text(skip)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.14), in: Capsule())
                }

                if isCurrent(item), player.isPlaying {
                    Image(systemName: "waveform")
                        .foregroundStyle(.tint)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func isCurrent(_ item: MediaItem) -> Bool {
        player.currentID == item.id
    }

    private var totalText: String {
        let bytes = service.library.totalBytes()
        return bytes > 1024 * 1024 * 1024
            ? String(format: "%.2f GB", Double(bytes) / 1024 / 1024 / 1024)
            : String(format: "%.0f MB", Double(bytes) / 1024 / 1024)
    }

}
