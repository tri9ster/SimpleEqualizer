import Foundation

/// キーボードの音量キー。
public enum VolumeKey: Equatable, Sendable {
    case up
    case down
    case mute

    /// 1回で動かす刻みの数。0〜100 を、この数に分ける(macOS 標準と同じ)。
    public static let coarseSteps: Double = 16
    /// 細かく変えるとき(Option + Shift を押しながら)の刻みの数。
    public static let fineSteps: Double = 64
}

extension OutputSettings {
    /// 音量キーを1回押したあとの設定。
    /// - 上げる・下げる: となりの刻みへ動かす。端(0、100)で止まる。消音していたら、解く。
    /// - 消音: 消音を切り替える。音量の数値は変えない。
    /// 壊れた音量からは、安全な側の音量(30)を元にして動かす。
    public func applying(_ key: VolumeKey, fine: Bool) -> OutputSettings {
        var result = sanitized
        switch key {
        case .mute:
            result.muted.toggle()
        case .up, .down:
            result.muted = false
            result.volume = Self.steppedVolume(result.volume, up: key == .up, fine: fine)
        }
        return result
    }

    /// 刻みの途中の音量からは、となりの刻みへ動かす(刻みの上に乗っているときは、1つ先へ)。
    private static func steppedVolume(_ volume: Double, up: Bool, fine: Bool) -> Double {
        let range = VolumeCurve.range
        let step = (range.upperBound - range.lowerBound) / (fine ? VolumeKey.fineSteps : VolumeKey.coarseSteps)
        let position = (volume - range.lowerBound) / step
        // 計算の誤差で、刻みの上にいるのに、手前と判断しないようにする。
        let tolerance = 1e-9
        let next = up ? (position + tolerance).rounded(.down) + 1 : (position - tolerance).rounded(.up) - 1
        return min(max(range.lowerBound + next * step, range.lowerBound), range.upperBound)
    }
}
