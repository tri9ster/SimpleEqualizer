import Foundation

/// 「リミッターが音を抑えている」ことを、画面に出すかどうかの判断。
///
/// リミッターが抑えていた回の数(経路ごとに数えている)を、少しおきに受け取り、前より増えていたら、出す。
/// 回数は、経路ごとに別々なので、出力先が変わったとき(別の経路の回数を受け取り始めたとき)は、比べ直す。
/// 比べ直さないと、前に抑えたことのある出力先へ切り替えただけで、いま抑えているかのように出てしまう。
public struct LimiterIndicator: Sendable {
    /// 最後に増えたときから、表示を保つ時間(秒)。短いと、音の山に合わせて点滅して、読めない。
    public static let holdSeconds: Double = 2

    private var source: String?
    private var lastCount: UInt64 = 0
    private var lastLimitedTime: Double?

    public init() {}

    /// いまの回数を受け取り、表示するかを返す。
    /// - `source`: 回数を数えている経路(出力先の識別子)。加工していないときは nil。
    /// - `time`: いまの時刻(秒)。どこを 0 にしてもよいが、戻らないこと。
    public mutating func update(source newSource: String?, count: UInt64, time: Double) -> Bool {
        if newSource != source {
            // 別の経路の回数とは、比べない。前の出力先で出していた表示も、消す。
            source = newSource
            lastCount = count
            lastLimitedTime = nil
            return false
        }
        // 加工を始め直すと、回数は 0 に戻る。増えたときだけ、抑えたものとして扱う。
        if count > lastCount {
            lastLimitedTime = time
        }
        lastCount = count
        guard newSource != nil, let lastLimitedTime else { return false }
        return time - lastLimitedTime < Self.holdSeconds
    }
}
