import CoreAudio
import Foundation
import SimpleEqualizerAudio
import SimpleEqualizerCore
import SimpleEqualizerEngine
import Testing

/// 本物のエンジンを、C のコールバックにつないだもの。装置には触らないので、音は出ない。
private final class Rig {
    static let blockFrames = 512
    let state = seq_render_state_create()
    let engine: EqualizerEngine
    let sampleRate: Double

    init(sampleRate: Double = 48000) throws {
        self.sampleRate = sampleRate
        seq_render_state_set_sample_rate(state, sampleRate)
        seq_render_state_set_target_gain(state, 1)
        engine = try EqualizerEngine(sampleRate: sampleRate, channels: 2, renderState: state)
    }

    deinit {
        engine.shutdown()
        seq_render_state_destroy(state)
    }

    /// 左右交互の音を、512 フレームずつコールバックに通す。
    func render(_ samples: [Float]) -> [Float] {
        var result: [Float] = []
        result.reserveCapacity(samples.count)
        let blockSamples = Self.blockFrames * 2
        var offset = 0
        while offset < samples.count {
            let count = min(blockSamples, samples.count - offset)
            var input = Array(samples[offset..<offset + count])
            var output = [Float](repeating: 0.77, count: count)
            input.withUnsafeMutableBytes { inputBytes in
                output.withUnsafeMutableBytes { outputBytes in
                    var inputList = AudioBufferList(
                        mNumberBuffers: 1,
                        mBuffers: AudioBuffer(
                            mNumberChannels: 2, mDataByteSize: UInt32(inputBytes.count), mData: inputBytes.baseAddress))
                    var outputList = AudioBufferList(
                        mNumberBuffers: 1,
                        mBuffers: AudioBuffer(
                            mNumberChannels: 2, mDataByteSize: UInt32(outputBytes.count), mData: outputBytes.baseAddress))
                    seq_render(state, &inputList, &outputList)
                }
            }
            result.append(contentsOf: output)
            offset += count
        }
        return result
    }

    /// その周波数の正弦波を1秒ぶん通し、後ろ半分で、入力に対する出力の大きさ(dB)を測る。
    func response(at frequency: Double, amplitude: Float = 0.1) -> Double {
        let frames = Int(sampleRate)
        let input = sine(frequency: frequency, amplitude: amplitude, frames: frames)
        let output = render(input)
        let half = frames  // 左右交互なので、サンプル数の半分はフレーム数と同じ。
        return 20 * log10(rms(output[half...]) / rms(input[half...]))
    }

    func sine(frequency: Double, amplitude: Float, frames: Int) -> [Float] {
        var samples = [Float](repeating: 0, count: frames * 2)
        for frame in 0..<frames {
            let value = amplitude * Float(sin(2 * Double.pi * frequency * Double(frame) / sampleRate))
            samples[frame * 2] = value
            samples[frame * 2 + 1] = value
        }
        return samples
    }

    var fallbackCount: UInt64 { seq_render_state_engine_fallback_count(state) }
    var limitCount: UInt64 { seq_render_state_limit_count(state) }
}

/// スレッドの間で受け渡す、止める合図。
private final class StopFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}

private func rms(_ samples: ArraySlice<Float>) -> Double {
    var sum = 0.0
    for sample in samples { sum += Double(sample) * Double(sample) }
    return (sum / Double(max(samples.count, 1))).squareRoot()
}

@Suite("エンジン(イコライザーとラウドネス)", .serialized)
struct EqualizerEngineTests {
    @Test("つなぐと、コールバックがエンジンを使う。止めると、外れる")
    func attachesAndDetaches() throws {
        let rig = try Rig()
        #expect(seq_render_state_has_engine(rig.state))
        rig.engine.shutdown()
        #expect(!seq_render_state_has_engine(rig.state))
        // 止めたあとも、音は取り出したまま出る。
        #expect(abs(rig.response(at: 1000)) < 0.01)
        #expect(rig.fallbackCount == 0)
    }

    @Test("すべて 0 dB のときは、どの高さの音も大きさが変わらない", arguments: [40.0, 100, 1000, 5000, 15000])
    func flatIsTransparent(frequency: Double) throws {
        let rig = try Rig()
        #expect(abs(rig.response(at: frequency)) < 0.1)
        #expect(rig.fallbackCount == 0)
        #expect(rig.limitCount == 0)
    }

    @Test("すべて 0 dB のときは、左右が入れ替わったり混ざったりしない")
    func keepsChannelsSeparate() throws {
        let rig = try Rig()
        var input = rig.sine(frequency: 1000, amplitude: 0.2, frames: 4800)
        for frame in 0..<4800 { input[frame * 2 + 1] = 0 }
        let output = rig.render(input)
        var rightPeak: Float = 0
        var leftPeak: Float = 0
        for frame in 2400..<4800 {
            leftPeak = max(leftPeak, abs(output[frame * 2]))
            rightPeak = max(rightPeak, abs(output[frame * 2 + 1]))
        }
        #expect(leftPeak > 0.19)
        #expect(rightPeak < 0.001)
    }

    @Test("1 kHz を 10 dB 下げると、1 kHz の音が約 10 dB 小さくなり、離れた高さの音は変わらない")
    func cutsBand() throws {
        let rig = try Rig()
        var settings = EqualizerSettings()
        settings.setGain(-10, at: 5)
        rig.engine.setEqualizer(settings, enabled: true)
        #expect(abs(rig.response(at: 1000) + 10) < 1)
        #expect(abs(rig.response(at: 62)) < 1)
        #expect(abs(rig.response(at: 12000)) < 1)
    }

    @Test("1 kHz を 10 dB 上げると、小さい音は約 10 dB 大きくなる")
    func boostsBand() throws {
        let rig = try Rig()
        var settings = EqualizerSettings()
        settings.setGain(10, at: 5)
        rig.engine.setEqualizer(settings, enabled: true)
        #expect(abs(rig.response(at: 1000, amplitude: 0.05) - 10) < 1)
        #expect(rig.limitCount == 0)
    }

    @Test("上げた結果がフルスケールを超えるときは、リミッターが抑える")
    func limiterCatchesBoost() throws {
        let rig = try Rig()
        var settings = EqualizerSettings()
        settings.setGain(10, at: 5)
        rig.engine.setEqualizer(settings, enabled: true)
        let output = rig.render(rig.sine(frequency: 1000, amplitude: 0.9, frames: 24000))
        for value in output {
            #expect(abs(value) <= 1)
        }
        #expect(rig.limitCount > 0)
    }

    @Test("イコライザーを切にすると、値が入っていても音は変わらない")
    func disabledIsTransparent() throws {
        let rig = try Rig()
        var settings = EqualizerSettings()
        settings.setGain(-10, at: 5)
        rig.engine.setEqualizer(settings, enabled: false)
        #expect(abs(rig.response(at: 1000)) < 0.1)
    }

    @Test("ラウドネスの補正は、低音と高音だけを持ち上げる")
    func loudnessBoostsEnds() throws {
        let rig = try Rig()
        rig.engine.setLoudness(LoudnessCurve.Correction(bassDb: 8, trebleDb: 3))
        #expect(abs(rig.response(at: 30, amplitude: 0.05) - 8) < 1.5)
        #expect(abs(rig.response(at: 1000, amplitude: 0.05)) < 1)
        #expect(abs(rig.response(at: 16000, amplitude: 0.05) - 3) < 1)
        rig.engine.setLoudness(.none)
        #expect(abs(rig.response(at: 30, amplitude: 0.05)) < 0.1)
    }

    @Test("イコライザーを切にしても、ラウドネスは効いたまま")
    func loudnessIndependentOfEqualizer() throws {
        let rig = try Rig()
        rig.engine.setLoudness(LoudnessCurve.Correction(bassDb: 8, trebleDb: 0))
        rig.engine.setEqualizer(EqualizerSettings(), enabled: false)
        #expect(rig.response(at: 30, amplitude: 0.05) > 6)
    }

    @Test("サンプリング周波数が低く、扱えない高さのバンドは、値を入れても効かない(ほかのバンドに重ならない)")
    func bandsAboveLimitAreIgnored() throws {
        // 16 kHz では、扱える上限は 7.2 kHz。8 kHz と 16 kHz のバンドは使わない。
        let rig = try Rig(sampleRate: 16000)
        var settings = EqualizerSettings()
        settings.setGain(10, at: 8)
        settings.setGain(10, at: 9)
        rig.engine.setEqualizer(settings, enabled: true)
        #expect(abs(rig.response(at: 7000, amplitude: 0.05)) < 0.5)
        #expect(abs(rig.response(at: 1000, amplitude: 0.05)) < 0.5)
    }

    @Test("バンドを重ねて上げたときの、合わせた増幅の見積もりは、本物のエンジンで測った値と合う(小さく見積もらない)", arguments: [
        [Double](repeating: 10, count: 10),
        [Double](repeating: 5, count: 10),
        [0, 0, 0, 0, 0, 10, 10, 10, 0, 0],
        [0, 0, 0, 0, 0, 10, 10, 0, 0, 0],
        [0, 0, 0, 0, 0, 10, 0, 0, 0, 0],
        [0, 0, 0, 0, 0, 10, 5, 0, 0, 0],
        [0, 0, 0, 0, 0, 10, -10, 0, 0, 0],
        [10, 10, 10, 0, 0, 0, 0, 0, 0, 0],
        [0, 0, 0, 0, 0, 0, 0, 10, 10, 10],
        [-10, -10, 3, 0, 0, 0, 0, 0, 0, 0],
        [-10, 10, -10, 0, 0, 0, 0, 0, 0, 0],
        [0, 0, 0, 0, 0, 0, 0, 0, 10, 10],
        [0, 0, 0, 0, 0, 0, 0, 0, 0, 10],
        [0, 0, 0, 0, 0, 0, 0, 0, 10, 0],
        [10, 0, 0, 0, 0, 0, 0, 0, 0, 0],
        [10, 0, 10, 0, 10, 0, 10, 0, 10, 0],
        [3, 6, 4, 0, -2, 0, 2, 5, 6, 4],
    ])
    func estimatedPeakMatchesEngine(gains: [Double]) throws {
        let settings = try #require(EqualizerSettings(storedGains: gains))
        let rig = try Rig()
        rig.engine.setEqualizer(settings, enabled: true)
        // 4 分の 1 オクターブおきに測り、いちばん大きい増幅を探す。
        var measured = 0.0
        var frequency = 25.0
        while frequency < 20000 {
            measured = max(measured, rig.response(at: frequency, amplitude: 0.01))
            frequency *= pow(2, 0.25)
        }
        let estimated = settings.estimatedPeakGainDb
        // 見積もりが小さすぎると、自動で下げても上限を超える。大きすぎると、必要以上に音を小さくする。
        #expect(measured <= estimated + 0.7, "測った値 \(measured) dB、見積もり \(estimated) dB")
        #expect(measured >= estimated - 1.5, "測った値 \(measured) dB、見積もり \(estimated) dB")
    }

    @Test("44.1 kHz でも動く")
    func worksAt441() throws {
        let rig = try Rig(sampleRate: 44100)
        var settings = EqualizerSettings()
        settings.setGain(-10, at: 5)
        rig.engine.setEqualizer(settings, enabled: true)
        #expect(abs(rig.response(at: 1000) + 10) < 1)
        #expect(rig.fallbackCount == 0)
    }

    @Test("設定を変えながら音を通しても、エンジンを通せなかった回はない")
    func survivesParameterChanges() throws {
        let rig = try Rig()
        var settings = EqualizerSettings()
        let block = rig.sine(frequency: 1000, amplitude: 0.1, frames: Rig.blockFrames)
        for step in 0..<200 {
            settings.setGain(Double(step % 41) * 0.5 - 10, at: step % 10)
            rig.engine.setEqualizer(settings, enabled: true)
            for value in rig.render(block) {
                #expect(value.isFinite)
            }
        }
        #expect(rig.fallbackCount == 0)
    }

    @Test("別のスレッドから設定を変え続けても、出力は数のままで、音がとぎれない")
    func survivesChangesFromAnotherThread() throws {
        let rig = try Rig()
        // エンジンの設定は、どのスレッドから変えてもよい(Apple の部品の決まり)。
        nonisolated(unsafe) let engine = rig.engine
        let done = DispatchSemaphore(value: 0)
        let stop = StopFlag()
        // 画面の役。イコライザーとラウドネスの値を、休みなく書き換える。
        let changer = Thread {
            var settings = EqualizerSettings()
            var step = 0
            while !stop.isSet {
                settings.setGain(Double(step % 41) * 0.5 - 10, at: step % 10)
                engine.setEqualizer(settings, enabled: step % 7 != 0)
                engine.setLoudness(LoudnessCurve.correction(forVolume: Double(step % 101), amount: 100))
                step += 1
            }
            done.signal()
        }
        changer.start()
        let block = rig.sine(frequency: 1000, amplitude: 0.05, frames: Rig.blockFrames)
        var silentBlocks = 0
        for _ in 0..<2000 {
            let output = rig.render(block)
            var peak: Float = 0
            for value in output {
                #expect(value.isFinite)
                #expect(abs(value) <= 1)
                peak = max(peak, abs(value))
            }
            if peak == 0 { silentBlocks += 1 }
        }
        stop.set()
        done.wait()
        // エンジンが断った回は、取り出した音をそのまま使うので、無音の回はない。
        #expect(silentBlocks == 0)
        // 断られた回の数は、記録として残す(多いようなら、扱いを考える)。
        print("別のスレッドから設定を変え続けたとき、エンジンを通せなかった回: \(rig.fallbackCount) / 2000")
    }

    @Test("使えない形(チャンネル数が 0 や多すぎる、周波数が 0)では、作らない", arguments: [(0, 48000.0), (9, 48000.0), (2, 0.0)])
    func rejectsInvalidFormat(channels: Int, sampleRate: Double) {
        let state = seq_render_state_create()
        defer { seq_render_state_destroy(state) }
        #expect(throws: EqualizerEngineError.self) {
            _ = try EqualizerEngine(sampleRate: sampleRate, channels: channels, renderState: state)
        }
        #expect(!seq_render_state_has_engine(state))
    }
}
