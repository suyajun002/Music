// 用途：并发闸门——只决定「谁在排队 / 谁在跑 / 还能不能再开一个」，不关心怎么下载、怎么落库。
// 纯 Foundation，无 UIKit 依赖，可在命令行直接单测并发语义。
import Foundation

/// 并发调度闸门。
///
/// 规则集中在这里，`ConversionService` 只负责入队、启动、跑完回来报到；
/// 这样「并行度」这条业务规则不会和下载实现、UI 状态混在一起。
struct ConcurrencyGate {
    /// 允许同时在跑的上限。调小不打断已在跑的任务，只会暂停开启新任务。
    var limit: Int {
        didSet { limit = max(1, limit) }
    }

    private(set) var running = 0
    private var waiting: [String] = []

    init(limit: Int = 3) {
        self.limit = max(1, limit)
    }

    var waitingCount: Int { waiting.count }

    /// 入队。已在排队的同一 id 不会重复加入。
    mutating func enqueue(_ id: String) {
        guard !waiting.contains(id) else { return }
        waiting.append(id)
    }

    /// 取消还在排队、尚未启动的任务。
    mutating func cancel(_ id: String) {
        waiting.removeAll { $0 == id }
    }

    /// 取出当前可以立刻启动的任务（先到先跑，最多到上限），并计入 running。
    mutating func takeStartable() -> [String] {
        var started: [String] = []
        while running < limit, !waiting.isEmpty {
            started.append(waiting.removeFirst())
            running += 1
        }
        return started
    }

    /// 一个任务结束（成功或失败都算），释放一个名额。
    mutating func finish() {
        running = max(0, running - 1)
    }
}
