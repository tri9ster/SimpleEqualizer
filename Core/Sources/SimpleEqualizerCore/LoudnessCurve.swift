import Foundation

/// ラウドネスの補正量。小さい音量で聞こえにくくなる低音と高音を、音量に応じて持ち上げる量を決める。
///
/// 音量を下げた量(dB)に比例して補正を増やし、`fullAttenuationDb` だけ下げたところで上限に達する。
/// 全体の効き具合は、利用者が「強さ」(0〜100)で決める。補正量は、強さに比例する。強さ 0 は、補正なし(入・切のスイッチは、`AppState.loudnessEnabled`)。
public enum LoudnessCurve {
    /// 強さの範囲。0 で補正なし、100 でいちばん強い。
    public static let amountRange: ClosedRange<Double> = 0...100
    /// 強さ 100 での、低音の補正の上限(dB)。
    public static let maxBassDb: Double = 15
    /// 強さ 100 での、高音の補正の上限(dB)。
    public static let maxTrebleDb: Double = 6
    /// 補正が上限に達する、音量による減衰の量(dB)。音量 50 あたり。これより音量を下げても、補正は増えない。
    /// 上限より大きくしておく(補正が、いつも音量による減衰より小さくなる。ラウドネスだけで元の音量を超えない)。
    public static let fullAttenuationDb: Double = 18
    /// 低音は、この周波数(Hz)より下を持ち上げる。
    public static let bassFrequency: Double = 100
    /// 高音は、この周波数(Hz)より上を持ち上げる。
    public static let trebleFrequency: Double = 8000

    public struct Correction: Equatable, Sendable {
        public var bassDb: Double
        public var trebleDb: Double

        public init(bassDb: Double, trebleDb: Double) {
            self.bassDb = bassDb
            self.trebleDb = trebleDb
        }

        /// 補正なし。
        public static let none = Correction(bassDb: 0, trebleDb: 0)
    }

    /// その音量と強さでの補正量。音量 100 か、強さ 0 で補正なし。
    /// 範囲の外の音量や強さは近い端として扱い、数でない値や無限大では補正しない。
    /// 渡す音量は、実際に音に掛けている音量にする(`OutputSettings.loudness(amount:)` を使う)。
    public static func correction(forVolume volume: Double, amount: Double) -> Correction {
        guard volume.isFinite, amount.isFinite else { return .none }
        let strength = min(max(amount, amountRange.lowerBound), amountRange.upperBound) / amountRange.upperBound
        let gain = VolumeCurve.gain(forVolume: volume)
        // 倍率 0(音量 0)では、減衰は限りなく大きい。上限の補正にする。
        let attenuation = gain > 0 ? -VolumeCurve.decibels(fromGain: gain) : fullAttenuationDb
        let ratio = min(max(attenuation / fullAttenuationDb, 0), 1) * strength
        return Correction(bassDb: maxBassDb * ratio, trebleDb: maxTrebleDb * ratio)
    }

    /// 保存してあった強さを、使える値にする。範囲の外、数でない値は 0(補正なし)にする(近い端の 100 に丸めない)。
    public static func storedAmount(_ amount: Double) -> Double {
        amount.isFinite && amountRange.contains(amount) ? amount : 0
    }

    /// 強さではなく入・切で保存していたころのファイルで、入だったときに使う強さ。
    public static let legacyEnabledAmount: Double = 50
}
