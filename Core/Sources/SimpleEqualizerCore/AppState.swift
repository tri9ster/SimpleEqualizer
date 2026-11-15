import Foundation

/// 出力先ごとの設定。
public struct OutputSettings: Codable, Equatable, Sendable {
    public var volume: Double
    public var muted: Bool

    public init(volume: Double = VolumeCurve.defaultVolume, muted: Bool = false) {
        self.volume = volume
        self.muted = muted
    }

    private enum CodingKeys: String, CodingKey {
        case volume
        case muted
    }

    /// 読めなかった出力先のかわりに使う設定。
    static let fallback = OutputSettings(volume: VolumeCurve.fallbackVolume, muted: false)

    /// 足りない項目、型が合わない項目は、安全な側の値(音量 30、消音なし)で補う。知らない項目は読み飛ばす。
    /// 書いてあるのに読めないものを、初めて使う出力先(音量 100)と同じには扱わない。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let volume = (try? container.decodeIfPresent(Double.self, forKey: .volume)) ?? nil
        let muted = (try? container.decodeIfPresent(Bool.self, forKey: .muted)) ?? nil
        self.init(volume: volume ?? VolumeCurve.fallbackVolume, muted: muted ?? false)
        self = sanitized
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(sanitized.volume, forKey: .volume)
        try container.encode(muted, forKey: .muted)
    }

    /// 音に掛ける倍率。消音しているときは 0。壊れた音量では、安全な側の音量(30)の倍率にする。
    public var gain: Float {
        muted ? 0 : VolumeCurve.gain(forVolume: sanitized.volume)
    }

    /// ラウドネスの補正量。倍率と同じ音量(壊れた音量では 30)から決める。消音していても、音量の数値で決める
    /// (消音を解いたときに、そのままの音で戻る)。強さ 0 のときは、補正なし。
    public func loudness(amount: Double) -> LoudnessCurve.Correction {
        LoudnessCurve.correction(forVolume: sanitized.volume, amount: amount)
    }

    /// 範囲の外の音量、数でない音量を、安全な側の値(30)に置き換えたもの。
    /// 近い端に丸めない(壊れた値で大きな音を出さないため)。
    var sanitized: OutputSettings {
        var result = self
        if !VolumeCurve.range.contains(volume) {
            result.volume = VolumeCurve.fallbackVolume
        }
        return result
    }
}

/// 前回の状態(`state.json` の中身)。
public struct AppState: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    /// 出力先(装置の UID)ごとの設定。
    public var outputs: [String: OutputSettings]
    /// 前の設定のファイルがあったのに、読めなかったか。ファイルには書かない。
    /// true のあいだは、覚えていない出力先を、初期値の音量 100 ではなく、安全な側の音量 30 で始める。
    /// 前に音量を小さくして使っていたかもしれないため。
    public var isRecovered = false
    /// イコライザーが入か。出力先に共通。
    public var equalizerEnabled = true
    /// イコライザーのいまの値。出力先に共通。
    public var equalizer = EqualizerSettings.flat
    /// ラウドネスの強さ(0〜100)。0 で効かない。出力先に共通。切にしても、強さは覚えておく。
    public var loudnessAmount: Double = 0
    /// ラウドネスが入か。出力先に共通。初期値は入(強さ 0 なら、効かないまま)。
    public var loudnessEnabled = true

    /// 音に掛けるラウドネスの強さ。切なら 0。
    public var effectiveLoudnessAmount: Double {
        loudnessEnabled ? loudnessAmount : 0
    }
    /// 音量調整が無効の出力先で、増幅した分だけ、全体を自動で下げるか。出力先に共通。
    public var autoLowerEnabled = true
    /// キーボードの音量キーを、アプリが受け取るか(音量調整が有効な出力先で)。出力先に共通。初期値は入。
    public var volumeKeysEnabled = true
    /// 選んでいるプリセットの id。`equalizer` は、保存していない変更を含む、いまの値。
    /// 一覧にない id のときは、「フラット」を選んでいるものとする(`PresetLibrary.resolvedSelection`)。
    public var selectedPresetID = Preset.flatID

    private enum CodingKeys: String, CodingKey {
        case version
        case outputs
        case equalizerEnabled
        case equalizerGainsDb
        case loudnessAmount
        case selectedPresetID = "selectedPresetId"
        case autoLowerEnabled
        case volumeKeysEnabled
        /// ラウドネスの入・切。強さ(`loudnessAmount`)がない古いファイルでは、強さの代わりに入・切だけを保存していた。
        case loudnessEnabled
    }

    public init(outputs: [String: OutputSettings] = [:]) {
        self.version = Self.currentVersion
        self.outputs = outputs
    }

    /// 前の設定のファイルが読めなかったときの状態。
    public static var recovered: AppState {
        var state = AppState()
        state.isRecovered = true
        return state
    }

    /// 知らない項目は読み飛ばす。出力先の項目がなければ、出力先を1つも覚えていない状態にする。
    /// イコライザーとラウドネスの項目がなければ(段階2 のアプリが作ったファイル)、初期値にする。
    /// 項目がないときの初期値は、イコライザーは入でフラット、ラウドネスは入で強さ 0(効かない)。
    /// 読めない出力先は、その1件だけを安全な側の値にする(ほかの出力先の設定を巻き込まない)。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = Self.currentVersion
        let entries = try container.decodeIfPresent([String: LenientOutput].self, forKey: .outputs) ?? [:]
        outputs = entries.mapValues { $0.value ?? .fallback }

        // 項目がないとき(段階2 のアプリが作ったファイル)は、初期値(イコライザーは入でフラット、ラウドネスは切)にする。
        // 書いてあるのに読めない入・切は、切にする(切にしていた増幅を、勝手に入れない)。
        // ここが読めなくても、出力先ごとの音量は巻き込まない。
        if container.contains(.equalizerEnabled) {
            equalizerEnabled = (try? container.decode(Bool.self, forKey: .equalizerEnabled)) ?? false
        } else {
            equalizerEnabled = true
        }
        if container.contains(.loudnessAmount) {
            // 書いてあるのに読めない強さ、範囲の外の強さは、0(効かない)にする。
            loudnessAmount = LoudnessCurve.storedAmount(
                (try? container.decode(Double.self, forKey: .loudnessAmount)) ?? 0)
            // 入・切がないとき(この項目を足す前のファイル)は入。書いてあるのに読めないときは、切にする(勝手に入れない)。
            if container.contains(.loudnessEnabled) {
                loudnessEnabled = (try? container.decode(Bool.self, forKey: .loudnessEnabled)) ?? false
            } else {
                loudnessEnabled = true
            }
        } else {
            // 強さがない古いファイル: 入・切を、強さに読み替える。入・切は入にする(いままでの効き方を変えない)。
            let wasEnabled = ((try? container.decodeIfPresent(Bool.self, forKey: .loudnessEnabled)) ?? nil) ?? false
            loudnessAmount = wasEnabled ? LoudnessCurve.legacyEnabledAmount : 0
            loudnessEnabled = true
        }
        let gains = (try? container.decodeIfPresent([Double].self, forKey: .equalizerGainsDb)) ?? nil
        equalizer = gains.flatMap(EqualizerSettings.init(storedGains:)) ?? .flat

        // 項目がない、読めないときは、「フラット」を選んでいるものとする。
        let selected = (try? container.decodeIfPresent(String.self, forKey: .selectedPresetID)) ?? nil
        selectedPresetID = selected.flatMap(UUID.init(uuidString:)) ?? Preset.flatID

        // 項目がない、読めないときは、入にする(下げる側。音がつぶれない)。
        autoLowerEnabled = ((try? container.decodeIfPresent(Bool.self, forKey: .autoLowerEnabled)) ?? nil) ?? true
        // 項目がない、読めないときは、入にする(初期値)。
        volumeKeysEnabled = ((try? container.decodeIfPresent(Bool.self, forKey: .volumeKeysEnabled)) ?? nil) ?? true
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(selectedPresetID.uuidString, forKey: .selectedPresetID)
        try container.encode(autoLowerEnabled, forKey: .autoLowerEnabled)
        try container.encode(volumeKeysEnabled, forKey: .volumeKeysEnabled)
        try container.encode(version, forKey: .version)
        try container.encode(outputs, forKey: .outputs)
        try container.encode(equalizerEnabled, forKey: .equalizerEnabled)
        try container.encode(equalizer.gainsDb, forKey: .equalizerGainsDb)
        try container.encode(LoudnessCurve.storedAmount(loudnessAmount), forKey: .loudnessAmount)
        try container.encode(loudnessEnabled, forKey: .loudnessEnabled)
    }

    /// その出力先の設定。覚えていない出力先では、初期値(音量 100、消音なし)を返す。
    /// ただし、前の設定が読めなかったとき(`isRecovered`)は、音量 30 を返す。
    public func settings(forOutput uid: String) -> OutputSettings {
        if let settings = outputs[uid] {
            return settings.sanitized
        }
        return isRecovered ? .fallback : OutputSettings()
    }

    /// その出力先の設定を書き換える。画面から来る値なので、範囲の外の音量は近い端に丸める。
    /// 数でない値は、安全な側の音量(30)にする。初めて使う出力先の音量(100)にはしない。
    public mutating func setSettings(_ settings: OutputSettings, forOutput uid: String) {
        var settings = settings
        if settings.volume.isNaN {
            settings.volume = VolumeCurve.fallbackVolume
        } else {
            settings.volume = min(max(settings.volume, VolumeCurve.range.lowerBound), VolumeCurve.range.upperBound)
        }
        outputs[uid] = settings
    }

    private struct LenientOutput: Decodable {
        let value: OutputSettings?

        init(from decoder: Decoder) throws {
            value = try? OutputSettings(from: decoder)
        }
    }
}
