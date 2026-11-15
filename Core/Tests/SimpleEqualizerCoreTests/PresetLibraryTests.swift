import Foundation
import Testing
@testable import SimpleEqualizerCore

/// 31 Hz だけ `gain` dB にした設定。プリセットどうしを見分けるために使う。
private func gains(_ gain: Double) -> EqualizerSettings {
    var settings = EqualizerSettings()
    settings.setGain(gain, at: 0)
    return settings
}

/// `error` が投げられることを確かめる。
private func expect(_ error: PresetError, _ body: () throws(PresetError) -> Void) {
    do {
        try body()
        Issue.record("エラーが投げられなかった(期待: \(error))")
    } catch let thrown {
        #expect(thrown == error)
    }
}

@Suite("プリセット")
struct PresetTests {
    @Test("「フラット」は、決まった id と名前を持ち、すべて 0 dB")
    func flat() {
        #expect(Preset.flat.id == Preset.flatID)
        #expect(Preset.flat.name == Preset.flatName)
        #expect(Preset.flat.gains.isFlat)
        #expect(Preset.flat.isBuiltIn)
    }

    @Test("利用者が作ったプリセットは、「フラット」ではない")
    func userPresetIsNotBuiltIn() {
        #expect(!Preset(id: UUID(), name: "映画", gains: gains(3)).isBuiltIn)
    }

    @Test("できない理由には、画面に出す説明がある", arguments: [
        PresetError.emptyName, .nameTooLong, .duplicateName, .builtIn, .notFound, .duplicateID, .readOnly,
    ])
    func errorsHaveDescriptions(error: PresetError) {
        #expect(!text(error.message, "ja").isEmpty)
    }
}

@Suite("プリセットの一覧")
struct PresetLibraryTests {
    @Test("はじめは「フラット」だけ")
    func startsWithFlat() {
        let library = PresetLibrary()
        #expect(library.presets == [Preset.flat])
        #expect(library.userPresets.isEmpty)
    }

    @Test("足したプリセットは、作った順に、「フラット」のあとに並ぶ")
    func addsInOrder() throws {
        var library = PresetLibrary()
        let movie = try library.add(name: "映画", gains: gains(4))
        let music = try library.add(name: "音楽", gains: gains(-2))
        #expect(library.presets.map(\.name) == [Preset.flatName, "映画", "音楽"])
        #expect(library.userPresets == [movie, music])
        #expect(movie.gains == gains(4))
        #expect(movie.id != music.id)
    }

    @Test("id からプリセットを探せる")
    func findsByID() throws {
        var library = PresetLibrary()
        let movie = try library.add(name: "映画", gains: gains(4))
        #expect(library.preset(withID: movie.id) == movie)
        #expect(library.preset(withID: Preset.flatID) == Preset.flat)
        #expect(library.preset(withID: UUID()) == nil)
    }

    @Test("名前の前後の空白は取る。途中の改行は空白にする")
    func normalizesName() throws {
        var library = PresetLibrary()
        #expect(try library.add(name: "  映画 \n", gains: gains(1)).name == "映画")
        #expect(try library.add(name: "夜\n用", gains: gains(1)).name == "夜 用")
    }

    @Test("空の名前では足せない", arguments: ["", "   ", "\n\t"])
    func rejectsEmptyName(name: String) {
        var library = PresetLibrary()
        expect(.emptyName) { () throws(PresetError) in _ = try library.add(name: name, gains: gains(1)) }
        #expect(library.userPresets.isEmpty)
    }

    @Test("名前は 30 文字まで")
    func limitsNameLength() throws {
        var library = PresetLibrary()
        #expect(Preset.maximumNameLength == 30)
        let longest = String(repeating: "あ", count: 30)
        #expect(try library.add(name: longest, gains: gains(1)).name == longest)
        expect(.nameTooLong) { () throws(PresetError) in
            _ = try library.add(name: String(repeating: "い", count: 31), gains: gains(1))
        }
        #expect(library.userPresets.count == 1)
    }

    @Test("同じ名前では足せない(前後の空白を取ってから比べる)")
    func rejectsDuplicateName() throws {
        var library = PresetLibrary()
        try library.add(name: "映画", gains: gains(1))
        expect(.duplicateName) { () throws(PresetError) in _ = try library.add(name: "映画", gains: gains(2)) }
        expect(.duplicateName) { () throws(PresetError) in _ = try library.add(name: " 映画 ", gains: gains(2)) }
        #expect(library.userPresets.count == 1)
    }

    @Test("「フラット」という名前は、ほかのプリセットに使えない")
    func rejectsFlatName() {
        var library = PresetLibrary()
        expect(.duplicateName) { () throws(PresetError) in _ = try library.add(name: Preset.flatName, gains: gains(2)) }
    }

    @Test("id を指定して足せる(ファイルから読むとき)。同じ id は2つ足せない")
    func addsWithGivenID() throws {
        var library = PresetLibrary()
        let id = UUID()
        #expect(try library.add(name: "映画", gains: gains(1), id: id).id == id)
        expect(.duplicateID) { () throws(PresetError) in _ = try library.add(name: "音楽", gains: gains(1), id: id) }
        expect(.duplicateID) { () throws(PresetError) in
            _ = try library.add(name: "別のフラット", gains: gains(1), id: Preset.flatID)
        }
        #expect(library.userPresets.count == 1)
    }

    @Test("上書きすると、値だけが変わる。名前、id、並び順は変わらない")
    func overwrites() throws {
        var library = PresetLibrary()
        let movie = try library.add(name: "映画", gains: gains(4))
        try library.add(name: "音楽", gains: gains(-2))
        let updated = try library.overwrite(id: movie.id, gains: gains(7))
        #expect(updated == Preset(id: movie.id, name: "映画", gains: gains(7)))
        #expect(library.presets.map(\.name) == [Preset.flatName, "映画", "音楽"])
        #expect(library.preset(withID: movie.id)?.gains == gains(7))
    }

    @Test("名前を変えられる。値、id、並び順は変わらない")
    func renames() throws {
        var library = PresetLibrary()
        let movie = try library.add(name: "映画", gains: gains(4))
        try library.add(name: "音楽", gains: gains(-2))
        let renamed = try library.rename(id: movie.id, to: " 夜の映画 ")
        #expect(renamed == Preset(id: movie.id, name: "夜の映画", gains: gains(4)))
        #expect(library.presets.map(\.name) == [Preset.flatName, "夜の映画", "音楽"])
    }

    @Test("いまと同じ名前に変えるのは、できる(何も変わらない)")
    func renamesToSameName() throws {
        var library = PresetLibrary()
        let movie = try library.add(name: "映画", gains: gains(4))
        #expect(try library.rename(id: movie.id, to: "映画") == movie)
    }

    @Test("使えない名前には変えられない")
    func rejectsInvalidRename() throws {
        var library = PresetLibrary()
        let movie = try library.add(name: "映画", gains: gains(4))
        try library.add(name: "音楽", gains: gains(-2))
        expect(.emptyName) { () throws(PresetError) in _ = try library.rename(id: movie.id, to: " ") }
        expect(.duplicateName) { () throws(PresetError) in _ = try library.rename(id: movie.id, to: "音楽") }
        expect(.duplicateName) { () throws(PresetError) in _ = try library.rename(id: movie.id, to: Preset.flatName) }
        expect(.nameTooLong) { () throws(PresetError) in
            _ = try library.rename(id: movie.id, to: String(repeating: "あ", count: 31))
        }
        #expect(library.preset(withID: movie.id)?.name == "映画")
    }

    @Test("削除できる。ほかのプリセットは残る")
    func deletes() throws {
        var library = PresetLibrary()
        let movie = try library.add(name: "映画", gains: gains(4))
        try library.add(name: "音楽", gains: gains(-2))
        #expect(try library.delete(id: movie.id) == movie)
        #expect(library.presets.map(\.name) == [Preset.flatName, "音楽"])
        // 消した名前は、また使える。
        try library.add(name: "映画", gains: gains(1))
    }

    @Test("「フラット」は、上書き、名前の変更、削除ができない")
    func flatIsProtected() {
        var library = PresetLibrary()
        expect(.builtIn) { () throws(PresetError) in _ = try library.overwrite(id: Preset.flatID, gains: gains(5)) }
        expect(.builtIn) { () throws(PresetError) in _ = try library.rename(id: Preset.flatID, to: "平ら") }
        expect(.builtIn) { () throws(PresetError) in _ = try library.delete(id: Preset.flatID) }
        #expect(library.presets == [Preset.flat])
    }

    @Test("一覧にない id への操作は、できない")
    func unknownIDFails() {
        var library = PresetLibrary()
        let unknown = UUID()
        expect(.notFound) { () throws(PresetError) in _ = try library.overwrite(id: unknown, gains: gains(5)) }
        expect(.notFound) { () throws(PresetError) in _ = try library.rename(id: unknown, to: "映画") }
        expect(.notFound) { () throws(PresetError) in _ = try library.delete(id: unknown) }
    }

    @Test("いまの値が、選んでいるプリセットと違うかを調べられる(変更の印に使う)")
    func detectsModification() throws {
        var library = PresetLibrary()
        let movie = try library.add(name: "映画", gains: gains(4))
        #expect(!library.isModified(gains(4), comparedTo: movie.id))
        #expect(library.isModified(gains(4.5), comparedTo: movie.id))
        #expect(!library.isModified(EqualizerSettings(), comparedTo: Preset.flatID))
        #expect(library.isModified(gains(1), comparedTo: Preset.flatID))
    }

    @Test("一覧にないプリセットと比べたときは、「フラット」と比べる(消したプリセットを選んだままのとき)")
    func unknownPresetIsComparedToFlat() {
        #expect(!PresetLibrary().isModified(EqualizerSettings(), comparedTo: UUID()))
        #expect(PresetLibrary().isModified(gains(2), comparedTo: UUID()))
    }

    @Test("名前の中の、続いた空白や改行、タブは、空白1つにまとめる(見分けのつかない別名を作らせない)")
    func collapsesWhitespace() throws {
        var library = PresetLibrary()
        #expect(try library.add(name: "夜\r\n用", gains: gains(1)).name == "夜 用")
        expect(.duplicateName) { () throws(PresetError) in _ = try library.add(name: "夜  用", gains: gains(1)) }
        expect(.duplicateName) { () throws(PresetError) in _ = try library.add(name: "夜\t用", gains: gains(1)) }
        expect(.duplicateName) { () throws(PresetError) in _ = try library.add(name: "夜\u{3000}用", gains: gains(1)) }
    }

    @Test("見えない文字(幅のない空白など)は取り除く。それだけの名前は、空の名前として扱う")
    func removesInvisibleCharacters() throws {
        var library = PresetLibrary()
        expect(.emptyName) { () throws(PresetError) in _ = try library.add(name: "\u{200B}", gains: gains(1)) }
        expect(.emptyName) { () throws(PresetError) in _ = try library.add(name: "\u{FEFF} \u{2060}", gains: gains(1)) }
        try library.add(name: "映画", gains: gains(1))
        expect(.duplicateName) { () throws(PresetError) in _ = try library.add(name: "映画\u{200B}", gains: gains(1)) }
        expect(.duplicateName) { () throws(PresetError) in _ = try library.add(name: "映\u{0007}画", gains: gains(1)) }
    }

    @Test("絵文字(複数の文字をつないだもの)は、そのまま使える")
    func keepsEmoji() throws {
        var library = PresetLibrary()
        let name = "映画 👨‍👩‍👧"
        #expect(try library.add(name: name, gains: gains(1)).name == name)
    }

    @Test("見た目は短くても、中身が極端に長い名前(記号を何百個も重ねた1文字)は、使えない")
    func rejectsHugeCombiningSequence() {
        var library = PresetLibrary()
        let huge = "a" + String(repeating: "\u{0301}", count: 500)
        #expect(huge.count == 1)
        expect(.nameTooLong) { () throws(PresetError) in _ = try library.add(name: huge, gains: gains(1)) }
        // そこから作る名前は、使える名前になる。
        let name = library.availableName(for: huge)
        #expect((try? library.validatedName(name, excluding: nil)) == name)
    }

    @Test("番号で終わる名前に番号をつけるときは、番号を重ねない(「映画 2 2」にしない)")
    func availableNameDoesNotStackNumbers() throws {
        var library = PresetLibrary()
        try library.add(name: "映画", gains: gains(1))
        try library.add(name: "映画 2", gains: gains(1))
        #expect(library.availableName(for: "映画 2") == "映画 3")
        #expect(library.availableName(for: "映画") == "映画 3")
        // 使われていない名前は、番号で終わっていても、そのまま返す。
        #expect(library.availableName(for: "映画 7") == "映画 7")
    }

    @Test("作った名前は、いつも、そのまま足せる名前である", arguments: [
        "映画", " 映画 ", "", "フラット", "映画 2", "2", " 2", String(repeating: "あ", count: 30), String(repeating: "あ", count: 29) + " 2",
    ])
    func availableNameIsAlwaysValid(name: String) throws {
        var library = PresetLibrary()
        try library.add(name: "映画", gains: gains(1))
        try library.add(name: "2", gains: gains(1))
        try library.add(name: String(repeating: "あ", count: 30), gains: gains(1))
        let available = library.availableName(for: name)
        #expect(try library.add(name: available, gains: gains(1)).name == available)
    }

    @Test("名前が重なるときは、番号をつけた名前を作る(読み込みに使う)")
    func makesAvailableName() throws {
        var library = PresetLibrary()
        #expect(library.availableName(for: "映画") == "映画")
        try library.add(name: "映画", gains: gains(1))
        #expect(library.availableName(for: "映画") == "映画 2")
        #expect(library.availableName(for: " 映画 ") == "映画 2")
        try library.add(name: "映画 2", gains: gains(1))
        #expect(library.availableName(for: "映画") == "映画 3")
        #expect(library.availableName(for: Preset.flatName) == "\(Preset.flatName) 2")
    }

    @Test("番号をつけると 30 文字を超えるときは、元の名前を縮める")
    func availableNameFitsLimit() throws {
        var library = PresetLibrary()
        let longest = String(repeating: "あ", count: 30)
        try library.add(name: longest, gains: gains(1))
        let name = library.availableName(for: longest)
        #expect(name.count <= 30)
        #expect(name.hasSuffix(" 2"))
        // 作った名前で、実際に足せる。
        #expect(try library.add(name: name, gains: gains(1)).name == name)
    }

    @Test("使えない名前(空、長すぎる)から作るときも、使える名前を返す")
    func availableNameFromInvalidName() throws {
        var library = PresetLibrary()
        let fromEmpty = library.availableName(for: "  ")
        #expect(try library.add(name: fromEmpty, gains: gains(1)).name == fromEmpty)
        let fromLong = library.availableName(for: String(repeating: "あ", count: 50))
        #expect(fromLong.count == 30)
        #expect(try library.add(name: fromLong, gains: gains(1)).name == fromLong)
    }
}
