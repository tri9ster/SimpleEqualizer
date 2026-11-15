import AppKit
import SimpleEqualizerCore
import UniformTypeIdentifiers

/// 確かめる画面と、案内の画面。
@MainActor
enum Dialogs {
    /// 音が最大音量に戻る操作の前に、確かめる。
    static func confirmLoudSound(message: String, button: String) -> Bool {
        confirm(message: message, detail: loudSoundDetail, button: button)
    }

    /// 終了を確かめる見出しと、進めるボタン。ダイアログ(⌘Q)と、ポップアップの中の確かめるカード(✕)で同じにする。
    static var quitMessage: String { String(localized: "SimpleEqualizer を終了しますか?") }
    static var quitButton: String { String(localized: "終了") }

    /// 音が最大音量に戻る操作の説明。ポップアップの中の確かめるカードでも使う。
    static var loudSoundDetail: String {
        String(localized: "音は、加工なしの最大音量に戻ります。先に、スピーカー側の音量を下げてください。")
    }

    /// 保存していない変更があるときに、別のプリセットへ切り替えてよいかを確かめる。
    /// `detail` には、変更を残したいときの方法も書く(できる操作だけを案内する)。
    static func confirmDiscardingChanges(presetName: String, detail: String) -> Bool {
        confirm(message: discardChangesMessage(presetName: presetName), detail: detail, button: discardChangesButton)
    }

    /// 変更を捨てて切り替えるときの見出しと、進めるボタン。ポップアップの中の確かめるカードでも使う。
    static func discardChangesMessage(presetName: String) -> String {
        String(localized: "「\(presetName)」への変更を保存していません")
    }
    static var discardChangesButton: String { String(localized: "変更を捨てて切り替える") }

    /// プリセットを消してよいかを確かめる(元に戻せないため)。
    static func confirmDeletingPreset(name: String) -> Bool {
        confirm(
            message: String(localized: "「\(name)」を削除しますか?"),
            detail: String(localized: """
                削除すると、元に戻せません。
                削除したあとは「フラット」に切り替わり、イコライザーはすべて 0 dB になります。\
                音を下げる設定だったときは、音が大きくなります。
                """),
            button: String(localized: "削除"))
    }

    /// すべて 0 dB の値で、プリセットを上書きしてよいかを確かめる。
    /// 「フラットに戻す」のあとに、「フラット」を選んだつもりで「保存」を押すと、作った設定が消えるため。
    static func confirmOverwritingWithFlat(name: String) -> Bool {
        confirm(
            message: String(localized: "「\(name)」を、すべて 0 dB で上書きしますか?"),
            detail: String(localized: "上書きすると、「\(name)」に保存してあった値は消えます。元に戻せません。"),
            button: String(localized: "上書き"))
    }

    /// 保存していない変更があるまま、書き出してよいかを確かめる(書き出されるのは、保存してある値)。
    static func confirmExportingWithUnsavedChanges(presetName: String) -> Bool {
        confirm(
            message: String(localized: "「\(presetName)」への変更を保存していません"),
            detail: String(localized: """
                書き出されるのは、保存してある値です。いまのスライダーの値を書き出したいときは、\
                キャンセルして、先に「保存」か「別名で保存」をしてください。
                """),
            button: String(localized: "このまま書き出す"))
    }

    /// 元に戻せない操作、音が大きくなる操作の前に、確かめる。
    /// 進めるボタンは、Return キーでは押せないようにする(押したはずみで進まないようにする)。Esc でキャンセルできる。
    private static func confirm(message: String, detail: String, button: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = detail
        let proceed = alert.addButton(withTitle: button)
        proceed.hasDestructiveAction = true
        proceed.keyEquivalent = ""
        alert.addButton(withTitle: String(localized: "キャンセル"))
        return run(alert) == .alertFirstButtonReturn
    }

    /// プリセットの名前を入れてもらう。キャンセルしたときは nil。
    /// `problem` は、前に入れた名前が使えなかったときの理由。
    static func askPresetName(title: String, button: String, initialName: String, problem: String?) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = problem ?? String(localized: "名前は \(Preset.maximumNameLength) 文字までです。")
        let field = NSTextField(string: initialName)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        field.placeholderString = String(localized: "プリセットの名前")
        alert.accessoryView = field
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: String(localized: "キャンセル"))
        // 開いたら、すぐ名前を打てるようにする。
        alert.window.initialFirstResponder = field
        return run(alert) == .alertFirstButtonReturn ? field.stringValue : nil
    }

    /// プリセットを書き出す場所を選んでもらう。キャンセルしたときは nil。
    static func askExportLocation() -> URL? {
        let panel = NSSavePanel()
        panel.title = String(localized: "プリセットの書き出し")
        panel.message = String(localized: "全部のプリセットを、1つのファイルに書き出します。")
        panel.nameFieldStringValue = PresetStore.defaultExportFileName
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        return run(panel) == .OK ? panel.url : nil
    }

    /// 読み込むプリセットのファイルを選んでもらう。キャンセルしたときは nil。
    static func askImportFile() -> URL? {
        let panel = NSOpenPanel()
        panel.title = String(localized: "プリセットの読み込み")
        panel.message = String(localized: "書き出したプリセットのファイルを選んでください。いまの一覧に足します。")
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        return run(panel) == .OK ? panel.url : nil
    }

    private static func run(_ panel: NSSavePanel) -> NSApplication.ModalResponse {
        // Dock に出ないアプリなので、ほかのウィンドウの裏に隠れないよう、前面に出す。
        panel.level = .floating
        NSApp.activate()
        panel.orderFrontRegardless()
        return panel.runModal()
    }

    /// 簡単な知らせ(できなかった理由など)。
    static func showMessage(_ message: String, detail: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.addButton(withTitle: String(localized: "OK"))
        _ = run(alert)
    }

    /// 音を取り出せていないときの案内。「システム音声の録音」の設定を開けるようにする。
    static func showCapturePermissionGuide() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "音を取り出せていません")
        alert.informativeText = String(localized: """
            ほかのアプリが音を出していますが、SimpleEqualizer は音を取り出せていません。
            「システム音声の録音」の許可がない可能性があります。許可がないと、音量を変えられません。

            設定を開き、「システムオーディオ録音のみ」の一覧で SimpleEqualizer を許可してください。
            許可したあとは、SimpleEqualizer を起動し直してください。
            """)
        alert.addButton(withTitle: String(localized: "設定を開く"))
        alert.addButton(withTitle: String(localized: "閉じる"))
        if run(alert) == .alertFirstButtonReturn {
            openCaptureSettings()
        }
    }

    /// システム設定の「プライバシーとセキュリティ」の、システム音声の録音の画面を開く。
    static func openCaptureSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")
        else { return }
        NSWorkspace.shared.open(url)
    }

    private static func run(_ alert: NSAlert) -> NSApplication.ModalResponse {
        // Dock に出ないアプリなので、ほかのウィンドウの裏に隠れないよう、前面に出す。
        alert.window.level = .floating
        NSApp.activate()
        alert.window.orderFrontRegardless()
        return alert.runModal()
    }
}
