import AppKit
import ServiceManagement

/// ログイン時に、このアプリを起動するかどうか。macOS の標準の仕組み(`SMAppService`)で登録する。
/// 登録の状態は macOS が覚えているので、アプリの設定のファイル(`state.json`)には書かない。
@MainActor
enum LoginItem {
    enum Status: Equatable {
        /// 登録してある(ログイン時に起動する)。
        case enabled
        /// 登録していない。
        case disabled
        /// 登録したが、システム設定の「ログイン項目」で、利用者が許可する必要がある。
        case requiresApproval
        /// このアプリを見つけられない(アプリが、決まった場所にない、など)。
        case notFound
    }

    static var status: Status {
        switch SMAppService.mainApp.status {
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notFound: .notFound
        case .notRegistered: .disabled
        @unknown default: .disabled
        }
    }

    /// 登録する、または外す。できなかったときは、理由を投げる。
    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    /// システム設定の「ログイン項目」を開く。
    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
