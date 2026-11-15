// この Mac の出力先(音を出せる装置)の一覧と、それぞれが自分で音量を変えられるかを調べる。
// 装置の情報を読むだけで、音は出さない。設定も変えない。
//
// 使い方: swift tools/list-output-devices.swift

import CoreAudio
import Foundation

func address(
    _ selector: AudioObjectPropertySelector,
    _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
    _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
}

func value<T>(_ id: AudioObjectID, _ addr: AudioObjectPropertyAddress, _ initial: T) -> T? {
    var addr = addr
    var result = initial
    var size = UInt32(MemoryLayout<T>.size)
    let status = withUnsafeMutablePointer(to: &result) { AudioObjectGetPropertyData(id, &addr, 0, nil, &size, $0) }
    return status == noErr ? result : nil
}

func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
    var addr = address(selector)
    var result: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &result) == noErr, let result else { return nil }
    return result.takeRetainedValue() as String
}

func list(_ id: AudioObjectID, _ addr: AudioObjectPropertyAddress) -> [AudioObjectID] {
    var addr = addr
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
    var items = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &items) == noErr else { return [] }
    return items
}

/// ある値が、あるか・変えられるか。
func describe(_ id: AudioObjectID, _ addr: AudioObjectPropertyAddress) -> String {
    var addr = addr
    guard AudioObjectHasProperty(id, &addr) else { return "なし" }
    var settable: DarwinBoolean = false
    let status = AudioObjectIsPropertySettable(id, &addr, &settable)
    if status != noErr { return "あり(変えられるかは不明)" }
    return settable.boolValue ? "あり・変えられる" : "あり・変えられない"
}

func fourCC(_ code: UInt32) -> String {
    let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
    return String(bytes: bytes, encoding: .ascii) ?? "\(code)"
}

let transports: [UInt32: String] = [
    kAudioDeviceTransportTypeBuiltIn: "内蔵",
    kAudioDeviceTransportTypeUSB: "USB",
    kAudioDeviceTransportTypeBluetooth: "Bluetooth",
    kAudioDeviceTransportTypeBluetoothLE: "Bluetooth LE",
    kAudioDeviceTransportTypeHDMI: "HDMI",
    kAudioDeviceTransportTypeDisplayPort: "DisplayPort",
    kAudioDeviceTransportTypeAirPlay: "AirPlay",
    kAudioDeviceTransportTypeThunderbolt: "Thunderbolt",
    kAudioDeviceTransportTypeVirtual: "仮想",
    kAudioDeviceTransportTypeAggregate: "集約",
]

let system = AudioObjectID(kAudioObjectSystemObject)
let defaultOutput = value(system, address(kAudioHardwarePropertyDefaultOutputDevice), AudioObjectID(0)) ?? 0
let output = kAudioObjectPropertyScopeOutput

for device in list(system, address(kAudioHardwarePropertyDevices)) {
    let streams = list(device, address(kAudioDevicePropertyStreams, output))
    guard !streams.isEmpty else { continue }
    let name = string(device, kAudioObjectPropertyName) ?? "(名前なし)"
    let transport = value(device, address(kAudioDevicePropertyTransportType), UInt32(0)) ?? 0
    let rate = value(device, address(kAudioDevicePropertyNominalSampleRate), Float64(0)) ?? 0
    let inputStreams = list(device, address(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput))

    print("■ \(name)\(device == defaultOutput ? "  ← いまの出力先" : "")")
    // UID には、装置の製造番号が入ることがある。記録に残さないよう、長さだけを出す。
    print("  UID: \((string(device, kAudioDevicePropertyDeviceUID) ?? "").count) 文字(中身は出さない)")
    print("  つなぎ方: \(transports[transport] ?? fourCC(transport))")
    print("  サンプリング周波数: \(Int(rate)) Hz")
    print("  ストリーム: 出力 \(streams.count) 本 / 入力 \(inputStreams.count) 本")
    for (index, stream) in streams.enumerated() {
        if let format = value(stream, address(kAudioStreamPropertyVirtualFormat), AudioStreamBasicDescription()) {
            let kind = format.mFormatFlags & kAudioFormatFlagIsFloat != 0 ? "浮動小数点" : "整数"
            let layout = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0 ? "チャンネル別" : "交互"
            print("    出力 \(index + 1): \(format.mChannelsPerFrame)ch / \(format.mBitsPerChannel) ビット \(kind) / \(layout) / \(fourCC(format.mFormatID))")
        }
    }
    print("  音量(全体): \(describe(device, address(kAudioDevicePropertyVolumeScalar, output)))")
    print("  音量(チャンネル 1): \(describe(device, address(kAudioDevicePropertyVolumeScalar, output, 1)))")
    print("  音量(チャンネル 2): \(describe(device, address(kAudioDevicePropertyVolumeScalar, output, 2)))")
    print("  消音(全体): \(describe(device, address(kAudioDevicePropertyMute, output)))")
    // macOS のメニューバーの音量が使う値('vmvc')。
    print("  まとめの音量: \(describe(device, address(0x766D_7663, output)))")
    print("")
}
