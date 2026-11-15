import AppKit
import SimpleEqualizerCore
import SwiftUI

/// メニューバーのアイコンを押したときに開くポップアップ。
struct PopupView: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 開いている選択パネル。タイルからパネルへ移り変わる(`matchedGeometryEffect`)。
    @State private var expanded: SelectionPanel?
    /// 出している確かめるカード。選択パネルと同時には出さない。
    @State private var confirmation: Confirmation?
    /// パネルか確かめるカードを出している間、ほかの中身を退かせるか。パネルの移り変わりより先に始める。
    @State private var isReceded = false
    @Namespace private var panelSpace

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            notices
                .receding(order: 0, isReceded: isReceded, reduceMotion: reduceMotion)

            // 音声の加工の入・切と、出力先。
            HStack(spacing: 8) {
                // 切るときは、最大音量に戻ることを、確かめるカードで伝える(`toggleProcessing`)。
                IconButton(
                    onImage: "bolt.fill", offImage: "bolt.slash.fill", label: "音声の加工", isOn: model.isRunning,
                    changeEffect: .bounce,
                    help: model.isRunning ? "音声の加工: 入(押すと切る。音は加工なしの最大音量に戻る)" : "音声の加工: 切(押すと入れる)"
                ) { toggleProcessing() }
                .receding(order: 1, isReceded: isReceded, reduceMotion: reduceMotion)
                // いまの出力先。押すと、選択パネルが開く。音量と消音は、出力先ごとに覚えている。
                selectionTile(.output, order: 1, label: "出力先", title: outputTitle, help: "出力先(押すと選ぶ)")
            }
            .popupRow()

            volumeCard
            soundCard

            HStack {
                // 設定の画面が開くと、ポップアップが閉じるので、歯車が回ってから開く。
                IconButton(systemImage: "gearshape", label: "設定", help: "設定", pressEffect: .rotate) {
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(IconButton.rotateDuration))
                        openSettings()
                    }
                }
                Spacer()
                IconButton(systemImage: "xmark.square", label: "終了", help: "終了") { quit() }
            }
            .popupRow()
            .receding(order: 4, isReceded: isReceded, reduceMotion: reduceMotion)
        }
        // 知らせの帯が出たり消えたりしたら、ほかの中身の位置の移動を、なめらかにする(帯の伸び縮みに合わせて動く)。
        // 「視差効果を減らす」が入なら、動かさずに切り替える。
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: shownNotices)
        // 選択パネルは、中身の上に重ねる。ポップアップの大きさは変えない(ウィンドウの大きさを動かすと、動きががたつくため)。
        .overlay(alignment: .top) {
            if let expanded {
                selectionPanel(expanded)
            }
        }
        // 確かめるカードも、中身の上に重ねる。押した場所の近くに出す(仕様書 5.1)。
        // 出す場所ごとに重ねる場所を分ける(1つにすると、閉じた瞬間に場所が決まらず、消える動きが上端へ飛ぶ)。
        .overlay(alignment: .top) { confirmCard(at: .top) }
        .overlay(alignment: .bottom) { confirmCard(at: .bottom) }
        .padding(14)
        .frame(width: 300)
        // 確かめる理由がなくなったら(加工が自動で止まった、プリセットの変更がなくなった、など)、何もせずにカードを閉じる。
        .onChange(of: model.isRunning) { closeConfirmationIfUnneeded() }
        .onChange(of: model.isEqualizerModified) { closeConfirmationIfUnneeded() }
        .onChange(of: model.selectedPresetID) { closeConfirmationIfUnneeded() }
        .onChange(of: model.library.presets) { closeConfirmationIfUnneeded() }
        // ⌘Q などで、終了の入口がダイアログを出すときは、カードを閉じる(カードとダイアログを同時に出さない)。
        .onReceive(NotificationCenter.default.publisher(for: AppDelegate.willConfirmQuit)) { _ in
            closeConfirmation()
        }
        // ポップアップを閉じたら、次に開いたときは、パネルとカードを閉じた状態から始める。
        // カードを出したまま閉じたときは、キャンセルとみなす(何もしない)。
        .onDisappear {
            expanded = nil
            confirmation = nil
            isReceded = false
        }
    }

    /// いちばん上の帯に出す知らせ。加工が止まっている、音を取り出せていない、保存できなかった、など。
    /// 出るときは上から伸び、消えるときは上へ縮む。
    private var notices: some View {
        ForEach(shownNotices) { notice in
            NoticeBanner(text: Text(verbatim: notice.text), color: notice.color) {
                if notice.opensCaptureSettings {
                    Button("設定を開く") { Dialogs.openCaptureSettings() }
                }
            }
            .transition(noticeTransition)
        }
    }

    /// 帯1枚。`id` は帯の置き場所。同じ置き場所の中で文や色が変わるときは、出し入れではなく、中身の入れ替えになる
    /// (加工が止まっている → 切、のように変わったとき、2枚が重なって出ない)。
    private struct Notice: Identifiable, Equatable {
        enum Slot { case status, save, output }
        let id: Slot
        let text: String
        let color: Color
        var opensCaptureSettings = false
    }

    /// いま出す帯。描くことと、出し入れの動きのきっかけの両方に使う(見えていない知らせの変化では、動かさない)。
    private var shownNotices: [Notice] {
        var notices: [Notice] = []
        if let problem = statusProblem {
            notices.append(Notice(id: .status, text: problem, color: .red))
        } else if model.status == .stoppedByUser {
            // 音声の加工のアイコンの絵だけでなく、文でも伝える(元の音が、加工なしの元の音量で出ている)。
            notices.append(Notice(
                id: .status, text: String(localized: "音声の加工は切です。音は、加工なしの元の音量で出ています。"), color: .orange))
        } else if model.isCaptureSuspected {
            notices.append(Notice(
                id: .status,
                text: String(localized: "音を取り出せていません。「システム音声の録音」の許可がない可能性があります。許可がないと、音量を変えられません。"),
                color: .red, opensCaptureSettings: true))
        }
        if let saveProblem {
            notices.append(Notice(id: .save, text: saveProblem, color: .orange))
        }
        if model.didFailToSelectOutput {
            notices.append(Notice(id: .output, text: String(localized: "出力先を切り替えられませんでした。"), color: .orange))
        }
        return notices
    }

    /// 帯の出入り。上端を軸に、縦だけ伸び縮みしながら、濃さも変える。「視差効果を減らす」が入なら、濃さだけ変える。
    private var noticeTransition: AnyTransition {
        reduceMotion
            ? .opacity
            : .modifier(active: VerticalScale(scale: 0.01), identity: VerticalScale(scale: 1)).combined(with: .opacity)
    }

    /// 音量の枠。音量と消音、音量に関わる注意。
    private var volumeCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                IconButton(
                    onImage: "speaker.slash.fill", offImage: "speaker.wave.2.fill", label: "消音",
                    isOn: model.isMuted, help: model.isMuted ? "消音: 入(押すと戻す)" : "消音: 切(押すと音を消す)"
                ) { model.isMuted.toggle() }
                // 消音の間は、スライダーを動かせない(2026-10-20、利用者の指示)。音量の数値は覚えたまま。
                Group {
                    Slider(value: $model.volume, in: 0...100, step: 1)
                        .accessibilityLabel("音量")
                        .help(model.isMuted ? "音量(消音の間は動かせない。消音のボタンで戻す)" : "音量")
                    ValueText(value: model.volume)
                }
                .disabled(model.isMuted)
            }
            .disabled(!model.isRunning || !model.isVolumeControlEnabled)
            if !model.isVolumeControlEnabled {
                NoticeText(text: Text("この出力先の音量は、macOS の音量で変えます。"), color: .secondary)
            } else if model.volumeKeysEnabled, model.volumeKeysNeedPermission {
                NoticeText(text: Text("キーボードの音量キーを使うには、「アクセシビリティ」の許可が必要です。"), color: .secondary)
                Button("許可を求める…") { model.requestVolumeKeyPermission() }
            } else if model.volumeKeysEnabled, model.didFailToInstallVolumeKeys {
                NoticeText(text: Text("キーボードの音量キーを受け取れませんでした。アプリを起動し直してください。"), color: .orange)
            }
        }
        .recedingCard(order: 2, isReceded: isReceded, reduceMotion: reduceMotion)
    }

    /// 音質の枠。ラウドネスとイコライザー。
    private var soundCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 切にしても強さは覚えていて、入に戻すと、その強さで効く(聴き比べに使う)。切の間は、スライダーを動かせない(2026-10-20、利用者の指示)。
            // 強さは 0 で効かない。大きくするほど、小さい音量のときに低音と高音を強く持ち上げる。
            // 音量と同じく、加工していない間は動かせない(動かしても音が変わらず、加工を入れた瞬間に効き始めるため)。
            HStack(spacing: 8) {
                IconButton(
                    onImage: "ear.badge.waveform", offImage: "ear", label: "ラウドネス", isOn: model.isLoudnessEnabled,
                    help: model.isLoudnessEnabled ? "ラウドネス: 入(押すと切る)" : "ラウドネス: 切(押すと入れる)"
                ) { model.isLoudnessEnabled.toggle() }
                Group {
                    Slider(value: $model.loudnessAmount, in: 0...100, step: 5)
                        .accessibilityLabel("ラウドネスの強さ")
                        .help(model.isLoudnessEnabled ? "ラウドネスの強さ" : "ラウドネスの強さ(切の間は動かせない。ラウドネスのボタンで入れる)")
                    ValueText(value: model.loudnessAmount)
                }
                .disabled(!model.isLoudnessEnabled)
            }
            .disabled(!model.isRunning || !model.isVolumeControlEnabled)
            .receding(order: 3, isReceded: isReceded, reduceMotion: reduceMotion)

            HStack(spacing: 8) {
                Group {
                    IconButton(
                        onImage: "waveform", offImage: "waveform.slash", label: "イコライザー", isOn: model.isEqualizerEnabled,
                        help: model.isEqualizerEnabled ? "イコライザー: 入(押すと切る)" : "イコライザー: 切(押すと入れる)"
                    ) { model.isEqualizerEnabled.toggle() }
                    IconButton(systemImage: "slider.vertical.3", label: "イコライザーを開く", help: "イコライザーを開く") {
                        openEqualizer()
                    }
                }
                .receding(order: 3, isReceded: isReceded, reduceMotion: reduceMotion)
                // いまのプリセット。押すと、選択パネルが開く。
                selectionTile(.preset, order: 3, label: "プリセット", title: presetTitle, help: "プリセット(押すと選ぶ)")
            }
        }
        // プリセットのタイルは、パネルへ移り変わるので、枠ごとではなく、枠の背景とほかの中身だけを退かせる。
        // プリセットのタイルはパネルへ移り変わるので、中身はここではまとめて退かせず、背景だけを退かせる(ぼかさない)。
        .popupCard(background: {
            CardBackground().receding(order: 3, isReceded: isReceded, reduceMotion: reduceMotion, blurs: false)
        })
    }

    // MARK: - 選択パネル(出力先、プリセット)

    enum SelectionPanel: Hashable {
        case output
        case preset
    }

    private var outputTitle: String {
        guard let device = model.currentDevice else { return String(localized: "見つかりません") }
        return optionTitle(device)
    }

    /// 扱えない装置も選べるが、加工はしないので、印をつける。
    private func optionTitle(_ device: OutputDevice) -> String {
        device.unsupportedReason == nil ? device.name : String(localized: "\(device.name)(加工できません)")
    }

    /// 保存していない変更があるときは、名前のあとに `*` をつける(イコライザーのウィンドウのプルダウンと同じ)。
    private var presetTitle: String {
        PresetPicker.title(for: model.selectedPreset, in: model)
    }

    /// 選択パネルとタイルが、同じものとして移り変わるための名前。
    /// 「視差効果を減らす」が入のときは、別の名前にして、移動させずに入れ替える。
    private func morphID(_ panel: SelectionPanel, isPanel: Bool) -> String {
        reduceMotion ? "\(panel)-\(isPanel ? "panel" : "tile")" : "\(panel)"
    }

    /// いまの値を文字列で出すタイル。押すと、選択パネルが開く。パネルを開いている間は、同じ高さの空きを残す。
    /// もう一方のパネルを開いている間は、ほかの中身と一緒に退く(`order` は、退く順番)。
    @ViewBuilder
    private func selectionTile(
        _ panel: SelectionPanel, order: Int, label: LocalizedStringKey, title: String, help: LocalizedStringKey
    ) -> some View {
        if expanded == panel {
            Color.clear.frame(maxWidth: .infinity).frame(height: SelectionTile.height)
        } else {
            // 文字はぼかすが、背景はぼかさない(`receding` の説明)ので、別々に退かせる。
            Button { openPanel(panel) } label: {
                SelectionTile(title: title, showsBackground: false)
                    .receding(order: order, isReceded: isReceded, reduceMotion: reduceMotion)
                    .background {
                        SelectionTile.background
                            .receding(order: order, isReceded: isReceded, reduceMotion: reduceMotion, blurs: false)
                    }
            }
            .buttonStyle(.plain)
            // ボタンそのものも、退いている間は押せなくする(見えない欄を、キーボードで押さないため)。
            .disabled(isReceded)
            .matchedGeometryEffect(id: morphID(panel, isPanel: false), in: panelSpace)
            .help(help)
            .accessibilityLabel(label)
            .accessibilityValue(Text(verbatim: title))
        }
    }

    private func selectionPanel(_ panel: SelectionPanel) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // 見出し(いまの値)。押すか Esc で、選ばずに閉じる。
            Button { closePanel() } label: {
                SelectionTile(title: panel == .output ? outputTitle : presetTitle, isHeader: true)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            // カードに切り替わる途中は、Esc をカードの「キャンセル」に渡す(パネルが消えきるまで、両方に Esc がついている)。
            .disabled(confirmation != nil)
            .help("閉じる")
            Divider().padding(.vertical, 4)
            // 選択肢が多いときだけ、中でスクロールする。
            ViewThatFits(in: .vertical) {
                options(panel)
                ScrollView { options(panel) }
            }
        }
        .padding(6)
        .popupPanelBackground()
        .matchedGeometryEffect(id: morphID(panel, isPanel: true), in: panelSpace)
    }

    @ViewBuilder
    private func options(_ panel: SelectionPanel) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            switch panel {
            case .output:
                ForEach(model.outputDevices, id: \.uid) { device in
                    OptionRow(title: optionTitle(device), isSelected: device.uid == model.currentDevice?.uid) {
                        closePanel()
                        model.selectOutput(uid: device.uid)
                    }
                }
            case .preset:
                ForEach(model.library.presets) { preset in
                    OptionRow(title: PresetPicker.title(for: preset, in: model), isSelected: preset.id == model.selectedPresetID) {
                        if preset.id == model.selectedPresetID {
                            closePanel()
                        } else if model.isEqualizerModified {
                            // 保存していない変更があるときは、パネルを、そのまま確かめるカードに切り替える(中身は退いたまま)。
                            switchPanel(to: .discardChanges(presetID: preset.id, from: model.selectedPresetID))
                        } else {
                            closePanel()
                            model.selectPreset(preset.id)
                        }
                    }
                }
            }
        }
    }

    /// パネルを開く。先にほかの中身を少しずつずらして退かせ、少し遅れて、タイルがパネルへ移り変わる。
    private func openPanel(_ panel: SelectionPanel) {
        isReceded = true
        withAnimation(appearAnimation) {
            expanded = panel
        }
    }

    /// パネルを閉じる。パネルがタイルへ戻り、ほかの中身が少し遅れて戻る。
    private func closePanel() {
        guard expanded != nil else { return }
        withAnimation(disappearAnimation) {
            expanded = nil
        }
        // カードを出しているときは、中身を退かせたままにする。
        isReceded = confirmation != nil
    }

    /// パネルとカードを出す動き。ほかの中身が退き始めてから、少し遅れて始める。
    private var appearAnimation: Animation {
        reduceMotion ? .easeOut(duration: 0.15) : .spring(duration: 0.25, bounce: 0.15).delay(0.08)
    }

    /// パネルとカードを閉じる動き。
    private var disappearAnimation: Animation {
        reduceMotion ? .easeOut(duration: 0.15) : .spring(duration: 0.25, bounce: 0.15)
    }

    // MARK: - 確かめるカード

    /// ポップアップの中で確かめる操作。別のダイアログでは、画面の真ん中に出て、目線の移動が大きいため(2026-11-07、利用者の指示)。
    enum Confirmation: Equatable {
        /// 稲妻のボタンで、音声の加工を切る。
        case stopProcessing
        /// ✕ のボタンで、加工中に終える。⌘Q とほかのアプリからの頼みは、ダイアログで確かめる(`AppDelegate`)。
        case quit
        /// プリセットの選択パネルで、保存していない変更を捨てて、`presetID` へ切り替える。`from` は、そのとき選んでいたプリセット。
        /// イコライザーのウィンドウから選んだときは、ダイアログで確かめる(`PresetActions.select`)。
        case discardChanges(presetID: UUID, from: UUID)

        /// カードを出す場所。押した場所の近くにする(2026-11-07、利用者が選んだ)。
        var edge: VerticalEdge {
            switch self {
            case .stopProcessing: .top
            case .quit: .bottom
            // 選択パネルは、いちばん上に開いているので、同じ場所。
            case .discardChanges: .top
            }
        }
    }

    /// `edge` の場所に出すカード。いまのカードが別の場所のものなら、何も出さない。
    @ViewBuilder
    private func confirmCard(at edge: VerticalEdge) -> some View {
        if let confirmation, confirmation.edge == edge {
            confirmCard(confirmation)
                // 出す場所を軸に、少し縮んだところから広がる。「視差効果を減らす」が入なら、濃さだけ変える。
                .transition(reduceMotion ? .opacity : .scale(scale: 0.92, anchor: edge == .top ? .top : .bottom).combined(with: .opacity))
        }
    }

    private func confirmCard(_ confirmation: Confirmation) -> some View {
        switch confirmation {
        case .stopProcessing:
            ConfirmCard(
                title: String(localized: "音声の加工を切りますか?"),
                message: Dialogs.loudSoundDetail,
                proceedTitle: String(localized: "切る"),
                onCancel: closeConfirmation
            ) {
                closeConfirmation()
                model.stopProcessing()
            }
        case .quit:
            ConfirmCard(
                title: Dialogs.quitMessage,
                message: Dialogs.loudSoundDetail,
                proceedTitle: Dialogs.quitButton,
                onCancel: closeConfirmation
            ) {
                AppDelegate.terminateConfirmedInPopup()
            }
        case .discardChanges(let presetID, _):
            ConfirmCard(
                title: Dialogs.discardChangesMessage(presetName: model.selectedPreset.name),
                message: PresetActions.discardDetail(model),
                proceedTitle: Dialogs.discardChangesButton,
                onCancel: closeConfirmation
            ) {
                // 押したのと同じ瞬間に、イコライザーのウィンドウで保存されたときなどは、切り替えない。
                let isNeeded = isNeeded(confirmation)
                closeConfirmation()
                if isNeeded { model.selectPreset(presetID) }
            }
        }
    }

    /// いまのカードに、まだ確かめる理由がなければ、何もせずに閉じる(仕様書 5.1)。
    private func closeConfirmationIfUnneeded() {
        guard let confirmation, !isNeeded(confirmation) else { return }
        closeConfirmation()
    }

    /// カードに、まだ確かめる理由があるか。
    private func isNeeded(_ confirmation: Confirmation) -> Bool {
        switch confirmation {
        // 音が最大音量に戻るのは、加工している間だけ。
        case .stopProcessing, .quit:
            model.isRunning
        // 変更がなくなった(イコライザーのウィンドウで保存した、など)、選んでいるプリセットが変わった、切り替える先が消えた。
        case .discardChanges(let presetID, let from):
            model.isEqualizerModified && model.selectedPresetID == from
                && model.library.presets.contains { $0.id == presetID }
        }
    }

    /// カードを出す。選択パネルと同じく、先にほかの中身を退かせ、少し遅れてカードを出す。
    private func showConfirmation(_ confirmation: Confirmation) {
        isReceded = true
        withAnimation(appearAnimation) {
            self.confirmation = confirmation
        }
    }

    /// カードを閉じる。カードが消え、ほかの中身が少し遅れて戻る。
    private func closeConfirmation() {
        guard confirmation != nil else { return }
        withAnimation(disappearAnimation) {
            confirmation = nil
        }
        // パネルを出しているときは、中身を退かせたままにする。
        isReceded = expanded != nil
    }

    /// 開いている選択パネルを、確かめるカードに切り替える。中身は退いたまま、パネルが消えて、カードが出る。
    private func switchPanel(to confirmation: Confirmation) {
        withAnimation(appearAnimation) {
            self.confirmation = confirmation
        }
        withAnimation(disappearAnimation) {
            expanded = nil
        }
    }

    private var statusProblem: String? {
        switch model.status {
        case .starting, .stoppedByUser:
            return nil
        case .running:
            return model.isStalled
                ? String(localized: "音声の加工が止まっています。元の音が最大音量で出ているおそれがあります。スピーカー側の音量を下げてから、「音声の加工」を入れ直してください。")
                : nil
        case .failed(let message):
            return String(localized: "音声を加工していません。\(message)")
        }
    }

    /// 設定やプリセットを、読めなかった・保存できなかったときの説明。いくつもあるときは、全部を出す。
    private var saveProblem: String? {
        var problems: [String] = []
        if let loadProblem = model.loadProblem { problems.append(loadProblem) }
        if model.didFailToSave { problems.append(String(localized: "設定を保存できませんでした。")) }
        if let presetLoadProblem = model.presetLoadProblem { problems.append(presetLoadProblem) }
        if model.didFailToSavePresets { problems.append(String(localized: "プリセットを保存できませんでした。")) }
        return problems.isEmpty ? nil : problems.joined(separator: "\n")
    }

    private func openSettings() {
        openWindow(id: SettingsWindow.id)
        // Dock に出ないアプリなので、ウィンドウがほかのアプリの裏に隠れないよう、前面に出す。
        NSApp.activate()
    }

    private func openEqualizer() {
        openWindow(id: EqualizerWindow.id)
        // Dock に出ないアプリなので、ウィンドウがほかのアプリの裏に隠れないよう、前面に出す。
        NSApp.activate()
    }

    private func toggleProcessing() {
        if !model.isRunning {
            model.startProcessing()
        } else {
            showConfirmation(.stopProcessing)
        }
    }

    /// 加工中は、ポップアップの中の確かめるカードで確かめる。加工していないときは、確かめずに終える(音量は変わらない)。
    /// どちらも、終了の入口(`AppDelegate.applicationShouldTerminate`)を通す(⌘Q と同じ道。ログイン項目などの後始末も同じになる)。
    private func quit() {
        if model.isRunning {
            showConfirmation(.quit)
        } else {
            NSApp.terminate(nil)
        }
    }
}

/// アイコンだけのボタン。押すと少し縮んで戻る。
/// 入・切は、色ではなく、アイコンの絵で表す(2026-10-20、利用者の指示)。呼ぶ側が、入と切で別の絵を渡し、
/// 入・切が変わったときに、絵が移り変わる(`replace`)。確かめる画面で取り消したときは、絵が変わらないので、動かない。
/// ただのボタン(`isOn` が nil)は、押すとアイコンが1回動く(弾む、または回る)。
/// 動きは見た目だけで、押してから効くまでの時間は変えない。「視差効果を減らす」が入のときは、動かさない。
/// 文言は、英語に訳せるよう、`LocalizedStringKey` で受け取る。
private struct IconButton: View {
    let systemImage: String
    /// 読み上げに使う名前。
    let label: LocalizedStringKey
    /// 入・切のあるボタンの状態(読み上げに使う)。ただのボタンは nil。
    let isOn: Bool?
    /// マウスを乗せたときの説明。入・切のあるボタンは、いまの状態と、押すとどうなるかを書く。
    let help: LocalizedStringKey
    /// ただのボタンを押したときの動き。入・切のあるボタンは nil(絵の移り変わりで動くので、ふつうは重ねない)。
    let pressEffect: PressEffect?
    /// 入・切のあるボタンで、絵の移り変わりに加えて、入・切が変わったときの動き(音声の加工は弾む。2026-10-20、利用者の指示)。
    /// 押したときに限らず、アプリが自分で入・切を変えたとき(加工が止まったときなど)も動き、状態が変わったことを知らせる。
    /// 確かめる画面で取り消したときは、入・切が変わらないので、動かない。
    let changeEffect: PressEffect?
    let action: () -> Void

    enum PressEffect {
        case bounce
        /// 1回転する(設定の歯車。2026-10-20、利用者の指示)。
        case rotate
    }

    /// 1回転にかける時間(秒)。
    static let rotateDuration = 0.5

    /// ただのボタン。
    init(
        systemImage: String, label: LocalizedStringKey, help: LocalizedStringKey, pressEffect: PressEffect = .bounce,
        action: @escaping () -> Void
    ) {
        self.systemImage = systemImage
        self.label = label
        self.isOn = nil
        self.help = help
        self.pressEffect = pressEffect
        self.changeEffect = nil
        self.action = action
    }

    /// 入・切のあるボタン。絵は、`isOn` から選ぶ(絵と読み上げの入・切が、食い違わないようにする)。
    init(
        onImage: String, offImage: String, label: LocalizedStringKey, isOn: Bool, changeEffect: PressEffect? = nil,
        help: LocalizedStringKey, action: @escaping () -> Void
    ) {
        self.systemImage = isOn ? onImage : offImage
        self.label = label
        self.isOn = isOn
        self.help = help
        self.pressEffect = nil
        self.changeEffect = changeEffect
        self.action = action
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled
    @State private var presses = 0

    var body: some View {
        Button {
            // 動きを先に始める(ポップアップを閉じる操作や、終了でも、動き始めてから効く)。
            if pressEffect != nil, !reduceMotion { presses += 1 }
            action()
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .medium))
                // 斜線やバッジが、つく・消える動きにする(できない組み合わせは、ふつうの差し替え)。
                .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace.magic(fallback: .replace)))
                .modifier(PressEffectModifier(effect: pressEffect ?? changeEffect, presses: presses))
                .frame(width: 30, height: 30)
                .opacity(isEnabled ? 1 : 0.4)
                .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(PressButtonStyle(reduceMotion: reduceMotion))
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: systemImage)
        .onChange(of: isOn) {
            if changeEffect != nil, !reduceMotion { presses += 1 }
        }
        .help(help)
        .accessibilityLabel(label)
        .accessibilityValue(isOn.map { $0 ? Text("入") : Text("切") } ?? Text(verbatim: ""))
        .accessibilityAddTraits(isOn == nil ? [] : .isToggle)
    }
}

/// ただのボタンを押したときの、アイコンの動き。
private struct PressEffectModifier: ViewModifier {
    let effect: IconButton.PressEffect?
    let presses: Int

    func body(content: Content) -> some View {
        switch effect {
        case .bounce:
            content.symbolEffect(.bounce, value: presses)
        case .rotate:
            // 既定の速さの1回転を、`rotateDuration` で終える(1回転の既定の長さは、確かめていない)。
            content.symbolEffect(.rotate, options: .speed(1 / IconButton.rotateDuration), value: presses)
        case nil:
            content
        }
    }
}

/// 押している間、少し縮める(押した感触)。
private struct PressButtonStyle: ButtonStyle {
    let reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.88 : 1)
            .animation(reduceMotion ? nil : .spring(duration: 0.2), value: configuration.isPressed)
    }
}

/// 枠の背景(コントロールセンターと同じ見た目)。
private struct CardBackground: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 12).fill(.fill.quaternary)
    }
}

/// 出力先・プリセットのいまの値を出す、文字列のタイル。パネルの見出しにも使う。
private struct SelectionTile: View {
    static let height: CGFloat = 26

    let title: String
    var isHeader = false
    /// 背景を自分で描くか。退かせるとき、背景だけをぼかさないために、外で描くことがある。
    var showsBackground = true

    static var background: some View {
        Capsule().fill(.fill.tertiary)
    }

    var body: some View {
        HStack(spacing: 4) {
            Text(verbatim: title)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            if isHeader {
                Image(systemName: "chevron.up")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: Self.height)
        .background { if showsBackground { Self.background } }
        .contentShape(Capsule())
    }
}

/// 選択パネルの選択肢1つ。いま選んでいるものに、印をつける。
private struct OptionRow: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "checkmark")
                    .font(.caption.weight(.semibold))
                    .opacity(isSelected ? 1 : 0)
                Text(verbatim: title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 24)
            .background(isHovered ? AnyShapeStyle(.fill.secondary) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 6))
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// ポップアップの中の確かめるカード。見出し、説明、ボタン2つ(キャンセル、進める)。
/// ダイアログと同じく、進めるボタンは Return キーでは押せない。Esc でキャンセルできる(仕様書 5章)。
/// キーボードで操作するときは、はじめは「キャンセル」にいる。読み上げは、出たらカードに移る。
private struct ConfirmCard: View {
    let title: String
    let message: String
    let proceedTitle: String
    let onCancel: () -> Void
    let onProceed: () -> Void

    @FocusState private var focusesCancel: Bool
    @AccessibilityFocusState private var readsTitle: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: title)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .accessibilityFocused($readsTitle)
            Text(verbatim: message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("キャンセル", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .focused($focusesCancel)
                // Return キーで押せないよう、既定のボタン(`.defaultAction`)にはしない。
                Button(role: .destructive, action: onProceed) {
                    Text(verbatim: proceedTitle).foregroundStyle(.red)
                }
            }
            .padding(.top, 4)
        }
        .padding(12)
        .popupPanelBackground()
        // 読み上げでは、カードの外へ移れないようにする(退いた中身は、操作できない)。
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .onAppear {
            // 出てくる動きの途中では、まだ移れないことがあるので、次の更新を待ってから移す。
            Task { @MainActor in
                focusesCancel = true
                readsTitle = true
            }
        }
    }
}

/// スライダーの右に出す数値(音量、ラウドネスの強さ)。幅を決めて右に寄せ、桁が変わってもスライダーの長さを変えない。
/// 右端は、枠の中の行の右端なので、タイル(出力先、プリセット)の右端とそろう。
/// となりのスライダーと同じく、使えないとき(`.disabled`)は薄く出す。
private struct ValueText: View {
    let value: Double
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Text(verbatim: "\(Int(value.rounded()))")
            .monospacedDigit()
            .foregroundStyle(isEnabled ? .secondary : .tertiary)
            .frame(width: 28, alignment: .trailing)
            // 値は、となりのスライダーが読み上げる(二重に読ませない)。
            .accessibilityHidden(true)
    }
}

/// 上端を軸に、縦だけ縮める(知らせの帯の出入りに使う)。
private struct VerticalScale: ViewModifier {
    let scale: CGFloat

    func body(content: Content) -> some View {
        content.scaleEffect(x: 1, y: scale, anchor: .top)
    }
}

/// 知らせの文。帯と、音量の枠の中で使う。
private struct NoticeText: View {
    let text: Text
    let color: Color

    var body: some View {
        text
            .font(.caption)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// いちばん上の帯に出す知らせ。文は、英語に訳せるよう、`Text` で受け取る。
private struct NoticeBanner<Accessory: View>: View {
    let text: Text
    let color: Color
    @ViewBuilder var accessory: () -> Accessory

    init(text: Text, color: Color, @ViewBuilder accessory: @escaping () -> Accessory = { EmptyView() }) {
        self.text = text
        self.color = color
        self.accessory = accessory
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            NoticeText(text: text, color: color)
            accessory()
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// 枠の内側の余白。枠の外の行(音声の加工と出力先、設定と終了)も、この分だけ内へ寄せ、ボタンの縦の中心をそろえる。
private let popupCardPadding: CGFloat = 10

private extension View {
    /// 選択パネルを開いている間、退かせる(消える、ぼける、少し縮む)。`order` の順に、少しずつずらして始める。
    /// 戻るときは、パネルがタイルへ戻り始めてから、同じ順に戻す。
    /// 退いている間は、マウスでもキーボードでも操作できない(見えないボタンで、加工を切ったり終了したりしないため)。
    ///
    /// 枠と欄の背景(`.fill.quaternary` などの半透明の塗り)には、`blurs: false` を渡してぼかさない。
    /// ぼかすと、ぼかしの始めと終わりに、背景が一瞬白く光る(2026-10-20 に実害。`docs/failures.md`)。
    func receding(order: Int, isReceded: Bool, reduceMotion: Bool, blurs: Bool = true) -> some View {
        let delay = isReceded ? Double(order) * 0.025 : 0.1 + Double(order) * 0.025
        return opacity(isReceded ? 0 : 1)
            .blur(radius: isReceded && blurs && !reduceMotion ? 6 : 0)
            .scaleEffect(isReceded && !reduceMotion ? 0.96 : 1)
            .allowsHitTesting(!isReceded)
            .disabled(isReceded)
            .animation(.easeOut(duration: 0.15).delay(delay), value: isReceded)
    }

    /// 枠の外の行(音声の加工と出力先、設定と終了)。枠の内側の余白と同じだけ内へ寄せ、枠の中のボタンと縦の中心をそろえる。
    func popupRow() -> some View {
        padding(.horizontal, popupCardPadding)
    }

    /// 関係する項目をまとめる、角の丸い枠(コントロールセンターと同じ見た目)。
    func popupCard() -> some View {
        popupCard { CardBackground() }
    }

    /// 枠ごと退かせる。中身はぼかすが、背景(半透明の塗り)はぼかさない(`receding` の説明)。
    func recedingCard(order: Int, isReceded: Bool, reduceMotion: Bool) -> some View {
        receding(order: order, isReceded: isReceded, reduceMotion: reduceMotion)
            .popupCard {
                CardBackground().receding(order: order, isReceded: isReceded, reduceMotion: reduceMotion, blurs: false)
            }
    }

    /// 中身の上に重ねるもの(選択パネル、確かめるカード)の背景。幅はポップアップいっぱい。
    /// パネルとカードで同じにする(パネルがカードへ移り変わるときに、背景が変わって見えないように)。
    func popupPanelBackground() -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
            .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }

    /// 背景を渡す形。背景だけを退かせたいときに使う。
    func popupCard<Background: View>(@ViewBuilder background: () -> Background) -> some View {
        padding(popupCardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background())
    }
}
