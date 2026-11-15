import Testing
@testable import SimpleEqualizerCore

@Suite("画面の言語の選択")
struct AppLanguageTests {
    @Test("アプリに言語の指定がなければ、システムの設定に合わせる")
    func noOverrideMeansSystem() {
        #expect(AppLanguage(preferredLanguages: nil) == .system)
        #expect(AppLanguage(preferredLanguages: []) == .system)
    }

    @Test("指定の先頭の言語で決める(地域つきの書き方も読む)", arguments: [
        (["ja"], AppLanguage.japanese), (["ja-JP"], .japanese), (["en"], .english), (["en-US", "ja"], .english),
        (["ja", "en"], .japanese),
    ])
    func readsFirstLanguage(languages: [String], expected: AppLanguage) {
        #expect(AppLanguage(preferredLanguages: languages) == expected)
    }

    @Test("用意していない言語の指定は、システムの設定に合わせる扱いにする", arguments: [["fr"], ["zh-Hans", "ja"]])
    func unknownLanguageMeansSystem(languages: [String]) {
        #expect(AppLanguage(preferredLanguages: languages) == .system)
    }

    @Test("選んだ言語を、アプリの言語の指定にする。システムの設定に合わせるときは、指定を消す(nil)")
    func writesPreferredLanguages() {
        #expect(AppLanguage.system.preferredLanguages == nil)
        #expect(AppLanguage.japanese.preferredLanguages == ["ja"])
        #expect(AppLanguage.english.preferredLanguages == ["en"])
    }

    @Test("書いた指定を読み直すと、同じ選択に戻る", arguments: AppLanguage.allCases)
    func roundTrip(language: AppLanguage) {
        #expect(AppLanguage(preferredLanguages: language.preferredLanguages) == language)
    }
}
