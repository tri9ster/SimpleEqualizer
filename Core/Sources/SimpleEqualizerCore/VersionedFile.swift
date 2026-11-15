import Foundation

/// 版の番号つきの JSON ファイル(`state.json`、`presets.json`)を読むときの、共通の手順。
/// あるか、読めるか、版が新しすぎないかを確かめ、壊れていたら別名で残す。中身の読み取りは、呼び出す側が行う。
enum VersionedFile {
    enum Contents {
        case noFile
        /// ファイルはあるが、読めなかった。または、版の番号が整数として読めなかった(新しい版かもしれない)。
        case unreadable
        case unsupportedVersion(Int)
        /// JSON のオブジェクトとして読めなかった。
        case broken
        /// 中身を読んでよい。
        case data(Data)
    }

    static func read(_ url: URL, currentVersion: Int) -> Contents {
        guard FileManager.default.fileExists(atPath: url.path) else { return .noFile }
        guard let data = try? Data(contentsOf: url) else { return .unreadable }
        return check(data, currentVersion: currentVersion)
    }

    /// 中身の版を確かめる。`.noFile` は返さない。
    static func check(_ data: Data, currentVersion: Int) -> Contents {
        guard let probe = try? JSONDecoder().decode(VersionProbe.self, from: data) else { return .broken }
        switch probe.version {
        case .missing:
            return .data(data)
        case .unreadable:
            // 小数、文字、とても大きな数など。新しい版の書き方かもしれないので、壊れたファイルとして動かさない。
            return .unreadable
        case .number(let version):
            return version > currentVersion ? .unsupportedVersion(version) : .data(data)
        }
    }

    /// 壊れたファイルを、別名(`<prefix>-<日時>.json`)にして残す。結果を、読み込みの状態として返す。
    static func moveAside(_ url: URL, prefix: String) -> StateStore.LoadStatus {
        let backup = BackupFile.url(in: url.deletingLastPathComponent(), prefix: prefix)
        if (try? FileManager.default.moveItem(at: url, to: backup)) != nil {
            return .brokenFileMovedAside(backup)
        }
        return .brokenFileLeftInPlace
    }

    private struct VersionProbe: Decodable {
        enum Version {
            case missing
            case number(Int)
            case unreadable
        }

        let version: Version

        private enum CodingKeys: String, CodingKey {
            case version
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            if !container.contains(.version) || ((try? container.decodeNil(forKey: .version)) ?? false) {
                version = .missing
            } else if let number = try? container.decode(Int.self, forKey: .version) {
                version = .number(number)
            } else {
                version = .unreadable
            }
        }
    }
}
