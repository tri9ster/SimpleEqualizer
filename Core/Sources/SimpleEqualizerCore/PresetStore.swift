import Foundation

/// `presets.json`(プリセットの一覧)の読み書きと、書き出し・読み込み(バックアップ)。
///
/// 利用者が作りためた設定なので、読めなかったものを黙って消さない。
/// - 全体が読めないファイルは、別名で残す。
/// - 一部のプリセットだけが壊れているファイルは、写しを別名で残してから、読めた分で書き直す。
/// - 新しい版のファイル、あるのに読めないファイルは、上書きさせない。
public struct PresetStore: Sendable {
    public typealias LoadStatus = StateStore.LoadStatus

    public struct LoadResult: Equatable, Sendable {
        public var library: PresetLibrary
        public var status: LoadStatus
        /// 壊れていて読まなかったプリセットの数。
        public var skippedCount: Int
        /// 読まなかったプリセットがあったときに残した、元のファイルの写しの場所。
        public var partialFileBackup: URL?

        public init(
            library: PresetLibrary, status: LoadStatus, skippedCount: Int = 0, partialFileBackup: URL? = nil
        ) {
            self.library = library
            self.status = status
            self.skippedCount = skippedCount
            self.partialFileBackup = partialFileBackup
        }

        /// 全体が読めなかったファイルを別名で残した場合の、その場所。
        public var brokenFileBackup: URL? { status.brokenFileBackup }

        /// このあと保存してよいか。保存すると、読めなかったものを上書きで消してしまう場合は false。
        /// 読まなかったプリセットがあるのに、写しを残して書き直せなかったときも、上書きさせない。
        public var isSafeToSave: Bool {
            status.allowsSaving && (skippedCount == 0 || partialFileBackup != nil)
        }

        /// 覚えていた選択(`id`)を、書き換えずに残しておくか。
        /// 一覧を読めなかった(または、読めなかったプリセットを上書きできない)せいで、覚えていた選択が一覧にないときは、残す。
        /// 次に正しく読めたときに、元の選択に戻れるようにするため。
        public func shouldKeepStoredSelection(_ id: UUID) -> Bool {
            !isSafeToSave && library.preset(withID: id) == nil
        }

        /// 読めなかったことを、画面に出す説明。問題がなければ nil。
        public var problemDescription: String? {
            problem.map { String(localized: $0) }
        }

        public var problem: LocalizedStringResource? {
            switch status {
            case .noFile:
                return nil
            case .loaded:
                guard skippedCount > 0 else { return nil }
                return partialFileBackup != nil
                    ? LocalizedStringResource(
                        "読めないプリセットが \(skippedCount) 件ありました。元のファイルの写しを、別名で残してあります。", bundle: .core)
                    : LocalizedStringResource(
                        "読めないプリセットが \(skippedCount) 件ありました。元のファイルを守るため、プリセットの変更は保存しません。",
                        bundle: .core)
            case .brokenFileMovedAside:
                return LocalizedStringResource(
                    "プリセットのファイルを読めなかったので、「フラット」だけで始めました。読めなかったファイルは、別名で残してあります。",
                    bundle: .core)
            case .brokenFileLeftInPlace, .unreadable:
                return LocalizedStringResource(
                    "プリセットのファイルを読めなかったので、「フラット」だけで始めました。元のファイルを守るため、プリセットの変更は保存しません。",
                    bundle: .core)
            case .unsupportedVersion:
                return LocalizedStringResource(
                    "プリセットのファイルは、新しい版のアプリが保存したものなので、「フラット」だけで始めました。元のファイルを守るため、プリセットの変更は保存しません。",
                    bundle: .core)
            }
        }
    }

    public static let fileName = "presets.json"
    public static let currentVersion = 1

    public let directory: URL
    public var fileURL: URL { directory.appendingPathComponent(Self.fileName) }

    public init(directory: URL) {
        self.directory = directory
    }

    // MARK: - presets.json

    /// ファイルがない、または読めなかったときは、「フラット」だけの一覧を返す。どちらだったかは `status` で伝える。
    public func load() -> LoadResult {
        let data: Data
        switch VersionedFile.read(fileURL, currentVersion: Self.currentVersion) {
        case .noFile:
            return LoadResult(library: PresetLibrary(), status: .noFile)
        case .unreadable:
            return LoadResult(library: PresetLibrary(), status: .unreadable)
        case .unsupportedVersion(let version):
            return LoadResult(library: PresetLibrary(), status: .unsupportedVersion(version))
        case .broken:
            return broken()
        case .data(let contents):
            data = contents
        }
        // プリセットの一覧がないファイルは、プリセットのファイルではない(項目の名前が変わった、別のファイルと入れ替わった)。
        // 読めたことにすると、次の保存で、元の中身が残らずに消える。壊れたファイルとして、別名で残す。
        guard let entries = (try? JSONDecoder().decode(FileContent.self, from: data))?.presets else {
            return broken()
        }

        var result = LoadResult(library: PresetLibrary(), status: .loaded)
        for entry in entries {
            // 読むときは、id、名前、値のどれが欠けても読まない。値は、近い端に丸めない。
            guard let entry,
                  let id = entry.id.flatMap(UUID.init(uuidString:)),
                  let name = entry.name,
                  let gains = entry.gainsDb.flatMap(EqualizerSettings.init(storedGains:)),
                  (try? result.library.add(name: name, gains: gains, id: id)) != nil
            else {
                result.skippedCount += 1
                continue
            }
        }
        if result.skippedCount > 0 {
            result.partialFileBackup = rewriteKeepingCopy(result.library)
        }
        return result
    }

    /// 読まなかったプリセットを、次の保存で黙って消さないよう、元のファイルの写しを別名で残してから、読めた分で書き直す。
    /// 書き直すのは、起動のたびに写しが増えないようにするため。
    /// 写しを残せなかったとき、書き直せなかったときは、元のファイルをそのままにして nil を返す(このあと保存させない)。
    private func rewriteKeepingCopy(_ library: PresetLibrary) -> URL? {
        let copy = BackupFile.url(in: directory, prefix: "presets.partial")
        guard (try? FileManager.default.copyItem(at: fileURL, to: copy)) != nil else { return nil }
        guard (try? save(library)) != nil else {
            // 元のファイルは残っているので、写しは要らない(残すと、起動のたびに増える)。
            try? FileManager.default.removeItem(at: copy)
            return nil
        }
        return copy
    }

    /// いったん別のファイルに書いてから置き換える(途中で止まっても、半端なファイルを残さない)。
    public func save(_ library: PresetLibrary) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.exportData(library).write(to: fileURL, options: .atomic)
    }

    // MARK: - 書き出しと読み込み(バックアップ)

    public struct ImportResult: Equatable, Sendable {
        /// 一覧に足した数。
        public var importedCount: Int
        /// 値が壊れていて、読み込まなかった数。
        public var skippedCount: Int

        public init(importedCount: Int, skippedCount: Int) {
            self.importedCount = importedCount
            self.skippedCount = skippedCount
        }

        /// 結果を、画面に出す文にしたもの。
        public var summary: String { String(localized: summaryMessage) }

        public var summaryMessage: LocalizedStringResource {
            switch (importedCount, skippedCount) {
            case (0, 0):
                return LocalizedStringResource("このファイルには、プリセットが入っていません。", bundle: .core)
            case (0, let skipped):
                return LocalizedStringResource(
                    "このファイルには、読み込めるプリセットがありません。読み込めないプリセットが \(skipped) 件あり、読み込みませんでした。",
                    bundle: .core)
            case (let imported, 0):
                return LocalizedStringResource("\(imported) 件のプリセットを読み込みました。", bundle: .core)
            case (let imported, let skipped):
                return LocalizedStringResource(
                    "\(imported) 件のプリセットを読み込みました。読み込めないプリセットが \(skipped) 件あり、読み込みませんでした。",
                    bundle: .core)
            }
        }
    }

    /// 1つのファイルから読み込めるプリセットの数の上限。まちがったファイルで、一覧があふれないようにする。
    public static let maximumImportCount = 500
    /// 読み込むファイルの大きさの上限(バイト)。上限の数のプリセットが、十分に入る大きさ。
    public static let maximumImportFileSize = 2_000_000

    /// 書き出すファイルの、はじめに入れておく名前。
    public static var defaultExportFileName: String { String(localized: defaultExportFileNameResource) }
    static let defaultExportFileNameResource = LocalizedStringResource("SimpleEqualizer プリセット.json", bundle: .core)

    public enum ImportError: Error, Equatable, Sendable, CustomStringConvertible {
        /// ファイルを読めない、またはプリセットのファイルではない。
        case unreadable
        /// このアプリより新しい版のファイル。
        case unsupportedVersion(Int)
        /// ファイルが大きすぎる、またはプリセットの数が多すぎる。
        case tooLarge

        /// 画面に出す説明。
        public var description: String { String(localized: message) }

        public var message: LocalizedStringResource {
            switch self {
            case .unreadable:
                return LocalizedStringResource("このファイルは、プリセットのファイルとして読めませんでした。", bundle: .core)
            case .unsupportedVersion:
                return LocalizedStringResource("このファイルは、新しい版のアプリが書き出したものなので、読み込めません。", bundle: .core)
            case .tooLarge:
                return LocalizedStringResource(
                    "このファイルは、大きすぎるか、プリセットの数が多すぎるので、読み込めません(\(PresetStore.maximumImportCount) 件まで)。",
                    bundle: .core)
            }
        }
    }

    /// 全部のプリセット(「フラット」を除く)を、1つのファイルの中身にする。形は `presets.json` と同じ。
    public static func exportData(_ library: PresetLibrary) throws -> Data {
        let content = FileContent(
            version: currentVersion,
            presets: library.userPresets.map {
                FileEntry(id: $0.id.uuidString, name: $0.name, gainsDb: $0.gains.gainsDb)
            })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(content)
    }

    public static func export(_ library: PresetLibrary, to url: URL) throws {
        try exportData(library).write(to: url, options: .atomic)
    }

    /// ファイルの中身のプリセットを、いまの一覧に足す(置き換えない)。
    /// - id は新しく振る(同じファイルを2回読み込んでも、ぶつからない)。
    /// - 名前が重なるときは、番号をつける。名前がない、空のときは、決まった名前にする。
    /// - 値が壊れているプリセットは読み込まない(近い端に丸めない)。
    /// 読めないファイル、新しい版のファイルのときは、何も足さずに、理由を投げる。
    @discardableResult
    public static func importPresets(
        from data: Data, into library: inout PresetLibrary
    ) throws(ImportError) -> ImportResult {
        guard data.count <= maximumImportFileSize else { throw .tooLarge }
        let contents: Data
        switch VersionedFile.check(data, currentVersion: currentVersion) {
        case .unsupportedVersion(let version):
            throw .unsupportedVersion(version)
        case .data(let checked):
            contents = checked
        case .noFile, .unreadable, .broken:
            throw .unreadable
        }
        // プリセットの一覧がないファイルは、プリセットのファイルではない。
        guard let entries = (try? JSONDecoder().decode(FileContent.self, from: contents))?.presets else {
            throw .unreadable
        }

        guard entries.count <= maximumImportCount else { throw .tooLarge }

        var updated = library
        var result = ImportResult(importedCount: 0, skippedCount: 0)
        for entry in entries {
            guard let entry,
                  let gains = entry.gainsDb.flatMap(EqualizerSettings.init(storedGains:)),
                  (try? updated.add(name: updated.availableName(for: entry.name ?? ""), gains: gains)) != nil
            else {
                result.skippedCount += 1
                continue
            }
            result.importedCount += 1
        }
        library = updated
        return result
    }

    @discardableResult
    public static func importPresets(
        fromFile url: URL, into library: inout PresetLibrary
    ) throws(ImportError) -> ImportResult {
        // 大きすぎるファイルは、読み込む前に断る。
        if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > maximumImportFileSize {
            throw .tooLarge
        }
        guard let data = try? Data(contentsOf: url) else { throw .unreadable }
        return try importPresets(from: data, into: &library)
    }

    // MARK: - ファイルの形

    private struct FileContent: Codable {
        var version: Int?
        /// 読めない要素(null など)は nil になる。1件が読めなくても、ほかの要素は読む。
        var presets: [FileEntry?]?
    }

    /// プリセット1件。読むときは、どの項目が欠けていても、型が違っていても、失敗にしない(その項目が nil になる)。
    private struct FileEntry: Codable {
        var id: String?
        var name: String?
        var gainsDb: [Double]?

        private enum CodingKeys: String, CodingKey {
            case id
            case name
            case gainsDb
        }

        init(id: String, name: String, gainsDb: [Double]) {
            self.id = id
            self.name = name
            self.gainsDb = gainsDb
        }

        init(from decoder: Decoder) throws {
            guard let container = try? decoder.container(keyedBy: CodingKeys.self) else { return }
            id = try? container.decode(String.self, forKey: .id)
            name = try? container.decode(String.self, forKey: .name)
            gainsDb = try? container.decode([Double].self, forKey: .gainsDb)
        }
    }

    // MARK: - 壊れたファイル

    private func broken() -> LoadResult {
        LoadResult(library: PresetLibrary(), status: VersionedFile.moveAside(fileURL, prefix: "presets.broken"))
    }
}
