import AppKit
import CoreAudio
import Foundation
import Observation
import SimpleEqualizerCore

/// アプリの状態。音量、消音、加工の状態を持ち、音声の経路と保存をつなぐ。
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    enum Status: Equatable {
        case starting
        case running
        /// 利用者が「音声の加工」を切った。
        case stoppedByUser
        /// 加工を始められなかった。音声には触っていない。
        case failed(String)
    }

    /// macOS の、いまの出力先。加工の対象は、いまの出力先(と、音量を変えられない出力先の全部)。
    /// 画面の音量と消音は、いまの出力先のものを出す。出力先が見つからないときは nil。
    private(set) var currentDevice: OutputDevice?
    /// ポップアップのプルダウンに並べる出力先(macOS の出力先になれる装置と、いまの出力先。並べ方は `OutputDevice.menuOrder`)。
    private(set) var outputDevices: [OutputDevice] = []
    /// 直前に選んだ出力先へ、切り替えられなかったか。出力先が変わるか、次に切り替えられたら消える。
    private(set) var didFailToSelectOutput = false

    private(set) var status: Status = .starting
    /// 動いているはずなのに、コールバックが呼ばれなくなっている。
    private(set) var isStalled = false
    /// 前回の設定を読めなかったときの説明。起動している間、出し続ける。
    private(set) var loadProblem: String?
    /// 直前の保存に失敗したか。次の保存が成功したら消える。
    private(set) var didFailToSave = false

    /// 音を取り出せていない(「システム音声の録音」の許可がないかもしれない)。
    private(set) var isCaptureSuspected = false

    /// キーボードの音量キーを、アプリが受け取るか(設定のウィンドウで切り替える)。初期値は入。
    /// 切のときは、音量キーに触らず、macOS に任せる。
    var volumeKeysEnabled = true {
        didSet {
            guard volumeKeysEnabled != oldValue, !isApplyingStoredSettings else { return }
            state.volumeKeysEnabled = volumeKeysEnabled
            scheduleSave()
            // 入にしたときに許可がなければ、許可を求める(仕様書 5.3)。切にしたときは、受け取りを外す。
            if volumeKeysEnabled, !VolumeKeyTap.hasPermission {
                requestVolumeKeyPermission()
            }
            checkVolumeKeyPermission()
        }
    }

    /// いまの出力先の経路が、無音でない音を1回でも受け取ったか(「システム音声の録音」の許可があることの手がかり)。
    /// 画面から、少しおきに読む。
    var hasReceivedSignal: Bool { currentPath?.hasReceivedSignal ?? false }

    /// 音量キーを使うための「アクセシビリティ」の許可が、まだないか。
    private(set) var volumeKeysNeedPermission = false
    /// 許可はあるのに、音量キーの受け取りを始められなかったか。
    private(set) var didFailToInstallVolumeKeys = false

    /// メニューバーのアイコンで知らせる必要があるか(加工していない、止まっている、音を取り出せていない)。
    var needsAttention: Bool {
        switch status {
        case .starting:
            false
        case .running:
            isStalled || isCaptureSuspected
        case .stoppedByUser:
            true
        case .failed:
            // 加工できていなくても、macOS の音量で変えられる出力先なら、危なくないので、知らせない。
            // 出力先が分からないときは、知らせる。
            currentDevice?.isVolumeControlEnabled ?? true
        }
    }

    var volume: Double = VolumeCurve.defaultVolume {
        didSet { if volume != oldValue { settingsChanged() } }
    }
    var isMuted = false {
        didSet { if isMuted != oldValue { settingsChanged() } }
    }

    /// イコライザーが入か。出力先に共通。
    var isEqualizerEnabled = true {
        didSet { if isEqualizerEnabled != oldValue { equalizerChanged() } }
    }
    /// 音量調整が無効の出力先で、増幅した分だけ、全体を自動で下げるか。出力先に共通。初期値は入。
    /// 切にすると、スピーカーごとに音量を合わせた状態で、音質を聴き比べられる(イコライザーの入・切で、全体の大きさが変わらない)。
    var autoLowerEnabled = true {
        didSet { if autoLowerEnabled != oldValue { autoLowerChanged() } }
    }

    /// いまの出力先で、増幅した分だけ自動で下げている量(dB)。下げていなければ 0。
    var currentAttenuationDb: Double {
        currentDevice?.autoAttenuationDb(
            equalizer: equalizer, equalizerEnabled: isEqualizerEnabled, autoLowerEnabled: autoLowerEnabled) ?? 0
    }

    /// ラウドネスの強さ(0〜100)。0 で効かない。出力先に共通。音量を下げるほど、低音と高音を持ち上げる。
    /// 切の間も変えられ、入に戻すと、この強さで効く。
    var loudnessAmount: Double = 0 {
        didSet { if loudnessAmount != oldValue { loudnessChanged() } }
    }
    /// ラウドネスの入・切。出力先に共通。
    var isLoudnessEnabled = true {
        didSet { if isLoudnessEnabled != oldValue { loudnessChanged() } }
    }
    /// イコライザーのいまの値。変えるときは `setEqualizerGain` か `resetEqualizer` を使う。
    private(set) var equalizer = EqualizerSettings.flat

    /// プリセットの一覧。先頭は「フラット」。
    private(set) var library = PresetLibrary()
    /// 選んでいるプリセット。`equalizer` は、保存していない変更を含む、いまの値。
    private(set) var selectedPresetID = Preset.flatID
    /// プリセットのファイルを読めなかったときの説明。起動している間、出し続ける。
    private(set) var presetLoadProblem: String?
    /// プリセットを変えてよいか。読めなかったファイルを上書きしないよう、変えられなくすることがある。
    private(set) var canEditPresets = true
    /// 直前のプリセットの保存に失敗したか。次の保存が成功したら消える。
    private(set) var didFailToSavePresets = false

    var isRunning: Bool { status == .running }

    /// いまの出力先で、アプリの音量調整(音量、消音、ラウドネス、音量キー)が有効か。
    /// 無効なのは、macOS の音量で変えられる出力先(内蔵スピーカーなど)。出力先が分からないときは、有効として扱う。
    var isVolumeControlEnabled: Bool {
        currentDevice?.isVolumeControlEnabled ?? true
    }

    /// 音声の経路。出力先(装置の UID)ごとに1つ。
    /// 音量を変えられない出力先の経路は、出力先でないあいだも、持ったままにする(戻した瞬間に、最大音量が出ないようにする)。
    /// 装置が抜かれたら、片付ける(差し直すと、装置の番号が変わり、前の経路は音を取り出せなくなるため)。
    @ObservationIgnored private var paths: [String: AudioPath] = [:]
    /// 片付けようとしたが、コールバックが止まったと確かめられなかった経路。捨てると、まだ呼ばれているコールバックが、
    /// 解放したメモリに触るおそれがあるので、アプリを終えるまで、持っておく。
    @ObservationIgnored private var retiredPaths: [AudioPath] = []
    /// 経路を始められなかったときに、すぐにやり直す回数の残り。出力先の顔ぶれが変わるたびに、戻す。
    @ObservationIgnored private var quickRetriesLeft = 0
    /// 経路を作ったときの、出力先の情報。
    @ObservationIgnored private var pathDevices: [String: OutputDevice] = [:]
    /// 経路を始められなかった出力先と、その理由。出力先が変わるまで、やり直さない。
    @ObservationIgnored private var startFailures: [String: String] = [:]
    /// 利用者が「音声の加工」を入にしているか。
    @ObservationIgnored private var isProcessingEnabled = true
    @ObservationIgnored private lazy var outputWatcher = OutputWatcher { [weak self] in
        self?.reconcileOutputs()
    }
    /// 前に出力先を確かめたときの、装置の番号の一覧と、いまの出力先の番号。変わったかを確かめるのに使う。
    @ObservationIgnored private var lastOutputSignature: [AudioObjectID] = []
    /// 前に出力先を確かめたときの、出力先の識別子の一覧と、いまの出力先の識別子。
    /// これが変わったら、前に始められなかった出力先を、もう一度試す。
    @ObservationIgnored private var lastOutputUIDs: [String] = []
    /// Mac がスリープに入ろうとしている、またはスリープしているか。
    /// この間は、経路を作ったり片付けたりしない。スリープの間は、装置を始められず(エラーになる)、
    /// 持ったままの経路は、復帰すると、何もしなくても、また動き出す(`docs/failures.md` の 2026-10-14)。
    @ObservationIgnored private var isSystemSleeping = false
    /// スリープの印が立っている間に、コールバックが止まったのを見たか(`checkStalled`)。
    @ObservationIgnored private var didStopWhileSleeping = false
    @ObservationIgnored private let keyTap = VolumeKeyTap()
    @ObservationIgnored private let volumeHUD = VolumeHUD()
    @ObservationIgnored private let store = StateStore(directory: StateStore.defaultDirectory)
    @ObservationIgnored private let presetStore = PresetStore(directory: StateStore.defaultDirectory)
    @ObservationIgnored private var state = AppState()
    /// 読めなかったファイルを、初期値で上書きしないための印。
    @ObservationIgnored private var canSave = true
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var watchTask: Task<Void, Never>?
    /// 覚えていた設定を画面へ写している間は、保存や音声の経路への反映をしない。
    @ObservationIgnored private var isApplyingStoredSettings = false
    @ObservationIgnored private var lastCallbackCount: UInt64 = 0
    @ObservationIgnored private var checkCount = 0
    @ObservationIgnored private var captureWatch = CaptureWatch()
    /// 見張りの回数(何回かに1回だけ行う確かめに使う)。
    @ObservationIgnored private var watchCount = 0
    /// 覚えていた選択(`state.selectedPresetID`)を、書き換えずに残しておくか(`rememberSelectedPreset`)。
    @ObservationIgnored private var keepsStoredSelection = false
    /// いま、それぞれの経路に設定してある、ラウドネスの補正量。エンジンは、経路を作るたびに作り直される。
    @ObservationIgnored private var appliedLoudness: [String: LoudnessCurve.Correction] = [:]

    private var currentSettings: OutputSettings {
        OutputSettings(volume: volume, muted: isMuted)
    }

    // MARK: - 起動と終了

    /// 起動時に呼ぶ。保存した状態を読み込み、加工を自動で始める。
    func launch() {
        let result = store.load()
        state = result.state
        canSave = result.isSafeToSave
        loadProblem = result.problemDescription
        // プリセットの一覧を読む。選んでいたプリセットが一覧になければ、「フラット」を選んでいるものとする。
        let presets = presetStore.load()
        library = presets.library
        canEditPresets = presets.isSafeToSave
        presetLoadProblem = presets.problemDescription
        selectedPresetID = library.resolvedSelection(state.selectedPresetID)
        // 一覧を読めなかったせいで、覚えていた選択が見つからなかったときは、利用者が選び直すまで、その記録を書き換えない。
        keepsStoredSelection = presets.shouldKeepStoredSelection(state.selectedPresetID)

        // 覚えていたイコライザーの設定を画面へ写す(保存や音声の経路への反映はしない)。
        isApplyingStoredSettings = true
        equalizer = state.equalizer
        isEqualizerEnabled = state.equalizerEnabled
        loudnessAmount = state.loudnessAmount
        isLoudnessEnabled = state.loudnessEnabled
        autoLowerEnabled = state.autoLowerEnabled
        volumeKeysEnabled = state.volumeKeysEnabled
        isApplyingStoredSettings = false
        outputWatcher.start()
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isSystemSleeping = true
                self?.didStopWhileSleeping = false
            }
        }
        workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.systemDidWake() }
        }
        startProcessing()
        setUpVolumeKeys()
        startWatching()
    }

    /// 終了時に呼ぶ。状態を保存し、音声の経路を片付ける。
    func shutdown() {
        watchTask?.cancel()
        saveTask?.cancel()
        // 音量キーを、macOS に戻す。
        keyTap.remove()
        volumeHUD.hide()
        saveNow()
        // 前のプリセットの保存に失敗していたら、もう一度試す。
        if didFailToSavePresets {
            savePresets()
        }
        stopAllPaths()
    }

    // MARK: - 加工の開始と停止

    /// スリープから復帰した。持ったままの経路は、何もしなくても、また動き出す。
    /// 復帰の直後は、装置がまだ落ち着いていないので、少し待ってから、経路に触ってよいことにして、出力先を合わせ直す
    /// (スリープの間に、出力先が変わっていた場合のため)。
    private func systemDidWake() {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            self?.finishWaking()
        }
    }

    /// スリープが終わったものとして、経路に触ってよいことにする。
    private func finishWaking() {
        guard isSystemSleeping else { return }
        isSystemSleeping = false
        // スリープの間に始められなかったものがあれば、もう一度試す。見張りも、数え直す。
        startFailures = [:]
        resetWatchCounters()
        reconcileOutputs()
    }

    /// 利用者が「音声の加工」を入れたとき、起動したとき。
    func startProcessing() {
        // 利用者が自分で入れ直したときは、スリープの印が残っていても(復帰の知らせを受け損ねていても)、始める。
        isSystemSleeping = false
        isProcessingEnabled = true
        // 前に始められなかった出力先も、もう一度試す。
        startFailures = [:]
        reconcileOutputs()
    }

    /// 利用者が「音声の加工」を切ったとき。音は、加工なしの元の音量に戻る。
    func stopProcessing() {
        isProcessingEnabled = false
        stopAllPaths()
        updateStatus()
    }

    private func stopAllPaths() {
        // 先に、全部の経路で音を消し始める。1本ずつ順に消すと、その数だけ待つことになる。
        for path in paths.values {
            path.beginFadeOut()
        }
        for path in paths.values where !path.stop() {
            retiredPaths.append(path)
        }
        paths = [:]
        pathDevices = [:]
        appliedLoudness = [:]
        startFailures = [:]
    }

    // MARK: - 出力先に合わせる

    /// いまの出力先(装置の UID)の経路。
    private var currentPath: AudioPath? {
        currentDevice.flatMap { paths[$0.uid] }
    }

    /// 利用者がポップアップで選んだ装置を、macOS の出力先にする。
    /// 経路と画面は、ここでは変えない。macOS からの知らせで `reconcileOutputs` が合わせる(macOS のメニューで切り替えたときと同じ)。
    func selectOutput(uid: String) {
        guard uid != currentDevice?.uid else { return }
        // 装置の番号は抜き差しで変わるので、選んだときに引き直す。
        let failed = !(OutputDevices.deviceID(forUID: uid).map(OutputDevices.setDefaultOutput) ?? false)
        if didFailToSelectOutput != failed { didFailToSelectOutput = failed }
    }

    /// いまある出力先に合わせて、経路を作ったり、片付けたりする。画面の音量と消音を、いまの出力先のものにする。
    ///
    /// 出力先が変わった知らせ、装置が増えた・減った知らせのたびに呼ぶ。知らせは、同じものが続けて来ることがあり、
    /// アプリが自分で集約装置を作ったり消したりしたときにも来るので、何度呼んでも同じ結果になるようにしてある。
    private func reconcileOutputs() {
        // スリープの間は、何もしない。復帰したときに、合わせ直す(`systemDidWake`)。
        guard !isSystemSleeping else { return }
        let ownAggregates = Set(paths.values.map(\.aggregateDeviceID).filter { $0 != kAudioObjectUnknown })
        let entries = OutputDevices.all(excluding: ownAggregates)
        let defaultID = OutputDevices.defaultOutputID()
        let current = entries.first { $0.id == defaultID }
        lastOutputSignature = OutputDevices.signature()
        let listed = OutputDevice.menuOrder(entries.filter { $0.canBeDefault || $0.id == defaultID }.map(\.device))
        if listed != outputDevices { outputDevices = listed }

        // 加工を切っている間も、画面の出力先と、音量を覚える先は、いまの出力先に合わせる。
        guard isProcessingEnabled else {
            setCurrentDevice(current?.device)
            updateStatus()
            return
        }

        // 出力先の顔ぶれか、いまの出力先が変わったときだけ、前に始められなかった出力先を、もう一度試す。
        // 知らせのたびに試すと、作りかけの集約装置を消したときの知らせで、やり直しが止まらなくなる。
        let outputUIDs = entries.map(\.device.uid).sorted() + [current?.device.uid ?? ""]
        if outputUIDs != lastOutputUIDs {
            lastOutputUIDs = outputUIDs
            startFailures = [:]
            // 装置を差した直後は、情報をまだ読めず、始めるのに失敗することがある。少しおいて、何回か、やり直す。
            quickRetriesLeft = 3
        }

        // 経路を持つ出力先: いまの出力先と、音量を変えられない出力先の全部(扱える形のものだけ)。
        var wanted: [String: OutputDevices.Entry] = [:]
        for entry in entries where entry.device.unsupportedReason == nil {
            if entry.id == defaultID || entry.device.keepsPathWhileNotDefault {
                wanted[entry.device.uid] = entry
            }
        }

        // 要らなくなった経路を片付ける。
        // - 音量を変えられる出力先が、いまの出力先でなくなった。
        // - 装置が抜かれた。差し直すと、装置の番号が変わり、前の経路は、動いていても音を取り出せなくなる
        //   (`docs/failures.md` の 2026-10-14)。持ったままにせず、差し直されたときに、作り直す。
        // - 装置の番号が変わっている(気づかないうちに、抜いて差し直されていた)。片付けて、下で作り直す。
        // 装置の情報を、一時的に読めなかっただけのとき(装置は一覧にあるのに、情報が取れなかった)は、片付けない。
        let listedIDs = Set(OutputDevices.deviceIDs())
        let presentUIDs = Set(entries.map(\.device.uid))
        var unwanted: [String] = []
        var rateChanged: [OutputDevices.Entry] = []
        for (uid, path) in paths {
            if let entry = wanted[uid] {
                if path.isRunning, path.outputDeviceID != entry.id {
                    unwanted.append(uid)
                } else if path.isRunning, path.startedSampleRate > 0, entry.device.sampleRate > 0,
                          entry.device.sampleRate != path.startedSampleRate {
                    // 周波数が、作ったときと違う(知らせを受けた、または取りこぼしていた)。下で、作り直す。
                    // 片付けてから作るのではなく、新しい経路を作ってから片付ける(`rebuildPath`)。
                    rateChanged.append(entry)
                }
            } else if presentUIDs.contains(uid) || (!listedIDs.isEmpty && !listedIDs.contains(path.outputDeviceID)) {
                unwanted.append(uid)
            }
        }
        // 先に、片付ける全部の経路で音を消し始める(1本ずつ順に消すと、その数だけ待つことになる)。
        for uid in unwanted {
            paths[uid]?.beginFadeOut()
        }
        for uid in unwanted {
            removePath(uid)
        }
        for entry in rateChanged {
            rebuildPath(for: entry)
        }

        var didStartCurrentPath = false
        // いまの出力先の経路を、先に作る(ほかの経路を作っている間、待たせない)。
        let ordered = wanted.sorted { first, second in first.value.id == defaultID && second.value.id != defaultID }
        for (uid, entry) in ordered {
            if let path = paths[uid], path.isRunning {
                // 動いている経路。装置の性質(自分で音量を変えられるか)が変わっていたら、合わせる。
                if pathDevices[uid] != entry.device {
                    pathDevices[uid] = entry.device
                    applyOutputValues(to: uid)
                }
            } else if startFailures[uid] == nil {
                startPath(for: entry)
                if entry.id == defaultID { didStartCurrentPath = true }
            }
        }

        setCurrentDevice(current?.device)
        if didStartCurrentPath {
            // いまの出力先の経路を作り直した。止まっていないか、音を取り出せているかの見張りを、数え直す。
            resetWatchCounters()
        }
        updateStatus()
    }

    private func removePath(_ uid: String) {
        if let path = paths[uid], !path.stop() {
            // コールバックが止まったと確かめられなかった。捨てずに、持っておく。
            retiredPaths.append(path)
        }
        paths[uid] = nil
        pathDevices[uid] = nil
        appliedLoudness[uid] = nil
    }

    private func resetWatchCounters() {
        if isStalled { isStalled = false }
        checkCount = 0
        lastCallbackCount = 0
        resetCaptureWatch()
    }

    /// その出力先の経路を作って、加工を始める。始められなかったときは、理由を覚えておく。
    private func startPath(for entry: OutputDevices.Entry) {
        let device = entry.device
        let path = paths[device.uid] ?? AudioPath()
        let values = outputValues(for: device)
        do {
            // 倍率、ラウドネスの補正量、イコライザーの値は、音を出し始める前に渡す。
            _ = try path.start(
                outputID: entry.id, outputUID: device.uid, deviceName: device.name,
                equalizer: equalizer, equalizerEnabled: isEqualizerEnabled, initial: values)
            paths[device.uid] = path
            pathDevices[device.uid] = device
            appliedLoudness[device.uid] = values.loudness
            // 出力装置のサンプリング周波数が変わったら、経路を作り直す。
            path.onSampleRateChange = { [weak self] in
                self?.sampleRateDidChange()
            }
            // 作っている間に、周波数が変わっていたら(知らせは、作り終える前に来て、捨てられている)、あとで合わせ直す。
            if path.startedSampleRate > 0, path.currentOutputSampleRate != path.startedSampleRate {
                Task { [weak self] in self?.sampleRateDidChange() }
            }
        } catch {
            paths[device.uid] = nil
            pathDevices[device.uid] = nil
            appliedLoudness[device.uid] = nil
            startFailures[device.uid] = "\(error)"
            scheduleQuickRetry(of: device.uid)
        }
    }

    /// 出力装置のサンプリング周波数が変わった知らせを受けた。出力先に合わせ直す(周波数が変わった経路は、作り直される)。
    private func sampleRateDidChange() {
        reconcileOutputs()
    }

    /// 周波数が変わった経路を、新しい周波数で作り直す。
    ///
    /// 経路(タップ、集約装置、エンジン、リミッター)は、作ったときの周波数で動いている。周波数が変わると、
    /// 音がとぎれる(取り出した音が、ところどころ無音になる)。エンジンも、前の周波数のまま計算するので、
    /// イコライザーの効く高さがずれる。作り直すと直る(`docs/failures.md` の 2026-10-15)。
    ///
    /// 前の経路の音を消してから、前の経路は残したまま、新しい経路を作り、できたら前の経路を片付ける。
    /// - 先に片付けると、作り直す間(周波数が変わった直後は 0.7 秒ほどかかる)、元の音を消すものがなくなり、
    ///   加工なしの元の大きさの音が出る。前の経路が残っていれば、そのタップが、元の音を消し続ける。
    /// - 前の経路の音を先に消すのは、2つの経路の音が重なって、元の大きさを超えないようにするため。
    ///   そのかわり、作り直す間は、無音になる。
    /// - 新しい経路を作れなかったときは、前の経路の音を戻して、そのまま使う。
    private func rebuildPath(for entry: OutputDevices.Entry) {
        let uid = entry.device.uid
        guard let oldPath = paths[uid] else { return }
        oldPath.beginFadeOut()
        paths[uid] = nil
        startPath(for: entry)
        if let newPath = paths[uid], newPath.isRunning {
            if !oldPath.stop() {
                retiredPaths.append(oldPath)
            }
        } else {
            oldPath.cancelFadeOut()
            paths[uid] = oldPath
            pathDevices[uid] = entry.device
            startFailures[uid] = nil
            appliedLoudness[uid] = nil
            applyOutputValues(to: uid)
        }
        if uid == currentDevice?.uid {
            resetWatchCounters()
        }
    }

    /// 始められなかった出力先を、1 秒後に、もう一度試す。装置を差した直後の、一時的な失敗のため。
    /// 何度もやり直さないよう、回数に上限がある(出力先の顔ぶれが変わるたびに、3 回まで)。
    private func scheduleQuickRetry(of uid: String) {
        guard quickRetriesLeft > 0 else { return }
        quickRetriesLeft -= 1
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, startFailures[uid] != nil else { return }
            startFailures[uid] = nil
            reconcileOutputs()
        }
    }

    /// その出力先の音に掛ける、倍率とラウドネスの補正量。出力先ごとに覚えている音量と消音から決める。
    private func outputValues(for device: OutputDevice) -> AudioPathInitialValues {
        let settings = state.settings(forOutput: device.uid)
        let attenuation = device.autoAttenuationDb(
            equalizer: equalizer, equalizerEnabled: isEqualizerEnabled, autoLowerEnabled: autoLowerEnabled)
        return AudioPathInitialValues(
            gain: device.gain(settings: settings, attenuationDb: attenuation),
            loudness: device.loudness(settings: settings, amount: state.effectiveLoudnessAmount))
    }

    /// その出力先の経路に、いまの倍率とラウドネスの補正量を伝える。補正量は、変わったときだけ伝える。
    private func applyOutputValues(to uid: String) {
        guard let path = paths[uid], let device = pathDevices[uid] else { return }
        let values = outputValues(for: device)
        path.setGain(values.gain)
        if appliedLoudness[uid] != values.loudness {
            appliedLoudness[uid] = values.loudness
            path.setLoudness(values.loudness)
        }
    }

    private func applyOutputValuesToAllPaths() {
        for uid in paths.keys {
            applyOutputValues(to: uid)
        }
    }

    /// いまの出力先が変わったら、画面の音量と消音を、その出力先について覚えているものにする。
    private func setCurrentDevice(_ device: OutputDevice?) {
        guard device != currentDevice else { return }
        let isSameOutput = device?.uid == currentDevice?.uid
        currentDevice = device
        guard !isSameOutput else { return }
        if didFailToSelectOutput { didFailToSelectOutput = false }
        if let device {
            // 覚えていた設定を画面へ写す(保存や音声の経路への反映はしない)。
            let settings = state.settings(forOutput: device.uid)
            isApplyingStoredSettings = true
            volume = settings.volume
            isMuted = settings.muted
            isApplyingStoredSettings = false
        }
        // 見張りは、いまの出力先の経路について行う。出力先が変わったら、数え直す。
        resetWatchCounters()
    }

    /// いまの出力先の様子から、画面に出す状態を決める。
    private func updateStatus() {
        let newStatus: Status
        if !isProcessingEnabled {
            newStatus = .stoppedByUser
        } else if let device = currentDevice {
            if let reason = device.unsupportedReason {
                newStatus = .failed(String(localized: "「\(device.name)」は、対応していない出力先です。\(reason.description)"))
            } else if paths[device.uid]?.isRunning == true {
                newStatus = .running
            } else {
                newStatus = .failed(startFailures[device.uid] ?? String(localized: "「\(device.name)」の加工を始められませんでした。"))
            }
        } else {
            newStatus = .failed(String(localized: "出力先が見つかりません。"))
        }
        // 値が変わったときだけ書く(同じ値でも、書くと画面が作り直される)。
        if status != newStatus {
            status = newStatus
            if newStatus != .running, isStalled { isStalled = false }
        }
    }

    // MARK: - 音量と消音

    /// 画面の音量か消音が変わった。いまの出力先について覚え、その経路に伝える。
    private func settingsChanged() {
        guard !isApplyingStoredSettings, let uid = currentDevice?.uid else { return }
        state.setSettings(currentSettings, forOutput: uid)
        applyOutputValues(to: uid)
        scheduleSave()
    }

    // MARK: - 音量キー

    /// 音量キーの受け取りを始める。「アクセシビリティ」の許可がなければ、許可が出るのを待つ(`checkVolumeKeyPermission`)。
    private func setUpVolumeKeys() {
        // 加工している間だけ、キーをアプリが受け取る。加工していないとき、止まっているときは、macOS に任せる。
        keyTap.isActive = { [weak self] in
            // 設定で切にしているときは、キーに触らず、macOS に任せる。
            guard let self, volumeKeysEnabled, let device = currentDevice else { return false }
            // 音量調整が無効の出力先(macOS の音量で変えられる出力先)では、キーに触らず、macOS に任せる。
            return device.interceptsVolumeKeys(isRunning: isRunning, isStalled: isStalled)
        }
        keyTap.onKey = { [weak self] key, fine in self?.handleVolumeKey(key, fine: fine) }
        checkVolumeKeyPermission()
    }

    /// 許可が出ていたら、受け取りを始める。許可が取り消されていたら、受け取りを外す。
    /// 許可は、利用者がシステム設定で変えるので、見張りのたびに確かめる。
    private func checkVolumeKeyPermission() {
        // 音量キーを使わない設定のときは、受け取りを外し、許可のことも出さない(キーの処理を、無駄に通さない)。
        guard volumeKeysEnabled else {
            keyTap.remove()
            if volumeKeysNeedPermission { volumeKeysNeedPermission = false }
            if didFailToInstallVolumeKeys { didFailToInstallVolumeKeys = false }
            return
        }
        let hasPermission = VolumeKeyTap.hasPermission
        var failed = false
        if !hasPermission {
            // 許可がないまま受け取りを残すと、キーが、アプリにも macOS にも届かなくなるおそれがある。
            keyTap.remove()
        } else if !keyTap.isInstalled {
            failed = !keyTap.install()
        }
        // 値が変わったときだけ書く(同じ値でも、書くと画面が作り直される)。
        if volumeKeysNeedPermission != !hasPermission {
            volumeKeysNeedPermission = !hasPermission
        }
        if didFailToInstallVolumeKeys != failed {
            didFailToInstallVolumeKeys = failed
        }
    }

    /// 「アクセシビリティ」の許可を求める(macOS の案内が出る)。
    func requestVolumeKeyPermission() {
        VolumeKeyTap.requestPermission()
    }

    private func handleVolumeKey(_ key: VolumeKey, fine: Bool) {
        guard isRunning, currentDevice?.isVolumeControlEnabled == true else { return }
        let changed = currentSettings.applying(key, fine: fine)
        // 音量と消音を、まとめて反映する。別々に反映すると、消音を解いた瞬間に、変える前の音量へ向かい始める。
        isApplyingStoredSettings = true
        volume = changed.volume
        isMuted = changed.muted
        isApplyingStoredSettings = false
        settingsChanged()
        volumeHUD.show(volume: volume, isMuted: isMuted)
    }

    // MARK: - ラウドネス

    /// 自動で下げる設定が変わった。下げる量は、出力先ごとに決まるので、全部の経路に伝え直す。
    /// 倍率は、コールバックの中で、なめらかに変わる(切り替えた瞬間に、雑音は出ない)。
    private func autoLowerChanged() {
        guard !isApplyingStoredSettings else { return }
        state.autoLowerEnabled = autoLowerEnabled
        applyOutputValuesToAllPaths()
        scheduleSave()
    }

    /// ラウドネスの強さか入・切が変わった。補正量は、出力先ごとの音量で決まるので、全部の経路に伝え直す。
    private func loudnessChanged() {
        guard !isApplyingStoredSettings else { return }
        state.loudnessAmount = loudnessAmount
        state.loudnessEnabled = isLoudnessEnabled
        applyOutputValuesToAllPaths()
        scheduleSave()
    }

    // MARK: - イコライザー

    /// あるバンドの値を変える。範囲に収め、0.5 dB 刻みに丸める(`EqualizerSettings`)。
    func setEqualizerGain(_ gain: Double, at band: Int) {
        var changed = equalizer
        changed.setGain(gain, at: band)
        guard changed != equalizer else { return }
        equalizer = changed
        equalizerChanged()
    }

    func resetEqualizer() {
        guard !equalizer.isFlat else { return }
        equalizer.reset()
        equalizerChanged()
    }

    private func equalizerChanged() {
        guard !isApplyingStoredSettings else { return }
        // イコライザーは、どの出力先にも、同じ値を掛ける。
        for path in paths.values {
            path.setEqualizer(equalizer, enabled: isEqualizerEnabled)
        }
        // 音量調整が無効の出力先では、増幅した分だけ、自動で下げる。下げる量は、イコライザーの値で変わる。
        applyOutputValuesToAllPaths()
        state.equalizer = equalizer
        state.equalizerEnabled = isEqualizerEnabled
        rememberSelectedPreset()
        scheduleSave()
    }

    /// 選んでいるプリセットを、保存する状態に写す。
    /// プリセットのファイルを読めなかったせいで、覚えていた選択が一覧になかった起動では、利用者が選び直すまで、写さない
    /// (スライダーを動かしただけで、覚えていた選択を「フラット」で上書きしない)。
    private func rememberSelectedPreset() {
        guard !keepsStoredSelection else { return }
        state.selectedPresetID = selectedPresetID
    }

    // MARK: - プリセット

    /// 選んでいるプリセット。
    var selectedPreset: Preset {
        library.preset(withID: selectedPresetID) ?? .flat
    }

    /// いまの値が、選んでいるプリセットの値と違うか(保存していない変更があるか)。
    var isEqualizerModified: Bool {
        library.isModified(equalizer, comparedTo: selectedPresetID)
    }

    /// 「保存」(選んでいるプリセットの上書き)ができるか。「フラット」は上書きできない。
    var canOverwriteSelectedPreset: Bool {
        canEditPresets && !selectedPreset.isBuiltIn && isEqualizerModified
    }

    /// プリセットを選ぶ。10 バンドの値が、そのプリセットの値になる。保存していない変更は消える。
    /// 変更があるときに確かめるのは、呼び出す側(画面)が行う。
    func selectPreset(_ id: UUID) {
        guard let preset = library.preset(withID: id) else { return }
        guard preset.id != selectedPresetID || preset.gains != equalizer else { return }
        if preset.id != selectedPresetID {
            // 利用者が、自分で別のプリセットを選んだ。ここからは、選択を記録してよい。
            keepsStoredSelection = false
        }
        selectedPresetID = preset.id
        equalizer = preset.gains
        equalizerChanged()
    }

    /// 保存していない変更を捨て、選んでいるプリセットの値に戻す。
    func revertToSelectedPreset() {
        selectPreset(selectedPresetID)
    }

    /// 選んでいるプリセットを、いまの値で上書きする(「保存」)。
    /// ファイルへ保存できたかは、`didFailToSavePresets` で分かる。
    func overwriteSelectedPreset() throws(PresetError) {
        guard canEditPresets else { throw .readOnly }
        try library.overwrite(id: selectedPresetID, gains: equalizer)
        savePresets()
    }

    /// いまの値を、新しいプリセットとして保存し、それを選ぶ(「別名で保存」)。値は変わらないので、音は変わらない。
    /// ファイルへ保存できたかは、`didFailToSavePresets` で分かる。
    func saveAsNewPreset(name: String) throws(PresetError) {
        guard canEditPresets else { throw .readOnly }
        let preset = try library.add(name: name, gains: equalizer)
        selectedPresetID = preset.id
        rememberSelectedPreset()
        savePresets()
        saveStateNow()
    }

    /// 選んでいるプリセットの、名前の変更と削除ができるか。「フラット」は、どちらもできない。
    var canModifySelectedPreset: Bool {
        canEditPresets && !selectedPreset.isBuiltIn
    }

    /// プリセットの名前を変える。値は変わらないので、音は変わらない。
    func renamePreset(id: UUID, to name: String) throws(PresetError) {
        guard canEditPresets else { throw .readOnly }
        try library.rename(id: id, to: name)
        savePresets()
    }

    /// プリセットを消す。選んでいたプリセットを消したときは、「フラット」に切り替える(値はすべて 0 dB になり、音が変わる)。
    /// 値を残して「フラット *」にする案もあったが、利用者には状況が分かりにくいので、採らなかった(2026-10-13、利用者の判断)。
    /// 音を下げる設定のプリセットを消すと、音が大きくなる。確かめる画面で、そのことを伝える(呼び出す側が行う)。
    func deletePreset(id: UUID) throws(PresetError) {
        guard canEditPresets else { throw .readOnly }
        try library.delete(id: id)
        if selectedPresetID == id {
            selectedPresetID = Preset.flatID
            equalizer = Preset.flat.gains
            equalizerChanged()
        }
        savePresets()
        // 一覧と、選んでいるプリセットの記録が、食い違ったまま残らないよう、状態もすぐ保存する。
        saveStateNow()
    }

    /// 書き出すプリセットがあるか(「フラット」は書き出さない)。
    var canExportPresets: Bool {
        !library.userPresets.isEmpty
    }

    /// 全部のプリセット(「フラット」を除く)を、1つのファイルに書き出す。
    func exportPresets(to url: URL) throws {
        try PresetStore.export(library, to: url)
    }

    /// ファイルのプリセットを、いまの一覧に足す。選んでいるプリセットとスライダーの値は変えない(音は変わらない)。
    /// 投げるのは、`PresetError.readOnly` か `PresetStore.ImportError`。
    func importPresets(from url: URL) throws -> PresetStore.ImportResult {
        guard canEditPresets else { throw PresetError.readOnly }
        var updated = library
        let result = try PresetStore.importPresets(fromFile: url, into: &updated)
        if result.importedCount > 0 {
            library = updated
            savePresets()
        }
        return result
    }

    /// プリセットの一覧を、すぐ保存する(作りためた設定なので、まとめて後で、にしない)。
    /// 失敗したときは、次にプリセットを変えたときと、終了のときに、もう一度試す。
    private func savePresets() {
        guard canEditPresets else { return }
        do {
            try presetStore.save(library)
            if didFailToSavePresets { didFailToSavePresets = false }
        } catch {
            if !didFailToSavePresets { didFailToSavePresets = true }
        }
    }

    /// あるバンドを、指定した量だけ増減する。範囲の端で止まる。
    func adjustEqualizerGain(band: Int, by delta: Double) {
        var changed = equalizer
        changed.adjust(band: band, by: delta)
        guard changed != equalizer else { return }
        equalizer = changed
        equalizerChanged()
    }

    /// リミッターが音を抑えていた回の数。増え続けていれば、いま抑えている。加工を始め直すと 0 に戻る。
    /// 読んでも値は変わらない。前に読んだ値との差は、読む側で持つ。
    var limitCount: UInt64 { isRunning ? (currentPath?.limitCount ?? 0) : 0 }
    /// エンジンを通せず、イコライザーなしの音を出した回の数。加工を始め直すと 0 に戻る。
    var engineFallbackCount: UInt64 { isRunning ? (currentPath?.engineFallbackCount ?? 0) : 0 }

    /// 待たずに、いますぐ状態を保存する。
    private func saveStateNow() {
        saveTask?.cancel()
        saveNow()
    }

    /// スライダーを動かしている間は、保存をまとめる(動かすたびにファイルへ書かない)。
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    private func saveNow() {
        guard canSave else { return }
        do {
            try store.save(state)
            if didFailToSave { didFailToSave = false }
        } catch {
            if !didFailToSave { didFailToSave = true }
        }
    }

    // MARK: - 加工が止まっていないかの見張り

    /// ポップアップを閉じている間も、数秒おきに確かめる。
    /// 止まると、元の音が加工なしの最大音量で出る。メニューバーのアイコンを変えて知らせる。
    private func startWatching() {
        watchTask?.cancel()
        watchTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard let self else { return }
                // 知らせを取りこぼした場合に備えて、装置の顔ぶれか、いまの出力先が変わっていたら、合わせ直す。
                // スリープの間は、何もしない(`reconcileOutputs` が、自分で確かめる)。
                if OutputDevices.signature() != lastOutputSignature {
                    reconcileOutputs()
                }
                checkStalled()
                checkCapture()
                checkVolumeKeyPermission()
                watchCount += 1
                if watchCount % 10 == 0 {
                    // 30 秒ごとに、前に始められなかった出力先や、対応していないと判断した出力先を、もう一度確かめる
                    // (装置を差した直後は、情報をまだ読めないことがある)。
                    if !isSystemSleeping,
                       !startFailures.isEmpty || currentDevice?.unsupportedReason != nil || currentDevice == nil {
                        startFailures = [:]
                        reconcileOutputs()
                    }
                }
            }
        }
    }

    private func checkStalled() {
        if isSystemSleeping {
            // スリープの間は、コールバックが呼ばれないのが正しい。止まっているとは、判断しない。
            // ただし、コールバックが呼ばれているなら、スリープは終わっている(復帰の知らせを受け損ねた場合の備え)。
            // スリープに入る知らせのあとも、数秒は呼ばれ続けるので、いったん止まったのを見てから、判断する。
            let count = currentPath?.callbackCount ?? 0
            if count == lastCallbackCount {
                didStopWhileSleeping = true
            } else if didStopWhileSleeping {
                finishWaking()
            }
            lastCallbackCount = count
            return
        }
        var stalled = false
        if isRunning, let path = currentPath {
            let count = path.callbackCount
            checkCount += 1
            // 開始の直後は判定しない。前に確かめたときから回数が増えていなければ、止まっている。
            stalled = checkCount > 1 && count == lastCallbackCount
            lastCallbackCount = count
        }
        // 値が変わったときだけ書く(同じ値でも、書くと画面が作り直される)。
        if isStalled != stalled {
            isStalled = stalled
        }
    }

    /// 音を取り出せているかを確かめる。許可の状態を直接調べる方法がないので、状況から判断する(`CaptureWatch`)。
    private func checkCapture() {
        // スリープの間は、音が来ないのが正しい。
        guard !isSystemSleeping else { return }
        // 止まっているとき、形が合わず無音を出しているときは、別の原因なので、許可の案内はしない。
        let path = currentPath
        let isHealthy = isRunning && !isStalled && path?.mismatchCount == 0
        let hasReceivedSignal = path?.hasReceivedSignal ?? false
        // ほかのアプリが音を出しているかは、結果を使うときだけ調べる。
        let isOtherProcessPlaying = isHealthy && !hasReceivedSignal && (path?.isOtherProcessPlaying() ?? false)
        let shouldAlert = captureWatch.update(
            isRunning: isHealthy,
            hasReceivedSignal: hasReceivedSignal,
            isOtherProcessPlaying: isOtherProcessPlaying)
        if isCaptureSuspected != captureWatch.isSuspected {
            isCaptureSuspected = captureWatch.isSuspected
        }
        if shouldAlert {
            // 案内の画面を閉じるまで、見張りを止めないよう、別に出す。
            Task { Dialogs.showCapturePermissionGuide() }
        }
    }

    /// 加工を始め直したとき、切ったときに、数え直す。
    private func resetCaptureWatch() {
        _ = captureWatch.update(isRunning: false, hasReceivedSignal: false, isOtherProcessPlaying: false)
        if isCaptureSuspected {
            isCaptureSuspected = false
        }
    }
}
