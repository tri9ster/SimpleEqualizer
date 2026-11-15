import AppKit
import SwiftUI

@main
struct SimpleEqualizerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // 加工していないとき、止まっているときは、アイコンを変えて知らせる。
        MenuBarExtra {
            PopupView(model: AppModel.shared)
        } label: {
            if AppModel.shared.needsAttention {
                Image(systemName: "exclamationmark.triangle")
                    .accessibilityLabel("SimpleEqualizer(音声を加工していません)")
            } else {
                // 元のデータは design/MenuBarIcon.svg。明るい表示でも暗い表示でも、macOS が色を合わせる。
                Image("MenuBarIcon")
                    .accessibilityLabel(Text(verbatim: "SimpleEqualizer"))
            }
        }
        .menuBarExtraStyle(.window)

        // イコライザーのウィンドウ。1つだけ開く。閉じても、アプリは終了しない。
        Window("イコライザー", id: EqualizerWindow.id) {
            EqualizerWindow(model: AppModel.shared)
        }
        .windowResizability(.contentSize)
        // 起動したときには開かない(メニューバーから開く)。前に開いていても、起動時に開き直さない。
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        // 設定のウィンドウ。1つだけ開く。閉じても、アプリは終了しない。
        Window("SimpleEqualizer の設定", id: SettingsWindow.id) {
            SettingsWindow(model: AppModel.shared)
        }
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// 起動したら、保存した状態を読み込み、加工を自動で始める。
    func applicationDidFinishLaunching(_ notification: Notification) {
        // 起動したときの言語の選択を覚える(設定のウィンドウで、起動し直すと切り替わることを知らせるため)。
        _ = LanguageSetting.atLaunch
        AppModel.shared.launch()
    }

    /// 終了の入口。⌘Q、ポップアップの終了のボタン、ほかのアプリからの終了の頼みが、すべてここを通る。
    /// 加工中は、音が加工なしの最大音量に戻ることを伝えて、確かめてから終える(仕様書 4.7)。
    /// 確かめをポップアップのボタンにだけ置いていたので、⌘Q では確かめずに終わっていた(2026-10-20 に実害。`docs/failures.md`)。
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // ポップアップの ✕ のボタンで、確かめるカードを通ってきたときは、二度確かめない。印は、この1回だけに使う。
        if Self.isQuitConfirmedInPopup {
            Self.isQuitConfirmedInPopup = false
            return .terminateNow
        }
        // 加工していないときは、終了しても音量は変わらないので、確かめずに終える。
        // ログアウト、再起動、システム終了のときも、確かめない(確かめる画面を出すと、macOS の操作が止まるため)。
        guard AppModel.shared.isRunning, !Self.isQuitBySystem else { return .terminateNow }
        // ポップアップに確かめるカードが出ていたら、閉じてから、ダイアログで確かめる(カードとダイアログを同時に出さない)。
        NotificationCenter.default.post(name: Self.willConfirmQuit, object: nil)
        return Dialogs.confirmLoudSound(message: Dialogs.quitMessage, button: Dialogs.quitButton)
            ? .terminateNow : .terminateCancel
    }

    /// ポップアップの確かめるカードで、終了を確かめたあとに終える(ダイアログで二度確かめない)。
    /// 終われば戻らない。終わらずに戻ってきたときも、印を必ず消す(入口が呼ばれなかったときに、印を残さない)。
    @MainActor static func terminateConfirmedInPopup() {
        isQuitConfirmedInPopup = true
        defer { isQuitConfirmedInPopup = false }
        NSApp.terminate(nil)
    }

    /// ポップアップの確かめるカードで、終了を確かめたか。`terminateConfirmedInPopup` の中だけで立てる
    /// (残すと、取り消されたあとの ⌘Q で、確かめずに終わるおそれがある)。
    @MainActor private static var isQuitConfirmedInPopup = false

    /// 終了の入口で、ダイアログを出して確かめる直前の知らせ。ポップアップは、確かめるカードを閉じる。
    static let willConfirmQuit = Notification.Name("SimpleEqualizer.willConfirmQuit")

    /// 終了の頼みについた、理由の項目('why?')。Swift からは、Apple の定数(`keyAEQuitReason`)が見えないので、ここで書く。
    private static let quitReasonKeyword = AEKeyword(0x7768_793F)

    /// いまの終了の頼みが、ログアウト、再起動、システム終了によるものか。
    /// macOS は、そのときの終了の頼み(Apple Event)に、理由をつけて送る。⌘Q には、理由がつかない。
    private static var isQuitBySystem: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              let descriptor = event.attributeDescriptor(forKeyword: quitReasonKeyword)
        else { return false }
        // 理由は、列挙の値か、型の値として届く。どちらで届いても読めるようにする(読めないと、再起動を止めてしまう)。
        let reason = descriptor.enumCodeValue != 0 ? descriptor.enumCodeValue : descriptor.typeCodeValue
        let systemReasons = [kAELogOut, kAEReallyLogOut, kAERestart, kAEShutDown, kAEShowRestartDialog, kAEShowShutdownDialog]
        return systemReasons.contains { OSType($0) == reason }
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppModel.shared.shutdown()
    }
}
