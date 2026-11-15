import CoreAudio
import Foundation
import SimpleEqualizerAudio
import SimpleEqualizerCore
import SimpleEqualizerEngine

/// 音声の経路の組み立て。
/// 経路: 各アプリの音 → タップ(元の音は消す) → エンジン(イコライザー、ラウドネス) → 音量 → リミッター → 出力装置
/// 出力先1つにつき、1つ作る。
///
/// 音声のスレッドで動く関数(`seq_io_proc`)は C で書いてあり、`Core/` パッケージにある。
/// ここでは、装置を探し、タップと集約装置を作り、エンジンを作り、コールバックを登録し、片付ける。

enum AudioPathError: Error, CustomStringConvertible {
    case ownProcessNotFound
    case unsupportedFormat(String)
    case coreAudio(String, OSStatus)
    case engine(String)

    var description: String {
        switch self {
        case .ownProcessNotFound:
            return String(localized: "自分のプロセスを対象から外せないので、開始しません(音が循環するおそれがあるため)。")
        case .unsupportedFormat(let format):
            return String(localized: "取り出した音の形式(\(format))には対応していません。")
        case .coreAudio(let step, let status):
            return String(localized: "\(step)に失敗しました(エラー \(status))。")
        case .engine(let reason):
            return reason
        }
    }
}

struct AudioPathInfo {
    var deviceName: String
    /// macOS が装置につける識別子。出力先ごとの設定を覚えるのに使う。
    var deviceUID: String
    var tapFormat: String
    var inputStreams: Int
    var outputStreams: Int
    var outputSampleRate: Double
    var bufferFrames: UInt32
    var inputLatencyFrames: UInt32
    var outputLatencyFrames: UInt32

    /// 装置が申告している値から見積もった遅れ。再生するアプリ側とスピーカー側の遅れは含まない。
    var estimatedLatencyMs: Double {
        guard outputSampleRate > 0 else { return 0 }
        let frames = Double(inputLatencyFrames + outputLatencyFrames + bufferFrames)
        return frames / outputSampleRate * 1000
    }
}

/// 加工を始めるときの、はじめの値。出力先が分かってから決まるもの。
struct AudioPathInitialValues {
    /// 音量の倍率。
    var gain: Float
    /// ラウドネスの補正量(音量によって変わる)。
    var loudness: LoudnessCurve.Correction
}

@MainActor
final class AudioPath {
    /// コールバックと受け渡す値(C の側で持つ)。アプリが動いている間、ずっと使う。
    private let renderState = seq_render_state_create()

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var isStarted = false
    /// 音を加工するエンジン。加工している間だけ持つ。
    private var engine: EqualizerEngine?
    /// いま加工している出力装置と、自分自身のプロセス。ほかのアプリが音を出しているかを調べるのに使う。
    private var outputID = AudioObjectID(kAudioObjectUnknown)
    /// 経路を作ったときの、出力装置のサンプリング周波数。エンジンとリミッターは、この周波数で作ってある。
    private(set) var startedSampleRate: Double = 0
    /// 出力装置の周波数の変化の知らせを受ける登録(経路を片付けるときに外す)。
    private var sampleRateListener: AudioObjectPropertyListenerBlock?
    private var sampleRateListenerDevice = AudioObjectID(kAudioObjectUnknown)

    /// 出力装置のサンプリング周波数が変わったときに呼ぶ(メインスレッド)。経路を作ったあとに設定する。
    var onSampleRateChange: (@MainActor () -> Void)?
    private var ownProcessID = AudioObjectID(kAudioObjectUnknown)

    var isRunning: Bool { isStarted }
    var inputPeak: Float { seq_render_state_input_peak(renderState) }
    var callbackCount: UInt64 { seq_render_state_callback_count(renderState) }
    var mismatchCount: UInt64 { seq_render_state_mismatch_count(renderState) }
    /// エンジンを通せず、取り出した音をそのまま使った回の数(音量とリミッターは掛かる)。
    var engineFallbackCount: UInt64 { seq_render_state_engine_fallback_count(renderState) }
    /// リミッターが音を抑えていた回の数。
    var limitCount: UInt64 { seq_render_state_limit_count(renderState) }
    /// 始めてから、無音でない音を1回でも受け取ったか。「システム音声の録音」の許可がないと、ずっと false のままになる。
    var hasReceivedSignal: Bool { seq_render_state_has_received_signal(renderState) }

    /// 自分以外のアプリが、この出力装置へ音を出しているか。
    func isOtherProcessPlaying() -> Bool {
        guard isStarted, outputID != kAudioObjectUnknown else { return false }
        return Self.objectList(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyProcessObjectList)
            .contains { process in
                process != ownProcessID
                    && ((try? Self.value(
                        process, kAudioProcessPropertyIsRunningOutput, initial: UInt32(0), step: "")) ?? 0) != 0
                    && Self.objectList(process, kAudioProcessPropertyDevices, kAudioObjectPropertyScopeOutput)
                        .contains(outputID)
            }
    }

    /// 倍率を決める。0 以上 1 以下に収まる(C の側で丸める)。
    func setGain(_ gain: Float) {
        seq_render_state_set_target_gain(renderState, gain)
    }

    /// イコライザーの値を変える。加工していない間は、何もしない(次に始めるときに、`start` で渡す)。
    func setEqualizer(_ settings: EqualizerSettings, enabled: Bool) {
        engine?.setEqualizer(settings, enabled: enabled)
    }

    /// ラウドネスの補正量を変える。加工していない間は、何もしない(次に始めるときに、`start` で渡す)。
    func setLoudness(_ correction: LoudnessCurve.Correction) {
        engine?.setLoudness(correction)
    }

    /// 動いたまま捨てられた場合に備え、片付けてから状態を捨てる。
    isolated deinit {
        stop()
        // エンジンは、状態より先に外して捨てる(エンジンが状態を指しているため)。
        engine?.shutdown()
        engine = nil
        seq_render_state_destroy(renderState)
    }

    /// この経路を作ったときの、出力装置の番号。装置を抜いて差し直すと、番号が変わる(識別子は変わらない)。
    /// 番号が変わったら、この経路は、もう音を取り出せない(タップが、前の番号の装置につながったままになる)。作り直す。
    var outputDeviceID: AudioObjectID { outputID }

    /// 止める前に、音をなめらかに消し始める。いくつもの経路を止めるときに、先に全部に指示しておくと、待つ時間が短くて済む。
    func beginFadeOut() {
        guard isStarted else { return }
        seq_render_state_set_fading_out(renderState, true)
    }

    /// 音を消し始めたのを、取りやめる(倍率は、なめらかに元へ戻る)。
    func cancelFadeOut() {
        guard isStarted else { return }
        seq_render_state_set_fading_out(renderState, false)
    }

    /// 装置のサンプリング周波数(読めなかったときは 0)。
    static func nominalSampleRate(of id: AudioObjectID) -> Double {
        (try? value(id, kAudioDevicePropertyNominalSampleRate, initial: Float64(0), step: "")) ?? 0
    }

    /// アプリが、音を取り出すために作った集約装置。出力先の一覧から外すために使う。作っていないときは、不明の番号。
    var aggregateDeviceID: AudioObjectID { aggregateID }

    /// その出力先の加工を始める。`outputID` は、いまの macOS の中での装置の番号、`outputUID` は、変わらない識別子。
    /// 倍率とラウドネスの補正量(`initial`)、イコライザーの値は、音を出し始める前に設定する(エンジンは、始めるたびに作り直す)。
    func start(
        outputID: AudioObjectID,
        outputUID: String,
        deviceName: String,
        equalizer: EqualizerSettings,
        equalizerEnabled: Bool,
        initial: AudioPathInitialValues
    ) throws -> AudioPathInfo {
        guard !isStarted else { throw AudioPathError.coreAudio(String(localized: "開始(すでに動いている)"), 0) }
        do {
            return try startUnchecked(
                outputID: outputID, outputUID: outputUID, deviceName: deviceName,
                equalizer: equalizer, equalizerEnabled: equalizerEnabled, initial: initial)
        } catch {
            stop()
            throw error
        }
    }

    private func startUnchecked(
        outputID: AudioObjectID,
        outputUID: String,
        deviceName: String,
        equalizer: EqualizerSettings,
        equalizerEnabled: Bool,
        initial: AudioPathInitialValues
    ) throws -> AudioPathInfo {
        // 自分自身の出力を対象から外す。外さないと音が循環する。
        var pid = getpid()
        var ownProcess = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = Self.address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address,
            UInt32(MemoryLayout<pid_t>.size), &pid, &size, &ownProcess)
        guard status == noErr else { throw AudioPathError.coreAudio(String(localized: "自分のプロセスの取得"), status) }
        guard ownProcess != kAudioObjectUnknown else { throw AudioPathError.ownProcessNotFound }
        self.outputID = outputID
        ownProcessID = ownProcess

        // 対象は、この出力装置に出ている音だけ。読み取っている間だけ元の音を消す。
        let description = CATapDescription(excludingProcesses: [ownProcess], deviceUID: outputUID, stream: 0)
        description.name = "SimpleEqualizer"
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped
        status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr else {
            tapID = AudioObjectID(kAudioObjectUnknown)
            throw AudioPathError.coreAudio(String(localized: "タップの作成"), status)
        }
        let tapFormat = try Self.value(
            tapID, kAudioTapPropertyFormat, initial: AudioStreamBasicDescription(), step: String(localized: "タップの形式の取得"))
        // コールバックは 32 ビットの浮動小数点として読み書きする。違う形式を読むと雑音になるので、開始しない。
        guard tapFormat.mFormatID == kAudioFormatLinearPCM,
              tapFormat.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              tapFormat.mBitsPerChannel == 32
        else {
            throw AudioPathError.unsupportedFormat(Self.describe(tapFormat))
        }

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "SimpleEqualizer",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            // 自動開始は使わない。使うと、音が流れ始めるまで開始の呼び出しが待たされる。
            kAudioAggregateDeviceTapAutoStartKey: false,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: description.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
        status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID)
        guard status == noErr else {
            aggregateID = AudioObjectID(kAudioObjectUnknown)
            throw AudioPathError.coreAudio(String(localized: "集約装置の作成"), status)
        }

        // 試作と同じく、入力(タップ)と出力がそれぞれ1本の装置だけを扱う。
        // 出力が複数本の装置では、コールバックが、タップではない入力(マイクなど)を出力へ写すおそれがある。
        let inputStreams = Self.streamCount(aggregateID, kAudioObjectPropertyScopeInput)
        let outputStreams = Self.streamCount(aggregateID, kAudioObjectPropertyScopeOutput)
        guard outputStreams == 1, inputStreams >= 1 else {
            throw AudioPathError.unsupportedFormat(String(localized: "入力 \(inputStreams) 本 / 出力 \(outputStreams) 本"))
        }

        // いまの倍率を 0 に戻してから始める(開始の瞬間に大きな音を出さない)。
        // 目標の倍率は、この出力先について覚えている音量から決める。
        seq_render_state_reset(renderState)
        seq_render_state_set_target_gain(renderState, initial.gain)
        // リミッターが倍率を戻す速さは、サンプリング周波数で決まる。コールバックは出力装置の周波数で動くので、
        // 出力装置の値を使う。読めないときは、取り出した音の形式の値を使う。
        // 周波数の変化の知らせは、周波数を読む前から受ける(読んだあと、知らせを受け始めるまでの間に変わると、気づけないため)。
        watchSampleRate(of: outputID)
        let outputRate = Self.nominalSampleRate(of: outputID)
        let sampleRate = outputRate > 0 ? outputRate : tapFormat.mSampleRate
        seq_render_state_set_sample_rate(renderState, sampleRate)

        // 音を加工するエンジンを作り、コールバックにつなぐ。作れないときは、開始しない。
        // 前の停止で、コールバックが止まったと確かめられず、エンジンを残した場合に備え、先に外す。
        // その装置はもう片付けてあり、新しい装置のコールバックは、まだ登録していない。
        engine?.shutdown()
        engine = nil
        do {
            engine = try EqualizerEngine(
                sampleRate: sampleRate, channels: Int(tapFormat.mChannelsPerFrame), renderState: renderState)
        } catch {
            throw AudioPathError.engine("\(error)")
        }
        engine?.setEqualizer(equalizer, enabled: equalizerEnabled)
        engine?.setLoudness(initial.loudness)

        // コールバックは C の関数を直接登録する。Swift のコードは、音声のスレッドでは動かない。
        status = AudioDeviceCreateIOProcID(
            aggregateID, seq_io_proc, UnsafeMutableRawPointer(renderState), &ioProcID)
        guard status == noErr else {
            ioProcID = nil
            throw AudioPathError.coreAudio(String(localized: "コールバックの登録"), status)
        }
        status = AudioDeviceStart(aggregateID, ioProcID)
        guard status == noErr else { throw AudioPathError.coreAudio(String(localized: "開始"), status) }
        isStarted = true
        // 出力装置の周波数を読めなかったとき(タップの形式の値で代用したとき)は、0(分からない)として覚える。
        // 分からないときは、周波数が変わったかを比べない(合わないと判断して、作り直しを繰り返さないため)。
        startedSampleRate = outputRate

        let input = kAudioObjectPropertyScopeInput
        let output = kAudioObjectPropertyScopeOutput
        return AudioPathInfo(
            deviceName: deviceName,
            deviceUID: outputUID,
            tapFormat: Self.describe(tapFormat),
            inputStreams: inputStreams,
            outputStreams: outputStreams,
            outputSampleRate: outputRate,
            bufferFrames: Self.frames(aggregateID, kAudioDevicePropertyBufferFrameSize, kAudioObjectPropertyScopeGlobal),
            inputLatencyFrames: Self.frames(aggregateID, kAudioDevicePropertyLatency, input)
                + Self.frames(aggregateID, kAudioDevicePropertySafetyOffset, input),
            outputLatencyFrames: Self.frames(aggregateID, kAudioDevicePropertyLatency, output)
                + Self.frames(aggregateID, kAudioDevicePropertySafetyOffset, output))
    }

    /// 出力装置の周波数の変化の知らせを受ける。知らせは、メインのキューで受ける。
    private func watchSampleRate(of device: AudioObjectID) {
        unwatchSampleRate()
        var address = Self.address(kAudioDevicePropertyNominalSampleRate)
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.onSampleRateChange?() }
        }
        if AudioObjectAddPropertyListenerBlock(device, &address, .main, block) == noErr {
            sampleRateListener = block
            sampleRateListenerDevice = device
        }
    }

    private func unwatchSampleRate() {
        if let sampleRateListener {
            var address = Self.address(kAudioDevicePropertyNominalSampleRate)
            AudioObjectRemovePropertyListenerBlock(sampleRateListenerDevice, &address, .main, sampleRateListener)
        }
        sampleRateListener = nil
        sampleRateListenerDevice = AudioObjectID(kAudioObjectUnknown)
    }

    /// いまの出力装置のサンプリング周波数(読めなかったときは 0)。
    var currentOutputSampleRate: Double {
        Self.nominalSampleRate(of: outputID)
    }

    /// コールバック、集約装置、タップ、エンジンの順に片付ける。途中まで作った状態でも呼べる。
    /// コールバックが止まったと確かめられたら true を返す。
    /// false のときは、コールバックが、まだ呼ばれているかもしれない。この経路を捨てると、コールバックが、
    /// 解放したメモリに触るおそれがあるので、呼び出す側は、捨てずに持っておく。
    @discardableResult
    func stop() -> Bool {
        unwatchSampleRate()
        startedSampleRate = 0
        if isStarted {
            fadeOut()
        }
        var callbackStopped = true
        if aggregateID != kAudioObjectUnknown {
            if let ioProcID {
                AudioDeviceStop(aggregateID, ioProcID)
                callbackStopped = AudioDeviceDestroyIOProcID(aggregateID, ioProcID) == noErr
            }
            // 集約装置を消せたなら、その装置のコールバックも、もう呼ばれない。
            if AudioHardwareDestroyAggregateDevice(aggregateID) == noErr {
                callbackStopped = true
            }
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
        ioProcID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
        outputID = AudioObjectID(kAudioObjectUnknown)
        ownProcessID = AudioObjectID(kAudioObjectUnknown)
        isStarted = false
        // 値を戻すのは、コールバックが止まったと分かっているときだけ(動いている間に書くと、値がぶつかる)。
        // 止められなかった場合も、次に始めるときに戻す。
        // エンジンを外すのも同じ(コールバックが、外したエンジンを呼ばないようにする)。
        if callbackStopped {
            engine?.shutdown()
            engine = nil
            seq_render_state_reset(renderState)
        }
        return callbackStopped
    }

    /// 音をなめらかに消し、消えきるのを待つ(波形を途中で切らない)。
    /// コールバックが呼ばれていない場合に備え、待つ時間には上限をつける。
    private func fadeOut() {
        seq_render_state_set_fading_out(renderState, true)
        let started = Date()
        let deadline = started.addingTimeInterval(0.3)
        let countAtStart = seq_render_state_callback_count(renderState)
        while !seq_render_state_is_silent(renderState), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.005)
            // コールバックが呼ばれていない(装置が抜かれている、など)なら、待っても消えない。早めに切り上げる。
            if Date().timeIntervalSince(started) > 0.05, seq_render_state_callback_count(renderState) == countAtStart {
                break
            }
        }
    }

    // MARK: - Core Audio の情報の読み取り

    private static func address(
        _ selector: AudioObjectPropertySelector,
        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func value<T>(
        _ id: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        initial: T,
        step: String
    ) throws -> T {
        var result = initial
        var size = UInt32(MemoryLayout<T>.size)
        var address = address(selector, scope)
        let status = withUnsafeMutablePointer(to: &result) {
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, $0)
        }
        guard status == noErr else { throw AudioPathError.coreAudio(step, status) }
        return result
    }

    private static func frames(
        _ id: AudioObjectID, _ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope
    ) -> UInt32 {
        (try? value(id, selector, scope, initial: UInt32(0), step: "")) ?? 0
    }

    private static func string(
        _ id: AudioObjectID, _ selector: AudioObjectPropertySelector, step: String
    ) throws -> String {
        var result: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var address = address(selector)
        let status = AudioObjectGetPropertyData(id, &address, 0, nil, &size, &result)
        guard status == noErr, let result else { throw AudioPathError.coreAudio(step, status) }
        return result.takeRetainedValue() as String
    }

    private static func objectList(
        _ id: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> [AudioObjectID] {
        var address = address(selector, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &objects) == noErr else { return [] }
        return Array(objects.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    private static func streamCount(_ id: AudioObjectID, _ scope: AudioObjectPropertyScope) -> Int {
        var address = address(kAudioDevicePropertyStreams, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr else { return 0 }
        return Int(size) / MemoryLayout<AudioObjectID>.size
    }

    private static func describe(_ format: AudioStreamBasicDescription) -> String {
        let kind = format.mFormatFlags & kAudioFormatFlagIsFloat != 0 ? String(localized: "浮動小数点") : String(localized: "整数")
        let layout = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
            ? String(localized: "チャンネル別") : String(localized: "交互")
        return String(
            localized: "\(Int(format.mSampleRate)) Hz / \(format.mChannelsPerFrame)ch / \(format.mBitsPerChannel) ビット \(kind) / \(layout)")
    }
}
