import Foundation

/// 読めなかったファイルを残すときの、別名の決め方。
enum BackupFile {
    /// `<prefix>-<日時>.json` の形の、まだ使われていない場所を返す。
    static func url(in directory: URL, prefix: String) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = formatter.string(from: Date())
        let url = directory.appendingPathComponent("\(prefix)-\(stamp).json")
        if FileManager.default.fileExists(atPath: url.path) {
            return directory.appendingPathComponent("\(prefix)-\(stamp)-\(UUID().uuidString).json")
        }
        return url
    }
}
