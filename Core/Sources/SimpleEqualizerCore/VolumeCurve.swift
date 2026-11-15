import Foundation

/// 音量の数値(0〜100)と、音に掛ける倍率の対応。
///
/// 音量を 0〜1 に直した値の3乗を倍率にする。100 で元の音量、0 で無音。
/// 直線的なデシベルの対応に比べ、小さい側が早く無音に近づき、ふだん使う大きさにスライダーの幅を多く割ける。
public enum VolumeCurve {
    public static let range: ClosedRange<Double> = 0...100
    /// 初めて使う出力先の音量。元の音量のまま(アプリを使う前より大きくならない)。
    public static let defaultVolume: Double = 100
    /// 保存してあった値が読めない、足りない、範囲の外のときに、かわりに使う音量。
    /// 壊れた値で大きな音を出さないよう、小さい側にしてある。
    public static let fallbackVolume: Double = 30

    /// 倍率は 0 以上 1 以下。範囲の外の音量は近い端に丸め、数でない値は無音にする。
    public static func gain(forVolume volume: Double) -> Float {
        guard !volume.isNaN else { return 0 }
        let normalized = min(max(volume, range.lowerBound), range.upperBound) / range.upperBound
        return Float(normalized * normalized * normalized)
    }

    public static func decibels(fromGain gain: Float) -> Double {
        guard gain > 0 else { return -.infinity }
        return 20 * log10(Double(gain))
    }

    public static func gain(fromDecibels decibels: Double) -> Float {
        guard !decibels.isNaN else { return 0 }
        return Float(pow(10, decibels / 20))
    }
}
