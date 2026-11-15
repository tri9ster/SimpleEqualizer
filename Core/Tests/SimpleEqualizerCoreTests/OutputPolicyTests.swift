import Foundation
import Testing
@testable import SimpleEqualizerCore

private func device(
    canSetVolume: Bool? = false, outputStreams: Int = 1, channels: Int = 2, sampleRate: Double = 48000
) -> OutputDevice {
    OutputDevice(
        uid: "装置", name: "テストの装置", canSetVolume: canSetVolume, outputStreamCount: outputStreams,
        channelCount: channels, sampleRate: sampleRate)
}

private func boosted(_ gain: Double, at band: Int = 3) -> EqualizerSettings {
    var settings = EqualizerSettings()
    settings.setGain(gain, at: band)
    return settings
}

@Suite("出力先ごとの判断: 音量調整")
struct VolumeControlPolicyTests {
    @Test("自分で音量を変えられない装置では、アプリの音量調整が有効")
    func enabledForFixedVolumeDevice() {
        #expect(device(canSetVolume: false).isVolumeControlEnabled)
    }

    @Test("自分で音量を変えられる装置では、アプリの音量調整は無効(音量が二重に掛からないようにする)")
    func disabledForAdjustableDevice() {
        #expect(!device(canSetVolume: true).isVolumeControlEnabled)
    }

    @Test("見分けられない装置では、有効として扱う(音量を変えられない装置から、最大音量が出るのを防ぐ)")
    func enabledWhenUnknown() {
        #expect(device(canSetVolume: nil).isVolumeControlEnabled)
    }

    @Test("経路を持ったままにするのは、音量調整が有効な装置(出力先でないあいだも、加工を続ける)")
    func keepsPathForVolumeControlledDevices() {
        #expect(device(canSetVolume: false).keepsPathWhileNotDefault)
        #expect(device(canSetVolume: nil).keepsPathWhileNotDefault)
        #expect(!device(canSetVolume: true).keepsPathWhileNotDefault)
    }

    @Test("ラウドネスを使えるのは、音量調整が有効な装置だけ")
    func loudnessAvailability() {
        #expect(device(canSetVolume: false).isLoudnessAvailable)
        #expect(!device(canSetVolume: true).isLoudnessAvailable)
    }
}

@Suite("出力先ごとの判断: 扱える出力先か")
struct OutputSupportTests {
    @Test("確かめてある形(出力 1 本、2 チャンネル)は、扱える", arguments: [44100.0, 48000, 96000])
    func supportsVerifiedShape(rate: Double) {
        #expect(device(sampleRate: rate).unsupportedReason == nil)
    }

    @Test("出力が 1 本でない装置は、扱わない", arguments: [0, 2, 4])
    func rejectsOtherStreamCounts(count: Int) {
        #expect(device(outputStreams: count).unsupportedReason != nil)
    }

    @Test("チャンネル数が 2 でない装置は、扱わない(確かめていないため)", arguments: [0, 1, 6, 8, 9])
    func rejectsOtherChannelCounts(count: Int) {
        #expect(device(channels: count).unsupportedReason != nil)
    }

    @Test("周波数が読めない装置は、扱わない", arguments: [0.0, -1, .nan, .infinity])
    func rejectsInvalidSampleRate(rate: Double) {
        #expect(device(sampleRate: rate).unsupportedReason != nil)
    }

    @Test("扱わない理由は、種類で見分けられる")
    func reasonsAreDistinguishable() {
        #expect(device(outputStreams: 2).unsupportedReason == .streamCount(2))
        #expect(device(channels: 6).unsupportedReason == .channelCount(6))
        #expect(device(sampleRate: 0).unsupportedReason == .unknownSampleRate)
    }

    @Test("扱わない理由は、画面に出せる文になる")
    func reasonsAreReadable() {
        #expect(text(OutputDevice.UnsupportedReason.channelCount(6).message, "ja").contains("6"))
        #expect(!text(OutputDevice.UnsupportedReason.streamCount(2).message, "ja").isEmpty)
        #expect(!text(OutputDevice.UnsupportedReason.unknownSampleRate.message, "ja").isEmpty)
    }
}

@Suite("イコライザーで増幅する量の見積もり")
struct EstimatedPeakGainTests {
    private func settings(_ gains: [Double]) -> EqualizerSettings {
        EqualizerSettings(storedGains: gains)!
    }

    @Test("フラットなら 0")
    func flat() {
        #expect(EqualizerSettings().estimatedPeakGainDb == 0)
    }

    @Test("1つのバンドだけを上げているときは、その量")
    func singleBand() {
        #expect(boosted(6).estimatedPeakGainDb == 6)
        #expect(boosted(10, at: 0).estimatedPeakGainDb == 10)
        #expect(boosted(10, at: 9).estimatedPeakGainDb == 10)
    }

    @Test("下げているだけなら 0(負の値にしない)")
    func cutsOnly() {
        #expect(boosted(-6).estimatedPeakGainDb == 0)
        #expect(settings([Double](repeating: -10, count: 10)).estimatedPeakGainDb == 0)
    }

    @Test("となりのバンドも上げていると、山が重なって、1つのバンドの量より大きくなる(本物のエンジンで測った値)", arguments: [
        ([0.0, 0, 0, 0, 0, 10, 10, 0, 0, 0], 12.0),
        ([0.0, 0, 0, 0, 0, 10, 10, 10, 0, 0], 14.0),
        ([Double](repeating: 10, count: 10), 15.75),
        ([Double](repeating: 5, count: 10), 7.875),
        ([10.0, 10, 10, 0, 0, 0, 0, 0, 0, 0], 14.0),
        // いちばん高い2つのバンドは、重なりが大きい。
        ([0.0, 0, 0, 0, 0, 0, 0, 0, 10, 10], 13.0),
        ([0.0, 0, 0, 0, 0, 0, 0, 10, 10, 10], 15.0),
    ])
    func overlappingBands(gains: [Double], expected: Double) {
        #expect(abs(settings(gains).estimatedPeakGainDb - expected) < 0.01)
    }

    @Test("となりのバンドを下げていると、そのぶん小さくなる")
    func neighbouringCut() {
        #expect(abs(settings([0, 0, 0, 0, 0, 10, -10, 0, 0, 0]).estimatedPeakGainDb - 8) < 0.01)
    }

    @Test("両どなりを大きく下げていると、山が削られて、さらに小さくなる")
    func cutsOnBothSides() {
        #expect(abs(settings([-10, 10, -10, 0, 0, 0, 0, 0, 0, 0]).estimatedPeakGainDb - 6) < 0.01)
    }

    @Test("見積もりは、負の値にも、数でない値にもならない")
    func alwaysNonNegative() {
        for gains in [[-10.0, -10, 3, 0, 0, 0, 0, 0, 0, 0], [Double](repeating: -10, count: 10), [0.0, 0, 0, 0, 0, 0.5, -10, 0, 0, 0]] {
            let estimate = settings(gains).estimatedPeakGainDb
            #expect(estimate >= 0)
            #expect(estimate.isFinite)
        }
    }
}

@Suite("出力先ごとの判断: 増幅した分を、自動で下げる量")
struct AutoAttenuationTests {
    private let adjustable = device(canSetVolume: true)
    private let fixed = device(canSetVolume: false)

    @Test("音量調整が無効の装置で、上げているバンドがあるときは、その分だけ下げる")
    func attenuatesByMaximumBoost() {
        #expect(adjustable.autoAttenuationDb(equalizer: boosted(6), equalizerEnabled: true, autoLowerEnabled: true) == 6)
    }

    @Test("となりのバンドも上げているときは、重なった分も下げる")
    func attenuatesOverlap() {
        var settings = boosted(10, at: 5)
        settings.setGain(10, at: 6)
        #expect(adjustable.autoAttenuationDb(equalizer: settings, equalizerEnabled: true, autoLowerEnabled: true) == 12)
    }

    @Test("下げるだけの設定、フラットな設定では、下げない")
    func noAttenuationWithoutBoost() {
        #expect(adjustable.autoAttenuationDb(equalizer: boosted(-6), equalizerEnabled: true, autoLowerEnabled: true) == 0)
        #expect(adjustable.autoAttenuationDb(equalizer: .flat, equalizerEnabled: true, autoLowerEnabled: true) == 0)
    }

    @Test("イコライザーが切のときは、下げない(増幅していないため)")
    func noAttenuationWhenEqualizerDisabled() {
        #expect(adjustable.autoAttenuationDb(equalizer: boosted(6), equalizerEnabled: false, autoLowerEnabled: true) == 0)
    }

    @Test("自動で下げる設定が切のときは、下げない")
    func noAttenuationWhenSettingOff() {
        #expect(adjustable.autoAttenuationDb(equalizer: boosted(6), equalizerEnabled: true, autoLowerEnabled: false) == 0)
    }

    @Test("音量調整が有効の装置では、下げない(音量を下げていれば、増幅しても上限を超えないため)")
    func noAttenuationForVolumeControlledDevice() {
        #expect(fixed.autoAttenuationDb(equalizer: boosted(10), equalizerEnabled: true, autoLowerEnabled: true) == 0)
    }
}

@Suite("出力先ごとの判断: 音に掛ける倍率とラウドネス")
struct OutputGainTests {
    private let adjustable = device(canSetVolume: true)
    private let fixed = device(canSetVolume: false)
    private let quiet = OutputSettings(volume: 50, muted: false)

    @Test("音量調整が有効の装置では、覚えている音量と消音から、倍率を決める")
    func usesStoredVolume() {
        #expect(fixed.gain(settings: quiet, attenuationDb: 0) == quiet.gain)
        #expect(fixed.gain(settings: OutputSettings(volume: 50, muted: true), attenuationDb: 0) == 0)
    }

    @Test("音量調整が無効の装置では、覚えている音量と消音を使わず、倍率は 1(元の音量のまま)")
    func ignoresStoredVolumeWhenDisabled() {
        #expect(adjustable.gain(settings: quiet, attenuationDb: 0) == 1)
        #expect(adjustable.gain(settings: OutputSettings(volume: 0, muted: true), attenuationDb: 0) == 1)
    }

    @Test("自動で下げる量があるときは、その分だけ倍率を下げる(6 dB で、ほぼ半分)")
    func appliesAttenuation() {
        #expect(abs(adjustable.gain(settings: quiet, attenuationDb: 6) - 0.5012) < 0.001)
        #expect(abs(adjustable.gain(settings: quiet, attenuationDb: 10) - 0.3162) < 0.001)
    }

    @Test("見分けられない装置では、音量調整が有効の装置と同じに扱う(覚えている音量を掛ける。安全な側)")
    func unknownDeviceIsTreatedAsVolumeControlled() {
        let unknown = device(canSetVolume: nil)
        #expect(unknown.gain(settings: quiet, attenuationDb: 0) == quiet.gain)
        #expect(unknown.loudness(settings: quiet, amount: 100) == quiet.loudness(amount: 100))
        #expect(unknown.interceptsVolumeKeys(isRunning: true, isStalled: false))
        #expect(unknown.autoAttenuationDb(equalizer: boosted(10), equalizerEnabled: true, autoLowerEnabled: true) == 0)
        #expect(unknown.isLoudnessAvailable)
    }

    @Test("下げる量が壊れているときは、音を出さない側に倒す(数でない値、無限大)。負の値は、下げないものとして扱う")
    func brokenAttenuation() {
        #expect(adjustable.gain(settings: quiet, attenuationDb: .nan) == 0)
        #expect(adjustable.gain(settings: quiet, attenuationDb: .infinity) == 0)
        #expect(adjustable.gain(settings: quiet, attenuationDb: -5) == 1)
    }

    @Test("倍率は、いつも 0 以上 1 以下(元の音量を超えない)", arguments: [-5.0, 0, 6, 100, .nan, .infinity])
    func gainStaysInRange(attenuation: Double) {
        for target in [adjustable, fixed] {
            let gain = target.gain(settings: quiet, attenuationDb: attenuation)
            #expect(gain >= 0)
            #expect(gain <= 1)
        }
    }

    @Test("ラウドネスの補正は、音量調整が有効の装置でだけ掛ける")
    func loudnessOnlyForVolumeControlledDevice() {
        #expect(fixed.loudness(settings: quiet, amount: 100) == quiet.loudness(amount: 100))
        #expect(adjustable.loudness(settings: quiet, amount: 100) == .none)
    }

    @Test("音量キーをアプリが受け取るのは、加工していて、止まっておらず、音量調整が有効なときだけ")
    func volumeKeyInterception() {
        #expect(fixed.interceptsVolumeKeys(isRunning: true, isStalled: false))
        #expect(!fixed.interceptsVolumeKeys(isRunning: false, isStalled: false))
        #expect(!fixed.interceptsVolumeKeys(isRunning: true, isStalled: true))
        #expect(!adjustable.interceptsVolumeKeys(isRunning: true, isStalled: false))
    }
}

@Suite("状態: 自動で下げる設定")
struct AutoLowerStateTests {
    private func load(_ text: String) throws -> AppState {
        let store = StateStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("SimpleEqualizerTests-\(UUID().uuidString)"))
        defer { try? FileManager.default.removeItem(at: store.directory) }
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: store.fileURL)
        let result = store.load()
        #expect(result.status == .loaded)
        return result.state
    }

    @Test("初期値は入")
    func defaultIsOn() {
        #expect(AppState().autoLowerEnabled)
        #expect(AppState.recovered.autoLowerEnabled)
    }

    @Test("保存して読み込むと、元に戻る。ファイルでの名前は autoLowerEnabled")
    func roundTrip() throws {
        let store = StateStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("SimpleEqualizerTests-\(UUID().uuidString)"))
        defer { try? FileManager.default.removeItem(at: store.directory) }
        var state = AppState()
        state.autoLowerEnabled = false
        try store.save(state)
        #expect(store.load().state == state)
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: store.fileURL)) as? [String: Any]
        #expect(object?["autoLowerEnabled"] as? Bool == false)
    }

    @Test("項目がない(前の版のファイル)、読めないときは、入にする(音がつぶれない側)", arguments: [
        "", ", \"autoLowerEnabled\": \"いいえ\"", ", \"autoLowerEnabled\": 0", ", \"autoLowerEnabled\": null",
    ])
    func fallsBackToOn(field: String) throws {
        let state = try load("{ \"version\": 1, \"outputs\": { \"装置A\": { \"volume\": 64, \"muted\": false } }\(field) }")
        #expect(state.autoLowerEnabled)
        #expect(state.settings(forOutput: "装置A").volume == 64)
    }

    @Test("切にしたことを読める")
    func readsOff() throws {
        #expect(try !load("{ \"version\": 1, \"outputs\": {}, \"autoLowerEnabled\": false }").autoLowerEnabled)
    }
}

@Suite("状態: 音量キーを使う設定")
struct VolumeKeysStateTests {
    private func load(_ text: String) throws -> AppState {
        let store = StateStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("SimpleEqualizerTests-\(UUID().uuidString)"))
        defer { try? FileManager.default.removeItem(at: store.directory) }
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: store.fileURL)
        let result = store.load()
        #expect(result.status == .loaded)
        return result.state
    }

    @Test("初期値は入(仕様書 5.3)")
    func defaultIsOn() {
        #expect(AppState().volumeKeysEnabled)
        #expect(AppState.recovered.volumeKeysEnabled)
    }

    @Test("保存して読み込むと、元に戻る。ファイルでの名前は volumeKeysEnabled")
    func roundTrip() throws {
        let store = StateStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("SimpleEqualizerTests-\(UUID().uuidString)"))
        defer { try? FileManager.default.removeItem(at: store.directory) }
        var state = AppState()
        state.volumeKeysEnabled = false
        try store.save(state)
        #expect(store.load().state == state)
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: store.fileURL)) as? [String: Any]
        #expect(object?["volumeKeysEnabled"] as? Bool == false)
    }

    @Test("項目がない(前の版のファイル)、読めないときは、入にする。ほかの項目は巻き込まない", arguments: [
        "", ", \"volumeKeysEnabled\": \"いいえ\"", ", \"volumeKeysEnabled\": null",
    ])
    func fallsBackToOn(field: String) throws {
        let state = try load("{ \"version\": 1, \"outputs\": { \"装置A\": { \"volume\": 64, \"muted\": false } }\(field) }")
        #expect(state.volumeKeysEnabled)
        #expect(state.settings(forOutput: "装置A").volume == 64)
    }

    @Test("切にしたことを読める")
    func readsOff() throws {
        #expect(try !load("{ \"version\": 1, \"outputs\": {}, \"volumeKeysEnabled\": false }").volumeKeysEnabled)
    }
}

@Suite("出力先の一覧(ポップアップのプルダウン)")
struct OutputMenuTests {
    private func named(_ name: String, uid: String) -> OutputDevice {
        OutputDevice(uid: uid, name: name, canSetVolume: false, outputStreamCount: 1, channelCount: 2, sampleRate: 48000)
    }

    @Test("名前の順に並べる。同じ名前は UID の順にして、並びが毎回同じになるようにする")
    func sortedByNameThenUID() {
        let devices = [named("B", uid: "2"), named("A", uid: "9"), named("B", uid: "1")]
        #expect(OutputDevice.menuOrder(devices).map(\.uid) == ["9", "1", "2"])
    }
}
