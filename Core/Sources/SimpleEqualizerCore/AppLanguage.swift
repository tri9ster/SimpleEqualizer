/// 画面の言語の選択(設定のウィンドウ)。
/// 選んだ言語は、macOS の「アプリごとの言語」の指定(アプリの設定の `AppleLanguages`)として持つ。
/// システム設定の「言語と地域」→「アプリケーション」と同じ指定なので、どちらで変えても食い違わない。
/// 切り替わるのは、アプリを起動し直したとき。
public enum AppLanguage: String, CaseIterable, Sendable {
    /// システムの設定に合わせる(アプリには指定を持たない)。
    case system
    case japanese
    case english

    /// アプリの言語の指定から読む。先頭の言語で決める。指定がない、または用意していない言語なら、システムの設定に合わせる。
    public init(preferredLanguages: [String]?) {
        let first = preferredLanguages?.first ?? ""
        if first == "ja" || first.hasPrefix("ja-") {
            self = .japanese
        } else if first == "en" || first.hasPrefix("en-") {
            self = .english
        } else {
            self = .system
        }
    }

    /// アプリの言語の指定にする値。システムの設定に合わせるときは nil(指定を消す)。
    public var preferredLanguages: [String]? {
        switch self {
        case .system:
            return nil
        case .japanese:
            return ["ja"]
        case .english:
            return ["en"]
        }
    }
}
