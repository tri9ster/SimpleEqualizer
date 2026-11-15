import Foundation

/// イコライザーの設定(10 バンドの値)。
///
/// 値は −10〜+10 dB、0.5 dB 刻み。入れるときに、範囲に収め、刻みに丸める。
public struct EqualizerSettings: Equatable, Sendable {
    /// バンドの中心の周波数(Hz)。
    public static let frequencies: [Double] = [31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    /// 画面に出すバンドの名前。
    public static let frequencyLabels = ["31", "62", "125", "250", "500", "1k", "2k", "4k", "8k", "16k"]
    public static let bandCount = frequencies.count
    public static let gainRange: ClosedRange<Double> = -10...10
    public static let step: Double = 0.5
    /// 矢印キーで大きく動かすとき(Shift を押しながら)の刻み。
    public static let largeStep: Double = 2

    public static let flat = EqualizerSettings()

    /// 31 Hz から 16 kHz の順に、10 個の値(dB)。
    public private(set) var gainsDb: [Double]

    /// フラット(すべて 0 dB)。
    public init() {
        gainsDb = [Double](repeating: 0, count: Self.bandCount)
    }

    /// 保存してあった値から作る。個数が 10 でないとき、範囲の外や数でない値が1つでもあるときは、作らない。
    /// 壊れた値を近い端(+10 dB)に丸めたり、読めた分だけ使ったりすると、意図しない増幅になるため。
    /// 範囲の中で刻みに乗っていない値は、近い刻みに丸める(ずれは 0.25 dB 以下)。
    public init?(storedGains: [Double]) {
        guard storedGains.count == Self.bandCount,
              storedGains.allSatisfy({ $0.isFinite && Self.gainRange.contains($0) })
        else {
            return nil
        }
        gainsDb = storedGains.map(Self.normalized)
    }

    public var isFlat: Bool {
        gainsDb.allSatisfy { $0 == 0 }
    }

    /// となりのバンドの山が、あるバンドの位置に重なる割合。バンドの幅(1 オクターブ)で決まる。
    /// 本物のエンジンで測って決めた値(1つとなりは約 2 割、2つとなりは約 0.75 割)。
    /// いちばん高い2つのバンド(8 kHz と 16 kHz)は、扱える周波数の上限に近く、重なりが大きい(約 3 割)。
    /// エンジンのバンドの幅を変えたら、測り直す(エンジンのテストが、見積もりと測った値を比べている)。
    static let adjacentBandOverlap: Double = 0.2
    static let topBandsOverlap: Double = 0.3
    static let secondBandOverlap: Double = 0.075

    /// イコライザーが、いちばん大きく増幅する量の見積もり(dB。0 以上)。
    /// となりのバンドも上げていると、山が重なって、1つのバンドの量より大きくなる(全部を +10 dB にすると、約 +15.5 dB)。
    /// となりのバンドを下げていると、そのぶん小さくなる。上げているバンドがなければ 0。
    /// 測った値とのずれは、1 dB 未満(見積もりを超えた分は、リミッターが抑える)。
    public var estimatedPeakGainDb: Double {
        var peak = 0.0
        for (band, gain) in gainsDb.enumerated() {
            let combined = gain
                + Self.overlap(between: band, and: band - 1) * self.gain(at: band - 1)
                + Self.overlap(between: band, and: band + 1) * self.gain(at: band + 1)
                + Self.secondBandOverlap * (self.gain(at: band - 2) + self.gain(at: band + 2))
            peak = max(peak, combined)
        }
        return peak
    }

    /// となり合う2つのバンドの、山の重なる割合。
    private static func overlap(between band: Int, and neighbour: Int) -> Double {
        max(band, neighbour) == bandCount - 1 ? topBandsOverlap : adjacentBandOverlap
    }

    /// そのバンドの値。ないバンドでは 0。
    public func gain(at band: Int) -> Double {
        gainsDb.indices.contains(band) ? gainsDb[band] : 0
    }

    /// そのバンドの値を変える。画面から来る値なので、範囲の外は近い端に収める。数でない値や無限大は 0 dB にする。
    /// ないバンドでは、何もしない。
    public mutating func setGain(_ value: Double, at band: Int) {
        guard gainsDb.indices.contains(band) else { return }
        gainsDb[band] = Self.normalized(value)
    }

    /// そのバンドを、指定した量だけ増減する。範囲の端で止まる。量が数でない値や無限大のときは、何もしない。
    public mutating func adjust(band: Int, by delta: Double) {
        guard delta.isFinite else { return }
        setGain(gain(at: band) + delta, at: band)
    }

    /// フラットに戻す。
    public mutating func reset() {
        self = .flat
    }

    /// 上下の矢印キーを1回押したときに、値を動かす量(dB)。上は増やし、下は減らす。
    /// `large` は、大きく動かすとき(Shift を押しながら)。
    public static func keyDelta(up: Bool, large: Bool) -> Double {
        let amount = large ? largeStep : step
        return up ? amount : -amount
    }

    /// 選んでいるバンドを、左右に動かしたあとの番号。端で止まる(反対の端へ回り込まない)。
    /// 元の番号が範囲の外でも、範囲の中の番号を返す。
    public static func band(_ band: Int, movedBy delta: Int) -> Int {
        let last = bandCount - 1
        let current = min(max(band, 0), last)
        // 大きな数どうしを足してあふれないよう、動かす量を先に収める。
        let moved = current + min(max(delta, -last), last)
        return min(max(moved, 0), last)
    }

    /// 画面に出す値の書き方。0 は符号なし、ほかは符号つきで小数1桁。
    public static func label(forGain gain: Double) -> String {
        // 小数1桁に丸めた結果が 0 なら、符号をつけない(「+0.0」「-0.0」と出さない)。
        let rounded = (gain * 10).rounded() / 10
        return rounded == 0 ? "0" : String(format: "%+.1f", rounded)
    }

    private static func normalized(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        let clamped = min(max(value, gainRange.lowerBound), gainRange.upperBound)
        let rounded = (clamped / step).rounded() * step
        // −0.0 を 0 にそろえる(保存したときに「-0」と書かれないようにする)。
        return rounded == 0 ? 0 : rounded
    }
}
