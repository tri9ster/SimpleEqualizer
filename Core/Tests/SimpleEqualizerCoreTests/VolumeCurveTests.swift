import Testing
@testable import SimpleEqualizerCore

@Suite("音量の換算")
struct VolumeCurveTests {
    @Test("音量 100 で元の音量になる")
    func fullVolumeIsUnity() {
        #expect(VolumeCurve.gain(forVolume: 100) == 1)
    }

    @Test("音量 0 で無音になる")
    func zeroVolumeIsSilent() {
        #expect(VolumeCurve.gain(forVolume: 0) == 0)
    }

    @Test("音量が大きいほど、倍率が大きい")
    func gainIncreasesWithVolume() {
        var previous = VolumeCurve.gain(forVolume: 0)
        for step in 1...100 {
            let current = VolumeCurve.gain(forVolume: Double(step))
            #expect(current > previous, "音量 \(step) で倍率が増えていない")
            previous = current
        }
    }

    @Test("3乗の対応になっている", arguments: [
        (50.0, 0.125),
        (30.0, 0.027),
        (10.0, 0.001),
    ])
    func followsCubicCurve(volume: Double, expected: Double) {
        #expect(abs(Double(VolumeCurve.gain(forVolume: volume)) - expected) < 1e-6)
    }

    @Test("初めて使う出力先の音量は 100(元の音量のまま。アプリを使う前より大きくならない)")
    func defaultVolumeIsUnity() {
        #expect(VolumeCurve.defaultVolume == 100)
        #expect(VolumeCurve.gain(forVolume: VolumeCurve.defaultVolume) == 1)
    }

    @Test("読めない値のかわりに使う音量は 30(およそ −31.4 dB。壊れた値で大きな音を出さない)")
    func fallbackVolumeIsQuiet() {
        #expect(VolumeCurve.fallbackVolume == 30)
        let decibels = VolumeCurve.decibels(fromGain: VolumeCurve.gain(forVolume: VolumeCurve.fallbackVolume))
        #expect(abs(decibels - -31.37) < 0.01)
    }

    @Test("範囲の外の音量でも、倍率は 0 以上 1 以下", arguments: [
        -1.0, -1000.0, 100.5, 1000.0, .infinity, -.infinity, .nan,
    ])
    func gainStaysWithinBounds(volume: Double) {
        let gain = VolumeCurve.gain(forVolume: volume)
        #expect(gain >= 0)
        #expect(gain <= 1)
    }

    @Test("範囲の外の音量は、近い端に丸める")
    func outOfRangeVolumeIsClamped() {
        #expect(VolumeCurve.gain(forVolume: -5) == 0)
        #expect(VolumeCurve.gain(forVolume: 150) == 1)
    }

    @Test("数でない音量は、無音にする(安全な側に倒す)")
    func notANumberIsSilent() {
        #expect(VolumeCurve.gain(forVolume: .nan) == 0)
    }

    @Test("デシベルと倍率の換算")
    func decibelConversion() {
        #expect(VolumeCurve.decibels(fromGain: 1) == 0)
        #expect(abs(VolumeCurve.decibels(fromGain: 0.5) - -6.0206) < 0.001)
        #expect(VolumeCurve.decibels(fromGain: 0) == -.infinity)
        #expect(VolumeCurve.gain(fromDecibels: 0) == 1)
        #expect(abs(Double(VolumeCurve.gain(fromDecibels: -20)) - 0.1) < 1e-6)
        #expect(VolumeCurve.gain(fromDecibels: -.infinity) == 0)
    }

    @Test("デシベルへ換算して戻すと、元の倍率になる", arguments: [0.001, 0.027, 0.125, 0.5, 1.0])
    func decibelRoundTrip(gain: Double) {
        let roundTrip = VolumeCurve.gain(fromDecibels: VolumeCurve.decibels(fromGain: Float(gain)))
        #expect(abs(Double(roundTrip) - gain) < 1e-6)
    }
}
