// 用途：跨曲响度归一化的测量内核（EBU R128 / ITU-R BS.1770）。
// 只做“读文件 → 算 integrated LUFS + 峰值”，不碰播放器；播放侧在 LoudnessNormalization.swift。
import AVFoundation
import Foundation

struct LoudnessMeasurement: Codable, Equatable, Sendable {
    /// 整曲积分响度（LUFS）。按 BS.1770 的 400ms 块 + 绝对/相对门限算。
    var integratedLUFS: Float
    /// 解码后的采样峰值（dBFS），不是真峰值。
    var samplePeakDBFS: Float
    /// 真峰值估计。4x 过采样留到以后；现在按“采样峰值 + 保守余量”算，
    /// 宁可少提升一点，也不把已经削波的母带推爆。
    var estimatedTruePeakDBFS: Float
    var fileSize: Int?
    var analyzedAt: Date
}

enum LoudnessTarget {
    /// Spotify / YouTube 等流媒体常用的目标响度。
    static let integratedLUFS: Float = -14
    /// 提升后允许的最高真峰值。
    static let ceilingDBTP: Float = -1
    /// 提升上限，防止把静音/坏文件拉爆。
    static let maximumBoostDB: Float = 12
    /// 衰减上限，防止异常测量把歌压没。
    static let maximumCutDB: Float = -30
    /// 采样峰值到真峰值的保守余量。实测这批文件真峰值普遍比采样峰值高 1~2dB。
    static let truePeakMarginDB: Float = 2
}

enum LoudnessGain {
    /// 把这一首拉到目标响度所需的 dB 增益。
    /// 先按目标算，再按真峰值上限让路：提升不能让 projected TP 超过 ceiling。
    static func gainDB(for measurement: LoudnessMeasurement) -> Float {
        var gain = LoudnessTarget.integratedLUFS - measurement.integratedLUFS
        gain = min(gain, LoudnessTarget.maximumBoostDB)
        gain = max(gain, LoudnessTarget.maximumCutDB)

        let projected = measurement.estimatedTruePeakDBFS + gain
        if projected > LoudnessTarget.ceilingDBTP {
            gain -= projected - LoudnessTarget.ceilingDBTP
        }
        return gain
    }

    static func linearGain(forDB db: Float) -> Float {
        powf(10, db / 20)
    }
}

enum LoudnessAnalyzerError: LocalizedError {
    case noAudioTrack
    case readerFailed(String)
    case tooShort
    case noSignal

    var errorDescription: String? {
        switch self {
        case .noAudioTrack: return "没有音轨"
        case .readerFailed(let message): return "读取音频失败：\(message)"
        case .tooShort: return "音频太短，测不出整曲响度"
        case .noSignal: return "音频没有有效信号"
        }
    }
}

enum LoudnessAnalyzer {
    static func measure(url: URL, fileSize: Int?) async throws -> LoudnessMeasurement {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else { throw LoudnessAnalyzerError.noAudioTrack }

        let descriptions = try await track.load(.formatDescriptions)
        let sourceChannels = descriptions.first
            .flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
            .map { Int($0.mChannelsPerFrame) } ?? 2
        // 我们的文件都是单/双声道；多声道先降到双声道，权重按 L/R 各 1.0 算。
        let channels = sourceChannels <= 1 ? 1 : 2

        return try await Task.detached(priority: .utility) {
            try decode(track: track, asset: asset, channels: channels, fileSize: fileSize)
        }.value
    }

    private static func decode(
        track: AVAssetTrack,
        asset: AVURLAsset,
        channels: Int,
        fileSize: Int?
    ) throws -> LoudnessMeasurement {
        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000.0,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw LoudnessAnalyzerError.readerFailed("这个音轨不支持 PCM 解码")
        }
        reader.add(output)
        guard reader.startReading() else {
            throw LoudnessAnalyzerError.readerFailed(reader.error?.localizedDescription ?? "无法开始读取")
        }

        // 100ms 一个能量块，4 块拼成 400ms 的 EBU R128 测量块。
        let chunkFrames = 48_000 / 10
        var chunkEnergy = [Double](repeating: 0, count: channels)
        var chunkSeen = 0
        var ring: [[Double]] = []
        var blocks: [Double] = []
        var peak: Float = 0

        var s1 = [KWeightState](repeating: KWeightState(), count: channels)
        var s2 = [KWeightState](repeating: KWeightState(), count: channels)

        func flushChunk() {
            let energies = chunkEnergy.map { $0 / Double(chunkFrames) }
            ring.append(energies)
            if ring.count > 4 { ring.removeFirst() }
            if ring.count == 4 {
                var sum = 0.0
                for channel in 0..<channels {
                    var energy = 0.0
                    for chunk in ring { energy += chunk[channel] }
                    sum += energy / Double(ring.count)
                }
                blocks.append(sum)
            }
            chunkEnergy = [Double](repeating: 0, count: channels)
            chunkSeen = 0
        }

        while reader.status == .reading {
            guard let sampleBuffer = output.copyNextSampleBuffer() else { break }
            guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
            let byteLength = CMBlockBufferGetDataLength(dataBuffer)
            let floatCount = byteLength / MemoryLayout<Float>.size
            guard floatCount > 0 else { continue }

            var samples = [Float](repeating: 0, count: floatCount)
            let status = samples.withUnsafeMutableBytes { raw -> OSStatus in
                guard let base = raw.baseAddress else { return -1 }
                return CMBlockBufferCopyDataBytes(
                    dataBuffer, atOffset: 0, dataLength: floatCount * 4, destination: base)
            }
            guard status == noErr else { continue }

            let frames = floatCount / channels
            for frame in 0..<frames {
                let base = frame * channels
                for channel in 0..<channels {
                    let x = samples[base + channel]
                    if abs(x) > peak { peak = abs(x) }
                    var y = KWeighting.stage1.process(x, &s1[channel])
                    y = KWeighting.stage2.process(y, &s2[channel])
                    chunkEnergy[channel] += Double(y * y)
                }
                chunkSeen += 1
                if chunkSeen == chunkFrames { flushChunk() }
            }
        }

        if reader.status == .failed {
            throw LoudnessAnalyzerError.readerFailed(reader.error?.localizedDescription ?? "读取中断")
        }
        guard !blocks.isEmpty else { throw LoudnessAnalyzerError.tooShort }
        guard peak > 0 else { throw LoudnessAnalyzerError.noSignal }

        // 绝对门限 -70 LUFS，再按绝对门限后的平均响度 -10LU 做相对门限。
        let blockLoudness = blocks.map(lufs)
        var absoluteGated: [Double] = []
        for (energy, loudness) in zip(blocks, blockLoudness) where loudness > -70 {
            absoluteGated.append(energy)
        }
        guard !absoluteGated.isEmpty else { throw LoudnessAnalyzerError.noSignal }
        let absoluteMean = absoluteGated.reduce(0, +) / Double(absoluteGated.count)
        let relativeThreshold = lufs(absoluteMean) - 10

        var gated: [Double] = []
        for (energy, loudness) in zip(blocks, blockLoudness)
        where loudness > -70 && loudness > relativeThreshold {
            gated.append(energy)
        }
        guard !gated.isEmpty else { throw LoudnessAnalyzerError.noSignal }
        let integrated = lufs(gated.reduce(0, +) / Double(gated.count))

        let samplePeak = 20 * log10(Double(peak))
        return LoudnessMeasurement(
            integratedLUFS: Float(integrated),
            samplePeakDBFS: Float(samplePeak),
            estimatedTruePeakDBFS: Float(samplePeak) + LoudnessTarget.truePeakMarginDB,
            fileSize: fileSize,
            analyzedAt: Date()
        )
    }

    private static func lufs(_ energy: Double) -> Double {
        -0.691 + 10 * log10(max(energy, 1e-12))
    }
}

// MARK: - K 加权（48kHz 标准系数）

private struct KWeightState {
    var x1: Float = 0
    var x2: Float = 0
    var y1: Float = 0
    var y2: Float = 0
}

private struct KWeighting {
    struct Coefficients {
        let b0, b1, b2, a1, a2: Float

        func process(_ x: Float, _ s: inout KWeightState) -> Float {
            let y = b0 * x + b1 * s.x1 + b2 * s.x2 - a1 * s.y1 - a2 * s.y2
            s.x2 = s.x1
            s.x1 = x
            s.y2 = s.y1
            s.y1 = y
            return y
        }
    }

    static let stage1 = Coefficients(
        b0: 1.53512485958697,
        b1: -2.69169618940638,
        b2: 1.19839281085285,
        a1: -1.69065929318241,
        a2: 0.73248077421585
    )

    static let stage2 = Coefficients(
        b0: 1.0,
        b1: -2.0,
        b2: 1.0,
        a1: -1.99004745483398,
        a2: 0.99007225036621
    )
}
