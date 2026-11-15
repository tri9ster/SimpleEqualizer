import Testing
@testable import SimpleEqualizerCore

@Suite("ラウドネスの補正量")
struct LoudnessCurveTests {
    private typealias Correction = LoudnessCurve.Correction

    @Test("値: 強さ 100 での上限は低音 +15 dB、高音 +6 dB。18 dB 下げたところ(音量 50 あたり)で上限になる")
    func constants() {
        #expect(LoudnessCurve.maxBassDb == 15)
        #expect(LoudnessCurve.maxTrebleDb == 6)
        #expect(LoudnessCurve.fullAttenuationDb == 18)
        #expect(LoudnessCurve.amountRange == 0...100)
    }

    @Test("強さ 0 では、どの音量でも補正しない(切と同じ)", arguments: [0.0, 30, 50, 100])
    func zeroAmountGivesNoCorrection(volume: Double) {
        #expect(LoudnessCurve.correction(forVolume: volume, amount: 0) == .none)
    }

    @Test("音量 100 では、どの強さでも補正しない", arguments: [0.0, 50, 100])
    func noCorrectionAtFullVolume(amount: Double) {
        #expect(LoudnessCurve.correction(forVolume: 100, amount: amount) == .none)
        #expect(Correction.none == Correction(bassDb: 0, trebleDb: 0))
    }

    @Test("強さ 100 での、音量ごとの補正量", arguments: [
        (90.0, 2.3, 0.9), (70.0, 7.7, 3.1), (60.0, 11.1, 4.4), (50.0, 15.0, 6.0), (30.0, 15.0, 6.0), (10.0, 15.0, 6.0),
    ])
    func tableAtFullAmount(volume: Double, bass: Double, treble: Double) {
        let correction = LoudnessCurve.correction(forVolume: volume, amount: 100)
        #expect(abs(correction.bassDb - bass) < 0.06)
        #expect(abs(correction.trebleDb - treble) < 0.06)
    }

    @Test("補正量は、強さに比例する", arguments: [30.0, 60, 90])
    func proportionalToAmount(volume: Double) {
        let full = LoudnessCurve.correction(forVolume: volume, amount: 100)
        let half = LoudnessCurve.correction(forVolume: volume, amount: 50)
        let quarter = LoudnessCurve.correction(forVolume: volume, amount: 25)
        #expect(abs(half.bassDb - full.bassDb / 2) < 1e-9)
        #expect(abs(half.trebleDb - full.trebleDb / 2) < 1e-9)
        #expect(abs(quarter.bassDb - full.bassDb / 4) < 1e-9)
    }

    @Test("音量を下げるほど、補正が増える(減ることはない)。上限は超えない")
    func monotonicInVolume() {
        var previous = LoudnessCurve.correction(forVolume: 100, amount: 100)
        var volume = 99.0
        while volume >= 0 {
            let correction = LoudnessCurve.correction(forVolume: volume, amount: 100)
            #expect(correction.bassDb >= previous.bassDb)
            #expect(correction.trebleDb >= previous.trebleDb)
            #expect(correction.bassDb <= LoudnessCurve.maxBassDb)
            #expect(correction.trebleDb <= LoudnessCurve.maxTrebleDb)
            previous = correction
            volume -= 1
        }
    }

    @Test("補正は、いちばん強くしても、いつも音量による減衰より小さい(ラウドネスだけで、元の音量を超えない)")
    func neverExceedsAttenuation() {
        var volume = 0.0
        while volume <= 100 {
            let attenuation = -VolumeCurve.decibels(fromGain: VolumeCurve.gain(forVolume: volume))
            let correction = LoudnessCurve.correction(forVolume: volume, amount: 100)
            #expect(correction.bassDb <= attenuation + 1e-9)
            #expect(correction.trebleDb <= attenuation + 1e-9)
            volume += 0.5
        }
    }

    @Test("音量 0 では、その強さでの上限")
    func maximumAtZeroVolume() {
        #expect(LoudnessCurve.correction(forVolume: 0, amount: 100)
                == Correction(bassDb: LoudnessCurve.maxBassDb, trebleDb: LoudnessCurve.maxTrebleDb))
    }

    @Test("範囲の外の音量は、近い端として扱う")
    func clampsVolume() {
        #expect(LoudnessCurve.correction(forVolume: 150, amount: 100) == .none)
        #expect(LoudnessCurve.correction(forVolume: -5, amount: 100)
                == LoudnessCurve.correction(forVolume: 0, amount: 100))
    }

    @Test("範囲の外の強さは、近い端として扱う(画面から来る値)")
    func clampsAmount() {
        #expect(LoudnessCurve.correction(forVolume: 30, amount: 250)
                == LoudnessCurve.correction(forVolume: 30, amount: 100))
        #expect(LoudnessCurve.correction(forVolume: 30, amount: -10) == .none)
    }

    @Test("数でない音量や強さでは補正しない(増幅の側へ倒さない)")
    func nonFiniteGivesNoCorrection() {
        #expect(LoudnessCurve.correction(forVolume: .nan, amount: 100) == .none)
        #expect(LoudnessCurve.correction(forVolume: -.infinity, amount: 100) == .none)
        #expect(LoudnessCurve.correction(forVolume: .infinity, amount: 100) == .none)
        #expect(LoudnessCurve.correction(forVolume: 30, amount: .nan) == .none)
        #expect(LoudnessCurve.correction(forVolume: 30, amount: .infinity) == .none)
    }

    @Test("補正量は、数でない値にならない")
    func alwaysFinite() {
        for volume in [0.0, 0.001, 1, 50, 99.999, 100] {
            let correction = LoudnessCurve.correction(forVolume: volume, amount: 100)
            #expect(correction.bassDb.isFinite)
            #expect(correction.trebleDb.isFinite)
        }
    }

    @Test("出力先の設定から決める補正量は、その音量の補正量。消音していても、音量の数値で決める")
    func correctionFromOutputSettings() {
        let expected = LoudnessCurve.correction(forVolume: 30, amount: 60)
        #expect(expected.bassDb > 3)
        #expect(OutputSettings(volume: 30, muted: false).loudness(amount: 60) == expected)
        #expect(OutputSettings(volume: 30, muted: true).loudness(amount: 60) == expected)
        #expect(OutputSettings(volume: 30, muted: false).loudness(amount: 0) == .none)
    }

    @Test("壊れた音量では、音に掛ける音量(30)と同じ音量で補正量を決める(音と補正が、別の音量を前提にしない)",
          arguments: [999.0, -5.0, .nan, .infinity])
    func correctionUsesSanitizedVolume(volume: Double) {
        #expect(OutputSettings(volume: volume, muted: false).loudness(amount: 100)
                == LoudnessCurve.correction(forVolume: 30, amount: 100))
    }
}
