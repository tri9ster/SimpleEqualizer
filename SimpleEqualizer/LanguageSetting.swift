import Foundation
import SimpleEqualizerCore

/// 画面の言語の選択。macOS の「アプリごとの言語」の指定(このアプリの設定の `AppleLanguages`)を読み書きする。
/// 指定は macOS が覚えているので、アプリの設定のファイル(`state.json`)には書かない。
/// 切り替わるのは、アプリを起動し直したとき(起動し直す間、音が加工なしの最大音量に戻るので、自動では起動し直さない)。
@MainActor
enum LanguageSetting {
    private static let key = "AppleLanguages"

    /// いま覚えている選択。
    /// `UserDefaults.standard` から読むと、macOS 全体の言語の一覧まで返るので、このアプリの設定だけを読む。
    static var current: AppLanguage {
        guard let domain = Bundle.main.bundleIdentifier else { return .system }
        return AppLanguage(preferredLanguages: UserDefaults.standard.persistentDomain(forName: domain)?[key] as? [String])
    }

    /// 起動したときの選択。いまの画面の言語は、これで決まっている。
    static let atLaunch = current

    static func set(_ language: AppLanguage) {
        if let languages = language.preferredLanguages {
            UserDefaults.standard.set(languages, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }
}
