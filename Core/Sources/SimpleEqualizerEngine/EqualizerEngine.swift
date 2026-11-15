import AVFAudio
import SimpleEqualizerAudio
import SimpleEqualizerCore

public enum EqualizerEngineError: Error, CustomStringConvertible {
    case unsupportedFormat(String)
    case setupFailed(String)

    public var description: String {
        switch self {
        case .unsupportedFormat(let format):
            return String(localized: "音を加工する部品が、この形式(\(format))に対応していません。", bundle: .module)
        case .setupFailed(let step):
            return String(localized: "音を加工する部品の準備(\(step))に失敗しました。", bundle: .module)
        }
    }
}

/// 音を加工するエンジン。イコライザー(10 バンド)と、ラウドネス用のフィルター(低音、高音)を持つ。
///
/// エンジンは「手動レンダリング(リアルタイム)」で動かす。装置は持たず、C のコールバック(`seq_render`)が、
/// 音声のスレッドから呼ぶ。経路: 取り出した音 → イコライザー → ラウドネス →(C の側で)音量 → リミッター。
///
/// ここのコードは、音声のスレッドでは動かない。エンジンと C のコールバックをつなぐところは、
/// `SimpleEqualizerAudio` の `seq_engine.m` にある。
public final class EqualizerEngine {
    /// 1回に扱えるフレーム数の上限。これより多い回は、コールバックがエンジンを通さない。
    public static let maximumFrames: UInt32 = 4096
    /// イコライザーの1バンドの幅(オクターブ)。バンドの間隔と同じにしてある。
    static let bandwidthOctaves: Float = 1

    private let engine = AVAudioEngine()
    private let equalizer = AVAudioUnitEQ(numberOfBands: EqualizerSettings.bandCount)
    private let loudness = AVAudioUnitEQ(numberOfBands: 2)
    private let renderState: OpaquePointer
    private var isAttached = false

    /// エンジンを組み立てて始め、`renderState` のコールバックにつなぐ。コールバックが止まっている間に呼ぶ。
    /// `renderState` は、このエンジンを止める(`shutdown`)まで捨てない。
    public init(sampleRate: Double, channels: Int, renderState: OpaquePointer) throws {
        self.renderState = renderState
        guard channels > 0, channels <= Int(SEQ_ENGINE_MAX_CHANNELS), sampleRate.isFinite, sampleRate > 0,
              let format = AVAudioFormat(
                standardFormatWithSampleRate: sampleRate, channels: AVAudioChannelCount(channels))
        else {
            throw EqualizerEngineError.unsupportedFormat("\(Int(sampleRate.isFinite ? sampleRate : 0)) Hz / \(channels)ch")
        }

        do {
            // エンジンのほかの部品に触る前に、手動レンダリングに切り替える。
            try engine.enableManualRenderingMode(.realtime, format: format, maximumFrameCount: Self.maximumFrames)
        } catch {
            throw EqualizerEngineError.setupFailed(String(localized: "手動レンダリングへの切り替え", bundle: .module))
        }

        // 扱える上限(サンプリング周波数の半分の少し下)より高いバンドは、使わない(素通しにする)。
        // 上限に寄せると、サンプリング周波数が低い装置で、複数のバンドが同じ場所に重なって、増幅が足し合わされる。
        let highest = sampleRate * 0.45
        for (index, band) in equalizer.bands.enumerated() {
            let frequency = EqualizerSettings.frequencies[index]
            band.filterType = .parametric
            band.frequency = Float(min(frequency, highest))
            band.bandwidth = Self.bandwidthOctaves
            band.gain = 0
            band.bypass = frequency > highest
        }
        let bass = loudness.bands[0]
        bass.filterType = .lowShelf
        bass.frequency = Float(LoudnessCurve.bassFrequency)
        bass.gain = 0
        bass.bypass = false
        let treble = loudness.bands[1]
        treble.filterType = .highShelf
        treble.frequency = Float(min(LoudnessCurve.trebleFrequency, highest))
        treble.gain = 0
        treble.bypass = LoudnessCurve.trebleFrequency > highest

        engine.attach(equalizer)
        engine.attach(loudness)
        guard seq_engine_connect_input(renderState, engine, format) else {
            throw EqualizerEngineError.setupFailed(String(localized: "入力の設定", bundle: .module))
        }
        do {
            // つなげないときにエラーを返す、新しい関数を使う(古い関数は、アプリを落とす)。
            try engine.connectNode(engine.inputNode, to: equalizer, format: format)
            try engine.connectNode(equalizer, to: loudness, format: format)
            try engine.connectNode(loudness, to: engine.outputNode, format: format)
            engine.prepare()
            try engine.start()
        } catch {
            engine.stop()
            throw EqualizerEngineError.setupFailed(String(localized: "部品の接続と開始", bundle: .module))
        }
        guard seq_engine_attach(renderState, engine, UInt32(channels), Self.maximumFrames) else {
            engine.stop()
            throw EqualizerEngineError.setupFailed(String(localized: "コールバックとの接続", bundle: .module))
        }
        isAttached = true
    }

    deinit {
        shutdown()
    }

    /// イコライザーの値を設定する。切のときは、すべて 0 dB として設定する(値は呼び出し側が持ち続ける)。
    public func setEqualizer(_ settings: EqualizerSettings, enabled: Bool) {
        for (index, band) in equalizer.bands.enumerated() {
            band.gain = enabled ? Float(settings.gain(at: index)) : 0
        }
    }

    /// ラウドネスの補正量を設定する。切のときは、補正なし(`.none`)を渡す。
    public func setLoudness(_ correction: LoudnessCurve.Correction) {
        loudness.bands[0].gain = Float(correction.bassDb)
        loudness.bands[1].gain = Float(correction.trebleDb)
    }

    /// コールバックから外し、エンジンを止める。コールバックが止まっている間に呼ぶ。何度呼んでもよい。
    public func shutdown() {
        guard isAttached else { return }
        isAttached = false
        seq_render_state_detach_engine(renderState)
        engine.stop()
    }
}
