import Testing
@testable import SimpleEqualizerCore

@Suite("音を取り出せていないことの判断")
struct CaptureWatchTests {
    /// ほかのアプリが音を出しているのに、音を受け取っていない状態を、count 回見せる。
    private func silentChecks(_ watch: inout CaptureWatch, count: Int) -> [Bool] {
        (0..<count).map { _ in
            watch.update(isRunning: true, hasReceivedSignal: false, isOtherProcessPlaying: true)
        }
    }

    @Test("はじめは疑っていない")
    func initiallyNotSuspected() {
        #expect(!CaptureWatch().isSuspected)
    }

    @Test("ほかのアプリが音を出しているのに受け取れない状態が3回続いたら、疑って知らせる")
    func suspectsAfterConsecutiveSilentChecks() {
        var watch = CaptureWatch()
        #expect(silentChecks(&watch, count: 3) == [false, false, true])
        #expect(watch.isSuspected)
    }

    @Test("知らせるのは、1回だけ")
    func alertsOnlyOnce() {
        var watch = CaptureWatch()
        #expect(silentChecks(&watch, count: 6) == [false, false, true, false, false, false])
        #expect(watch.isSuspected)
    }

    @Test("ほかのアプリが音を出していないときは、疑わない(ただの無音かもしれない)")
    func doesNotSuspectWhenNothingIsPlaying() {
        var watch = CaptureWatch()
        for _ in 0..<10 {
            do { let alerted = watch.update(isRunning: true, hasReceivedSignal: false, isOtherProcessPlaying: false); #expect(!alerted) }
        }
        #expect(!watch.isSuspected)
    }

    @Test("途中で、ほかのアプリの音が止まったら、数え直す")
    func countRestartsWhenPlaybackStops() {
        var watch = CaptureWatch()
        #expect(silentChecks(&watch, count: 2) == [false, false])
        do { let alerted = watch.update(isRunning: true, hasReceivedSignal: false, isOtherProcessPlaying: false); #expect(!alerted) }
        #expect(silentChecks(&watch, count: 3) == [false, false, true])
    }

    @Test("音を受け取れたら、疑うのをやめる")
    func signalClearsSuspicion() {
        var watch = CaptureWatch()
        _ = silentChecks(&watch, count: 3)
        do { let alerted = watch.update(isRunning: true, hasReceivedSignal: true, isOtherProcessPlaying: true); #expect(!alerted) }
        #expect(!watch.isSuspected)
    }

    @Test("音を受け取れているあいだは、疑わない")
    func neverSuspectsWhileReceivingSignal() {
        var watch = CaptureWatch()
        for _ in 0..<10 {
            do { let alerted = watch.update(isRunning: true, hasReceivedSignal: true, isOtherProcessPlaying: true); #expect(!alerted) }
        }
        #expect(!watch.isSuspected)
    }

    @Test("加工していないときは、疑わない。数え直す")
    func notRunningResets() {
        var watch = CaptureWatch()
        #expect(silentChecks(&watch, count: 2) == [false, false])
        do { let alerted = watch.update(isRunning: false, hasReceivedSignal: false, isOtherProcessPlaying: true); #expect(!alerted) }
        #expect(!watch.isSuspected)
        #expect(silentChecks(&watch, count: 2) == [false, false])
    }

    @Test("疑ったあと、ほかのアプリの音が止まっても、疑いは残る(音を受け取れるまで)")
    func suspicionRemainsUntilSignal() {
        var watch = CaptureWatch()
        _ = silentChecks(&watch, count: 3)
        do { let alerted = watch.update(isRunning: true, hasReceivedSignal: false, isOtherProcessPlaying: false); #expect(!alerted) }
        #expect(watch.isSuspected)
    }

    @Test("一度知らせたあとは、疑いが晴れてからまた疑っても、知らせない(画面には出し続ける)")
    func doesNotAlertAgainAfterRecovery() {
        var watch = CaptureWatch()
        _ = silentChecks(&watch, count: 3)
        _ = watch.update(isRunning: false, hasReceivedSignal: false, isOtherProcessPlaying: false)
        #expect(silentChecks(&watch, count: 3) == [false, false, false])
        #expect(watch.isSuspected)
    }
}
