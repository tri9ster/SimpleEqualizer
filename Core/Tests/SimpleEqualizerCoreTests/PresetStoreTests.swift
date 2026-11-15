import Foundation
import Testing
@testable import SimpleEqualizerCore

/// テストごとに一時的なフォルダを使う。本物の保存先には書き込まない。
private final class Temporary {
    let store = PresetStore(directory: FileManager.default.temporaryDirectory
        .appendingPathComponent("SimpleEqualizerTests-\(UUID().uuidString)"))

    deinit {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: store.directory.path)
        try? FileManager.default.removeItem(at: store.directory)
    }

    func write(_ text: String) throws {
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: store.fileURL)
    }

    var fileText: String? { try? String(contentsOf: store.fileURL, encoding: .utf8) }

    /// 保存先のフォルダにあるファイルの名前。
    var fileNames: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: store.directory.path)) ?? []).sorted()
    }
}

private func gains(_ values: [Double]) -> EqualizerSettings {
    EqualizerSettings(storedGains: values)!
}

private let movieGains: [Double] = [0, 4, 3, 1.5, 0, 0, 1, 2, 2.5, 2]
private let flatGains = "[0, 0, 0, 0, 0, 0, 0, 0, 0, 0]"
private let idA = "11111111-1111-1111-1111-111111111111"
private let idB = "22222222-2222-2222-2222-222222222222"

private func sampleLibrary() throws -> PresetLibrary {
    var library = PresetLibrary()
    try library.add(name: "映画", gains: gains(movieGains))
    try library.add(name: "音楽", gains: gains([-2, 0, 0, 0, 0, 0, 0, 0, 0, 5.5]))
    return library
}

@Suite("プリセットの保存と読み込み")
struct PresetStoreTests {
    @Test("保存先は、状態と同じフォルダの presets.json")
    func location() {
        let store = PresetStore(directory: StateStore.defaultDirectory)
        #expect(store.fileURL.lastPathComponent == "presets.json")
        #expect(store.fileURL.deletingLastPathComponent() == StateStore.defaultDirectory)
    }

    @Test("ファイルがないときは、「フラット」だけで始まる。保存してよい")
    func noFile() {
        let result = Temporary().store.load()
        #expect(result.status == .noFile)
        #expect(result.library == PresetLibrary())
        #expect(result.skippedCount == 0)
        #expect(result.isSafeToSave)
    }

    @Test("保存して読み込むと、同じ一覧に戻る(id、名前、値、並び順)")
    func roundTrip() throws {
        let temporary = Temporary()
        let library = try sampleLibrary()
        try temporary.store.save(library)
        let result = temporary.store.load()
        #expect(result.status == .loaded)
        #expect(result.library == library)
        #expect(result.skippedCount == 0)
        #expect(result.isSafeToSave)
    }

    @Test("保存したファイルは、仕様書の形(版の番号と、id・名前・値の一覧)。「フラット」は書かない")
    func fileFormat() throws {
        let temporary = Temporary()
        let library = try sampleLibrary()
        try temporary.store.save(library)
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: temporary.store.fileURL)) as? [String: Any]
        #expect(object?["version"] as? Int == 1)
        let presets = try #require(object?["presets"] as? [[String: Any]])
        #expect(presets.count == 2)
        #expect(presets[0]["name"] as? String == "映画")
        #expect(presets[0]["id"] as? String == library.userPresets[0].id.uuidString)
        #expect(presets[0]["gainsDb"] as? [Double] == movieGains)
        #expect(!presets.contains { $0["name"] as? String == Preset.flatName })
    }

    @Test("保存先のフォルダがなければ作る。上書きできる")
    func savesRepeatedly() throws {
        let temporary = Temporary()
        var library = try sampleLibrary()
        try temporary.store.save(library)
        try library.delete(id: library.userPresets[0].id)
        try temporary.store.save(library)
        #expect(temporary.store.load().library == library)
    }

    @Test("仕様書の例のファイルを読める")
    func readsSpecExample() throws {
        let temporary = Temporary()
        try temporary.write("""
            { "version": 1, "presets": [
              { "id": "\(idA)", "name": "映画", "gainsDb": [0, 4.0, 3.0, 1.5, 0, 0, 1.0, 2.0, 2.5, 2.0] } ] }
            """)
        let result = temporary.store.load()
        #expect(result.status == .loaded)
        #expect(result.library.presets.map(\.name) == [Preset.flatName, "映画"])
        #expect(result.library.preset(withID: UUID(uuidString: idA)!)?.gains == gains(movieGains))
    }

    @Test("版の番号がないファイル、知らない項目があるファイルを読める")
    func readsLenientFile() throws {
        let temporary = Temporary()
        try temporary.write("""
            { "presets": [ { "id": "\(idA)", "name": "映画", "gainsDb": \(flatGains), "別の項目": true } ] }
            """)
        #expect(temporary.store.load().library.userPresets.map(\.name) == ["映画"])
    }

    @Test("全体が読めないファイルは、別名で残し、「フラット」だけで始まる", arguments: [
        "壊れている", "", "[1, 2, 3]", "{ \"presets\": \"ない\" }",
        // プリセットの一覧がないファイルは、プリセットのファイルではない(項目の名前が変わった、別のファイルと入れ替わった)。
        // 読めたことにすると、次の保存で、元の中身が残らずに消える。
        "{ \"あとで足す項目\": 1 }", "{ \"version\": 1, \"preset\": [] }", "{ \"version\": 1, \"presets\": null }",
    ])
    func brokenFileIsMovedAside(content: String) throws {
        let temporary = Temporary()
        try temporary.write(content)
        let result = temporary.store.load()
        let backup = try #require(result.brokenFileBackup)
        #expect(result.status == .brokenFileMovedAside(backup))
        #expect(backup.lastPathComponent.hasPrefix("presets.broken-"))
        #expect(try String(contentsOf: backup, encoding: .utf8) == content)
        #expect(temporary.fileText == nil)
        #expect(result.library == PresetLibrary())
        #expect(result.isSafeToSave)
    }

    @Test("新しい版のファイルは読まず、触らず、上書きもさせない")
    func newerVersionIsLeftAlone() throws {
        let temporary = Temporary()
        let content = "{ \"version\": 2, \"presets\": [ { \"id\": \"\(idA)\", \"name\": \"映画\", \"gainsDb\": \(flatGains) } ] }"
        try temporary.write(content)
        let result = temporary.store.load()
        #expect(result.status == .unsupportedVersion(2))
        #expect(result.library == PresetLibrary())
        #expect(!result.isSafeToSave)
        #expect(temporary.fileText == content)
    }

    @Test("版の番号が整数として読めないファイルは、新しい版かもしれないので、触らず、上書きもさせない",
          arguments: ["1.5", "\"2\"", "1e30", "true"])
    func oddVersionIsLeftAlone(version: String) throws {
        let temporary = Temporary()
        let content = "{ \"version\": \(version), \"presets\": [] }"
        try temporary.write(content)
        let result = temporary.store.load()
        #expect(result.status == .unreadable)
        #expect(!result.isSafeToSave)
        #expect(temporary.fileText == content)
        #expect(temporary.fileNames == ["presets.json"])
    }

    @Test("版の番号が null のファイルは、版 1 として読む")
    func nullVersionIsVersionOne() throws {
        let temporary = Temporary()
        try temporary.write("{ \"version\": null, \"presets\": [] }")
        #expect(temporary.store.load().status == .loaded)
    }

    @Test("あるのに読めないファイルは、ないものとして扱わない(上書きさせない)")
    func unreadableFile() throws {
        let temporary = Temporary()
        try temporary.store.save(try sampleLibrary())
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: temporary.store.fileURL.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: temporary.store.fileURL.path) }
        let result = temporary.store.load()
        #expect(result.status == .unreadable)
        #expect(result.library == PresetLibrary())
        #expect(!result.isSafeToSave)
    }

    @Test("壊れたファイルを別名にできなかったときは、上書きさせない")
    func brokenFileThatCannotBeMoved() throws {
        let temporary = Temporary()
        try temporary.write("壊れている")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: temporary.store.directory.path)
        let result = temporary.store.load()
        #expect(result.status == .brokenFileLeftInPlace)
        #expect(!result.isSafeToSave)
        #expect(temporary.fileText == "壊れている")
    }

    @Test("一部のプリセットだけが壊れているときは、それだけを読まない。ほかは読む", arguments: [
        "{ \"id\": \"\(idB)\", \"name\": \"壊れ\", \"gainsDb\": [1, 2, 3] }",
        "{ \"id\": \"\(idB)\", \"name\": \"壊れ\", \"gainsDb\": [0, 0, 0, 0, 0, 99, 0, 0, 0, 0] }",
        "{ \"id\": \"\(idB)\", \"name\": \"壊れ\", \"gainsDb\": \"なし\" }",
        "{ \"id\": \"\(idB)\", \"name\": \"壊れ\" }",
        "{ \"id\": \"\(idB)\", \"name\": \"  \", \"gainsDb\": \(flatGains) }",
        "{ \"id\": \"\(idB)\", \"name\": 5, \"gainsDb\": \(flatGains) }",
        "{ \"id\": \"\(idB)\", \"gainsDb\": \(flatGains) }",
        "{ \"id\": \"UUID ではない\", \"name\": \"壊れ\", \"gainsDb\": \(flatGains) }",
        "{ \"name\": \"壊れ\", \"gainsDb\": \(flatGains) }",
        "{ \"id\": \"\(idA)\", \"name\": \"同じ id\", \"gainsDb\": \(flatGains) }",
        "{ \"id\": \"\(idB)\", \"name\": \"映画\", \"gainsDb\": \(flatGains) }",
        "{ \"id\": \"\(idB)\", \"name\": \"\(Preset.flatName)\", \"gainsDb\": \(flatGains) }",
        "{ \"id\": \"00000000-0000-0000-0000-000000000001\", \"name\": \"にせのフラット\", \"gainsDb\": [5, 0, 0, 0, 0, 0, 0, 0, 0, 0] }",
        "\"文字だけ\"",
        "null",
        "[]",
    ])
    func skipsBrokenPreset(entry: String) throws {
        let temporary = Temporary()
        try temporary.write("""
            { "version": 1, "presets": [
              { "id": "\(idA)", "name": "映画", "gainsDb": [0, 4.0, 3.0, 1.5, 0, 0, 1.0, 2.0, 2.5, 2.0] },
              \(entry),
              { "id": "33333333-3333-3333-3333-333333333333", "name": "音楽", "gainsDb": \(flatGains) } ] }
            """)
        let result = temporary.store.load()
        #expect(result.status == .loaded)
        #expect(result.skippedCount == 1)
        #expect(result.library.presets.map(\.name) == [Preset.flatName, "映画", "音楽"])
        #expect(result.library.preset(withID: UUID(uuidString: idA)!)?.gains == gains(movieGains))
        #expect(result.library.preset(withID: Preset.flatID) == Preset.flat)
    }

    @Test("読まなかったプリセットがあるときは、元のファイルの写しを別名で残してから、読めた分で書き直す(壊れた1件を、黙って消さない)")
    func keepsCopyOfPartiallyBrokenFile() throws {
        let temporary = Temporary()
        let content = """
            { "version": 1, "presets": [
              { "id": "\(idA)", "name": "映画", "gainsDb": \(flatGains) },
              { "id": "\(idB)", "name": "壊れ", "gainsDb": [1, 2, 3] } ] }
            """
        try temporary.write(content)
        let result = temporary.store.load()
        let copy = try #require(result.partialFileBackup)
        #expect(copy.lastPathComponent.hasPrefix("presets.partial-"))
        #expect(try String(contentsOf: copy, encoding: .utf8) == content)
        #expect(result.isSafeToSave)
        // 書き直したあとのファイルには、読めた分だけがある。もう一度読んでも、写しは増えない。
        let again = temporary.store.load()
        #expect(again.skippedCount == 0)
        #expect(again.partialFileBackup == nil)
        #expect(again.library == result.library)
        #expect(temporary.fileNames.filter { $0.hasPrefix("presets.partial-") }.count == 1)
    }

    @Test("読まなかったプリセットがなければ、写しは作らない")
    func noCopyWhenNothingSkipped() throws {
        let temporary = Temporary()
        try temporary.store.save(try sampleLibrary())
        #expect(temporary.store.load().partialFileBackup == nil)
        #expect(temporary.fileNames == ["presets.json"])
    }

    @Test("写しを残せなかったときは、元のファイルを書き直さず、上書きもさせない")
    func doesNotRewriteWithoutCopy() throws {
        let temporary = Temporary()
        let content = """
            { "version": 1, "presets": [
              { "id": "\(idA)", "name": "映画", "gainsDb": \(flatGains) },
              { "id": "\(idB)", "name": "壊れ", "gainsDb": [1, 2, 3] } ] }
            """
        try temporary.write(content)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: temporary.store.directory.path)
        let result = temporary.store.load()
        #expect(result.status == .loaded)
        #expect(result.skippedCount == 1)
        #expect(result.partialFileBackup == nil)
        #expect(!result.isSafeToSave)
        #expect(result.library.userPresets.map(\.name) == ["映画"])
        #expect(temporary.fileText == content)
    }

    @Test("名前は、読むときにも整える(前後の空白を取る)")
    func normalizesNamesOnLoad() throws {
        let temporary = Temporary()
        try temporary.write("{ \"presets\": [ { \"id\": \"\(idA)\", \"name\": \"  映画 \", \"gainsDb\": \(flatGains) } ] }")
        #expect(temporary.store.load().library.userPresets.map(\.name) == ["映画"])
    }
}

@Suite("プリセットを読めなかったときの説明")
struct PresetLoadProblemTests {
    private let url = URL(fileURLWithPath: "/tmp/presets.broken.json")

    @Test("問題なく読めたとき、ファイルがまだないときは、説明を出さない")
    func noProblem() {
        #expect(PresetStore.LoadResult(library: PresetLibrary(), status: .loaded).problem == nil)
        #expect(PresetStore.LoadResult(library: PresetLibrary(), status: .noFile).problem == nil)
    }

    @Test("全体が読めず、別名で残したときは、残したことを伝える")
    func movedAside() throws {
        let result = PresetStore.LoadResult(library: PresetLibrary(), status: .brokenFileMovedAside(url))
        let message = text(try #require(result.problem), "ja")
        #expect(message.contains("別名で残して"))
        #expect(!message.contains("保存しません"))
    }

    @Test("上書きさせないときは、プリセットの変更を保存しないことを伝える", arguments: [
        StateStore.LoadStatus.brokenFileLeftInPlace, .unreadable, .unsupportedVersion(2),
    ])
    func notSaving(status: StateStore.LoadStatus) throws {
        let result = PresetStore.LoadResult(library: PresetLibrary(), status: status)
        #expect(!result.isSafeToSave)
        #expect(text(try #require(result.problem), "ja").contains("保存しません"))
    }

    @Test("新しい版のファイルのときは、そのことを伝える")
    func newerVersion() throws {
        let result = PresetStore.LoadResult(library: PresetLibrary(), status: .unsupportedVersion(2))
        #expect(text(try #require(result.problem), "ja").contains("新しい版"))
    }

    @Test("読まなかったプリセットがあるときは、数と、写しを残したことを伝える")
    func skippedWithCopy() throws {
        let result = PresetStore.LoadResult(
            library: PresetLibrary(), status: .loaded, skippedCount: 2, partialFileBackup: url)
        let message = text(try #require(result.problem), "ja")
        #expect(message.contains("2 件"))
        #expect(message.contains("写し"))
        #expect(!message.contains("保存しません"))
    }

    @Test("読まなかったプリセットがあり、写しを残せなかったときは、保存しないことを伝える")
    func skippedWithoutCopy() throws {
        let result = PresetStore.LoadResult(library: PresetLibrary(), status: .loaded, skippedCount: 1)
        let message = text(try #require(result.problem), "ja")
        #expect(message.contains("1 件"))
        #expect(message.contains("保存しません"))
    }
}

@Suite("覚えていた選択を、書き換えずに残すか")
struct KeepStoredSelectionTests {
    private let stored = UUID()

    @Test("一覧を読めなかったせいで、覚えていた選択が一覧にないときは、残す", arguments: [
        StateStore.LoadStatus.unreadable, .unsupportedVersion(2), .brokenFileLeftInPlace,
    ])
    func keepsWhenListWasNotRead(status: StateStore.LoadStatus) {
        let result = PresetStore.LoadResult(library: PresetLibrary(), status: status)
        #expect(result.shouldKeepStoredSelection(stored))
    }

    @Test("一部を読めず、写しも残せなかったときに、覚えていた選択が一覧になければ、残す")
    func keepsWhenPartlyReadWithoutCopy() {
        let result = PresetStore.LoadResult(library: PresetLibrary(), status: .loaded, skippedCount: 1)
        #expect(result.shouldKeepStoredSelection(stored))
    }

    @Test("覚えていた選択が一覧にあるときは、残さない(ふつうに記録してよい)")
    func doesNotKeepWhenSelectionExists() throws {
        var library = PresetLibrary()
        let movie = try library.add(name: "映画", gains: .flat)
        let result = PresetStore.LoadResult(library: library, status: .loaded, skippedCount: 1)
        #expect(!result.shouldKeepStoredSelection(movie.id))
        #expect(!PresetStore.LoadResult(library: PresetLibrary(), status: .unreadable)
            .shouldKeepStoredSelection(Preset.flatID))
    }

    @Test("問題なく読めたのに一覧にない選択(消したプリセットなど)は、残さない")
    func doesNotKeepWhenListIsTrusted() {
        #expect(!PresetStore.LoadResult(library: PresetLibrary(), status: .loaded).shouldKeepStoredSelection(stored))
        #expect(!PresetStore.LoadResult(library: PresetLibrary(), status: .noFile).shouldKeepStoredSelection(stored))
        #expect(!PresetStore.LoadResult(
            library: PresetLibrary(), status: .brokenFileMovedAside(URL(fileURLWithPath: "/tmp/a.json")))
            .shouldKeepStoredSelection(stored))
    }
}

@Suite("プリセットの書き出しと読み込み(バックアップ)")
struct PresetExportTests {
    @Test("書き出したものを、空の一覧に読み込むと、名前と値が戻る")
    func exportThenImport() throws {
        let source = try sampleLibrary()
        let data = try PresetStore.exportData(source)
        var library = PresetLibrary()
        let result = try PresetStore.importPresets(from: data, into: &library)
        #expect(result == PresetStore.ImportResult(importedCount: 2, skippedCount: 0))
        #expect(library.presets.map(\.name) == [Preset.flatName, "映画", "音楽"])
        #expect(library.userPresets.map(\.gains) == source.userPresets.map(\.gains))
    }

    @Test("書き出しのファイルは、presets.json と同じ形。「フラット」は入らない")
    func exportFormat() throws {
        let data = try PresetStore.exportData(try sampleLibrary())
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(object?["version"] as? Int == 1)
        #expect((object?["presets"] as? [[String: Any]])?.compactMap { $0["name"] as? String } == ["映画", "音楽"])
    }

    @Test("読み込みは、いまの一覧に足す(置き換えない)。id は新しく振る")
    func importAppends() throws {
        var library = PresetLibrary()
        let night = try library.add(name: "夜", gains: gains(movieGains))
        let source = try sampleLibrary()
        try PresetStore.importPresets(from: PresetStore.exportData(source), into: &library)
        #expect(library.presets.map(\.name) == [Preset.flatName, "夜", "映画", "音楽"])
        #expect(library.preset(withID: night.id) == night)
        #expect(Set(library.userPresets.map(\.id)).isDisjoint(with: source.userPresets.map(\.id)))
    }

    @Test("同じファイルを2回読み込むと、名前に番号がついて足される")
    func importTwice() throws {
        var library = PresetLibrary()
        let data = try PresetStore.exportData(try sampleLibrary())
        try PresetStore.importPresets(from: data, into: &library)
        let second = try PresetStore.importPresets(from: data, into: &library)
        #expect(second.importedCount == 2)
        #expect(library.presets.map(\.name) == [Preset.flatName, "映画", "音楽", "映画 2", "音楽 2"])
    }

    @Test("値が壊れているプリセットは読み込まず、数を返す。名前が空のものは、決まった名前にして読み込む")
    func importSkipsBrokenGains() throws {
        var library = PresetLibrary()
        let data = Data("""
            { "version": 1, "presets": [
              { "id": "\(idA)", "name": "映画", "gainsDb": \(flatGains) },
              { "id": "\(idB)", "name": "壊れ", "gainsDb": [0, 0, 0, 0, 0, 99, 0, 0, 0, 0] },
              { "name": "", "gainsDb": \(flatGains) },
              "文字だけ" ] }
            """.utf8)
        let result = try PresetStore.importPresets(from: data, into: &library)
        #expect(result == PresetStore.ImportResult(importedCount: 2, skippedCount: 2))
        #expect(library.presets.map(\.name) == [Preset.flatName, "映画", Preset.defaultName])
    }

    @Test("「フラット」という名前のプリセットを読み込むと、番号がつく(「フラット」は置き換わらない)")
    func importDoesNotReplaceFlat() throws {
        var library = PresetLibrary()
        let data = Data("""
            { "presets": [ { "id": "00000000-0000-0000-0000-000000000001", "name": "\(Preset.flatName)",
                             "gainsDb": [5, 0, 0, 0, 0, 0, 0, 0, 0, 0] } ] }
            """.utf8)
        try PresetStore.importPresets(from: data, into: &library)
        #expect(library.presets.map(\.name) == [Preset.flatName, "\(Preset.flatName) 2"])
        #expect(library.preset(withID: Preset.flatID) == Preset.flat)
    }

    @Test("読めないファイル、プリセットのファイルではないファイルからは、何も足さずに、理由を返す", arguments: [
        "壊れている", "", "[1]", "{ \"presets\": 3 }", "{}", "{ \"presets\": null }",
        "{ \"version\": 1, \"outputs\": {}, \"equalizerGainsDb\": [0, 0, 0, 0, 0, 0, 0, 0, 0, 0] }",
        "{ \"version\": 1.5, \"presets\": [] }", "{ \"version\": \"2\", \"presets\": [] }",
    ])
    func importRejectsBrokenFile(content: String) throws {
        var library = try sampleLibrary()
        let before = library
        #expect(throws: PresetStore.ImportError.unreadable) {
            try PresetStore.importPresets(from: Data(content.utf8), into: &library)
        }
        #expect(library == before)
    }

    @Test("新しい版のファイルからは、何も足さずに、理由を返す")
    func importRejectsNewerVersion() throws {
        var library = PresetLibrary()
        let data = Data("{ \"version\": 3, \"presets\": [ { \"name\": \"映画\", \"gainsDb\": \(flatGains) } ] }".utf8)
        #expect(throws: PresetStore.ImportError.unsupportedVersion(3)) {
            try PresetStore.importPresets(from: data, into: &library)
        }
        #expect(library == PresetLibrary())
    }

    @Test("読めるプリセットが1つもないファイルは、何も足さない(数だけ返す)")
    func importEmpty() throws {
        var library = PresetLibrary()
        let result = try PresetStore.importPresets(from: Data("{ \"presets\": [] }".utf8), into: &library)
        #expect(result == PresetStore.ImportResult(importedCount: 0, skippedCount: 0))
    }

    @Test("プリセットが多すぎるファイルは、何も足さずに、理由を返す(まちがったファイルで、一覧があふれないようにする)")
    func importRejectsTooManyPresets() throws {
        let entry = "{ \"name\": \"映画\", \"gainsDb\": \(flatGains) }"
        func file(count: Int) -> Data {
            Data("{ \"presets\": [\([String](repeating: entry, count: count).joined(separator: ","))] }".utf8)
        }
        var library = PresetLibrary()
        #expect(throws: PresetStore.ImportError.tooLarge) {
            try PresetStore.importPresets(from: file(count: PresetStore.maximumImportCount + 1), into: &library)
        }
        #expect(library == PresetLibrary())
        // 上限ちょうどは、読み込める。
        #expect(try PresetStore.importPresets(from: file(count: PresetStore.maximumImportCount), into: &library)
            .importedCount == PresetStore.maximumImportCount)
    }

    @Test("大きすぎるファイルは、中身を読まずに、理由を返す")
    func importRejectsHugeFile() throws {
        var library = PresetLibrary()
        let huge = Data(repeating: UInt8(ascii: " "), count: PresetStore.maximumImportFileSize + 1)
        #expect(throws: PresetStore.ImportError.tooLarge) {
            try PresetStore.importPresets(from: huge, into: &library)
        }
        let temporary = Temporary()
        try FileManager.default.createDirectory(at: temporary.store.directory, withIntermediateDirectories: true)
        let url = temporary.store.directory.appendingPathComponent("大きい.json")
        try huge.write(to: url)
        #expect(throws: PresetStore.ImportError.tooLarge) {
            try PresetStore.importPresets(fromFile: url, into: &library)
        }
    }

    @Test("読み込みの結果を、画面に出す文にできる")
    func importSummary() {
        typealias Result = PresetStore.ImportResult
        #expect(text(Result(importedCount: 3, skippedCount: 0).summaryMessage, "ja") == "3 件のプリセットを読み込みました。")
        let partly = text(Result(importedCount: 2, skippedCount: 1).summaryMessage, "ja")
        #expect(partly.contains("2 件のプリセットを読み込みました。"))
        #expect(partly.contains("1 件"))
        #expect(partly.contains("読み込みませんでした"))
        let none = text(Result(importedCount: 0, skippedCount: 0).summaryMessage, "ja")
        #expect(none.contains("プリセットが入っていません"))
        let allBroken = text(Result(importedCount: 0, skippedCount: 2).summaryMessage, "ja")
        #expect(allBroken.contains("読み込めるプリセットがありません"))
        #expect(allBroken.contains("2 件"))
    }

    @Test("書き出すファイルの、はじめに入れておく名前は、.json で終わる")
    func defaultExportName() {
        #expect(PresetStore.defaultExportFileName.hasSuffix(".json"))
        #expect(!PresetStore.defaultExportFileName.contains("/"))
    }

    @Test("読み込めない理由には、画面に出す説明がある")
    func importErrorsHaveDescriptions() {
        #expect(text(PresetStore.ImportError.tooLarge.message, "ja").contains("大きすぎ"))
        #expect(!text(PresetStore.ImportError.unreadable.message, "ja").isEmpty)
        #expect(text(PresetStore.ImportError.unsupportedVersion(3).message, "ja").contains("新しい版"))
    }

    @Test("ファイルへ書き出し、ファイルから読み込める")
    func exportAndImportFiles() throws {
        let temporary = Temporary()
        try FileManager.default.createDirectory(at: temporary.store.directory, withIntermediateDirectories: true)
        let url = temporary.store.directory.appendingPathComponent("バックアップ.json")
        try PresetStore.export(try sampleLibrary(), to: url)
        var library = PresetLibrary()
        #expect(try PresetStore.importPresets(fromFile: url, into: &library).importedCount == 2)
        #expect(throws: PresetStore.ImportError.unreadable) {
            try PresetStore.importPresets(
                fromFile: temporary.store.directory.appendingPathComponent("ない.json"), into: &library)
        }
    }
}

@Suite("状態: 選んでいるプリセット")
struct SelectedPresetTests {
    private func load(_ text: String) throws -> AppState {
        let store = StateStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("SimpleEqualizerTests-\(UUID().uuidString)"))
        defer { try? FileManager.default.removeItem(at: store.directory) }
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: store.fileURL)
        let result = store.load()
        #expect(result.status == .loaded)
        return result.state
    }

    @Test("初期値は「フラット」")
    func defaultIsFlat() {
        #expect(AppState().selectedPresetID == Preset.flatID)
        #expect(AppState.recovered.selectedPresetID == Preset.flatID)
    }

    @Test("保存して読み込むと、選んでいたプリセットが戻る。ファイルでの名前は selectedPresetId")
    func roundTrip() throws {
        let store = StateStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("SimpleEqualizerTests-\(UUID().uuidString)"))
        defer { try? FileManager.default.removeItem(at: store.directory) }
        var state = AppState()
        state.selectedPresetID = UUID(uuidString: idA)!
        try store.save(state)
        #expect(store.load().state == state)
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: store.fileURL)) as? [String: Any]
        #expect(object?["selectedPresetId"] as? String == idA)
    }

    @Test("項目がない(段階3 のファイル)、読めないときは、「フラット」。ほかの項目は巻き込まない", arguments: [
        "", ", \"selectedPresetId\": \"UUID ではない\"", ", \"selectedPresetId\": 5", ", \"selectedPresetId\": null",
    ])
    func fallsBackToFlat(field: String) throws {
        let state = try load("""
            { "version": 1, "outputs": { "装置A": { "volume": 64, "muted": false } },
              "equalizerGainsDb": [1, 0, 0, 0, 0, 0, 0, 0, 0, 0]\(field) }
            """)
        #expect(state.selectedPresetID == Preset.flatID)
        #expect(state.equalizer.gain(at: 0) == 1)
        #expect(state.settings(forOutput: "装置A").volume == 64)
    }

    @Test("読み込みの結果を、アプリの側でも作れる(読み込む前の初期値など)")
    func loadResultCanBeConstructed() {
        let result = PresetStore.LoadResult(library: PresetLibrary(), status: .noFile)
        #expect(result.isSafeToSave)
        #expect(result.skippedCount == 0)
        #expect(result.partialFileBackup == nil)
    }

    @Test("一覧にないプリセットを選んでいたら、「フラット」を選んでいるものとする")
    func resolvesMissingSelection() throws {
        var library = PresetLibrary()
        let movie = try library.add(name: "映画", gains: gains(movieGains))
        #expect(library.resolvedSelection(movie.id) == movie.id)
        #expect(library.resolvedSelection(Preset.flatID) == Preset.flatID)
        #expect(library.resolvedSelection(UUID()) == Preset.flatID)
    }
}
