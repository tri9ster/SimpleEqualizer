import Foundation

/// プリセット。イコライザーの設定(10 バンドの値)に、名前をつけたもの。
/// 音量、消音、ラウドネスの強さ、イコライザーの入・切は含めない。
public struct Preset: Equatable, Sendable, Identifiable {
    /// 「フラット」の id。どの Mac でも同じ値にする。
    public static let flatID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1))
    /// 「フラット」の、画面に出す名前(言語で変わる)。
    public static var flatName: String { String(localized: flatNameResource) }
    static let flatNameResource = LocalizedStringResource("フラット", bundle: .core)
    /// 名前を決められないときに使う名前(空の名前のプリセットを読み込んだときなど)。
    public static var defaultName: String { String(localized: defaultNameResource) }
    static let defaultNameResource = LocalizedStringResource("プリセット", bundle: .core)
    /// 利用者のプリセットには使わせない名前。どの言語の「フラット」の名前も含める。
    /// 言語を切り替えたときに、利用者のプリセットと「フラット」の名前が重ならないようにするため。
    static let reservedNames = flatNameResource.allLocalizations.union([flatName])
    /// 名前の長さの上限(文字数)。
    public static let maximumNameLength = 30
    /// 名前の中身の長さの上限。見た目は1文字でも、記号を大量に重ねた名前を防ぐ。
    static let maximumNameScalars = maximumNameLength * 8

    /// はじめからあるプリセット。すべて 0 dB。削除、上書き、名前の変更はできない。
    public static let flat = Preset(id: flatID, name: flatName, gains: .flat)

    public let id: UUID
    public internal(set) var name: String
    public internal(set) var gains: EqualizerSettings

    /// プリセットは、一覧(`PresetLibrary`)を通して作る(名前の決まりと、「フラット」の扱いを、一覧が守るため)。
    init(id: UUID, name: String, gains: EqualizerSettings) {
        self.id = id
        self.name = name
        self.gains = gains
    }

    /// はじめからあるプリセット(「フラット」)か。
    public var isBuiltIn: Bool { id == Self.flatID }
}

/// プリセットの操作ができない理由。
public enum PresetError: Error, Equatable, Sendable, CustomStringConvertible {
    case emptyName
    case nameTooLong
    case duplicateName
    /// 「フラット」は、削除、上書き、名前の変更ができない。
    case builtIn
    case notFound
    case duplicateID
    /// プリセットのファイルを読めなかったので、上書きしないよう、変更を受けつけていない。
    case readOnly

    /// 画面に出す説明。
    public var description: String { String(localized: message) }

    public var message: LocalizedStringResource {
        switch self {
        case .emptyName:
            return LocalizedStringResource("名前を入れてください。", bundle: .core)
        case .nameTooLong:
            return LocalizedStringResource("名前は \(Preset.maximumNameLength) 文字までにしてください。", bundle: .core)
        case .duplicateName:
            return LocalizedStringResource("同じ名前のプリセットがあります。別の名前にしてください。", bundle: .core)
        case .builtIn:
            return LocalizedStringResource("「フラット」は、変えたり消したりできません。", bundle: .core)
        case .notFound:
            return LocalizedStringResource("プリセットが見つかりません。", bundle: .core)
        case .duplicateID:
            return LocalizedStringResource("同じプリセットが、すでに一覧にあります。", bundle: .core)
        case .readOnly:
            return LocalizedStringResource(
                "プリセットのファイルを読めなかったので、元のファイルを守るため、プリセットを変えられません。", bundle: .core)
        }
    }
}
