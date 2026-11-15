import SimpleEqualizerCore
import SwiftUI

/// プリセットの選択。ポップアップと、イコライザーのウィンドウの両方で使う。
/// 保存していない変更があるときは、選んでいるプリセットの名前のあとに `*` をつける。
struct PresetPicker: View {
    let model: AppModel
    /// 選ぶ操作が終わったあとに呼ぶ(切り替えなかったときも呼ぶ)。
    var onFinish: () -> Void = {}

    var body: some View {
        Picker("プリセット", selection: selection) {
            ForEach(model.library.presets) { preset in
                Text(Self.title(for: preset, in: model)).tag(preset.id)
            }
        }
    }

    private var selection: Binding<UUID> {
        Binding {
            model.selectedPresetID
        } set: { id in
            // 確かめる画面を出すことがあるので、メニューが閉じてから行う(画面の更新の途中で、別の画面を開かない)。
            Task { @MainActor in
                PresetActions.select(id, model)
                onFinish()
            }
        }
    }

    /// 一覧に出す名前。保存していない変更があるときは、選んでいるプリセットの名前のあとに `*` をつける。
    /// ポップアップの選択パネルでも使う。
    static func title(for preset: Preset, in model: AppModel) -> String {
        preset.id == model.selectedPresetID && model.isEqualizerModified ? "\(preset.name) *" : preset.name
    }
}

/// プリセットの操作のうち、確かめる画面や、名前を入れる画面をはさむもの。
@MainActor
enum PresetActions {
    /// プリセットを選ぶ。保存していない変更があるときは、確かめてから切り替える。
    static func select(_ id: UUID, _ model: AppModel) {
        guard id != model.selectedPresetID else { return }
        if model.isEqualizerModified,
           !Dialogs.confirmDiscardingChanges(presetName: model.selectedPreset.name, detail: discardDetail(model)) {
            return
        }
        model.selectPreset(id)
    }

    /// 切り替えると変更が消えることと、変更を残したいときの方法。できる操作だけを案内する。
    /// ポップアップの中の確かめるカードでも使う。
    static func discardDetail(_ model: AppModel) -> String {
        if !model.canEditPresets {
            return String(localized: "切り替えると、変更は消えます。")
        }
        return model.selectedPreset.isBuiltIn
            ? String(localized: "切り替えると、変更は消えます。残したいときは、キャンセルして、イコライザーのウィンドウで「別名で保存」をしてください。")
            : String(localized: "切り替えると、変更は消えます。残したいときは、キャンセルして、イコライザーのウィンドウで「保存」か「別名で保存」をしてください。")
    }

    /// 選んでいるプリセットを、いまの値で上書きする。
    static func overwrite(_ model: AppModel) {
        if model.equalizer.isFlat, !Dialogs.confirmOverwritingWithFlat(name: model.selectedPreset.name) {
            return
        }
        do {
            try model.overwriteSelectedPreset()
            reportSaveFailure(model)
        } catch {
            Dialogs.showMessage(String(localized: "保存できませんでした"), detail: error.description)
        }
    }

    /// 一覧は変えられたが、ファイルへ書けなかったときに知らせる。
    private static func reportSaveFailure(_ model: AppModel) {
        guard model.didFailToSavePresets else { return }
        Dialogs.showMessage(
            String(localized: "プリセットを、ファイルに保存できませんでした"),
            detail: String(localized: "いまの一覧は、アプリを終えるまでは使えます。終了のときに、もう一度保存を試します。"))
    }

    /// 名前を入れてもらい、新しいプリセットとして保存する。
    static func saveAs(_ model: AppModel) {
        // はじめに入れておく名前。「フラット」から作るときは、空にする。
        let initial = model.selectedPreset.isBuiltIn ? "" : model.library.availableName(for: model.selectedPreset.name)
        askName(title: String(localized: "別名で保存"), button: String(localized: "保存"), initialName: initial, model) { name throws(PresetError) in
            try model.saveAsNewPreset(name: name)
        }
    }

    /// 選んでいるプリセットの名前を変える。
    static func rename(_ model: AppModel) {
        // 画面を出している間に選択が変わっても、別のプリセットを変えないよう、先に相手を決めておく。
        let preset = model.selectedPreset
        askName(title: String(localized: "名前の変更"), button: String(localized: "変更"), initialName: preset.name, model) { name throws(PresetError) in
            try model.renamePreset(id: preset.id, to: name)
        }
    }

    /// 選んでいるプリセットを、確かめてから消す。
    static func delete(_ model: AppModel) {
        let preset = model.selectedPreset
        guard Dialogs.confirmDeletingPreset(name: preset.name) else { return }
        do {
            try model.deletePreset(id: preset.id)
            reportSaveFailure(model)
        } catch {
            Dialogs.showMessage(String(localized: "削除できませんでした"), detail: error.description)
        }
    }

    /// 全部のプリセットを、選んだ場所の1つのファイルに書き出す。
    static func export(_ model: AppModel) {
        // 保存していない変更は、書き出されない。知らないまま、古い値をバックアップしないよう、先に確かめる。
        if model.isEqualizerModified,
           !Dialogs.confirmExportingWithUnsavedChanges(presetName: model.selectedPreset.name) {
            return
        }
        guard let url = Dialogs.askExportLocation() else { return }
        do {
            try model.exportPresets(to: url)
        } catch {
            Dialogs.showMessage(
                String(localized: "書き出せませんでした"),
                detail: String(localized: "ファイルを書けませんでした。\n\(error.localizedDescription)"))
        }
    }

    /// 選んだファイルのプリセットを、いまの一覧に足す。
    static func importPresets(_ model: AppModel) {
        guard let url = Dialogs.askImportFile() else { return }
        do {
            let result = try model.importPresets(from: url)
            guard result.importedCount > 0 else {
                Dialogs.showMessage(String(localized: "読み込みませんでした"), detail: result.summary)
                return
            }
            if model.didFailToSavePresets {
                // 一覧には足せたが、ファイルに書けなかった。成功と失敗を、別々の画面で伝えない。
                Dialogs.showMessage(
                    String(localized: "読み込みましたが、ファイルに保存できませんでした"),
                    detail: result.summary + "\n"
                        + String(localized: "いまの一覧は、アプリを終えるまでは使えます。終了のときに、もう一度保存を試します。"))
            } else {
                Dialogs.showMessage(String(localized: "読み込みました"), detail: result.summary)
            }
        } catch let error as PresetStore.ImportError {
            Dialogs.showMessage(String(localized: "読み込めませんでした"), detail: error.description)
        } catch let error as PresetError {
            Dialogs.showMessage(String(localized: "読み込めませんでした"), detail: error.description)
        } catch {
            Dialogs.showMessage(String(localized: "読み込めませんでした"), detail: error.localizedDescription)
        }
    }

    /// 名前を入れてもらい、`action` を行う。使えない名前のときは、理由を出して、入れ直してもらう。
    /// 名前を直しても解決しない理由のときは、知らせて終える。
    private static func askName(
        title: String, button: String, initialName: String, _ model: AppModel,
        action: (String) throws(PresetError) -> Void
    ) {
        var name = initialName
        var problem: String?
        while let entered = Dialogs.askPresetName(title: title, button: button, initialName: name, problem: problem) {
            do {
                try action(entered)
                reportSaveFailure(model)
                return
            } catch {
                switch error {
                case .emptyName, .nameTooLong, .duplicateName:
                    name = entered
                    problem = error.description
                case .builtIn, .notFound, .duplicateID, .readOnly:
                    Dialogs.showMessage(String(localized: "できませんでした"), detail: error.description)
                    return
                }
            }
        }
    }
}
