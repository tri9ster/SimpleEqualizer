import SimpleEqualizerCore
import SwiftUI

/// 設定のウィンドウ(仕様書 5.3)。
struct SettingsWindow: View {
    static let id = "settings"

    @Bindable var model: AppModel
    @State private var loginStatus = LoginItem.status
    @State private var loginError: String?
    @State private var hasReceivedSignal = false
    @State private var language = LanguageSetting.current

    var body: some View {
        Form {
            Section("出力先") {
                LabeledContent("いまの出力先", value: model.currentDevice?.name ?? String(localized: "見つかりません"))
                LabeledContent("アプリの音量調整", value: volumeControlText)
                Text(outputDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle("増幅した分だけ、全体を自動で下げる", isOn: $model.autoLowerEnabled)
                Text("macOS の音量で変える出力先で、イコライザーで上げているときに働きます。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("音量キー") {
                Toggle("キーボードの音量キーで、アプリの音量を変える", isOn: $model.volumeKeysEnabled)
                LabeledContent("アクセシビリティの許可") {
                    if !model.volumeKeysEnabled {
                        Text("音量キーを使わない設定です")
                            .foregroundStyle(.secondary)
                    } else if model.volumeKeysNeedPermission {
                        HStack {
                            Text("許可されていません")
                            Button("許可を求める…") { model.requestVolumeKeyPermission() }
                        }
                    } else if model.didFailToInstallVolumeKeys {
                        Text("許可はありますが、キーを受け取れませんでした。アプリを起動し直してください。")
                    } else {
                        Text("許可されています")
                    }
                }
            }

            Section("起動") {
                // 「見つからない」と返されても、登録を試せるようにしておく(登録する前は、そう返されることがある)。
                Toggle("ログイン時に起動する", isOn: loginBinding)
                if loginStatus == .requiresApproval {
                    HStack {
                        Text("システム設定の「ログイン項目」で、SimpleEqualizer を許可してください。")
                            .font(.caption)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("設定を開く") { LoginItem.openSystemSettings() }
                    }
                }
                if let loginError {
                    Text(loginError)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("言語") {
                // 言語の名前は、どちらの画面でも、その言語の文字で出す(読めない言語に切り替えても、戻せるように)。
                Picker("画面の言語", selection: languageBinding) {
                    Text("システムの設定に合わせる").tag(AppLanguage.system)
                    Text(verbatim: "日本語").tag(AppLanguage.japanese)
                    Text(verbatim: "English").tag(AppLanguage.english)
                }
                if language != LanguageSetting.atLaunch {
                    Text("アプリを起動し直すと、切り替わります。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("システム音声の録音") {
                LabeledContent("音の取り出し", value: captureStatusText)
                HStack {
                    Text("この許可の状態は、アプリからは調べられません。音を取り出せているかで判断しています。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("設定を開く") { Dialogs.openCaptureSettings() }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        // ウィンドウを開いている間だけ、macOS が覚えている状態(ログイン項目)と、音を取り出せているかを、少しおきに読み直す。
        // どちらも、アプリの外(システム設定)で変わることがある。
        .task {
            while !Task.isCancelled {
                let status = LoginItem.status
                if loginStatus != status { loginStatus = status }
                // 言語は、システム設定の「言語と地域」でも変えられる。
                let currentLanguage = LanguageSetting.current
                if language != currentLanguage { language = currentLanguage }
                let received = model.hasReceivedSignal
                if hasReceivedSignal != received { hasReceivedSignal = received }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private var outputDescription: String {
        guard model.currentDevice != nil else {
            return String(localized: "出力先が見つからないので、加工していません。")
        }
        return model.isVolumeControlEnabled
            ? String(localized: "この出力先は、macOS では音量を変えられないので、アプリが音量を変えます。")
            : String(localized: "この出力先は、macOS の音量で変えます。アプリの音量、消音、ラウドネスは使えません。")
    }

    private var volumeControlText: String {
        guard model.currentDevice != nil else { return "—" }
        return model.isVolumeControlEnabled ? String(localized: "有効") : String(localized: "無効")
    }

    private var captureStatusText: String {
        if !model.isRunning {
            return String(localized: "加工していないので、分かりません")
        }
        if model.isCaptureSuspected {
            return String(localized: "取り出せていない可能性があります(許可がないかもしれません)")
        }
        return hasReceivedSignal
            ? String(localized: "取り出せています(許可されています)") : String(localized: "まだ分かりません(音が流れていません)")
    }

    private var languageBinding: Binding<AppLanguage> {
        Binding {
            language
        } set: { newValue in
            LanguageSetting.set(newValue)
            language = newValue
        }
    }

    /// ログイン時の起動の切り替え。登録できなかったときは、理由を出して、表示を macOS の状態に戻す。
    private var loginBinding: Binding<Bool> {
        Binding {
            loginStatus == .enabled || loginStatus == .requiresApproval
        } set: { enabled in
            do {
                try LoginItem.setEnabled(enabled)
                loginError = nil
            } catch {
                loginError = enabled
                    ? String(localized: "登録できませんでした。\(error.localizedDescription)")
                    : String(localized: "解除できませんでした。\(error.localizedDescription)")
            }
            loginStatus = LoginItem.status
        }
    }
}
