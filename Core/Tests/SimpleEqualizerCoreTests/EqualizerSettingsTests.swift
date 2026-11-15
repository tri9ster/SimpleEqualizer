import Testing
@testable import SimpleEqualizerCore

@Suite("イコライザーの設定")
struct EqualizerSettingsTests {
    @Test("バンドは 10 個で、31 Hz から 16 kHz まで")
    func bands() {
        #expect(EqualizerSettings.bandCount == 10)
        #expect(EqualizerSettings.frequencies == [31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000])
    }

    @Test("はじめはフラット(すべて 0 dB)")
    func startsFlat() {
        let settings = EqualizerSettings()
        #expect(settings.gainsDb == [Double](repeating: 0, count: 10))
        #expect(settings.isFlat)
        #expect(settings == EqualizerSettings.flat)
    }

    @Test("バンドの値を変えられる")
    func setsGain() {
        var settings = EqualizerSettings()
        settings.setGain(4.5, at: 1)
        settings.setGain(-3, at: 9)
        #expect(settings.gain(at: 1) == 4.5)
        #expect(settings.gain(at: 9) == -3)
        #expect(settings.gain(at: 0) == 0)
        #expect(!settings.isFlat)
    }

    @Test("範囲の外の値は、近い端(±10 dB)に収める", arguments: [(10.5, 10.0), (99.0, 10.0), (-10.5, -10.0), (-1e9, -10.0)])
    func clampsToRange(input: Double, expected: Double) {
        var settings = EqualizerSettings()
        settings.setGain(input, at: 3)
        #expect(settings.gain(at: 3) == expected)
    }

    @Test("0.5 dB 刻みに丸める", arguments: [(0.2, 0.0), (0.3, 0.5), (1.74, 1.5), (1.76, 2.0), (-0.3, -0.5), (-9.8, -10.0), (3.5, 3.5)])
    func roundsToStep(input: Double, expected: Double) {
        var settings = EqualizerSettings()
        settings.setGain(input, at: 0)
        #expect(settings.gain(at: 0) == expected)
    }

    @Test("数でない値や無限大は 0 dB にする(増幅の側へ倒さない)", arguments: [Double.nan, .infinity, -.infinity])
    func nonFiniteBecomesZero(value: Double) {
        var settings = EqualizerSettings()
        settings.setGain(5, at: 2)
        settings.setGain(value, at: 2)
        #expect(settings.gain(at: 2) == 0)
    }

    @Test("ないバンドを指定しても、何も変わらない", arguments: [-1, 10, 99])
    func ignoresInvalidBand(band: Int) {
        var settings = EqualizerSettings()
        settings.setGain(5, at: band)
        settings.adjust(band: band, by: 2)
        #expect(settings.isFlat)
        #expect(settings.gain(at: band) == 0)
    }

    @Test("バンドを、指定した量だけ増減できる")
    func adjusts() {
        var settings = EqualizerSettings()
        settings.adjust(band: 4, by: 0.5)
        #expect(settings.gain(at: 4) == 0.5)
        settings.adjust(band: 4, by: 2)
        #expect(settings.gain(at: 4) == 2.5)
        settings.adjust(band: 4, by: -0.5)
        #expect(settings.gain(at: 4) == 2)
    }

    @Test("増減は、範囲の端で止まる")
    func adjustStopsAtEnds() {
        var settings = EqualizerSettings()
        settings.setGain(9.5, at: 0)
        settings.adjust(band: 0, by: 2)
        #expect(settings.gain(at: 0) == 10)
        settings.setGain(-9, at: 0)
        settings.adjust(band: 0, by: -2)
        #expect(settings.gain(at: 0) == -10)
    }

    @Test("増減の量が数でない値や無限大のときは、何も変えない", arguments: [Double.nan, .infinity, -.infinity])
    func adjustIgnoresNonFiniteDelta(delta: Double) {
        var settings = EqualizerSettings()
        settings.setGain(6, at: 4)
        settings.adjust(band: 4, by: delta)
        #expect(settings.gain(at: 4) == 6)
    }

    @Test("フラットに戻せる")
    func resets() {
        var settings = EqualizerSettings()
        settings.setGain(5, at: 0)
        settings.setGain(-5, at: 9)
        settings.reset()
        #expect(settings.isFlat)
    }

    @Test("保存してあった 10 個の値から作れる")
    func fromStoredGains() {
        let gains: [Double] = [0, 4, 3, 1.5, 0, 0, 1, 2, 2.5, -10]
        #expect(EqualizerSettings(storedGains: gains)?.gainsDb == gains)
    }

    @Test("保存してあった値は、0.5 dB 刻みに丸める")
    func storedGainsAreRounded() {
        let settings = EqualizerSettings(storedGains: [0.2, 3.3, 0, 0, 0, 0, 0, 0, 0, -9.9])
        #expect(settings?.gainsDb == [0, 3.5, 0, 0, 0, 0, 0, 0, 0, -10])
    }

    @Test("保存してあった値の個数が 10 でなければ、使わない", arguments: [0, 1, 9, 11])
    func rejectsWrongCount(count: Int) {
        #expect(EqualizerSettings(storedGains: [Double](repeating: 1, count: count)) == nil)
    }

    @Test("保存してあった値に、範囲の外や数でない値が1つでもあれば、全部を使わない(近い端に丸めない)",
          arguments: [99.0, 10.5, -10.5, .nan, .infinity])
    func rejectsBrokenValues(value: Double) {
        var gains = [Double](repeating: 2, count: 10)
        gains[6] = value
        #expect(EqualizerSettings(storedGains: gains) == nil)
    }

    @Test("画面に出す値の書き方(0 は符号なし、ほかは符号つきで小数1桁)", arguments: [
        (0.0, "0"), (4.0, "+4.0"), (0.5, "+0.5"), (-3.5, "-3.5"), (10.0, "+10.0"), (-10.0, "-10.0"),
        (0.04, "0"), (-0.04, "0"), (-0.0, "0"),
    ])
    func gainLabels(gain: Double, expected: String) {
        #expect(EqualizerSettings.label(forGain: gain) == expected)
    }

    @Test("矢印キーの刻みは、ふつうは 0.5 dB、大きく動かすときは 2 dB")
    func keySteps() {
        #expect(EqualizerSettings.step == 0.5)
        #expect(EqualizerSettings.largeStep == 2)
    }

    @Test("上下の矢印キーで動かす量: 上は増やす、下は減らす。大きく動かすときは 2 dB", arguments: [
        (true, false, 0.5), (false, false, -0.5), (true, true, 2.0), (false, true, -2.0),
    ])
    func keyDelta(up: Bool, large: Bool, expected: Double) {
        #expect(EqualizerSettings.keyDelta(up: up, large: large) == expected)
    }

    @Test("選んでいるバンドを、左右に動かせる")
    func movesSelection() {
        #expect(EqualizerSettings.band(0, movedBy: 1) == 1)
        #expect(EqualizerSettings.band(5, movedBy: -1) == 4)
        #expect(EqualizerSettings.band(8, movedBy: 1) == 9)
    }

    @Test("選んでいるバンドは、端で止まる(反対の端へ回り込まない)")
    func selectionStopsAtEnds() {
        #expect(EqualizerSettings.band(0, movedBy: -1) == 0)
        #expect(EqualizerSettings.band(9, movedBy: 1) == 9)
        #expect(EqualizerSettings.band(3, movedBy: 100) == 9)
        #expect(EqualizerSettings.band(3, movedBy: -100) == 0)
    }

    @Test("選んでいるバンドが範囲の外になっていても、範囲の中に戻す", arguments: [(-5, 0, 0), (42, 0, 9), (42, -1, 8), (Int.max, 1, 9), (Int.min, -1, 0)])
    func selectionRecoversFromInvalidBand(band: Int, delta: Int, expected: Int) {
        #expect(EqualizerSettings.band(band, movedBy: delta) == expected)
    }

    @Test("画面に出すバンドの名前")
    func labels() {
        #expect(EqualizerSettings.frequencyLabels == ["31", "62", "125", "250", "500", "1k", "2k", "4k", "8k", "16k"])
    }
}
