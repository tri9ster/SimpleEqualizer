import Foundation

/// 出力先(音を出す装置)の情報と、そこから決まる、アプリの動きの判断。
///
/// 情報は、Core Audio から読んだものを、アプリの側が入れる。判断は、音を出さずに確かめられるよう、ここに置く。
public struct OutputDevice: Equatable, Sendable {
    /// macOS が装置につける識別子。音量と消音は、これごとに覚える。
    public var uid: String
    public var name: String
    /// 装置が、自分で音量を変えられるか(macOS の音量調整が効くか)。見分けられなかったときは nil。
    public var canSetVolume: Bool?
    /// 出力のストリームの本数。
    public var outputStreamCount: Int
    public var channelCount: Int
    public var sampleRate: Double

    public init(
        uid: String, name: String, canSetVolume: Bool?, outputStreamCount: Int, channelCount: Int, sampleRate: Double
    ) {
        self.uid = uid
        self.name = name
        self.canSetVolume = canSetVolume
        self.outputStreamCount = outputStreamCount
        self.channelCount = channelCount
        self.sampleRate = sampleRate
    }

    /// 動くことを確かめてあるチャンネル数。
    public static let supportedChannelCount = 2

    // MARK: - 音量調整

    /// アプリの音量調整が有効か。装置が自分で音量を変えられないとき、有効。
    /// 見分けられないときも、有効として扱う。無効とまちがえると、音量を変えられない装置から、最大音量が出るため
    /// (有効とまちがえた場合は、音量が二重に掛かるだけで、危なくない)。
    public var isVolumeControlEnabled: Bool {
        canSetVolume != true
    }

    /// 出力先でないあいだも、この装置の経路を持ったままにするか。音量調整が有効な装置では、持ったままにする。
    /// 出力先に戻った瞬間に、加工なしの最大音量が出るのを防ぐため(経路を作り直すと、0.15 秒ほどかかる)。
    public var keepsPathWhileNotDefault: Bool {
        isVolumeControlEnabled
    }

    /// ラウドネスを使えるか。補正量を決める音量値があるとき(音量調整が有効なとき)だけ。
    public var isLoudnessAvailable: Bool {
        isVolumeControlEnabled
    }

    // MARK: - 扱える出力先か

    /// 出力先を扱えない理由。
    public enum UnsupportedReason: Equatable, Sendable, CustomStringConvertible {
        case streamCount(Int)
        case channelCount(Int)
        case unknownSampleRate

        /// 画面に出す文。
        public var description: String { String(localized: message) }

        public var message: LocalizedStringResource {
            switch self {
            case .streamCount(let count):
                return LocalizedStringResource("出力が \(count) 本ある装置には、対応していません。", bundle: .core)
            case .channelCount(let count):
                return LocalizedStringResource("\(count) チャンネルの装置には、対応していません。", bundle: .core)
            case .unknownSampleRate:
                return LocalizedStringResource("装置のサンプリング周波数を読めませんでした。", bundle: .core)
            }
        }
    }

    /// この出力先を扱えない理由。扱えるときは nil。
    /// 動くことを確かめてある形(出力 1 本、2 チャンネル)だけを扱う。
    /// アプリが自分で作った集約装置は、ここへ来る前に、一覧から外してある(アプリの側の `OutputDevices`)。
    public var unsupportedReason: UnsupportedReason? {
        if outputStreamCount != 1 {
            return .streamCount(outputStreamCount)
        }
        if channelCount != Self.supportedChannelCount {
            return .channelCount(channelCount)
        }
        if !sampleRate.isFinite || sampleRate <= 0 {
            return .unknownSampleRate
        }
        return nil
    }

    // MARK: - 出力先の一覧(ポップアップのプルダウン)

    /// 一覧の並べ方。名前の順。同じ名前は UID の順にして、装置の番号が変わっても、並びが毎回同じになるようにする。
    public static func menuOrder(_ devices: [OutputDevice]) -> [OutputDevice] {
        devices.sorted { first, second in
            let order = first.name.localizedStandardCompare(second.name)
            return order == .orderedSame ? first.uid < second.uid : order == .orderedAscending
        }
    }

    // MARK: - 音に掛けるもの

    /// 増幅した分を、自動で下げる量(dB。0 以上)。
    /// 音量調整が無効の装置では、アプリの中を通る音が、いつも元の大きさなので、少しでも増幅すると上限を超える。
    /// そこで、イコライザーがいちばん大きく増幅する量(バンドの山の重なりを含めた見積もり)だけ、全体を下げる。
    /// ラウドネスの分は、含めない(音量調整が無効の装置では、ラウドネスを使えないため)。
    public func autoAttenuationDb(equalizer: EqualizerSettings, equalizerEnabled: Bool, autoLowerEnabled: Bool) -> Double {
        guard !isVolumeControlEnabled, equalizerEnabled, autoLowerEnabled else { return 0 }
        return equalizer.estimatedPeakGainDb
    }

    /// 音に掛ける倍率(0 以上 1 以下)。
    /// - 音量調整が有効の装置: 覚えている音量と消音から決める。
    /// - 音量調整が無効の装置: 覚えている音量は使わない。自動で下げる量の分だけ、下げる。
    public func gain(settings: OutputSettings, attenuationDb: Double) -> Float {
        guard !isVolumeControlEnabled else { return settings.gain }
        // 壊れた値(数でない値、無限大)は、音を出さない側に倒す。負の値は、下げないものとして扱う(上げる側には、しない)。
        guard attenuationDb.isFinite else { return 0 }
        return min(max(VolumeCurve.gain(fromDecibels: -max(attenuationDb, 0)), 0), 1)
    }

    /// ラウドネスの補正量。音量調整が無効の装置では、補正しない。
    public func loudness(settings: OutputSettings, amount: Double) -> LoudnessCurve.Correction {
        isLoudnessAvailable ? settings.loudness(amount: amount) : .none
    }

    /// キーボードの音量キーを、アプリが受け取るか。加工していて、止まっておらず、音量調整が有効なときだけ。
    /// それ以外は、キーに触らず、macOS に任せる。
    public func interceptsVolumeKeys(isRunning: Bool, isStalled: Bool) -> Bool {
        isRunning && !isStalled && isVolumeControlEnabled
    }
}
