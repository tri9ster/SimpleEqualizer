import Foundation

/// プリセットの一覧。先頭は、いつも「フラット」。そのあとは、作った順に並ぶ。
public struct PresetLibrary: Equatable, Sendable {
    /// 全部のプリセット。先頭は「フラット」。
    public private(set) var presets: [Preset] = [.flat]

    /// 「フラット」だけの一覧。
    public init() {}

    /// 利用者が作ったプリセット(「フラット」を除く)。保存や書き出しの対象。
    public var userPresets: [Preset] {
        presets.filter { !$0.isBuiltIn }
    }

    public func preset(withID id: UUID) -> Preset? {
        presets.first { $0.id == id }
    }

    /// 選んでいるプリセットの id を、一覧にあるものにして返す。一覧にない id(消したプリセットなど)は、「フラット」にする。
    public func resolvedSelection(_ id: UUID) -> UUID {
        preset(withID: id) == nil ? Preset.flatID : id
    }

    // MARK: - 操作

    /// 新しいプリセットを、一覧の最後に足す(「別名で保存」)。
    /// `id` は、ファイルから読むときにだけ指定する。
    @discardableResult
    public mutating func add(name: String, gains: EqualizerSettings, id: UUID = UUID()) throws(PresetError) -> Preset {
        guard preset(withID: id) == nil else { throw .duplicateID }
        let preset = Preset(id: id, name: try validatedName(name, excluding: nil), gains: gains)
        presets.append(preset)
        return preset
    }

    /// プリセットの値を、いまの値にする(「保存」)。名前、id、並び順は変えない。
    @discardableResult
    public mutating func overwrite(id: UUID, gains: EqualizerSettings) throws(PresetError) -> Preset {
        let index = try editableIndex(of: id)
        presets[index].gains = gains
        return presets[index]
    }

    @discardableResult
    public mutating func rename(id: UUID, to name: String) throws(PresetError) -> Preset {
        let index = try editableIndex(of: id)
        presets[index].name = try validatedName(name, excluding: id)
        return presets[index]
    }

    /// プリセットを消す。消したプリセットを返す。
    @discardableResult
    public mutating func delete(id: UUID) throws(PresetError) -> Preset {
        presets.remove(at: try editableIndex(of: id))
    }

    // MARK: - 調べる

    /// いまの値が、そのプリセットの値と違うか(変更の印に使う)。
    /// 一覧にないプリセット(消したものを選んだまま、など)は、「フラット」と比べる。
    public func isModified(_ gains: EqualizerSettings, comparedTo id: UUID) -> Bool {
        preset(withID: resolvedSelection(id))?.gains != gains
    }

    /// 名前を、使える形に整えて返す(整え方は `normalized`)。
    /// 使えない名前(空、長すぎる、ほかのプリセットと同じ)のときは、理由を投げる。
    /// `excluding` は、名前を変えようとしているプリセット(自分自身の名前とは、重なってよい)。
    public func validatedName(_ name: String, excluding id: UUID?) throws(PresetError) -> String {
        let normalized = Self.normalized(name)
        guard !normalized.isEmpty else { throw .emptyName }
        guard Self.fitsLimit(normalized) else { throw .nameTooLong }
        guard isNameAvailable(normalized, excluding: id) else { throw .duplicateName }
        return normalized
    }

    /// その名前が使われているときに、番号をつけた名前を作る(「映画 2」「映画 3」)。読み込みに使う。
    /// 使われていなければ、そのまま返す。空の名前、長すぎる名前からも、使える名前を作る。
    /// 返す名前は、いつも、そのまま `add` に渡せる。
    public func availableName(for name: String) -> String {
        var base = Self.normalized(name)
        if base.isEmpty {
            base = Preset.defaultName
        }
        base = Self.truncated(base, to: Preset.maximumNameLength)
        if isNameAvailable(base, excluding: nil) {
            return base
        }
        // 番号で終わる名前には、番号を重ねない(「映画 2」から「映画 2 2」を作らない)。
        let stem = Self.removingTrailingNumber(base)
        var number = 2
        while true {
            let suffix = " \(number)"
            // 番号をつけても上限に収まるよう、元の名前を縮める。
            let candidate = Self.truncated(stem, to: max(Preset.maximumNameLength - suffix.count, 1)) + suffix
            if isNameAvailable(candidate, excluding: nil) {
                return candidate
            }
            number += 1
        }
    }

    // MARK: - 内部

    /// ほかのプリセットと重ならず、どの言語の「フラット」の名前でもないか。
    private func isNameAvailable(_ name: String, excluding id: UUID?) -> Bool {
        !Preset.reservedNames.contains(name) && !presets.contains { $0.id != id && $0.name == name }
    }

    /// 変えたり消したりできるプリセットの位置。「フラット」と、一覧にないものは、理由を投げる。
    private func editableIndex(of id: UUID) throws(PresetError) -> Int {
        guard id != Preset.flatID else { throw .builtIn }
        guard let index = presets.firstIndex(where: { $0.id == id }) else { throw .notFound }
        return index
    }

    /// 取り除く、見えない文字(幅のない空白、語をつなぐ印、ファイルの先頭の印)。
    /// 絵文字をつなぐ文字(U+200D)は、取り除かない。
    private static let invisibleScalars: Set<Unicode.Scalar> = ["\u{200B}", "\u{2060}", "\u{FEFF}"]

    /// 名前の整え方。見分けのつかない別名を作らせないために、次のことをする。
    /// - 見えない文字と、制御文字を取り除く。
    /// - 空白、改行、タブ(続いているものも)を、空白1つにまとめる。
    /// - 前後の空白を取る。
    private static func normalized(_ name: String) -> String {
        var scalars = String.UnicodeScalarView()
        var pendingSpace = false
        for scalar in name.unicodeScalars {
            if invisibleScalars.contains(scalar) {
                continue
            }
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                pendingSpace = true
                continue
            }
            if scalar.properties.generalCategory == .control {
                continue
            }
            // 先頭の空白は入れない。末尾の空白は、次の文字が来ないので入らない。
            if pendingSpace, !scalars.isEmpty {
                scalars.append(" ")
            }
            pendingSpace = false
            scalars.append(scalar)
        }
        return String(scalars)
    }

    private static func fitsLimit(_ name: String) -> Bool {
        name.count <= Preset.maximumNameLength && name.unicodeScalars.count <= Preset.maximumNameScalars
    }

    /// 整えてある名前を、`length` 文字までに縮める。中身の長さの上限にも収める。末尾の空白は取る。
    private static func truncated(_ name: String, to length: Int) -> String {
        var result = String(name.prefix(length))
        while result.unicodeScalars.count > Preset.maximumNameScalars, !result.isEmpty {
            result.removeLast()
        }
        while result.last == " " {
            result.removeLast()
        }
        // 1文字で上限を超えていた場合など、何も残らないときは、決まった名前にする。
        return result.isEmpty ? Preset.defaultName : result
    }

    /// 末尾の「 2」のような番号を取った名前。番号だけの名前や、番号で終わらない名前は、そのまま返す。
    private static func removingTrailingNumber(_ name: String) -> String {
        guard let space = name.lastIndex(of: " ") else { return name }
        let digits = name[name.index(after: space)...]
        let stem = name[..<space]
        guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }), !stem.isEmpty else { return name }
        return String(stem)
    }
}
