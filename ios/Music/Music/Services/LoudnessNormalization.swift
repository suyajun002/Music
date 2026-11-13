// 用途：跨曲响度归一化的播放侧。测量结果按条目缓存，播放时折算成固定增益。
// 衰减直接走 AVAudioMix（0…1 线性音量），需要提升时走一个极简 MTAudioProcessingTap，
// 因为 Apple 把 AVAudioMix 的音量限制在 0…1，音量超过 1 会被夹掉。
import AVFoundation
import Foundation
import MediaToolbox

@MainActor
final class LoudnessStore: ObservableObject {
    static let shared = LoudnessStore()
    /// 默认开。关掉后立即恢复原声，不再对当前曲目加增益。
    static let enabledKey = "audio.normalization.enabled"

    private(set) var records: [String: LoudnessMeasurement] = [:]
    private let fileManager = FileManager.default
    private let storeURL: URL
    /// 本次启动已经试过的条目，失败也不反复重试（避免每次切歌都卡一下）。
    private var attemptedThisLaunch = Set<String>()
    private var isBackfilling = false

    private init() {
        let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        storeURL = documents.appendingPathComponent("audio-analysis.json")
        load()
    }

    var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.enabledKey) }
    }

    func measurement(for id: String, fileSize: Int? = nil) -> LoudnessMeasurement? {
        guard let record = records[id] else { return nil }
        // 文件被替换过就作废旧测量，避免拿上一版的结果去压新文件。
        if let fileSize, let stored = record.fileSize, stored != fileSize { return nil }
        return record
    }

    func gainDB(for item: MediaItem, fileURL: URL) -> Float? {
        guard isEnabled else { return nil }
        let size = fileSize(at: fileURL)
        guard let measurement = measurement(for: item.id, fileSize: size) else { return nil }
        return LoudnessGain.gainDB(for: measurement)
    }

    func analyzeIfNeeded(id: String, url: URL) async {
        guard !attemptedThisLaunch.contains(id) else { return }
        let size = fileSize(at: url)
        if measurement(for: id, fileSize: size) != nil { return }
        attemptedThisLaunch.insert(id)

        do {
            let measurement = try await LoudnessAnalyzer.measure(url: url, fileSize: size)
            records[id] = measurement
            persist()
            let gain = LoudnessGain.gainDB(for: measurement)
            MusicDebug.log(String(
                format: "响度：%@ %.1f LUFS，峰值 %.1f dBTP，增益 %+.1f dB",
                String(id.prefix(8)), measurement.integratedLUFS,
                measurement.estimatedTruePeakDBFS, gain))
        } catch {
            MusicDebug.log("响度：测量失败 \(id.prefix(8)) — \(error.localizedDescription)")
        }
    }

    /// 启动/回前台时补测老条目。一次两首，不挡播放；已测过的直接跳过。
    func backfill(items: [MediaItem], fileURL: (MediaItem) -> URL) async {
        guard isEnabled, !isBackfilling else { return }
        isBackfilling = true
        defer { isBackfilling = false }

        let validIDs = Set(items.map(\.id))
        let before = records.count
        records = records.filter { validIDs.contains($0.key) }
        if records.count != before { persist() }

        let pending = items.filter { item in
            measurement(for: item.id, fileSize: fileSize(at: fileURL(item))) == nil
        }
        guard !pending.isEmpty else { return }
        MusicDebug.log("响度：待补测 \(pending.count) 首")

        let batchSize = 2
        var start = 0
        while start < pending.count {
            let end = min(start + batchSize, pending.count)
            let batch = Array(pending[start..<end])
            await withTaskGroup(of: Void.self) { group in
                for item in batch {
                    let url = fileURL(item)
                    group.addTask { [weak self] in
                        await self?.analyzeIfNeeded(id: item.id, url: url)
                    }
                }
            }
            start = end
        }
    }

    private func fileSize(at url: URL) -> Int? {
        (try? fileManager.attributesOfItem(atPath: url.path))?[.size] as? Int
    }

    private func load() {
        guard let data = try? Data(contentsOf: storeURL) else { return }
        do {
            records = try JSONDecoder().decode([String: LoudnessMeasurement].self, from: data)
        } catch {
            let stamp = Int(Date().timeIntervalSince1970)
            let backup = storeURL.appendingPathExtension("corrupt-\(stamp)")
            try? fileManager.moveItem(at: storeURL, to: backup)
            MusicDebug.log("响度：缓存解码失败，已留档 \(backup.lastPathComponent)")
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }
}

/// 只做线性增益 + 防削波钳位。用于“这首需要提升、但没开音效”的少数情况。
enum NormalizationTap {
    static func make(gainDB: Float) -> MTAudioProcessingTap? {
        let context = NormalizationTapContext(gain: LoudnessGain.linearGain(forDB: gainDB))
        let retained = Unmanaged.passRetained(context)

        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: retained.toOpaque(),
            init: { _, clientInfo, storageOut in
                storageOut.pointee = clientInfo
            },
            finalize: { tap in
                Unmanaged<NormalizationTapContext>
                    .fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
            },
            prepare: { tap, _, format in
                Unmanaged<NormalizationTapContext>
                    .fromOpaque(MTAudioProcessingTapGetStorage(tap))
                    .takeUnretainedValue().prepare(format: format.pointee)
            },
            unprepare: { tap in
                Unmanaged<NormalizationTapContext>
                    .fromOpaque(MTAudioProcessingTapGetStorage(tap))
                    .takeUnretainedValue().teardown()
            },
            process: { tap, numberFrames, _, bufferListInOut, numberFramesOut, flagsOut in
                let status = MTAudioProcessingTapGetSourceAudio(
                    tap, numberFrames, bufferListInOut, flagsOut, nil, numberFramesOut)
                guard status == noErr, numberFramesOut.pointee > 0 else { return }
                Unmanaged<NormalizationTapContext>
                    .fromOpaque(MTAudioProcessingTapGetStorage(tap))
                    .takeUnretainedValue()
                    .process(bufferList: bufferListInOut, frames: Int(numberFramesOut.pointee))
            }
        )

        var tap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(
            kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PostEffects, &tap)
        guard status == noErr, let tap else {
            MusicDebug.log("响度：增益 tap 创建失败（\(status)）")
            retained.release()
            return nil
        }
        return tap
    }
}

private final class NormalizationTapContext {
    private let gain: Float
    private var channels = 2
    private var isFloat = true
    private var isInterleaved = true
    private var bytesPerSample = 4
    private var ready = false

    init(gain: Float) { self.gain = gain }

    func prepare(format: AudioStreamBasicDescription) {
        channels = Int(format.mChannelsPerFrame)
        isFloat = format.mFormatFlags & kAudioFormatFlagIsFloat != 0
        isInterleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        bytesPerSample = Int(format.mBitsPerChannel / 8)
        ready = (channels == 1 || channels == 2) && (isFloat || bytesPerSample == 2)
        if !ready {
            MusicDebug.log("响度：增益 tap 不支持这个格式（\(channels)ch / \(bytesPerSample)B）")
        }
    }

    func teardown() { ready = false }

    func process(bufferList: UnsafeMutablePointer<AudioBufferList>, frames: Int) {
        guard ready, gain != 1 else { return }
        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)

        if isFloat {
            if isInterleaved {
                guard buffers.count > 0, let raw = buffers[0].mData else { return }
                let p = raw.assumingMemoryBound(to: Float.self)
                for i in 0..<(frames * channels) { p[i] = clamp(p[i] * gain) }
            } else {
                for channel in 0..<min(channels, buffers.count) {
                    guard let raw = buffers[channel].mData else { continue }
                    let p = raw.assumingMemoryBound(to: Float.self)
                    for i in 0..<frames { p[i] = clamp(p[i] * gain) }
                }
            }
        } else if bytesPerSample == 2 {
            if isInterleaved {
                guard buffers.count > 0, let raw = buffers[0].mData else { return }
                let p = raw.assumingMemoryBound(to: Int16.self)
                for i in 0..<(frames * channels) { p[i] = scale(p[i]) }
            } else {
                for channel in 0..<min(channels, buffers.count) {
                    guard let raw = buffers[channel].mData else { continue }
                    let p = raw.assumingMemoryBound(to: Int16.self)
                    for i in 0..<frames { p[i] = scale(p[i]) }
                }
            }
        }
    }

    private func scale(_ sample: Int16) -> Int16 {
        let value = clamp(Float(sample) / 32_768 * gain)
        return Int16((value * 32_767).rounded())
    }

    private func clamp(_ value: Float) -> Float {
        min(1, max(-1, value))
    }
}
