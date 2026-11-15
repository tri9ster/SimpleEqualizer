import Testing
@testable import SimpleEqualizerCore

@Suite("音量キー")
struct VolumeKeyTests {
    private func settings(_ volume: Double, muted: Bool = false) -> OutputSettings {
        OutputSettings(volume: volume, muted: muted)
    }

    @Test("1回で 1/16 ずつ変わる(macOS 標準と同じ刻み)")
    func coarseStep() {
        #expect(VolumeKey.coarseSteps == 16)
        #expect(settings(50).applying(.up, fine: false).volume == 56.25)
        #expect(settings(50).applying(.down, fine: false).volume == 43.75)
    }

    @Test("細かく変えるとき(Option + Shift)は、1/64 ずつ変わる")
    func fineStep() {
        #expect(VolumeKey.fineSteps == 64)
        #expect(settings(50).applying(.up, fine: true).volume == 51.5625)
        #expect(settings(50).applying(.down, fine: true).volume == 48.4375)
    }

    @Test("刻みの途中の音量からは、となりの刻みへ動く(スライダーで決めた 30 から、上は 31.25、下は 25)")
    func snapsToGrid() {
        #expect(settings(30).applying(.up, fine: false).volume == 31.25)
        #expect(settings(30).applying(.down, fine: false).volume == 25)
        #expect(settings(30).applying(.up, fine: true).volume == 31.25)
        #expect(settings(30).applying(.down, fine: true).volume == 29.6875)
    }

    @Test("0 から 16 回上げると、ちょうど 100 になる。16 回下げると、ちょうど 0 に戻る")
    func fullTravel() {
        var current = settings(0)
        for _ in 0..<16 { current = current.applying(.up, fine: false) }
        #expect(current.volume == 100)
        for _ in 0..<16 { current = current.applying(.down, fine: false) }
        #expect(current.volume == 0)
    }

    @Test("100 と 0 で止まる(元の音量を超えない)")
    func stopsAtEnds() {
        #expect(settings(100).applying(.up, fine: false).volume == 100)
        #expect(settings(98).applying(.up, fine: false).volume == 100)
        #expect(settings(0).applying(.down, fine: false).volume == 0)
        #expect(settings(2).applying(.down, fine: false).volume == 0)
        #expect(settings(100).applying(.up, fine: true).volume == 100)
    }

    @Test("消音のキーは、消音を切り替える。音量の数値は変えない")
    func muteToggles() {
        #expect(settings(40).applying(.mute, fine: false) == settings(40, muted: true))
        #expect(settings(40, muted: true).applying(.mute, fine: false) == settings(40))
        // 細かく変える指定は、消音には関係しない。
        #expect(settings(40).applying(.mute, fine: true) == settings(40, muted: true))
    }

    @Test("消音しているときに音量のキーを押すと、消音を解く(macOS 標準と同じ)")
    func volumeKeysUnmute() {
        #expect(settings(50, muted: true).applying(.up, fine: false) == settings(56.25))
        #expect(settings(50, muted: true).applying(.down, fine: false) == settings(43.75))
    }

    @Test("壊れた音量からは、安全な側の音量(30)を元にして動かす(大きい側へ飛ばない)", arguments: [999.0, -5.0, .nan, .infinity])
    func brokenVolumeUsesFallback(volume: Double) {
        #expect(settings(volume).applying(.up, fine: false).volume == 31.25)
        #expect(settings(volume).applying(.down, fine: false).volume == 25)
        #expect(settings(volume).applying(.mute, fine: false).volume == 30)
    }

    @Test("結果は、いつも 0〜100 の範囲に収まる")
    func alwaysInRange() {
        var volume = 0.0
        while volume <= 100 {
            for key in [VolumeKey.up, .down, .mute] {
                for fine in [false, true] {
                    let result = settings(volume).applying(key, fine: fine).volume
                    #expect(VolumeCurve.range.contains(result))
                }
            }
            volume += 0.7
        }
    }
}
