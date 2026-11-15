import Foundation
import Testing
@testable import SimpleEqualizerCore

/// テストごとに一時的なフォルダを使う。本物の保存先には書き込まない。
private final class TemporaryStore {
    let store = StateStore(directory: FileManager.default.temporaryDirectory
        .appendingPathComponent("SimpleEqualizerTests-\(UUID().uuidString)"))

    deinit {
        try? FileManager.default.removeItem(at: store.directory)
    }

    func write(_ text: String) throws {
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: store.fileURL)
    }

    /// ファイルの中身を読み、その状態を返す。壊れたファイルとして扱われていないことも確かめる。
    func load(_ text: String) throws -> AppState {
        try write(text)
        let result = store.load()
        #expect(result.status == .loaded)
        return result.state
    }
}

@Suite("状態: イコライザーとラウドネス")
struct AppStateEqualizerTests {
    @Test("初期値は、イコライザーが入でフラット、ラウドネスが入で強さ 0(効かない)")
    func defaults() {
        let state = AppState()
        #expect(state.equalizerEnabled)
        #expect(state.equalizer.isFlat)
        #expect(state.loudnessAmount == 0)
        #expect(state.loudnessEnabled)
    }

    @Test("前の設定が読めなかったときも、フラットで、ラウドネスは強さ 0(効かない)。スイッチは初期値の入")
    func recoveredIsFlat() {
        #expect(AppState.recovered.equalizer.isFlat)
        #expect(AppState.recovered.loudnessAmount == 0)
        #expect(AppState.recovered.loudnessEnabled)
        #expect(AppState.recovered.effectiveLoudnessAmount == 0)
    }

    @Test("保存して読み込むと、同じ値に戻る")
    func roundTrip() throws {
        let temporary = TemporaryStore()
        var state = AppState(outputs: ["装置A": OutputSettings(volume: 42, muted: false)])
        state.equalizerEnabled = false
        state.equalizer.setGain(4.5, at: 1)
        state.equalizer.setGain(-10, at: 9)
        state.loudnessAmount = 65
        state.loudnessEnabled = false
        try temporary.store.save(state)
        let result = temporary.store.load()
        #expect(result.status == .loaded)
        #expect(result.state == state)
    }

    @Test("保存したファイルに、足した項目が、決めた名前で入る")
    func savedKeys() throws {
        let temporary = TemporaryStore()
        var state = AppState()
        state.equalizer.setGain(3, at: 0)
        try temporary.store.save(state)
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: temporary.store.fileURL)) as? [String: Any]
        #expect(object?["version"] as? Int == 1)
        #expect(object?["equalizerEnabled"] as? Bool == true)
        #expect(object?["loudnessAmount"] as? Double == 0)
        #expect(object?["loudnessEnabled"] as? Bool == true)
        #expect(object?["equalizerGainsDb"] as? [Double] == [3, 0, 0, 0, 0, 0, 0, 0, 0, 0])
        #expect(object?["isRecovered"] == nil)
    }

    @Test("段階2 のアプリが作ったファイル(足した項目がない)を読める。音量は残る")
    func readsStage2File() throws {
        let state = try TemporaryStore().load("""
            { "version": 1, "outputs": { "装置A": { "volume": 64, "muted": true } } }
            """)
        #expect(state.settings(forOutput: "装置A") == OutputSettings(volume: 64, muted: true))
        #expect(state.equalizerEnabled)
        #expect(state.equalizer.isFlat)
        #expect(state.loudnessAmount == 0)
    }

    @Test("足した項目を読める")
    func readsNewFields() throws {
        let state = try TemporaryStore().load("""
            { "version": 1, "outputs": {}, "equalizerEnabled": false, "loudnessAmount": 65,
              "equalizerGainsDb": [0, 4.0, 3.0, 1.5, 0, 0, 1.0, 2.0, 2.5, 2.0] }
            """)
        #expect(!state.equalizerEnabled)
        #expect(state.loudnessAmount == 65)
        #expect(state.equalizer.gainsDb == [0, 4, 3, 1.5, 0, 0, 1, 2, 2.5, 2])
    }

    @Test("イコライザーの値が壊れているときは、フラットにする。ほかの項目は巻き込まない", arguments: [
        "[1, 2, 3]",
        "[0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 5]",
        "[0, 0, 0, 0, 0, 99, 0, 0, 0, 0]",
        "[0, 0, 0, 0, 0, -10.5, 0, 0, 0, 0]",
        "[0, 0, 0, null, 0, 0, 0, 0, 0, 0]",
        "[0, 0, 0, \"5\", 0, 0, 0, 0, 0, 0]",
        "\"フラット\"",
        "null",
        "{}",
    ])
    func brokenGainsBecomeFlat(gains: String) throws {
        let state = try TemporaryStore().load("""
            { "version": 1, "outputs": { "装置A": { "volume": 64, "muted": false } },
              "loudnessAmount": 40, "equalizerGainsDb": \(gains) }
            """)
        #expect(state.equalizer.isFlat)
        #expect(state.loudnessAmount == 40)
        #expect(state.settings(forOutput: "装置A").volume == 64)
    }

    @Test("イコライザーの入・切や、ラウドネスの強さが、書いてあるのに読めないときは、切にする(切にしていた増幅を、勝手に入れない)")
    func brokenSwitchesTurnOff() throws {
        let state = try TemporaryStore().load("""
            { "version": 1, "outputs": { "装置A": { "volume": 64, "muted": false } },
              "equalizerEnabled": "はい", "loudnessAmount": "強め",
              "equalizerGainsDb": [1, 0, 0, 0, 0, 0, 0, 0, 0, 0] }
            """)
        #expect(!state.equalizerEnabled)
        #expect(state.loudnessAmount == 0)
        #expect(state.equalizer.gain(at: 0) == 1)
        #expect(state.settings(forOutput: "装置A").volume == 64)
    }

    @Test("ラウドネスの強さが範囲の外のときは、0(切)にする(近い端の 100 に丸めない)", arguments: ["150", "-1", "1e9"])
    func outOfRangeAmountBecomesZero(amount: String) throws {
        let state = try TemporaryStore().load("""
            { "version": 1, "outputs": {}, "loudnessAmount": \(amount) }
            """)
        #expect(state.loudnessAmount == 0)
    }

    @Test("範囲の端の強さは、そのまま使う", arguments: [0.0, 100.0])
    func boundaryAmountIsKept(amount: Double) throws {
        let state = try TemporaryStore().load("""
            { "version": 1, "outputs": {}, "loudnessAmount": \(amount) }
            """)
        #expect(state.loudnessAmount == amount)
    }

    @Test("強さではなく入・切で保存してあった古いファイル: 入なら強さ 50、切なら 0 として読む",
          arguments: [("true", 50.0), ("false", 0.0), ("3", 0.0)])
    func readsLegacySwitch(value: String, expected: Double) throws {
        let state = try TemporaryStore().load("""
            { "version": 1, "outputs": {}, "loudnessEnabled": \(value) }
            """)
        #expect(state.loudnessAmount == expected)
        // 古いファイルには、強さとは別の入・切がないので、入にする(いままでの効き方を変えない)。
        #expect(state.loudnessEnabled)
    }

    @Test("強さと、古い入・切の両方があるときは、強さを使う")
    func amountWinsOverLegacySwitch() throws {
        let state = try TemporaryStore().load("""
            { "version": 1, "outputs": {}, "loudnessEnabled": true, "loudnessAmount": 20 }
            """)
        #expect(state.loudnessAmount == 20)
        #expect(state.loudnessEnabled)
    }

    @Test("強さのあるファイルで、ラウドネスの入・切を読む", arguments: [("true", true), ("false", false)])
    func readsLoudnessSwitch(value: String, expected: Bool) throws {
        let state = try TemporaryStore().load("""
            { "version": 1, "outputs": {}, "loudnessAmount": 40, "loudnessEnabled": \(value) }
            """)
        #expect(state.loudnessAmount == 40)
        #expect(state.loudnessEnabled == expected)
    }

    @Test("強さのあるファイルに、入・切の項目がないときは、入にする(この項目を足す前のファイル)")
    func missingLoudnessSwitchIsOn() throws {
        let state = try TemporaryStore().load("""
            { "version": 1, "outputs": {}, "loudnessAmount": 40 }
            """)
        #expect(state.loudnessEnabled)
    }

    @Test("強さのあるファイルで、入・切が書いてあるのに読めないときは、切にする(勝手に入れない)")
    func brokenLoudnessSwitchTurnsOff() throws {
        let state = try TemporaryStore().load("""
            { "version": 1, "outputs": {}, "loudnessAmount": 40, "loudnessEnabled": "はい" }
            """)
        #expect(!state.loudnessEnabled)
        #expect(state.loudnessAmount == 40)
    }

    @Test("音に掛ける強さは、切なら 0、入なら覚えている強さ")
    func effectiveAmount() {
        var state = AppState()
        state.loudnessAmount = 60
        #expect(state.effectiveLoudnessAmount == 60)
        state.loudnessEnabled = false
        #expect(state.effectiveLoudnessAmount == 0)
        #expect(state.loudnessAmount == 60)
    }

    @Test("数でない強さや範囲の外の強さが入っていても保存でき、0 として書く", arguments: [Double.nan, .infinity, 150, -5])
    func savesBrokenAmountAsZero(amount: Double) throws {
        let temporary = TemporaryStore()
        var state = AppState()
        state.loudnessAmount = amount
        try temporary.store.save(state)
        #expect(temporary.store.load().state.loudnessAmount == 0)
    }
}
