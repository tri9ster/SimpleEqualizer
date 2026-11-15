import Foundation

// 画面に出す文言は、日本語で書き、英語の訳を `Resources/Localizable.xcstrings` に置く。
// 文言は `LocalizedStringResource` で持つ(テストで、言語を指定して引けるようにするため)。
// 画面に出すときは、`String(localized:)` で、アプリが選んだ言語の文にする。

extension LocalizedStringResource.BundleDescription {
    /// Core の文字列カタログがある場所。
    static var core: Self { .atURL(Bundle.module.bundleURL) }
}

extension LocalizedStringResource {
    /// 用意してある、どの言語でも引いた文。
    var allLocalizations: Set<String> {
        var result: Set<String> = []
        for language in Bundle.module.localizations where language != "Base" {
            var resource = self
            resource.locale = Locale(identifier: language)
            result.insert(String(localized: resource))
        }
        return result
    }
}
