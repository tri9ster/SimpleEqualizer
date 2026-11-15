import CoreAudio
import Foundation
import SimpleEqualizerCore

/// Core Audio から、出力先(音を出す装置)の情報を読む。音は出さない。
/// 設定を変えるのは、利用者が選んだ装置を macOS の出力先にする `setDefaultOutput` だけ。
/// 読んだ情報から決まる判断(音量調整が有効か、扱えるか、など)は、`Core/` の `OutputDevice` にある。
@MainActor
enum OutputDevices {
    /// 出力先1つ。`id` は、いまの macOS の中での番号(抜き差しで変わることがある)。変わらない識別子は `device.uid`。
    struct Entry {
        let id: AudioObjectID
        let device: OutputDevice
        /// macOS の出力先になれるか(macOS のサウンドの一覧に出るか)。プルダウンの一覧を絞るのにだけ使う。
        /// 加工の対象は、これで絞らない(いまの出力先が、なれないと答えても、加工を止めないため)。
        let canBeDefault: Bool
    }

    /// いまある出力先の一覧。`ownAggregates` は、アプリが音を取り出すために自分で作った集約装置(出力先の候補にしない)。
    static func all(excluding ownAggregates: Set<AudioObjectID>) -> [Entry] {
        objects(AudioObjectID(kAudioObjectSystemObject), address(kAudioHardwarePropertyDevices))
            .filter { !ownAggregates.contains($0) }
            .compactMap(entry)
    }

    /// macOS の、いまの出力先。
    static func defaultOutputID() -> AudioObjectID {
        value(AudioObjectID(kAudioObjectSystemObject), address(kAudioHardwarePropertyDefaultOutputDevice), AudioObjectID(0))
            ?? AudioObjectID(kAudioObjectUnknown)
    }

    /// macOS の出力先を、その装置に切り替える(利用者がポップアップで選んだとき)。切り替えられたら true。
    /// アプリの経路は、ここでは触らない。macOS からの知らせ(`OutputWatcher`)で、ほかの切り替え方と同じように合わせる。
    static func setDefaultOutput(_ id: AudioObjectID) -> Bool {
        var address = address(kAudioHardwarePropertyDefaultOutputDevice)
        var id = id
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, UInt32(MemoryLayout<AudioObjectID>.size), &id)
        return status == noErr
    }

    /// UID から、いまの装置の番号を引く(番号は抜き差しで変わるため、使う直前に引く)。見つからないときは nil。
    static func deviceID(forUID uid: String) -> AudioObjectID? {
        var address = address(kAudioHardwarePropertyTranslateUIDToDevice)
        var uid = uid as CFString
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &uid) {
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject), &address, UInt32(MemoryLayout<CFString>.size), $0, &size, &id)
        }
        return status == noErr && id != kAudioObjectUnknown ? id : nil
    }

    /// いまある装置の番号の一覧(出力先でないものも含む)。読めなかったときは、空。
    static func deviceIDs() -> [AudioObjectID] {
        objects(AudioObjectID(kAudioObjectSystemObject), address(kAudioHardwarePropertyDevices))
    }

    /// 装置の番号の一覧と、いまの出力先の番号。前に見たときから変わったかを、少ない手間で確かめるのに使う。
    static func signature() -> [AudioObjectID] {
        deviceIDs() + [defaultOutputID()]
    }

    /// 装置の情報を読む。出力のストリームを持たない装置(マイクなど)、識別子を読めない装置は nil。
    private static func entry(_ id: AudioObjectID) -> Entry? {
        let output = kAudioObjectPropertyScopeOutput
        let streams = objects(id, address(kAudioDevicePropertyStreams, output))
        guard !streams.isEmpty, let uid = string(id, kAudioDevicePropertyDeviceUID) else { return nil }
        let format = value(streams[0], address(kAudioStreamPropertyVirtualFormat), AudioStreamBasicDescription())
        let device = OutputDevice(
            uid: uid,
            name: string(id, kAudioObjectPropertyName) ?? String(localized: "(名前のない装置)"),
            canSetVolume: canSetVolume(id),
            outputStreamCount: streams.count,
            channelCount: Int(format?.mChannelsPerFrame ?? 0),
            sampleRate: value(id, address(kAudioDevicePropertyNominalSampleRate), Float64(0)) ?? 0)
        // 読めなかったときは、なれるものとして扱う(一覧に出す)。
        let canBeDefault = value(id, address(kAudioDevicePropertyDeviceCanBeDefaultDevice, output), UInt32(1)) != 0
        return Entry(id: id, device: device, canBeDefault: canBeDefault)
    }

    /// 装置が、自分で音量を変えられるか(macOS の音量調整が効くか)。
    /// 全体の音量、左右のチャンネルごとの音量、macOS のメニューバーの音量が使う値('vmvc')のどれかを変えられれば、変えられるとする。
    /// 値があるのに、変えられるかを読めなかったときは、見分けられない(nil)。
    /// 調べ方は `docs/research/OutputDevices_Survey.md`。
    private static func canSetVolume(_ id: AudioObjectID) -> Bool? {
        let scope = kAudioObjectPropertyScopeOutput
        let candidates = [
            address(kAudioDevicePropertyVolumeScalar, scope, 0),
            address(kAudioDevicePropertyVolumeScalar, scope, 1),
            address(kAudioDevicePropertyVolumeScalar, scope, 2),
            address(0x766D_7663, scope, 0),
        ]
        var isUnknown = false
        for candidate in candidates {
            var candidate = candidate
            guard AudioObjectHasProperty(id, &candidate) else { continue }
            var settable: DarwinBoolean = false
            if AudioObjectIsPropertySettable(id, &candidate, &settable) != noErr {
                isUnknown = true
            } else if settable.boolValue {
                return true
            }
        }
        return isUnknown ? nil : false
    }

    // MARK: - Core Audio の値の読み取り

    static func address(
        _ selector: AudioObjectPropertySelector,
        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func value<T>(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, _ initial: T) -> T? {
        var address = address
        var result = initial
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &result) {
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0)
        }
        return status == noErr ? result : nil
    }

    private static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = address(selector)
        var result: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &result) == noErr, let result else {
            return nil
        }
        return result.takeRetainedValue() as String
    }

    private static func objects(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> [AudioObjectID] {
        var address = address
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var items = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &items) == noErr else { return [] }
        return Array(items.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }
}

/// 出力先の変化(いまの出力先が変わった、装置が増えた・減った)の知らせを受ける。
/// 知らせは、同じものが続けて来ることがあり、アプリが自分で集約装置を作ったときにも来る。
/// 受ける側は、何度呼ばれても同じ結果になるように作る。
@MainActor
final class OutputWatcher {
    private let onChange: @MainActor () -> Void
    private var isStarted = false

    init(onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        for selector in [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDevices] {
            var address = OutputDevices.address(selector)
            let onChange = onChange
            // 知らせは、メインのキューで受ける。アプリが動いている間、ずっと受けるので、外さない。
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main) { _, _ in
                MainActor.assumeIsolated { onChange() }
            }
        }
    }
}
