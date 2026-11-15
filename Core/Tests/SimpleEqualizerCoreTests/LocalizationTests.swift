import Foundation
import Testing
@testable import SimpleEqualizerCore

/// 文言を、言語を指定して引く。
/// 言語を指定しないと、テストを動かすプログラム(英語だけに対応)に合わせて、いつも英語になる。
func text(_ resource: LocalizedStringResource, _ language: String) -> String {
    var resource = resource
    resource.locale = Locale(identifier: language)
    return String(localized: resource)
}

/// 日本語の文字(かな、漢字、「」)を含むか。
private func containsJapanese(_ string: String) -> Bool {
    string.unicodeScalars.contains { scalar in
        (0x3000...0x30FF).contains(scalar.value) || (0x4E00...0x9FFF).contains(scalar.value)
            || (0xFF00...0xFFEF).contains(scalar.value)
    }
}

@Suite("文言の英語対応")
struct LocalizationTests {
    /// Core が画面に出す文言の全部。
    private static var messages: [LocalizedStringResource] {
        let url = URL(fileURLWithPath: "/tmp/a.json")
        let statuses: [StateStore.LoadStatus] = [
            .brokenFileMovedAside(url), .brokenFileLeftInPlace, .unreadable, .unsupportedVersion(2),
        ]
        let errors: [PresetError] = [.emptyName, .nameTooLong, .duplicateName, .builtIn, .notFound, .duplicateID, .readOnly]
        let reasons: [OutputDevice.UnsupportedReason] = [.streamCount(2), .channelCount(6), .unknownSampleRate]
        let importErrors: [PresetStore.ImportError] = [.unreadable, .unsupportedVersion(3), .tooLarge]
        let summaries = [(1, 0), (3, 0), (2, 1), (0, 0), (0, 2)].map {
            PresetStore.ImportResult(importedCount: $0.0, skippedCount: $0.1).summaryMessage
        }
        let presetProblems = statuses.compactMap { PresetStore.LoadResult(library: PresetLibrary(), status: $0).problem }
            + [
                PresetStore.LoadResult(library: PresetLibrary(), status: .loaded, skippedCount: 2, partialFileBackup: url),
                PresetStore.LoadResult(library: PresetLibrary(), status: .loaded, skippedCount: 1),
            ].compactMap(\.problem)
        let stateProblems = statuses.compactMap { StateStore.LoadResult(state: .recovered, status: $0).problem }
        return [Preset.flatNameResource, Preset.defaultNameResource, PresetStore.defaultExportFileNameResource]
            + errors.map(\.message) + reasons.map(\.message) + importErrors.map(\.message)
            + summaries + presetProblems + stateProblems
    }

    @Test("どの文言も、日本語と英語で引ける")
    func everyMessageHasBothLanguages() {
        for message in Self.messages {
            let japanese = text(message, "ja")
            let english = text(message, "en")
            #expect(containsJapanese(japanese), "日本語: \(japanese)")
            #expect(!english.isEmpty && !containsJapanese(english), "英語: \(english)(日本語: \(japanese))")
        }
    }

    @Test("日本語と英語のほかの言語では、英語になる")
    func otherLanguagesFallBackToEnglish() {
        for message in Self.messages {
            #expect(text(message, "fr") == text(message, "en"))
        }
    }

    @Test("「フラット」の名前と、件数の文")
    func specificMessages() {
        #expect(text(Preset.flatNameResource, "ja") == "フラット")
        #expect(text(Preset.flatNameResource, "en") == "Flat")
        typealias Result = PresetStore.ImportResult
        #expect(text(Result(importedCount: 3, skippedCount: 0).summaryMessage, "ja") == "3 件のプリセットを読み込みました。")
        #expect(text(Result(importedCount: 1, skippedCount: 0).summaryMessage, "en") == "Imported 1 preset.")
        #expect(text(Result(importedCount: 3, skippedCount: 0).summaryMessage, "en") == "Imported 3 presets.")
    }

    @Test("どの言語の「フラット」の名前も、プリセットの名前には使えない(言語を切り替えても、名前が重ならない)",
          arguments: ["フラット", "Flat"])
    func flatNamesAreReserved(name: String) {
        var library = PresetLibrary()
        do {
            try library.add(name: name, gains: EqualizerSettings())
            Issue.record("足せてしまった: \(name)")
        } catch {
            #expect(error == .duplicateName)
        }
        #expect(library.availableName(for: name) == "\(name) 2")
    }
}

@Suite("文字列カタログ")
struct StringCatalogTests {
    /// リポジトリの中の、文字列カタログの全部(アプリの側のものも、ここで確かめる。アプリにはテストがないため)。
    private static let catalogs = [
        "Core/Sources/SimpleEqualizerCore/Resources/Localizable.xcstrings",
        "Core/Sources/SimpleEqualizerEngine/Resources/Localizable.xcstrings",
        "SimpleEqualizer/Localizable.xcstrings",
        "SimpleEqualizer/InfoPlist.xcstrings",
    ]

    private static let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// `object` の中にある、すべての訳(`stringUnit`)。複数形などで分かれた訳も含める。
    private static func stringUnits(in object: Any) -> [[String: Any]] {
        guard let dictionary = object as? [String: Any] else { return [] }
        if let unit = dictionary["stringUnit"] as? [String: Any] {
            return [unit]
        }
        return dictionary.values.flatMap { stringUnits(in: $0) }
    }

    /// 日本語の値も、見出しと同じものを明示して入れておく。入れないと、日本語の表(ja.lproj)が作られず、
    /// 日本語の Mac でも、英語の表から引かれることがある(開発の地域を英語にしているため)。
    @Test("すべての見出しに、英語の訳と、日本語の値がある", arguments: catalogs)
    func everyKeyIsTranslated(path: String) throws {
        let data = try Data(contentsOf: Self.repository.appendingPathComponent(path))
        let catalog = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(catalog["sourceLanguage"] as? String == "ja")
        let strings = try #require(catalog["strings"] as? [String: [String: Any]])
        #expect(!strings.isEmpty)
        for (key, entry) in strings where entry["shouldTranslate"] as? Bool != false {
            let japanese = Self.stringUnits(in: (entry["localizations"] as? [String: Any])?["ja"] as Any)
            #expect(!japanese.isEmpty, "日本語の値がない: \(key)")
            let english = Self.stringUnits(in: (entry["localizations"] as? [String: Any])?["en"] as Any)
            #expect(!english.isEmpty, "訳がない: \(key)")
            for unit in english {
                let value = unit["value"] as? String ?? ""
                #expect(unit["state"] as? String == "translated", "訳を確かめていない: \(key)")
                #expect(!value.isEmpty && !containsJapanese(value), "英語になっていない: \(key) → \(value)")
            }
        }
    }
}
