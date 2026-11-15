import Foundation

/// `state.json` の読み書き。
public struct StateStore: Sendable {
    public enum LoadStatus: Equatable, Sendable {
        case loaded
        case noFile
        /// 壊れていて読めなかった。別名で残した(その場所)。
        case brokenFileMovedAside(URL)
        /// 壊れていて読めなかった。別名にもできず、元の場所に残っている。
        case brokenFileLeftInPlace
        /// このアプリより新しい版のファイル。触っていない。
        case unsupportedVersion(Int)
        /// ファイルはあるが、読めなかった(権限、ドライブの不調など)。
        /// または、版の番号が整数として読めなかった(新しい版の書き方かもしれない)。触っていない。
        case unreadable
    }

    public struct LoadResult: Equatable, Sendable {
        public var state: AppState
        public var status: LoadStatus

        public init(state: AppState, status: LoadStatus) {
            self.state = state
            self.status = status
        }

        /// 読めなかったファイルを別名で残した場合の、その場所。
        public var brokenFileBackup: URL? { status.brokenFileBackup }

        /// このあと保存してよいか。保存すると、読めなかった元のファイルを初期値で上書きしてしまう場合は false。
        public var isSafeToSave: Bool { status.allowsSaving }

        /// 読めなかったことを、画面に出す説明。問題がなければ nil。
        public var problemDescription: String? {
            problem.map { String(localized: $0) }
        }

        public var problem: LocalizedStringResource? {
            let volume = Int(VolumeCurve.fallbackVolume)
            switch status {
            case .loaded, .noFile:
                return nil
            case .brokenFileMovedAside:
                return LocalizedStringResource(
                    "前回の設定を読めなかったので、音量 \(volume) で始めました。読めなかったファイルは、別名で残してあります。", bundle: .core)
            case .brokenFileLeftInPlace, .unreadable:
                return LocalizedStringResource(
                    "前回の設定を読めなかったので、音量 \(volume) で始めました。元のファイルを守るため、今回の設定は保存しません。", bundle: .core)
            case .unsupportedVersion:
                return LocalizedStringResource(
                    "前回の設定は、新しい版のアプリが保存したものなので、音量 \(volume) で始めました。上書きしないよう、今回の設定は保存しません。",
                    bundle: .core)
            }
        }
    }

    public static let fileName = "state.json"

    /// 本物の保存先: `~/Library/Application Support/SimpleEqualizer/`。
    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SimpleEqualizer", isDirectory: true)
    }

    public let directory: URL
    public var fileURL: URL { directory.appendingPathComponent(Self.fileName) }

    public init(directory: URL) {
        self.directory = directory
    }

    /// ファイルがなければ、初期値を返す。あるのに読めなかったときは、`AppState.recovered`(音量を小さい側で始める状態)を返す。
    /// どちらだったかは `status` で伝える。
    public func load() -> LoadResult {
        switch VersionedFile.read(fileURL, currentVersion: AppState.currentVersion) {
        case .noFile:
            return LoadResult(state: AppState(), status: .noFile)
        case .unreadable:
            return LoadResult(state: .recovered, status: .unreadable)
        case .unsupportedVersion(let version):
            return LoadResult(state: .recovered, status: .unsupportedVersion(version))
        case .broken:
            return broken()
        case .data(let data):
            guard let state = try? JSONDecoder().decode(AppState.self, from: data) else { return broken() }
            return LoadResult(state: state, status: .loaded)
        }
    }

    /// いったん別のファイルに書いてから置き換える(途中で止まっても、半端なファイルを残さない)。
    public func save(_ state: AppState) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: fileURL, options: .atomic)
    }

    private func broken() -> LoadResult {
        LoadResult(state: .recovered, status: VersionedFile.moveAside(fileURL, prefix: "state.broken"))
    }
}

extension StateStore.LoadStatus {
    /// 読めなかったファイルを別名で残した場合の、その場所。
    public var brokenFileBackup: URL? {
        if case .brokenFileMovedAside(let url) = self { return url }
        return nil
    }

    /// このあと保存してよいか。保存すると、読めなかった元のファイルを上書きしてしまう場合は false。
    public var allowsSaving: Bool {
        switch self {
        case .loaded, .noFile, .brokenFileMovedAside: true
        case .brokenFileLeftInPlace, .unsupportedVersion, .unreadable: false
        }
    }
}
