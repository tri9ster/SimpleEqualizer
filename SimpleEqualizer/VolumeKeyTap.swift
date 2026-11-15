import AppKit
import ApplicationServices
import SimpleEqualizerCore

/// キーボードの音量キー(上げる、下げる、消音)を受け取る。
///
/// 受け取ったキーは、macOS には渡さない(macOS の音量は変わらず、macOS の音量の表示も出ない)。
/// 受け取るには、「アクセシビリティ」の許可が要る。許可がないと、`install` が失敗する。
/// アプリが止まったり落ちたりすると、受け取りは自動で外れ、キーは macOS に戻る。
@MainActor
final class VolumeKeyTap {
    /// いま、キーをアプリが受け取るべきか。false のときは、キーに触らず、macOS に任せる。
    var isActive: () -> Bool = { false }
    /// キーが押されたときに呼ぶ。`fine` は、細かく変える指定(Option + Shift)。
    var onKey: (_ key: VolumeKey, _ fine: Bool) -> Void = { _, _ in }

    private var port: CFMachPort?
    private var source: CFRunLoopSource?

    var isInstalled: Bool { port != nil }

    /// macOS には、このオブジェクトの場所を渡してある。捨てる前に、受け取りを外す。
    isolated deinit {
        remove()
    }

    /// 「アクセシビリティ」の許可があるか。
    static var hasPermission: Bool { AXIsProcessTrusted() }

    /// 「アクセシビリティ」の許可を求める(macOS の案内が出る)。
    static func requestPermission() {
        // 案内を出す指定の名前(kAXTrustedCheckOptionPrompt の中身)。
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// 受け取りを始める。許可がないなど、始められなかったときは false。
    @discardableResult
    func install() -> Bool {
        guard port == nil else { return true }
        guard let newPort = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(1) << Self.systemDefinedEventType,
            callback: volumeKeyTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque())
        else {
            return false
        }
        // メインスレッドで受け取る。
        let newSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, newPort, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), newSource, .commonModes)
        CGEvent.tapEnable(tap: newPort, enable: true)
        port = newPort
        source = newSource
        return true
    }

    func remove() {
        if let port {
            CGEvent.tapEnable(tap: port, enable: false)
            CFMachPortInvalidate(port)
        }
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        port = nil
        source = nil
    }

    // MARK: - キーの見分け

    /// 音量キーなどの特別なキーが入ってくる、イベントの種類(NX_SYSDEFINED)。
    private static let systemDefinedEventType: UInt32 = 14
    /// 特別なキーを表す、イベントの細かい種類。
    private static let mediaKeySubtype: Int16 = 8
    /// キーの番号(NX_KEYTYPE_SOUND_UP、NX_KEYTYPE_SOUND_DOWN、NX_KEYTYPE_MUTE)。
    private static let keys: [Int: VolumeKey] = [0: .up, 1: .down, 7: .mute]
    /// キーが押された(離されたのではない)ことを表す値。
    private static let keyDownState = 0xA

    /// イベントを調べる。true を返すと、そのイベントを macOS に渡さない。
    /// ここは、キーを押すたびに呼ばれる。すぐに終える(遅いと、macOS が受け取りを止める)。
    fileprivate func process(type: CGEventType, event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // macOS が受け取りを止めた。入れ直す。
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
            return false
        }
        guard type.rawValue == Self.systemDefinedEventType,
              let nsEvent = NSEvent(cgEvent: event),
              nsEvent.subtype.rawValue == Self.mediaKeySubtype
        else {
            return false
        }
        let keyCode = (nsEvent.data1 & 0xFFFF_0000) >> 16
        let isDown = ((nsEvent.data1 & 0xFF00) >> 8) == Self.keyDownState
        guard let key = Self.keys[keyCode], isActive() else { return false }
        // 離したときのイベントも、macOS に渡さない(押したときだけ渡さないと、macOS の側で食い違う)。
        // 押し続けたときの繰り返しは、上げる・下げるでは受けつけ、消音では受けつけない
        // (消音が、入ったり切れたりを繰り返さないようにする)。
        let isRepeat = (nsEvent.data1 & 0x1) != 0
        if isDown, !(isRepeat && key == .mute) {
            let fine = nsEvent.modifierFlags.isSuperset(of: [.option, .shift])
            onKey(key, fine)
        }
        return true
    }
}

/// macOS から呼ばれる入口。受け取りはメインの実行ループにつないであるので、メインスレッドで呼ばれる。
private func volumeKeyTapCallback(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    nonisolated(unsafe) let unsafeEvent = event
    nonisolated(unsafe) let pointer = userInfo
    let swallow = MainActor.assumeIsolated {
        Unmanaged<VolumeKeyTap>.fromOpaque(pointer).takeUnretainedValue().process(type: type, event: unsafeEvent)
    }
    return swallow ? nil : Unmanaged.passUnretained(event)
}
