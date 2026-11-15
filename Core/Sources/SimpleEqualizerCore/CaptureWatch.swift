import Foundation

/// 「音を取り出せていない(「システム音声の録音」の許可がないかもしれない)」と疑うかどうかの判断。
///
/// 許可の状態を直接調べる方法がないので、状況から判断する:
/// ほかのアプリが音を出しているのに、始めてから一度も無音でない音を受け取っていない状態が続いたら、疑う。
public struct CaptureWatch: Sendable {
    /// 続けて何回、上の状態を見たら疑うか。
    public static let checksBeforeSuspecting = 3

    public private(set) var isSuspected = false
    private var silentChecks = 0
    private var didAlert = false

    public init() {}

    /// 定期的に呼ぶ。利用者に知らせるべきとき(起動してから1回だけ)に true を返す。
    public mutating func update(isRunning: Bool, hasReceivedSignal: Bool, isOtherProcessPlaying: Bool) -> Bool {
        // 加工していないとき、音を受け取れているときは、疑わない。
        guard isRunning, !hasReceivedSignal else {
            silentChecks = 0
            isSuspected = false
            return false
        }
        // だれも音を出していないなら、ただの無音かもしれない。数え直す(すでに疑っているなら、疑いは残す)。
        guard isOtherProcessPlaying else {
            silentChecks = 0
            return false
        }
        silentChecks += 1
        guard silentChecks >= Self.checksBeforeSuspecting else { return false }
        isSuspected = true
        guard !didAlert else { return false }
        didAlert = true
        return true
    }
}
