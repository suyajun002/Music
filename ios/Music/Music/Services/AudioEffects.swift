// 用途：音效的音频处理内核。走 AVPlayer 的 MTAudioProcessingTap，在解码后的 PCM 上做 DSP，
// 播放器的 seek / 视频画面 / 锁屏遥控 / 后台播放都不受影响。
//
// 为什么是 tap 而不是 AVAudioEngine：这个 App 要放 mp4，画面挂在 AVPlayerLayer 上，
// 一旦把音频搬到 AVAudioEngine 就得自己维护音画同步（见 GitHub 上 equal-sounds 那种做法：
// 整条 Player 都得重写）。tap 挂在 AVPlayerItem 的 audioMix 上，播放内核一行都不用动。
//
// 架构（对着 QQ音乐 / 汽水音乐 反编译的结论来的，见 skill android-apk-intel）：
//   **预设是数据，不是代码** —— 九套音效全在 Resources/effectPresets.json 里，
//   每套是一串模块配置（EQ 段 / 谐波激励 / 饱和 / 展宽 / 环境声 / 底噪 / 输出增益）。
//   两家商业 App 都是这个结构（QQ音乐 是 50+ 个 .aep 数据包，汽水是服务端下发参数），
//   好处一样：加一套音效只改数据，不碰引擎、不发版。
//
// 处理顺序（固定，不按 JSON 里的书写顺序）：
//   去次声 → EQ → 谐波激励 → 饱和 → 立体声展宽 → 环境声/延迟 → 底噪 → 输出增益
//   → 低频段限幅 → 响度护栏 → 柔性削波
import AVFoundation
import Accelerate
import MediaToolbox

// MARK: - 预设数据

/// EQ 的一段。`type`: lowShelf / highShelf / peaking / highPass / lowPass
struct EffectBand: Codable {
    let type: String
    let freq: Double
    var gain: Double?
    var q: Double?
    var slope: Double?
}

/// 一个模块。字段是各模块的并集，用 `type` 区分 —— 比 Codable + enum 简单，
/// 而且加新模块时旧 JSON 不用改。
struct EffectModuleConfig: Codable {
    let type: String
    var bands: [EffectBand]?      // eq
    var freq: Double?             // rumbleCut
    var db: Double?               // gain
    var driveDb: Double?          // saturation / harmonics
    var mix: Double?              // saturation / ambience
    var amount: Double?           // width
    var cutoff: Double?           // harmonics
    var highPass: Double?         // harmonics
    var weight: Double?           // harmonics
    var delaysMs: [Double]?       // ambience
    var feedback: Double?         // ambience
    var levelDb: Double?          // noise
    var lowPass: Double?          // noise
    var ir: String?               // convolver：Resource 里的 IR 文件名
    var minDb: Double?            // adaptiveTilt
    var maxDb: Double?
    var updateSec: Double?
}

struct EffectPresetConfig: Codable, Identifiable {
    let id: String
    let name: String
    let subtitle: String
    let modules: [EffectModuleConfig]
}

private struct EffectPresetLibrary: Codable {
    let version: Int
    let presets: [EffectPresetConfig]
}

enum AudioEffectPresets {
    /// 从 bundle 读；读不到就用内置的最小集合（绝不能因为缺一个 json 就让播放器装不上音效）。
    static let all: [EffectPresetConfig] = load()

    static func preset(id: String?) -> EffectPresetConfig? {
        guard let id else { return nil }
        return all.first { $0.id == id }
    }

    private static func load() -> [EffectPresetConfig] {
        if let url = Bundle.main.url(forResource: "effectPresets", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let lib = try? JSONDecoder().decode(EffectPresetLibrary.self, from: data) {
            MusicDebug.log("音效：预设库已加载，\(lib.presets.count) 套")
            return lib.presets
        }
        MusicDebug.log("音效：⚠️ 没读到 effectPresets.json，退回内置的一套")
        return fallback
    }

    private static let fallback: [EffectPresetConfig] = [
        EffectPresetConfig(id: "bassBoost", name: "超重低音", subtitle: "澎湃低音带来更多震撼", modules: [
            EffectModuleConfig(type: "rumbleCut", freq: 28),
            EffectModuleConfig(type: "eq", bands: [EffectBand(type: "lowShelf", freq: 85, gain: 10, slope: 1.0)]),
            EffectModuleConfig(type: "harmonics", driveDb: 16, cutoff: 120, highPass: 100, weight: 0.5),
            EffectModuleConfig(type: "gain", db: -1.4),
        ])
    ]
}

// MARK: - 装配

enum AudioEffectTap {
    /// 给出一个配好 DSP 的 tap。返回 nil 表示这次没装上（调用方照常播，就是没音效）。
    static func make(preset: EffectPresetConfig, extraGainDB: Float = 0) -> MTAudioProcessingTap? {
        let context = TapContext(preset: preset, extraGainDB: extraGainDB)
        // 引用计数交给 tap：finalize 回调里 release 回来。tap 创建失败要自己收掉，
        // 否则每换一首歌泄一个 context。
        let retained = Unmanaged.passRetained(context)

        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: retained.toOpaque(),
            init: { tap, clientInfo, storageOut in
                storageOut.pointee = clientInfo
            },
            finalize: { tap in
                Unmanaged<TapContext>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
            },
            prepare: { tap, maxFrames, format in
                let context = Unmanaged<TapContext>
                    .fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                context.prepare(format: format.pointee, maxFrames: Int(maxFrames))
            },
            unprepare: { tap in
                Unmanaged<TapContext>
                    .fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue().teardown()
            },
            process: { tap, numberFrames, _, bufferListInOut, numberFramesOut, flagsOut in
                // 先把源音频取进 bufferListInOut；flagsOut 直接透传给它，
                // 这样「流结束」这类标志位不用我们自己搬。
                let status = MTAudioProcessingTapGetSourceAudio(
                    tap, numberFrames, bufferListInOut, flagsOut, nil, numberFramesOut)
                guard status == noErr, numberFramesOut.pointee > 0 else { return }
                Unmanaged<TapContext>
                    .fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                    .process(bufferList: bufferListInOut, frames: Int(numberFramesOut.pointee))
            }
        )

        var tap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(
            kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PostEffects, &tap)
        guard status == noErr, let tap else {
            MusicDebug.log("音效：tap 创建失败（\(status)），这首按原声放")
            retained.release()
            return nil
        }
        return tap
    }
}

/// tap 的生命周期载体。回调是 C 函数指针、拿不到 self，只能靠它来回传状态。
private final class TapContext {
    private let preset: EffectPresetConfig
    private let extraGainDB: Float
    private var processor: EffectProcessor?

    init(preset: EffectPresetConfig, extraGainDB: Float) {
        self.preset = preset
        self.extraGainDB = extraGainDB
    }

    func prepare(format: AudioStreamBasicDescription, maxFrames: Int) {
        processor = EffectProcessor(
            preset: preset, format: format, maxFrames: maxFrames, extraGainDB: extraGainDB)
        if let processor {
            MusicDebug.log("音效：准备就绪 —— \(preset.name)，\(processor.describe)")
        } else {
            MusicDebug.log("音效：这个音频格式处理不了，按原声放（\(format.mFormatID)）")
        }
    }

    func teardown() { processor = nil }

    func process(bufferList: UnsafeMutablePointer<AudioBufferList>, frames: Int) {
        processor?.process(bufferList: bufferList, frames: frames)
    }
}

// MARK: - 引擎

/// 按预设配置组装出来的处理链。所有工作区在 init 里预分配 —— 渲染回调里不能碰堆。
final class EffectProcessor {
    /// 限幅/响度这两级是**全预设共用**的护栏，不写进 JSON：
    /// 它们的职责是「别削波、别让切音效时音量跳」，跟具体音色无关。
    enum Guard {
        /// 低频段天花板：低音鼓顶到这儿就压它自己，中高频（人声）原样通过。
        static let lowBandCeiling: Float = 0.40
        static let splitFreq = 180.0
        /// 响度护栏的死区：偏离原曲 ≤2dB 直通，超过才介入，最多 ±1.5dB。
        static let deadZoneDb: Float = 2
        static let maxMakeupDB: Float = 1.0
        static let minMakeupDB: Float = -1.5
        static let loudnessTau: Float = 0.40
        static let makeupSmoothTau: Float = 0.08
        /// 末级柔性削波的拐点与渐近线
        static let softKnee: Float = 0.90
        static let asymptote: Float = 0.95
    }

    private let presetName: String
    private let channels: Int
    private let isFloat: Bool
    private let isInterleaved: Bool
    private let sampleRate: Double

    // 模块状态
    private var rumble: [Biquad]
    private var rumbleState: [BiquadState]
    private var eq: [Biquad]
    private var eqState: [BiquadState]
    private let harmonics: HarmonicsConfig?
    private var harmonicsLP: [Biquad]
    private var harmonicsHP: [Biquad]
    private var harmonicsLPState: [BiquadState]
    private var harmonicsHPState: [BiquadState]
    private let saturationDrive: Float
    private let widthAmount: Float
    private let ambience: AmbienceConfig?
    private var delays: [DelayLine]
    private let noise: NoiseConfig?
    private var noiseSeed: [UInt32]
    private var noiseLP: Float = 0
    private let convolver: Convolver?
    private let convolverMix: Float
    private let adaptive: AdaptiveTiltConfig?
    private var adaptiveLow: [Biquad]
    private var adaptiveHigh: [Biquad]
    private var adaptiveLowState: [BiquadState]
    private var adaptiveHighState: [BiquadState]
    private var adaptiveLowEnergy: Float = 0
    private var adaptiveHighEnergy: Float = 0
    private var adaptiveAccum: Float = 0
    private var adaptiveTilt: [Biquad]
    private var adaptiveTiltState: [BiquadState]
    private let outputGain: Float

    // 护栏状态
    private var splitLP: [Biquad]
    private var splitLPState: [BiquadState]
    private var limiterGain: [Float]
    private var loudInFilter: [Biquad]
    private var loudOutFilter: [Biquad]
    private var loudInState: [BiquadState]
    private var loudOutState: [BiquadState]
    private var inPower: Float = 0
    private var outPower: Float = 0
    private var makeupGain: Float = 1
    private var peakEnvelope: Float = 0

    // 工作区
    private var scratch: [[Float]] = []
    private var subBuffer: [Float]
    private var lowBuffer: [Float]
    private var loudBuffer: [Float]

    private var peakSinceLog: Float = 0
    private var gainSinceLog: Float = 1
    private var makeupDbSinceLog: Float = 0
    private var framesSinceLog = 0

    private struct HarmonicsConfig {
        let cutoff: Double, drive: Float, weight: Float, highPass: Double
    }
    private struct AmbienceConfig {
        let delaysMs: [Double], feedback: Float, mix: Float
    }
    private struct NoiseConfig {
        let level: Float, lowPass: Double
    }
    private struct AdaptiveTiltConfig {
        let minDb, maxDb, updateSec: Float
    }

    init?(
        preset: EffectPresetConfig,
        format: AudioStreamBasicDescription,
        maxFrames: Int,
        extraGainDB: Float = 0
    ) {
        guard format.mFormatID == kAudioFormatLinearPCM else { return nil }
        let isFloat = format.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let isSignedInt = format.mFormatFlags & kAudioFormatFlagIsSignedInteger != 0
        guard isFloat || isSignedInt else { return nil }
        let bytesPerSample = Int(format.mBitsPerChannel / 8)
        guard bytesPerSample == 4 || bytesPerSample == 2 else { return nil }
        let channels = Int(format.mChannelsPerFrame)
        guard channels == 1 || channels == 2 else { return nil }
        let sampleRate = format.mSampleRate > 0 ? format.mSampleRate : 44100

        self.presetName = preset.name
        self.channels = channels
        self.isFloat = isFloat
        self.isInterleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        self.sampleRate = sampleRate

        // ——— 从配置组装 ———
        func module(_ type: String) -> EffectModuleConfig? { preset.modules.first { $0.type == type } }

        let rumbleFreq = module("rumbleCut")?.freq ?? 0
        rumble = Array(repeating: Biquad.highPass(freq: rumbleFreq, q: 0.707, sampleRate: sampleRate),
                       count: channels)
        rumbleState = Array(repeating: BiquadState(), count: channels)

        var bands: [Biquad] = []
        for band in module("eq")?.bands ?? [] {
            switch band.type {
            case "lowShelf":  bands.append(.lowShelf(freq: band.freq, gainDB: band.gain ?? 0, slope: band.slope ?? 1, sampleRate: sampleRate))
            case "highShelf": bands.append(.highShelf(freq: band.freq, gainDB: band.gain ?? 0, slope: band.slope ?? 1, sampleRate: sampleRate))
            case "highPass":  bands.append(.highPass(freq: band.freq, q: band.q ?? 0.707, sampleRate: sampleRate))
            case "lowPass":   bands.append(.lowPass(freq: band.freq, q: band.q ?? 0.707, sampleRate: sampleRate))
            default:          bands.append(.peaking(freq: band.freq, gainDB: band.gain ?? 0, q: band.q ?? 1, sampleRate: sampleRate))
            }
        }
        eq = bands
        eqState = Array(repeating: BiquadState(), count: max(bands.count * channels, 1))

        if let h = module("harmonics"), let cutoff = h.cutoff {
            harmonics = HarmonicsConfig(cutoff: cutoff,
                                        drive: EffectProcessor.dbToGain(h.driveDb ?? 12),
                                        weight: Float(h.weight ?? 0.4),
                                        highPass: h.highPass ?? cutoff)
        } else {
            harmonics = nil
        }
        let hpFreq = harmonics?.highPass ?? 100
        let lpFreq = harmonics?.cutoff ?? 120
        harmonicsLP = Array(repeating: Biquad.lowPass(freq: lpFreq, q: 0.707, sampleRate: sampleRate), count: channels)
        harmonicsHP = Array(repeating: Biquad.highPass(freq: hpFreq, q: 0.707, sampleRate: sampleRate), count: channels)
        harmonicsLPState = Array(repeating: BiquadState(), count: channels)
        harmonicsHPState = Array(repeating: BiquadState(), count: channels)

        saturationDrive = EffectProcessor.dbToGain(module("saturation")?.driveDb ?? 0)
        widthAmount = Float(module("width")?.amount ?? 1)
        if let a = module("ambience"), let d = a.delaysMs, !d.isEmpty {
            ambience = AmbienceConfig(delaysMs: d, feedback: Float(a.feedback ?? 0.3), mix: Float(a.mix ?? 0.3))
        } else {
            ambience = nil
        }
        var lines: [DelayLine] = []
        for ms in ambience?.delaysMs ?? [] {
            lines.append(DelayLine(length: max(1, Int(ms / 1000 * sampleRate)), channels: channels))
        }
        delays = lines
        if let n = module("noise"), let level = n.levelDb {
            noise = NoiseConfig(level: EffectProcessor.dbToGain(level), lowPass: n.lowPass ?? 8000)
        } else {
            noise = nil
        }
        noiseSeed = [UInt32](repeating: 12_345, count: max(channels, 1))

        // 卷积混响：IR 从 Resources 读，按当前采样率重采样后预计算频谱（在 prepare 里，不在回调里）
        if let c = module("convolver"), let irName = c.ir {
            convolver = Convolver(irName: irName, channels: channels,
                                  sampleRate: sampleRate, maxFrames: maxFrames)
            convolverMix = Float(c.mix ?? 0.4)
        } else {
            convolver = nil
            convolverMix = 0
        }

        // 自适应倾斜（智能音效）：按低频/高频能量比实时推一条搁架曲线
        if let a = module("adaptiveTilt") {
            adaptive = AdaptiveTiltConfig(minDb: Float(a.minDb ?? -3),
                                          maxDb: Float(a.maxDb ?? 4),
                                          updateSec: Float(a.updateSec ?? 2))
        } else {
            adaptive = nil
        }
        adaptiveLow = Array(repeating: Biquad.lowPass(freq: 250, q: 0.707, sampleRate: sampleRate), count: channels)
        adaptiveHigh = Array(repeating: Biquad.highPass(freq: 2500, q: 0.707, sampleRate: sampleRate), count: channels)
        adaptiveLowState = Array(repeating: BiquadState(), count: channels)
        adaptiveHighState = Array(repeating: BiquadState(), count: channels)
        adaptiveTilt = Array(repeating: Biquad.lowShelf(freq: 200, gainDB: 0, slope: 1, sampleRate: sampleRate), count: channels)
        adaptiveTiltState = Array(repeating: BiquadState(), count: channels)

        // 响度归一化的增益并进输出增益，不额外加一级处理；音效链的护栏照旧兜底。
        outputGain = EffectProcessor.dbToGain((module("gain")?.db ?? 0) + Double(extraGainDB))

        // ——— 护栏 ———
        splitLP = Array(repeating: Biquad.lowPass(freq: Guard.splitFreq, q: 0.707, sampleRate: sampleRate), count: channels)
        splitLPState = Array(repeating: BiquadState(), count: channels)
        limiterGain = [Float](repeating: 1, count: channels)
        loudInFilter = Array(repeating: Biquad.highPass(freq: 60, q: 0.707, sampleRate: sampleRate), count: channels)
        loudOutFilter = Array(repeating: Biquad.highPass(freq: 60, q: 0.707, sampleRate: sampleRate), count: channels)
        loudInState = Array(repeating: BiquadState(), count: channels)
        loudOutState = Array(repeating: BiquadState(), count: channels)

        // ——— 工作区（预分配）———
        subBuffer = [Float](repeating: 0, count: maxFrames)
        lowBuffer = [Float](repeating: 0, count: maxFrames)
        loudBuffer = [Float](repeating: 0, count: maxFrames)
        if isInterleaved || !isFloat {
            scratch = (0..<channels).map { _ in [Float](repeating: 0, count: maxFrames) }
        }
    }

    var describe: String {
        "\(Int(sampleRate))Hz/\(channels)ch \(isFloat ? "float" : "int16")\(isInterleaved ? "/交织" : "/平面") · \(presetName)"
    }

    // MARK: 处理

    func process(bufferList: UnsafeMutablePointer<AudioBufferList>, frames: Int) {
        guard frames > 0 else { return }
        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)

        // 统一拿到每个通道的 Float 指针（平面 float 直接用，其它布局先拆到 scratch）
        var pointers: [UnsafeMutablePointer<Float>] = []
        var int16Pointers: [UnsafeMutablePointer<Int16>] = []
        var usedScratch = false

        if !isInterleaved, buffers.count >= channels, isFloat {
            for ch in 0..<channels {
                guard let data = buffers[ch].mData else { return }
                pointers.append(data.assumingMemoryBound(to: Float.self))
            }
        } else {
            guard let data = buffers[0].mData, frames <= scratch.first?.count ?? 0 else { return }
            usedScratch = true
            if isFloat {
                let src = data.assumingMemoryBound(to: Float.self)
                for ch in 0..<channels {
                    for i in 0..<frames { scratch[ch][i] = src[i * channels + ch] }
                    pointers.append(UnsafeMutablePointer(mutating: scratch[ch]))
                }
            } else {
                let src = data.assumingMemoryBound(to: Int16.self)
                for ch in 0..<channels {
                    for i in 0..<frames { scratch[ch][i] = Float(src[i * channels + ch]) / 32768 }
                    pointers.append(UnsafeMutablePointer(mutating: scratch[ch]))
                    int16Pointers.append(src)
                }
            }
        }

        let dt = Float(frames) / Float(sampleRate)
        var inBlockPower: Float = 0

        // 1) 逐通道：量输入响度 → 去次声 → EQ → 谐波 → 饱和 → 环境声 → 底噪 → 增益
        for ch in 0..<channels {
            let p = pointers[ch]
            inBlockPower += measureInput(p, frames: frames, channel: ch)
            applyChannel(p, frames: frames, channel: ch)
        }
        inBlockPower /= Float(channels)

        // 2) 立体声展宽（需要两个通道一起算中/侧）
        if channels == 2, widthAmount != 1 {
            applyWidth(pointers[0], pointers[1], frames: frames)
        }

        // 3) 护栏：低频段限幅 → 响度护栏 → 柔性削波
        var outBlockPower: Float = 0
        for ch in 0..<channels {
            outBlockPower += applyGuards(pointers[ch], frames: frames, channel: ch)
        }
        outBlockPower /= Float(channels)

        let aLoud = 1 - expf(-dt / Guard.loudnessTau)
        inPower += (inBlockPower - inPower) * aLoud
        outPower += (outBlockPower - outPower) * aLoud

        // 4) 写回
        if !int16Pointers.isEmpty {
            for ch in 0..<min(channels, int16Pointers.count) {
                let dst = int16Pointers[ch]
                let src = pointers[ch]
                for i in 0..<frames { dst[i] = Int16(max(-32768, min(32767, src[i] * 32767))) }
            }
        } else if usedScratch {
            guard let data = buffers[0].mData else { return }
            let dst = data.assumingMemoryBound(to: Float.self)
            for ch in 0..<channels {
                let src = pointers[ch]
                for i in 0..<frames { dst[i * channels + ch] = src[i] }
            }
        }

        framesSinceLog += frames
        if framesSinceLog >= Int(sampleRate) * 5 {
            MusicDebug.log("音效[\(presetName)]：已处理 \(framesSinceLog / Int(sampleRate))s，"
                            + "峰值 \(String(format: "%.2f", peakSinceLog))，"
                            + "低频限幅 \(String(format: "%.2f", gainSinceLog))，"
                            + "响度补偿 \(String(format: "%+.1f", makeupDbSinceLog))dB")
            framesSinceLog = 0
            peakSinceLog = 0
            gainSinceLog = 1
        }
    }

    /// 输入响度样本（K 加权）。必须在任何处理之前取。
    private func measureInput(_ p: UnsafeMutablePointer<Float>, frames: Int, channel: Int) -> Float {
        var power: Float = 0
        loudBuffer.withUnsafeMutableBufferPointer { buf in
            for i in 0..<frames { buf[i] = p[i] }
            loudInFilter[channel].process(buf.baseAddress!, frames: frames, state: &loudInState[channel])
            for i in 0..<frames { power += buf[i] * buf[i] }
        }
        return power / Float(frames)
    }

    private func applyChannel(_ p: UnsafeMutablePointer<Float>, frames: Int, channel: Int) {
        if !rumble[channel].isIdentity {
            rumble[channel].process(p, frames: frames, state: &rumbleState[channel])
        }

        if !eq.isEmpty {
            for b in 0..<eq.count {
                eq[b].process(p, frames: frames, state: &eqState[channel * eq.count + b])
            }
        }

        if let h = harmonics {
            subBuffer.withUnsafeMutableBufferPointer { sub in
                for i in 0..<frames { sub[i] = p[i] }
                harmonicsLP[channel].process(sub.baseAddress!, frames: frames, state: &harmonicsLPState[channel])
                for i in 0..<frames { sub[i] = tanhf(sub[i] * h.drive) }
                harmonicsHP[channel].process(sub.baseAddress!, frames: frames, state: &harmonicsHPState[channel])
                for i in 0..<frames { p[i] += sub[i] * h.weight }
            }
        }

        if saturationDrive > 1 {
            // 归一化要除以 tanh(drive)，不是除以 drive —— 后者会把整条链压掉 6-10dB
            // （tanh(0.3×10)/10 ≈ −9.6dB），实测「摇滚」预设整个人声掉了 6.4dB。
            let norm = 1 / tanhf(saturationDrive)
            for i in 0..<frames { p[i] = tanhf(p[i] * saturationDrive) * norm }
        }

        if let a = ambience, !delays.isEmpty {
            // 并联带反馈的延时 ≈ 简化版 Schroeder 混响；湿声按 mix 均分
            let wet = a.mix / Float(delays.count)
            for d in 0..<delays.count {
                delays[d].process(p, frames: frames, channel: channel, feedback: a.feedback, wet: wet)
            }
        }

        if let c = convolver {
            c.process(p, frames: frames, channel: channel, mix: convolverMix)
        }

        if adaptive != nil {
            analyzeForTilt(p, frames: frames, channel: channel)
        }
        if !adaptiveTilt[channel].isIdentity {
            adaptiveTilt[channel].process(p, frames: frames, state: &adaptiveTiltState[channel])
        }

        if let n = noise {
            // 底噪：LCG 白噪经一级低通后混入（黑胶的"沙"）。
            // ⚠️ 种子必须是 UInt32 做整数运算 —— 用 Float 累乘会在几十个样本内溢出成 inf。
            var seed = noiseSeed[channel]
            var x1 = noiseLP
            let a: Float = 0.15
            for i in 0..<frames {
                seed = seed &* 1_664_525 &+ 1_013_904_223
                let white = Float(seed >> 9) / 4_194_304.0 - 1   // [-1,1)
                x1 += a * (white - x1)
                p[i] += x1 * n.level
            }
            noiseSeed[channel] = seed
            if channel == channels - 1 { noiseLP = x1 }
        }

        if outputGain != 1 {
            for i in 0..<frames { p[i] *= outputGain }
        }
    }

    /// 「智能音效」的自适应部分：统计低频/高频能量比，按比例推一条低频搁架。
    ///
    /// 判断依据是**频谱重心**的高低，不是"曲风"——我们没有 genre 元数据，
    /// 这一步只能做到"这首歌低频太多就收一点、太少就补一点"，跟 QQ音乐 的
    /// `IntelligentEffect` 那种分类器不是一回事，别把宣传词当真。
    private func analyzeForTilt(_ p: UnsafeMutablePointer<Float>, frames: Int, channel: Int) {
        guard let cfg = adaptive else { return }
        var lowPower: Float = 0
        var highPower: Float = 0
        subBuffer.withUnsafeMutableBufferPointer { buf in
            for i in 0..<frames { buf[i] = p[i] }
            adaptiveLow[channel].process(buf.baseAddress!, frames: frames, state: &adaptiveLowState[channel])
            for i in 0..<frames { lowPower += buf[i] * buf[i] }
            for i in 0..<frames { buf[i] = p[i] }
            adaptiveHigh[channel].process(buf.baseAddress!, frames: frames, state: &adaptiveHighState[channel])
            for i in 0..<frames { highPower += buf[i] * buf[i] }
        }
        let dt = Float(frames) / Float(sampleRate)
        let a = 1 - expf(-dt / 0.5)     // 0.5 秒滑动窗
        adaptiveLowEnergy += (lowPower / Float(frames) - adaptiveLowEnergy) * a
        adaptiveHighEnergy += (highPower / Float(frames) - adaptiveHighEnergy) * a

        // 每 updateSec 才重算一次系数，别在每块里重建 biquad
        adaptiveAccum += dt
        guard adaptiveAccum >= cfg.updateSec else { return }
        if channel == channels - 1 { adaptiveAccum = 0 }

        let lowDb = 10 * log10f(max(adaptiveLowEnergy, 1e-9))
        let highDb = 10 * log10f(max(adaptiveHighEnergy, 1e-9))
        // 低频比高频高 12dB 认为是"闷"，需要收；低于 3dB 认为是"薄"，需要补
        let excess = (lowDb - highDb) - 7
        let gain = min(max(excess * 0.4, cfg.minDb), cfg.maxDb)
        for ch in 0..<channels {
            adaptiveTilt[ch] = Biquad.lowShelf(freq: 200, gainDB: Double(gain), slope: 1, sampleRate: sampleRate)
        }
        MusicDebug.log("音效[智能]：低频 \(String(format: "%.0f", lowDb))dB / 高频 \(String(format: "%.0f", highDb))dB → 倾斜 \(String(format: "%+.1f", gain))dB")
    }

    /// 中/侧展宽：只放大侧信号，中频（人声、底鼓）不动。
    private func applyWidth(_ l: UnsafeMutablePointer<Float>, _ r: UnsafeMutablePointer<Float>, frames: Int) {
        let w = widthAmount
        for i in 0..<frames {
            let mid = (l[i] + r[i]) * 0.5
            let side = (l[i] - r[i]) * 0.5 * w
            l[i] = mid + side
            r[i] = mid - side
        }
    }

    /// 低频段限幅 → 响度护栏 → 柔性削波。返回这一块的输出能量（供响度估计）。
    private func applyGuards(_ p: UnsafeMutablePointer<Float>, frames: Int, channel: Int) -> Float {
        var peak: Float = 0

        // 分频：低段 = 低通(p)，高段 = p − 低段（两段相加严格等于原信号）
        lowBuffer.withUnsafeMutableBufferPointer { low in
            for i in 0..<frames { low[i] = p[i] }
            splitLP[channel].process(low.baseAddress!, frames: frames, state: &splitLPState[channel])
            for i in 0..<frames { p[i] -= low[i] }

            var lowPeak: Float = 0
            for i in 0..<frames { lowPeak = max(lowPeak, abs(low[i])) }
            let target = lowPeak > Guard.lowBandCeiling ? Guard.lowBandCeiling / lowPeak : 1
            let start = limiterGain[channel]
            // 放：每块最多回升 5%（≈14dB/s）。0.5% 太慢，一被压住就长期压着，人声会被拖下去。
            let g1 = target > start ? min(target, start * 1.05) : target
            let begin = min(start, g1)   // 衰减必须立刻到位：没有前瞻就没有"温柔进入"的余地
            for i in 0..<frames {
                let g = begin + (g1 - begin) * Float(i) / Float(max(frames - 1, 1))
                p[i] += low[i] * g
                peak = max(peak, abs(p[i]))
            }
            limiterGain[channel] = g1
            gainSinceLog = min(gainSinceLog, g1)
        }

        // 响度护栏：只有偏离原曲超过死区才介入，左右各最多 1.5/1 dB。
        // ⚠️ 别做成"强行拉平"：满电平母带上总响度不变和低音变重互斥，拉平等于从人声里扣。
        if inPower > 1e-9, outPower > 1e-9 {
            let deltaDb = 10 * log10f(inPower / outPower)
            var desiredDb: Float = 0
            if deltaDb > Guard.deadZoneDb {
                desiredDb = min(deltaDb - Guard.deadZoneDb, Guard.maxMakeupDB)
            } else if deltaDb < -Guard.deadZoneDb {
                desiredDb = max(deltaDb + Guard.deadZoneDb, Guard.minMakeupDB)
            }
            var desired = powf(10, desiredDb / 20)
            if desired > 1 {
                // 提升方向才受削波余量限制（无条件限制会把"不需要补偿"也压掉几个 dB）
                let headroom = peakEnvelope > 1e-4 ? min(1.0, 0.89 / peakEnvelope) : 1.0
                desired = min(desired, max(headroom, 1.0))
            }
            let aMake = 1 - expf(-Float(frames) / Float(sampleRate) / Guard.makeupSmoothTau)
            makeupGain += (desired - makeupGain) * aMake
            let g = makeupGain
            for i in 0..<frames { p[i] *= g; peak = max(peak, abs(p[i])) }
            makeupDbSinceLog = 20 * log10f(max(makeupGain, 1e-6))
        }

        let aPeak = 1 - expf(-Float(frames) / Float(sampleRate) / 1.0)
        peakEnvelope += (peak - peakEnvelope) * aPeak

        // 末级柔性削波：留一点余量给采样率转换和 int16 量化
        let range = Guard.asymptote - Guard.softKnee
        var finalPeak: Float = 0
        for i in 0..<frames {
            if abs(p[i]) > Guard.softKnee {
                let over = abs(p[i]) - Guard.softKnee
                p[i] = (p[i] < 0 ? -1 : 1) * (Guard.softKnee + range * tanhf(over / range))
            }
            finalPeak = max(finalPeak, abs(p[i]))
        }

        peakSinceLog = max(peakSinceLog, finalPeak)

        var power: Float = 0
        loudBuffer.withUnsafeMutableBufferPointer { buf in
            for i in 0..<frames { buf[i] = p[i] }
            loudOutFilter[channel].process(buf.baseAddress!, frames: frames, state: &loudOutState[channel])
            for i in 0..<frames { power += buf[i] * buf[i] }
        }
        return power / Float(frames)
    }

    static func dbToGain(_ db: Float) -> Float { powf(10, db / 20) }
    static func dbToGain(_ db: Double) -> Float { powf(10, Float(db) / 20) }
}

// MARK: - 延时线

/// 带反馈的整数延时。用于「环境声/现场感」——真正做混响要用卷积 + IR，这一版先用并联梳状延时。
final class DelayLine {
    private let length: Int
    private var buffers: [[Float]]
    private var writeIndex = 0

    init(length: Int, channels: Int) {
        self.length = length
        buffers = (0..<channels).map { _ in [Float](repeating: 0, count: length) }
    }

    func process(_ p: UnsafeMutablePointer<Float>, frames: Int, channel: Int, feedback: Float, wet: Float) {
        guard channel < buffers.count else { return }
        // ⚠️ 闭包外先取出来：在 withUnsafeMutableBufferPointer 里再读 buffers.count
        // 就是对同一个数组的读写重叠访问，真机会以 exclusivity conflict 直接崩。
        let isLastChannel = channel == buffers.count - 1
        var w = writeIndex
        buffers[channel].withUnsafeMutableBufferPointer { buf in
            for i in 0..<frames {
                let delayed = buf[w]
                buf[w] = p[i] + delayed * feedback
                p[i] += delayed * wet
                w += 1
                if w == length { w = 0 }
            }
        }
        if isLastChannel { writeIndex = w }
    }
}

// MARK: - 双二阶滤波器

struct BiquadState {
    var x1: Float = 0, x2: Float = 0, y1: Float = 0, y2: Float = 0
}

struct Biquad {
    var b0: Float, b1: Float, b2: Float, a1: Float, a2: Float
    var isIdentity: Bool { b0 == 1 && b1 == 0 && b2 == 0 && a1 == 0 && a2 == 0 }

    static let identity = Biquad(b0: 1, b1: 0, b2: 0, a1: 0, a2: 0)

    /// RBJ cookbook 的低频搁架。
    static func lowShelf(freq: Double, gainDB: Double, slope: Double, sampleRate: Double) -> Biquad {
        guard freq > 0, gainDB != 0, freq < sampleRate / 2 else { return .identity }
        let A = pow(10, gainDB / 40)
        let w0 = 2 * Double.pi * freq / sampleRate
        let cosw = cos(w0)
        let alpha = sin(w0) / 2 * sqrt((A + 1 / A) * (1 / slope - 1) + 2)
        let sqA = sqrt(A)
        let a0 = (A + 1) + (A - 1) * cosw + 2 * sqA * alpha
        return Biquad(
            b0: Float(A * ((A + 1) - (A - 1) * cosw + 2 * sqA * alpha) / a0),
            b1: Float(2 * A * ((A - 1) - (A + 1) * cosw) / a0),
            b2: Float(A * ((A + 1) - (A - 1) * cosw - 2 * sqA * alpha) / a0),
            a1: Float(-2 * ((A - 1) + (A + 1) * cosw) / a0),
            a2: Float((A + 1) + (A - 1) * cosw - 2 * sqA * alpha) / Float(a0))
    }

    /// RBJ 高频搁架，用来补人声存在感（2-4kHz 一带）。
    static func highShelf(freq: Double, gainDB: Double, slope: Double, sampleRate: Double) -> Biquad {
        guard freq > 0, gainDB != 0, freq < sampleRate / 2 else { return .identity }
        let A = pow(10, gainDB / 40)
        let w0 = 2 * Double.pi * freq / sampleRate
        let cosw = cos(w0)
        let alpha = sin(w0) / 2 * sqrt((A + 1 / A) * (1 / slope - 1) + 2)
        let sqA = sqrt(A)
        let a0 = (A + 1) - (A - 1) * cosw + 2 * sqA * alpha
        return Biquad(
            b0: Float(A * ((A + 1) + (A - 1) * cosw + 2 * sqA * alpha) / a0),
            b1: Float(-2 * A * ((A - 1) + (A + 1) * cosw) / a0),
            b2: Float(A * ((A + 1) + (A - 1) * cosw - 2 * sqA * alpha) / a0),
            a1: Float(2 * ((A - 1) - (A + 1) * cosw) / a0),
            a2: Float((A + 1) - (A - 1) * cosw - 2 * sqA * alpha) / Float(a0))
    }

    /// 参数均衡（peaking）
    static func peaking(freq: Double, gainDB: Double, q: Double, sampleRate: Double) -> Biquad {
        guard freq > 0, gainDB != 0, freq < sampleRate / 2 else { return .identity }
        let A = pow(10, gainDB / 40)
        let w0 = 2 * Double.pi * freq / sampleRate
        let cosw = cos(w0), alpha = sin(w0) / (2 * q)
        let a0 = 1 + alpha / A
        return Biquad(
            b0: Float((1 + alpha * A) / a0),
            b1: Float(-2 * cosw / a0),
            b2: Float((1 - alpha * A) / a0),
            a1: Float(-2 * cosw / a0),
            a2: Float((1 - alpha / A) / a0))
    }

    static func lowPass(freq: Double, q: Double, sampleRate: Double) -> Biquad {
        guard freq > 0, freq < sampleRate / 2 else { return .identity }
        let w0 = 2 * Double.pi * freq / sampleRate
        let cosw = cos(w0), alpha = sin(w0) / (2 * q)
        let a0 = 1 + alpha
        return Biquad(
            b0: Float((1 - cosw) / 2 / a0),
            b1: Float((1 - cosw) / a0),
            b2: Float((1 - cosw) / 2 / a0),
            a1: Float(-2 * cosw / a0),
            a2: Float((1 - alpha) / a0))
    }

    static func highPass(freq: Double, q: Double, sampleRate: Double) -> Biquad {
        guard freq > 0, freq < sampleRate / 2 else { return .identity }
        let w0 = 2 * Double.pi * freq / sampleRate
        let cosw = cos(w0), alpha = sin(w0) / (2 * q)
        let a0 = 1 + alpha
        return Biquad(
            b0: Float((1 + cosw) / 2 / a0),
            b1: Float(-(1 + cosw) / a0),
            b2: Float((1 + cosw) / 2 / a0),
            a1: Float(-2 * cosw / a0),
            a2: Float((1 - alpha) / a0))
    }

    /// Direct Form I。状态按通道/段分开存，切歌时随 processor 一起丢掉。
    func process(_ p: UnsafeMutablePointer<Float>, frames: Int, state: inout BiquadState) {
        var x1 = state.x1, x2 = state.x2, y1 = state.y1, y2 = state.y2
        for i in 0..<frames {
            let x = p[i]
            let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1; x1 = x
            y2 = y1; y1 = y
            p[i] = y
        }
        state = BiquadState(x1: x1, x2: x2, y1: y1, y2: y2)
    }
}

// MARK: - 卷积混响

/// 频域卷积（overlap-add）。IR 只用 170ms 左右 —— 和 QQ音乐 那批 16KB 的 `.dat` 同量级，
/// 短 IR 的"厅堂感"靠早期反射而不是长尾巴，长了反而糊。
///
/// 为什么不用时域 `vDSP_conv`：8192 抽头 × 48kHz × 2 声道 ≈ 8 亿次乘加/秒，
/// 单核要吃掉两位数百分比。频域每 1024 个样本只做一次 FFT，代价低一个数量级。
final class Convolver {
    private let hop = 1024
    private let n: Int                     // FFT 长度（>= taps + hop 的 2 的幂）
    private let log2n: vDSP_Length
    private let fftSetup: FFTSetup
    private let channels: Int

    private var irReal: [[Float]]
    private var irImag: [[Float]]
    private var acc: [[Float]]             // overlap 累加缓冲，长度 n
    private var inAccum: [[Float]]         // 输入攒块，长度 hop
    // ⚠️ 这些状态必须**按通道**分开：左右声道是交替调用的，共用一个下标会把两路搅在一起。
    private var inIndex: [Int]
    private var fifo: [[Float]]            // 已算好的湿声，长度 hop
    private var fifoIndex: [Int]
    private var fifoReady: [Bool]

    // 工作区
    private var timeBuf: [Float]
    private var re: [Float]
    private var im: [Float]
    private var or_: [Float]
    private var oi: [Float]

    init?(irName: String, channels: Int, sampleRate: Double, maxFrames: Int) {
        guard var samples = Convolver.loadIR(named: irName) else {
            MusicDebug.log("音效：⚠️ 找不到 IR 资源 \(irName)，卷积混响跳过")
            return nil
        }
        let irRate = samples.1
        var taps = samples.0[0]
        // 能量归一化：卷积会把能量按 IR 能量放大，不归一的话整体响 6-8dB（实测）。
        // 目标：sum(h²)=1，卷积前后功率基本不变。
        var energy: Float = 0
        for v in taps { energy += v * v }
        if energy > 0 {
            let g = 1 / sqrt(energy)
            taps = taps.map { $0 * g }
            for c in samples.0.indices { samples.0[c] = samples.0[c].map { $0 * g } }
        }
        // 重采样到当前会话采样率（IR 很短，线性插值足够）
        if abs(irRate - sampleRate) > 1 {
            let ratio = sampleRate / irRate
            let outCount = max(1, Int(Double(taps.count) * ratio))
            var out = [Float](repeating: 0, count: outCount)
            for i in 0..<outCount {
                let src = Double(i) / ratio
                let i0 = min(taps.count - 1, Int(src))
                let i1 = min(taps.count - 1, i0 + 1)
                let frac = Float(src - Double(i0))
                out[i] = taps[i0] * (1 - frac) + taps[i1] * frac
            }
            taps = out
        }

        let hopSamples = hop          // 局部量：闭包里用 self.hop 会报"捕获未初始化的 self"
        var size = 1
        while size < taps.count + hopSamples { size <<= 1 }
        self.n = size
        self.log2n = vDSP_Length(log2(Double(size)))
        self.channels = channels
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return nil }
        self.fftSetup = setup

        // IR 频谱（每个通道一份：立体声 IR 的左右尾巴本来就不同）
        irReal = []; irImag = []
        acc = (0..<channels).map { _ in [Float](repeating: 0, count: size) }
        inAccum = (0..<channels).map { _ in [Float](repeating: 0, count: hopSamples) }
        fifo = (0..<channels).map { _ in [Float](repeating: 0, count: hopSamples) }
        inIndex = [Int](repeating: 0, count: channels)
        fifoIndex = [Int](repeating: 0, count: channels)
        fifoReady = [Bool](repeating: false, count: channels)
        timeBuf = [Float](repeating: 0, count: size)
        re = [Float](repeating: 0, count: size / 2)
        im = [Float](repeating: 0, count: size / 2)
        or_ = [Float](repeating: 0, count: size / 2)
        oi = [Float](repeating: 0, count: size / 2)

        for ch in 0..<channels {
            let src = samples.0[min(ch, samples.0.count - 1)]
            var padded = [Float](repeating: 0, count: size)
            for k in 0..<min(src.count, size) { padded[k] = src[k] }
            let (r, i) = forwardFFT(padded)
            irReal.append(r)
            irImag.append(i)
        }
        MusicDebug.log("音效：卷积混响就绪，IR \(taps.count) 抽头 @\(Int(sampleRate))Hz，FFT \(size)")
    }

    deinit { vDSP_destroy_fftsetup(fftSetup) }

    /// 实数 FFT（手工打包）。返回 (realp, imagp)，长度 n/2。
    /// ⚠️ 故意不写成 inout + 指针混用：那版实测数据会对不上（无羁的别名/临时拷贝很难查）。
    private func forwardFFT(_ input: [Float]) -> ([Float], [Float]) {
        var r = [Float](repeating: 0, count: n / 2)
        var i = [Float](repeating: 0, count: n / 2)
        for k in 0..<(n / 2) { r[k] = input[2 * k]; i[k] = input[2 * k + 1] }
        r.withUnsafeMutableBufferPointer { rp in
            i.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
            }
        }
        return (r, i)
    }

    private func inverseFFT(_ pr: [Float], _ pi: [Float]) -> [Float] {
        var r = pr, i = pi
        var out = [Float](repeating: 0, count: n)
        r.withUnsafeMutableBufferPointer { rp in
            i.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_INVERSE))
                for k in 0..<(n / 2) {
                    out[2 * k] = rp[k]
                    out[2 * k + 1] = ip[k]
                }
            }
        }
        return out
    }

    func process(_ p: UnsafeMutablePointer<Float>, frames: Int, channel: Int, mix: Float) {
        guard channel < acc.count else { return }
        for i in 0..<frames {
            // ⚠️ 先存干声再叠加湿声：如果先 `p[i] += wet` 再把它塞进输入缓冲，
            // 湿声会被再次卷积、形成正反馈（实测输出能量会涨到原来的 8000 倍）。
            let dry = p[i]
            // 吐湿声（比输入晚一个 hop）
            if fifoReady[channel] {
                p[i] = dry + fifo[channel][fifoIndex[channel]] * mix
                fifoIndex[channel] += 1
                if fifoIndex[channel] == hop { fifoIndex[channel] = 0; fifoReady[channel] = false }
            }
            inAccum[channel][inIndex[channel]] = dry
            inIndex[channel] += 1
            if inIndex[channel] == hop {
                inIndex[channel] = 0
                computeBlock(channel: channel)
                fifoIndex[channel] = 0
                fifoReady[channel] = true
            }
        }
    }

    private func computeBlock(channel: Int) {
        var block = [Float](repeating: 0, count: n)
        for k in 0..<hop { block[k] = inAccum[channel][k] }
        let (xr, xi) = forwardFFT(block)

        // 复数相乘。bin0 单独处理：vDSP 实数 FFT 把 DC 放在 realp[0]、Nyquist 放在 imagp[0]，
        // 当普通复数相乘会把这两个不相干的分量混在一起（实测冲激响应会偏上千倍）。
        var pr = [Float](repeating: 0, count: n / 2)
        var pi = [Float](repeating: 0, count: n / 2)
        pr[0] = xr[0] * irReal[channel][0]
        pi[0] = xi[0] * irImag[channel][0]
        for k in 1..<(n / 2) {
            let ar = xr[k], ai = xi[k], br = irReal[channel][k], bi = irImag[channel][k]
            pr[k] = ar * br - ai * bi
            pi[k] = ar * bi + ai * br
        }

        // ⚠️ 归一化是 1/(4n)：正变换 2×，两个频谱相乘 4×，逆变换再 2n 倍。
        let scale = 1 / Float(4 * n)
        let out = inverseFFT(pr, pi)

        for k in 0..<n { acc[channel][k] += out[k] * scale }
        for k in 0..<hop { fifo[channel][k] = acc[channel][k] }
        for k in 0..<(n - hop) { acc[channel][k] = acc[channel][k + hop] }
        for k in (n - hop)..<n { acc[channel][k] = 0 }
    }

    /// 读 IR：先找 bundle（App），再找仓库 Resources（离线校验台用）。
    /// 返回**每条通道各一份**：立体声 IR 的左右尾巴是去相关的，两声道共用同一份
    /// 会让湿声完全相关、声场反而变窄（实测 LR 相关度 0.68→0.73）。
    static func loadIR(named name: String) -> (samples: [[Float]], sampleRate: Double)? {
        var url = Bundle.main.url(forResource: name, withExtension: nil)
        if url == nil {
            let repo = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("../../ios/Music/Music/Resources/\(name)")
            if FileManager.default.fileExists(atPath: repo.path) { url = repo }
        }
        guard let url, let file = try? AVAudioFile(forReading: url) else { return nil }
        let frames = AVAudioFrameCount(file.length)
        guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames),
              (try? file.read(into: buf)) != nil,
              let data = buf.floatChannelData else { return nil }
        let count = Int(buf.frameLength)
        let chans = Int(buf.format.channelCount)
        var perChannel: [[Float]] = []
        for c in 0..<chans {
            var samples = [Float](repeating: 0, count: count)
            for i in 0..<count { samples[i] = data[min(c, chans - 1)][i] }
            perChannel.append(samples)
        }
        return (perChannel, file.processingFormat.sampleRate)
    }
}
