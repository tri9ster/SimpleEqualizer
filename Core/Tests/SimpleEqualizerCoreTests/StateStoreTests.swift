import Foundation
import Testing
@testable import SimpleEqualizerCore

/// テストごとに一時的なフォルダを使う。本物の保存先には書き込まない。テストが終わったら消す。
private final class TemporaryDirectory {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("SimpleEqualizerTests-\(UUID().uuidString)")

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}

private func write(_ text: String, to store: StateStore) throws {
    try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
    try Data(text.utf8).write(to: store.fileURL)
}

@Suite("状態の初期値")
struct AppStateTests {
    @Test("初めて使う出力先は、音量 100、消音なし")
    func unknownOutputUsesDefaults() {
        let settings = AppState().settings(forOutput: "初めての装置")
        #expect(settings == OutputSettings(volume: 100, muted: false))
        #expect(OutputSettings() == OutputSettings(volume: 100, muted: false))
    }

    @Test("覚えている出力先は、その設定を返す")
    func knownOutputReturnsStoredSettings() {
        let state = AppState(outputs: ["装置A": OutputSettings(volume: 55, muted: true)])
        #expect(state.settings(forOutput: "装置A") == OutputSettings(volume: 55, muted: true))
        #expect(state.settings(forOutput: "装置B") == OutputSettings())
    }

    @Test("範囲の外の音量は、30 にする(大きい側へ丸めない。初期値の 100 にもしない)", arguments: [-5.0, 100.5, 150.0, 1e9])
    func outOfRangeVolumeFallsBackToDefault(volume: Double) {
        let state = AppState(outputs: ["装置A": OutputSettings(volume: volume, muted: true)])
        let settings = state.settings(forOutput: "装置A")
        #expect(settings.volume == 30)
        #expect(settings.muted == true)
    }

    @Test("範囲の端の音量は、そのまま使う", arguments: [0.0, 100.0])
    func boundaryVolumeIsKept(volume: Double) {
        let state = AppState(outputs: ["装置A": OutputSettings(volume: volume)])
        #expect(state.settings(forOutput: "装置A").volume == volume)
    }
}

@Suite("状態の保存と読み込み")
struct StateStoreTests {
    @Test("保存して読み込むと、同じ値に戻る")
    func roundTrip() throws {
        let temporary = TemporaryDirectory()
        defer { withExtendedLifetime(temporary) {} }
        let store = StateStore(directory: temporary.url)
        let state = AppState(outputs: [
            "装置A": OutputSettings(volume: 42, muted: true),
            "装置B": OutputSettings(volume: 7.5, muted: false),
        ])
        try store.save(state)
        let result = store.load()
        #expect(result.state == state)
        #expect(result.brokenFileBackup == nil)
    }

    @Test("ファイルがないときは、初期値になる")
    func missingFileGivesDefaults() {
        let temporary = TemporaryDirectory()
        defer { withExtendedLifetime(temporary) {} }
        let store = StateStore(directory: temporary.url)
        let result = store.load()
        #expect(result.state == AppState())
        #expect(result.brokenFileBackup == nil)
        #expect(!FileManager.default.fileExists(atPath: store.directory.path), "読み込みだけでフォルダを作らない")
    }

    @Test("保存先のフォルダがなければ作る")
    func saveCreatesDirectory() throws {
        let temporary = TemporaryDirectory()
        defer { withExtendedLifetime(temporary) {} }
        let directory = temporary.url.appendingPathComponent("深い/フォルダ")
        let store = StateStore(directory: directory)
        try store.save(AppState())
        #expect(FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    @Test("保存したファイルは、版の番号つきの JSON になる")
    func savedFileIsVersionedJSON() throws {
        let temporary = TemporaryDirectory()
        defer { withExtendedLifetime(temporary) {} }
        let store = StateStore(directory: temporary.url)
        try store.save(AppState(outputs: ["装置A": OutputSettings(volume: 42, muted: true)]))
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: store.fileURL)) as? [String: Any]
        #expect(object?["version"] as? Int == 1)
        let output = (object?["outputs"] as? [String: Any])?["装置A"] as? [String: Any]
        #expect(output?["volume"] as? Double == 42)
        #expect(output?["muted"] as? Bool == true)
    }

    @Test("上書きして保存できる")
    func saveOverwrites() throws {
        let temporary = TemporaryDirectory()
        defer { withExtendedLifetime(temporary) {} }
        let store = StateStore(directory: temporary.url)
        try store.save(AppState(outputs: ["装置A": OutputSettings(volume: 10)]))
        try store.save(AppState(outputs: ["装置A": OutputSettings(volume: 80)]))
        #expect(store.load().state.settings(forOutput: "装置A").volume == 80)
    }

    @Test("壊れたファイルは別名で残し、初期値になる", arguments: [
        "これは JSON ではない",
        "",
        "{ \"version\": 1, \"outputs\": ",
        "[1, 2, 3]",
        "{ \"version\": 1, \"outputs\": \"なし\" }",
    ])
    func brokenFileIsKeptAside(content: String) throws {
        let temporary = TemporaryDirectory()
        defer { withExtendedLifetime(temporary) {} }
        let store = StateStore(directory: temporary.url)
        try write(content, to: store)
        let result = store.load()
        #expect(result.state == AppState.recovered)
        let backup = try #require(result.brokenFileBackup)
        #expect(try String(contentsOf: backup, encoding: .utf8) == content, "元の中身が残っている")
        #expect(backup.lastPathComponent != StateStore.fileName)
        #expect(!FileManager.default.fileExists(atPath: store.fileURL.path), "壊れたファイルは元の場所に残さない")
    }

    @Test("壊れたファイルを残したあと、保存し直せる")
    func canSaveAfterBrokenFile() throws {
        let temporary = TemporaryDirectory()
        defer { withExtendedLifetime(temporary) {} }
        let store = StateStore(directory: temporary.url)
        try write("壊れている", to: store)
        _ = store.load()
        try store.save(AppState(outputs: ["装置A": OutputSettings(volume: 20)]))
        #expect(store.load().state.settings(forOutput: "装置A").volume == 20)
    }

    @Test("項目が足りないファイルは、音量 30、消音なしで補う(書いてあるのに足りないものは、安全な側にする)")
    func missingFieldsUseDefaults() throws {
        let temporary = TemporaryDirectory()
        defer { withExtendedLifetime(temporary) {} }
        let store = StateStore(directory: temporary.url)
        try write("{ \"outputs\": { \"装置A\": {}, \"装置B\": { \"muted\": true } } }", to: store)
        let result = store.load()
        #expect(result.brokenFileBackup == nil)
        #expect(result.state.version == 1)
        #expect(result.state.settings(forOutput: "装置A") == OutputSettings(volume: 30, muted: false))
        #expect(result.state.settings(forOutput: "装置B") == OutputSettings(volume: 30, muted: true))
    }

    @Test("出力先の項目がないファイルを読める")
    func missingOutputsIsEmpty() throws {
        let temporary = TemporaryDirectory()
        defer { withExtendedLifetime(temporary) {} }
        let store = StateStore(directory: temporary.url)
        try write("{ \"version\": 1 }", to: store)
        let result = store.load()
        #expect(result.brokenFileBackup == nil)
        #expect(result.state == AppState())
    }

    @Test("知らない項目があるファイルを読める")
    func unknownFieldsAreIgnored() throws {
        let temporary = TemporaryDirectory()
        defer { withExtendedLifetime(temporary) {} }
        let store = StateStore(directory: temporary.url)
        try write("""
            { "version": 1, "あとで足す項目": [1, 2],
              "outputs": { "装置A": { "volume": 64, "muted": false, "別の項目": "x" } } }
            """, to: store)
        let result = store.load()
        #expect(result.brokenFileBackup == nil)
        #expect(result.state.settings(forOutput: "装置A").volume == 64)
    }

    @Test("範囲の外の音量が書かれたファイルは、30 として読む")
    func outOfRangeVolumeInFile() throws {
        let temporary = TemporaryDirectory()
        defer { withExtendedLifetime(temporary) {} }
        let store = StateStore(directory: temporary.url)
        try write("{ \"version\": 1, \"outputs\": { \"装置A\": { \"volume\": 999, \"muted\": false } } }", to: store)
        let result = store.load()
        #expect(result.brokenFileBackup == nil)
        #expect(result.state.settings(forOutput: "装置A").volume == 30)
    }

    @Test("本物の保存先は、Application Support の SimpleEqualizer フォルダ")
    func defaultDirectoryLocation() {
        let path = StateStore.defaultDirectory.path
        #expect(path.hasSuffix("/Library/Application Support/SimpleEqualizer"))
    }

    // MARK: - 見直しで足したテスト

    @Test("範囲の外の音量は、読み込んだ時点で 30 に直す(そのまま保存し直しても残らない)")
    func outOfRangeVolumeIsFixedOnLoad() throws {
        let temporary = TemporaryDirectory()
        defer { withExtendedLifetime(temporary) {} }
        let store = StateStore(directory: temporary.url)
        try write("{ \"version\": 1, \"outputs\": { \"装置A\": { \"volume\": 999, \"muted\": true } } }", to: store)
        let loaded = store.load().state
        #expect(loaded.outputs["装置A"] == OutputSettings(volume: 30, muted: true))
        try store.save(loaded)
        #expect(try String(contentsOf: store.fileURL, encoding: .utf8).contains("999") == false)
    }

    @Test("数でない音量が入っていても保存でき、30 として書く", arguments: [Double.nan, .infinity, -.infinity])
    func nonFiniteVolumeIsSavedAsDefault(volume: Double) throws {
        let temporary = TemporaryDirectory()
        defer { withExtendedLifetime(temporary) {} }
        let store = StateStore(directory: temporary.url)
        try store.save(AppState(outputs: [
            "装置A": OutputSettings(volume: volume, muted: true),
            "装置B": OutputSettings(volume: 60),
        ]))
        let loaded = store.load().state
        #expect(loaded.outputs["装置A"] == OutputSettings(volume: 30, muted: true))
        #expect(loaded.outputs["装置B"] == OutputSettings(volume: 60))
    }

    @Test("読めない出力先が1件あっても、ほかの出力先は読める")
    func oneBadOutputDoesNotAffectOthers() throws {
        let temporary = TemporaryDirectory()
        defer { withExtendedLifetime(temporary) {} }
        let store = StateStore(directory: temporary.url)
        try write("""
            { "version": 1, "outputs": {
                "装置A": { "volume": "大きい", "muted": true },
                "装置B": { "volume": 64, "muted": true },
                "装置C": 5 } }
            """, to: store)
        let result = store.load()
        #expect(result.status == .loaded)
        #expect(result.state.settings(forOutput: "装置A") == OutputSettings(volume: 30, muted: true))
        #expect(result.state.settings(forOutput: "装置B") == OutputSettings(volume: 64, muted: true))
        // 読めなかった出力先も、初めて使う出力先(音量 100)としては扱わない。
        #expect(result.state.settings(forOutput: "装置C") == OutputSettings(volume: 30, muted: false))
        #expect(result.state.settings(forOutput: "載っていない装置") == OutputSettings(volume: 100, muted: false))
    }

    @Test("読み込みの結果の種類が分かる")
    func loadStatus() throws {
        let temporary = TemporaryDirectory()
        defer { withExtendedLifetime(temporary) {} }
        let store = StateStore(directory: temporary.url)
        #expect(store.load().status == .noFile)
        #expect(store.load().isSafeToSave)

        try store.save(AppState())
        #expect(store.load().status == .loaded)
        #expect(store.load().isSafeToSave)

        try write("壊れている", to: store)
        let broken = store.load()
        let backup = try #require(broken.brokenFileBackup)
        #expect(broken.status == .brokenFileMovedAside(backup))
        #expect(broken.isSafeToSave)
    }

    @Test("新しい版のファイルは読まず、触らず、上書きもさせない")
    func newerVersionIsLeftAlone() throws {
        let temporary = TemporaryDirectory()
        defer { withExtendedLifetime(temporary) {} }
        let store = StateStore(directory: temporary.url)
        let content = "{ \"version\": 2, \"outputs\": { \"装置A\": { \"volume\": 80 } }, \"新しい項目\": true }"
        try write(content, to: store)
        let result = store.load()
        #expect(result.status == .unsupportedVersion(2))
        #expect(result.state == AppState.recovered)
        #expect(!result.isSafeToSave)
        #expect(try String(contentsOf: store.fileURL, encoding: .utf8) == content)
    }

    @Test("版の番号が整数として読めないファイルは、新しい版かもしれないので、触らず、上書きもさせない",
          arguments: ["1.5", "\"2\"", "1e30", "true", "\"一\""])
    func oddVersionIsLeftAlone(version: String) throws {
        let temporary = TemporaryDirectory()
        defer { withExtendedLifetime(temporary) {} }
        let store = StateStore(directory: temporary.url)
        let content = "{ \"version\": \(version), \"outputs\": { \"装置A\": { \"volume\": 80 } } }"
        try write(content, to: store)
        let result = store.load()
        #expect(result.status == .unreadable)
        #expect(result.state == AppState.recovered)
        #expect(!result.isSafeToSave)
        #expect(try String(contentsOf: store.fileURL, encoding: .utf8) == content)
    }

    @Test("版の番号がないファイルは、版 1 として読む")
    func missingVersionIsVersionOne() throws {
        let temporary = TemporaryDirectory()
        defer { withExtendedLifetime(temporary) {} }
        let store = StateStore(directory: temporary.url)
        try write("{ \"outputs\": { \"装置A\": { \"volume\": 80 } } }", to: store)
        let result = store.load()
        #expect(result.status == .loaded)
        #expect(result.state.settings(forOutput: "装置A").volume == 80)
    }

    @Test("あるのに読めないファイルは、ないものとして扱わない(初期値で上書きさせない)")
    func unreadableFileIsNotTreatedAsMissing() throws {
        let temporary = TemporaryDirectory()
        defer { withExtendedLifetime(temporary) {} }
        let store = StateStore(directory: temporary.url)
        try store.save(AppState(outputs: ["装置A": OutputSettings(volume: 80)]))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: store.fileURL.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: store.fileURL.path) }
        let result = store.load()
        #expect(result.status == .unreadable)
        #expect(result.state == AppState.recovered)
        #expect(!result.isSafeToSave)
    }

    @Test("壊れたファイルを別名にできなかったときは、そのことが分かる(上書きさせない)")
    func brokenFileThatCannotBeMoved() throws {
        let temporary = TemporaryDirectory()
        defer { withExtendedLifetime(temporary) {} }
        let store = StateStore(directory: temporary.url)
        try write("壊れている", to: store)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: store.directory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: store.directory.path) }
        let result = store.load()
        #expect(result.status == .brokenFileLeftInPlace)
        #expect(result.state == AppState.recovered)
        #expect(result.brokenFileBackup == nil)
        #expect(!result.isSafeToSave)
        #expect(try String(contentsOf: store.fileURL, encoding: .utf8) == "壊れている")
    }
}

@Suite("前の設定を読めなかったときの説明")
struct StateLoadProblemTests {
    private func result(_ status: StateStore.LoadStatus) -> StateStore.LoadResult {
        StateStore.LoadResult(state: .recovered, status: status)
    }

    @Test("問題なく読めたとき、ファイルがまだないときは、説明を出さない")
    func noProblem() {
        #expect(result(.loaded).problem == nil)
        #expect(result(.noFile).problem == nil)
    }

    @Test("読めなかったときは、音量 30 で始めたことを伝える", arguments: [
        StateStore.LoadStatus.brokenFileMovedAside(URL(fileURLWithPath: "/tmp/state.broken.json")),
        .brokenFileLeftInPlace, .unreadable, .unsupportedVersion(2),
    ])
    func mentionsFallbackVolume(status: StateStore.LoadStatus) throws {
        #expect(text(try #require(result(status).problem), "ja").contains("音量 30"))
    }

    @Test("別名で残したときは、残したことを伝える。保存はする")
    func movedAside() throws {
        let message = text(try #require(result(.brokenFileMovedAside(URL(fileURLWithPath: "/tmp/a.json"))).problem), "ja")
        #expect(message.contains("別名で残して"))
        #expect(!message.contains("保存しません"))
    }

    @Test("上書きさせないときは、保存しないことを伝える", arguments: [
        StateStore.LoadStatus.brokenFileLeftInPlace, .unreadable, .unsupportedVersion(2),
    ])
    func notSaving(status: StateStore.LoadStatus) throws {
        #expect(text(try #require(result(status).problem), "ja").contains("保存しません"))
    }

    @Test("新しい版のファイルのときは、そのことを伝える")
    func newerVersion() throws {
        #expect(text(try #require(result(.unsupportedVersion(2)).problem), "ja").contains("新しい版"))
    }
}

@Suite("前の設定が読めなかったときの状態")
struct RecoveredStateTests {
    @Test("前の設定が読めなかったときは、どの出力先も音量 30 で始める(前に小さくしていたかもしれないので、100 にしない)")
    func recoveredStateUsesFallbackVolume() {
        let state = AppState.recovered
        #expect(state.settings(forOutput: "装置A") == OutputSettings(volume: 30, muted: false))
        #expect(state.settings(forOutput: "装置A").gain == VolumeCurve.gain(forVolume: 30))
    }

    @Test("設定のファイルがまだないとき(初めての起動)は、音量 100 で始める")
    func freshStateUsesDefaultVolume() {
        #expect(AppState().settings(forOutput: "装置A") == OutputSettings(volume: 100, muted: false))
    }

    @Test("読めなかったあとでも、書き換えた出力先は、その値を使う")
    func recoveredStateKeepsNewSettings() {
        var state = AppState.recovered
        state.setSettings(OutputSettings(volume: 70), forOutput: "装置A")
        #expect(state.settings(forOutput: "装置A").volume == 70)
        #expect(state.settings(forOutput: "装置B").volume == 30)
    }

    @Test("読めなかったことは、保存しても残らない(保存し直したあとの起動では、初めての出力先は 100)")
    func recoveredFlagIsNotSaved() throws {
        let temporary = TemporaryDirectory()
        defer { withExtendedLifetime(temporary) {} }
        let store = StateStore(directory: temporary.url)
        var state = AppState.recovered
        state.setSettings(OutputSettings(volume: 70), forOutput: "装置A")
        try store.save(state)
        let loaded = store.load().state
        #expect(loaded.settings(forOutput: "装置A").volume == 70)
        #expect(loaded.settings(forOutput: "装置B").volume == 100)
    }
}

@Suite("状態の書き換え")
struct AppStateUpdateTests {
    @Test("出力先の設定を書き換えられる")
    func updateStoresSettings() {
        var state = AppState()
        state.setSettings(OutputSettings(volume: 45, muted: true), forOutput: "装置A")
        #expect(state.outputs["装置A"] == OutputSettings(volume: 45, muted: true))
    }

    @Test("書き換えるとき、範囲の外の音量は近い端に丸める", arguments: [(-5.0, 0.0), (150.0, 100.0)])
    func updateClampsVolume(volume: Double, expected: Double) {
        var state = AppState()
        state.setSettings(OutputSettings(volume: volume), forOutput: "装置A")
        #expect(state.outputs["装置A"]?.volume == expected)
    }

    @Test("書き換えるとき、数でない音量は 30 にする")
    func updateRejectsNotANumber() {
        var state = AppState()
        state.setSettings(OutputSettings(volume: .nan), forOutput: "装置A")
        #expect(state.outputs["装置A"]?.volume == 30)
    }
}

@Suite("出力先の設定から倍率を決める")
struct OutputSettingsGainTests {
    @Test("消音していなければ、音量の換算どおりの倍率")
    func gainFollowsVolume() {
        #expect(OutputSettings(volume: 100, muted: false).gain == 1)
        #expect(OutputSettings(volume: 50, muted: false).gain == VolumeCurve.gain(forVolume: 50))
        #expect(OutputSettings(volume: 0, muted: false).gain == 0)
    }

    @Test("消音しているときは、音量に関係なく倍率 0", arguments: [0.0, 30.0, 100.0])
    func mutedIsSilent(volume: Double) {
        #expect(OutputSettings(volume: volume, muted: true).gain == 0)
    }

    @Test("壊れた音量では、30 の倍率にする(大きい側へ丸めない)", arguments: [999.0, -5.0, .nan, .infinity])
    func brokenVolumeUsesDefault(volume: Double) {
        #expect(OutputSettings(volume: volume, muted: false).gain == VolumeCurve.gain(forVolume: 30))
    }
}

