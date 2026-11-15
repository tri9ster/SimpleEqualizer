import AVFAudio
import CoreAudio
import Foundation
import SimpleEqualizerCore
import Synchronization

/// 試作(TICKET-002): タップで取り出した音に音量を掛けて、出力装置へ流す。
/// 経路: 各アプリの音 → タップ(元の音は消す) → 音量 → 出力装置
/// TICKET-004 で、音量の前に AVAudioEngine を通す経路を足した。

enum PathMode: String, CaseIterable, Identifiable {
    /// TICKET-002 の経路。音量だけを掛ける。
    case direct = "直接"
    /// TICKET-004 の経路。AVAudioEngine(イコライザー1バンド)を通してから音量を掛ける。
    case engine = "AVAudioEngine"

    var id: String { rawValue }
}

enum PassthroughError: Error, CustomStringConvertible {
    case deviceNotFound(String)
    case deviceAmbiguous(String, Int)
    case ownProcessNotFound
    case unsupportedFormat(String)
    case coreAudio(String, OSStatus)

    var description: String {
        switch self {
        case .deviceNotFound(let name):
            return "出力装置「\(name)」が見つかりません。"
        case .deviceAmbiguous(let name, let count):
            return "出力装置「\(name)」が \(count) 台見つかりました。どれを使うか決められないので、開始しません。"
        case .ownProcessNotFound:
            return "自分のプロセスを対象から外せないので、開始しません(音が循環するおそれがあるため)。"
        case .unsupportedFormat(let format):
            return "取り出した音の形式(\(format))には対応していません。"
        case .coreAudio(let step, let status):
            return "\(step)に失敗しました(エラー \(status))。"
        }
    }
}

/// 音声のコールバックと画面の間で受け渡す値。
/// コールバックの中では、ここにある値の読み書きだけを行う(メモリの確保、ロック、ログ出力をしない)。
final class RenderState: @unchecked Sendable {
    /// 画面が決めた倍率(Float のビット列)。
    let targetGainBits = Atomic<UInt32>(Float(0).bitPattern)
    /// 直前のコールバックで取り出した音の最大値(Float のビット列)。音が届いているかを画面で見るために使う。
    let inputPeakBits = Atomic<UInt32>(Float(0).bitPattern)
    let callbackCount = Atomic<Int>(0)
    /// 入力と出力の形式が合わず、無音を出した回数。
    let formatMismatchCount = Atomic<Int>(0)
    /// エンジンを通せず、加工なしの音に切り替えた回数。
    let engineFallbackCount = Atomic<Int>(0)
    /// 最後にエンジンを通せなかった理由。0 はなし、`RenderState.shapeMismatch` は形が合わない、
    /// それ以外はエンジンが返した状態(`AVAudioEngineManualRenderingStatus` の値)。
    let engineLastFailure = Atomic<Int>(0)
    /// そのときエンジンが返したエラー番号。
    let engineLastError = Atomic<Int32>(0)
    static let shapeMismatch = -100
    /// いま掛けている倍率。コールバックだけが読み書きする。
    let currentGain: UnsafeMutablePointer<Float>

    init() {
        currentGain = .allocate(capacity: 1)
        currentGain.initialize(to: 0)
    }

    deinit {
        currentGain.deallocate()
    }
}

struct PassthroughInfo {
    var deviceName: String
    var mode: PathMode
    var tapFormat: String
    var inputStreams: Int
    var outputStreams: Int
    var outputSampleRate: Double
    var bufferFrames: UInt32
    var inputLatencyFrames: UInt32
    var outputLatencyFrames: UInt32

    /// 装置が申告している値から見積もった遅れ。再生するアプリ側と SONOS 側の遅れは含まない。
    var estimatedLatencyMs: Double {
        guard outputSampleRate > 0 else { return 0 }
        let frames = Double(inputLatencyFrames + outputLatencyFrames + bufferFrames)
        return frames / outputSampleRate * 1000
    }
}

@MainActor
final class AudioPassthrough {
    let state = RenderState()

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var isStarted = false
    private var engineProcessor: EngineProcessor?

    var isRunning: Bool { isStarted }

    func setVolume(_ volume: Double) {
        state.targetGainBits.store(VolumeCurve.gain(forVolume: volume).bitPattern, ordering: .relaxed)
    }

    /// 1 kHz を −10 dB にする(AVAudioEngine の経路だけ)。
    func setCut(_ enabled: Bool) {
        engineProcessor?.setCut(enabled)
    }

    func start(deviceName: String, volume: Double, mode: PathMode, cut: Bool) throws -> PassthroughInfo {
        guard !isStarted else { throw PassthroughError.coreAudio("開始(すでに動いている)", 0) }
        do {
            return try startUnchecked(deviceName: deviceName, volume: volume, mode: mode, cut: cut)
        } catch {
            stop()
            throw error
        }
    }

    private func startUnchecked(
        deviceName: String, volume: Double, mode: PathMode, cut: Bool
    ) throws -> PassthroughInfo {
        let candidates = Self.findOutputDevices(named: deviceName)
        guard let outputID = candidates.first else {
            throw PassthroughError.deviceNotFound(deviceName)
        }
        guard candidates.count == 1 else {
            throw PassthroughError.deviceAmbiguous(deviceName, candidates.count)
        }
        let outputUID = try Self.string(outputID, kAudioDevicePropertyDeviceUID, step: "出力装置の UID の取得")

        // 自分自身の出力を対象から外す。外さないと音が循環する。
        var pid = getpid()
        var ownProcess = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = Self.address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address,
            UInt32(MemoryLayout<pid_t>.size), &pid, &size, &ownProcess)
        guard status == noErr else { throw PassthroughError.coreAudio("自分のプロセスの取得", status) }
        guard ownProcess != kAudioObjectUnknown else { throw PassthroughError.ownProcessNotFound }

        // 対象は、この出力装置に出ている音だけ。読み取っている間だけ元の音を消す。
        let description = CATapDescription(excludingProcesses: [ownProcess], deviceUID: outputUID, stream: 0)
        description.name = "SimpleEqualizer"
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped
        status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr else {
            tapID = AudioObjectID(kAudioObjectUnknown)
            throw PassthroughError.coreAudio("タップの作成", status)
        }
        let tapFormat = try Self.value(
            tapID, kAudioTapPropertyFormat, initial: AudioStreamBasicDescription(), step: "タップの形式の取得")
        // コールバックは 32 ビットの浮動小数点として読み書きする。違う形式を読むと雑音になるので、開始しない。
        guard tapFormat.mFormatID == kAudioFormatLinearPCM,
              tapFormat.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              tapFormat.mBitsPerChannel == 32
        else {
            throw PassthroughError.unsupportedFormat(Self.describe(tapFormat))
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
            throw PassthroughError.coreAudio("集約装置の作成", status)
        }

        // 倍率を先に決め、0 から始める(開始の瞬間に大きな音を出さない)。
        setVolume(volume)
        state.currentGain.pointee = 0
        state.callbackCount.store(0, ordering: .relaxed)
        state.formatMismatchCount.store(0, ordering: .relaxed)
        state.engineFallbackCount.store(0, ordering: .relaxed)

        state.engineLastFailure.store(0, ordering: .relaxed)
        state.engineLastError.store(0, ordering: .relaxed)

        var engineBlock: AVAudioEngineManualRenderingBlock?
        var engineBuffers: EngineBuffers?
        if mode == .engine {
            // エンジンの経路は、左右交互の1本と、決めた上限以下のバッファだけを扱う。
            // 合わないまま始めると、表示は AVAudioEngine なのに、実際は加工なしの音が出続ける。
            let bufferFrames = Self.frames(
                aggregateID, kAudioDevicePropertyBufferFrameSize, kAudioObjectPropertyScopeGlobal)
            guard tapFormat.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0,
                  bufferFrames > 0, Int(bufferFrames) <= EngineProcessor.maximumFrames
            else {
                throw PassthroughError.unsupportedFormat(
                    "\(Self.describe(tapFormat))、バッファ \(bufferFrames) フレーム")
            }
            let processor = try EngineProcessor(
                sampleRate: tapFormat.mSampleRate, channels: Int(tapFormat.mChannelsPerFrame))
            processor.setCut(cut)
            engineProcessor = processor
            engineBlock = processor.renderBlock
            engineBuffers = processor.buffers
        }

        status = AudioDeviceCreateIOProcIDWithBlock(
            &ioProcID, aggregateID, nil,
            Self.makeIOBlock(state: state, engine: engineBlock, buffers: engineBuffers))
        guard status == noErr else {
            ioProcID = nil
            throw PassthroughError.coreAudio("コールバックの登録", status)
        }
        status = AudioDeviceStart(aggregateID, ioProcID)
        guard status == noErr else { throw PassthroughError.coreAudio("開始", status) }
        isStarted = true

        let input = kAudioObjectPropertyScopeInput
        let output = kAudioObjectPropertyScopeOutput
        return PassthroughInfo(
            deviceName: deviceName,
            mode: mode,
            tapFormat: Self.describe(tapFormat),
            inputStreams: Self.streamCount(aggregateID, input),
            outputStreams: Self.streamCount(aggregateID, output),
            outputSampleRate: (try? Self.value(
                outputID, kAudioDevicePropertyNominalSampleRate, initial: Float64(0), step: "")) ?? 0,
            bufferFrames: Self.frames(aggregateID, kAudioDevicePropertyBufferFrameSize, kAudioObjectPropertyScopeGlobal),
            inputLatencyFrames: Self.frames(aggregateID, kAudioDevicePropertyLatency, input)
                + Self.frames(aggregateID, kAudioDevicePropertySafetyOffset, input),
            outputLatencyFrames: Self.frames(aggregateID, kAudioDevicePropertyLatency, output)
                + Self.frames(aggregateID, kAudioDevicePropertySafetyOffset, output))
    }

    /// コールバック、集約装置、タップの順に片付ける。途中まで作った状態でも呼べる。
    func stop() {
        if isStarted {
            // 倍率を 0 へ下げてから止める(波形を途中で切らない)。コールバック数回分だけ待つ。
            state.targetGainBits.store(Float(0).bitPattern, ordering: .relaxed)
            Thread.sleep(forTimeInterval: 0.05)
        }
        if aggregateID != kAudioObjectUnknown {
            if let ioProcID {
                AudioDeviceStop(aggregateID, ioProcID)
                AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
        // エンジンは、コールバックを止めたあとに片付ける。
        engineProcessor?.shutdown()
        engineProcessor = nil
        ioProcID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
        isStarted = false
        state.inputPeakBits.store(Float(0).bitPattern, ordering: .relaxed)
    }

    // MARK: - 音声のコールバック

    /// コールバックを作る。必ずこの関数(メインスレッド専用ではない)の中で作る。
    /// メインスレッド専用のメソッドの中で作ると、コールバックもメインスレッド専用とみなされ、
    /// 音声のスレッドで呼ばれた瞬間にアプリが落ちる(`docs/failures.md` の 2026-10-12)。
    private nonisolated static func makeIOBlock(
        state: RenderState,
        engine: AVAudioEngineManualRenderingBlock?,
        buffers: EngineBuffers?
    ) -> AudioDeviceIOBlock {
        guard let engine, let buffers else {
            return { _, input, _, output, _ in
                render(input: input, output: output, state: state)
            }
        }
        return { _, input, _, output, _ in
            // エンジンを通せなかった回は、加工なしの経路に切り替える(無音にしない)。
            if !renderThroughEngine(input: input, output: output, state: state, engine: engine, buffers: buffers) {
                state.engineFallbackCount.add(1, ordering: .relaxed)
                render(input: input, output: output, state: state)
            }
        }
    }

    /// 入力をエンジンに通し、倍率を掛けて出力へ書く。音声のスレッドで呼ばれる。
    /// 通せなかったときは、出力に何も書かずに false を返す。書き方の決まりは `render` と同じ。
    private nonisolated static func renderThroughEngine(
        input: UnsafePointer<AudioBufferList>,
        output: UnsafeMutablePointer<AudioBufferList>,
        state: RenderState,
        engine: AVAudioEngineManualRenderingBlock,
        buffers: EngineBuffers
    ) -> Bool {
        let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outputs = UnsafeMutableAudioBufferListPointer(output)
        // 試作では、入力(タップ)と出力が、それぞれ左右交互の1本である場合だけを扱う。
        guard outputs.count == 1, inputs.count >= 1 else {
            state.engineLastFailure.store(RenderState.shapeMismatch, ordering: .relaxed)
            return false
        }
        let source = inputs[inputs.count - 1]
        let destination = outputs[0]
        let channels = buffers.channels
        guard Int(source.mNumberChannels) == channels,
              Int(destination.mNumberChannels) == channels,
              source.mDataByteSize == destination.mDataByteSize,
              let sourceData = source.mData,
              let destinationData = destination.mData
        else {
            state.engineLastFailure.store(RenderState.shapeMismatch, ordering: .relaxed)
            return false
        }
        let frames = Int(source.mDataByteSize) / MemoryLayout<Float>.size / channels
        guard frames > 0, frames <= buffers.capacity else {
            state.engineLastFailure.store(RenderState.shapeMismatch, ordering: .relaxed)
            return false
        }
        let from = sourceData.assumingMemoryBound(to: Float.self)
        let to = destinationData.assumingMemoryBound(to: Float.self)
        let byteSize = UInt32(frames * MemoryLayout<Float>.size)

        // 左右交互の音を、チャンネル別に並べ替えてエンジンに渡す。大きさは、加工の前の音で測る(直接の経路と同じ意味にする)。
        var peak: Float = 0
        var channel = 0
        while channel < channels {
            let plane = buffers.inputData + channel * buffers.capacity
            var frame = 0
            var position = channel
            while frame < frames {
                let sample = from[position]
                let magnitude = sample.magnitude
                if magnitude > peak { peak = magnitude }
                plane[frame] = sample
                position += channels
                frame += 1
            }
            buffers.inputList[channel].mDataByteSize = byteSize
            buffers.outputList[channel].mDataByteSize = byteSize
            buffers.outputList[channel].mData = UnsafeMutableRawPointer(buffers.outputData + channel * buffers.capacity)
            channel += 1
        }

        var error: OSStatus = 0
        let result = engine(AVAudioFrameCount(frames), buffers.outputList.unsafeMutablePointer, &error)
        // 数値で比べる。`==` で比べると、Swift の実行時の処理を呼ぶ。
        guard result.rawValue == AVAudioEngineManualRenderingStatus.success.rawValue else {
            state.engineLastFailure.store(result.rawValue, ordering: .relaxed)
            state.engineLastError.store(error, ordering: .relaxed)
            return false
        }
        channel = 0
        while channel < channels {
            guard buffers.outputList[channel].mDataByteSize == byteSize,
                  buffers.outputList[channel].mData != nil
            else {
                state.engineLastFailure.store(RenderState.shapeMismatch, ordering: .relaxed)
                return false
            }
            channel += 1
        }

        // エンジンの出力を左右交互に並べ直しながら、倍率を掛ける。
        let target = Float(bitPattern: state.targetGainBits.load(ordering: .relaxed))
        let start = state.currentGain.pointee
        let step = (target - start) / Float(frames)
        channel = 0
        while channel < channels {
            // エンジンが置き場を差し替えた場合に備え、呼んだあとの場所から読む(上で nil でないことを確かめてある)。
            guard let planeData = buffers.outputList[channel].mData else {
                channel += 1
                continue
            }
            let plane = planeData.assumingMemoryBound(to: Float.self)
            var gain = start
            var frame = 0
            var position = channel
            while frame < frames {
                gain += step
                to[position] = plane[frame] * gain
                position += channels
                frame += 1
            }
            channel += 1
        }
        state.currentGain.pointee = target
        state.inputPeakBits.store(peak.bitPattern, ordering: .relaxed)
        state.callbackCount.add(1, ordering: .relaxed)
        return true
    }

    /// 入力を出力へ写しながら倍率を掛ける。音声のスレッドで呼ばれる。
    /// この中では、メモリの確保、ロック、ログ出力、ファイル操作をしない。
    /// 繰り返しは `while` で書く。`for ... in 0..<n` は、最適化なしのビルドでは Swift の実行時の処理
    /// (ロックを使う)を1回ごとに呼び、CPU 使用率が上がる(`docs/failures.md` の 2026-10-12)。
    private nonisolated static func render(
        input: UnsafePointer<AudioBufferList>,
        output: UnsafeMutablePointer<AudioBufferList>,
        state: RenderState
    ) {
        let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outputs = UnsafeMutableAudioBufferListPointer(output)
        state.callbackCount.add(1, ordering: .relaxed)

        // 先に無音で埋める。形式が合わないときは、そのまま無音を出す。
        let outputCount = outputs.count
        var index = 0
        while index < outputCount {
            if let data = outputs[index].mData {
                memset(data, 0, Int(outputs[index].mDataByteSize))
            }
            index += 1
        }
        // 集約装置の入力には、出力装置が持つ入力が先に、タップが最後に並ぶ。後ろから出力と同じ数だけ使う。
        guard inputs.count >= outputCount, outputCount > 0 else {
            state.formatMismatchCount.add(1, ordering: .relaxed)
            return
        }
        let inputOffset = inputs.count - outputCount

        let target = Float(bitPattern: state.targetGainBits.load(ordering: .relaxed))
        let start = state.currentGain.pointee
        var peak: Float = 0
        var didCopy = false

        index = -1
        while index + 1 < outputCount {
            index += 1
            let source = inputs[inputOffset + index]
            let destination = outputs[index]
            guard source.mDataByteSize == destination.mDataByteSize,
                  source.mNumberChannels == destination.mNumberChannels,
                  source.mNumberChannels > 0,
                  let sourceData = source.mData,
                  let destinationData = destination.mData
            else {
                state.formatMismatchCount.add(1, ordering: .relaxed)
                continue
            }
            let channels = Int(source.mNumberChannels)
            let frames = Int(source.mDataByteSize) / MemoryLayout<Float>.size / channels
            guard frames > 0 else { continue }
            let from = sourceData.assumingMemoryBound(to: Float.self)
            let to = destinationData.assumingMemoryBound(to: Float.self)

            // 倍率を1回のコールバックの中でなめらかに変える(スライダー操作時の雑音を防ぐ)。
            let step = (target - start) / Float(frames)
            var gain = start
            didCopy = true
            var position = 0
            var frame = 0
            while frame < frames {
                gain += step
                var channel = 0
                while channel < channels {
                    let sample = from[position]
                    let magnitude = sample.magnitude
                    if magnitude > peak { peak = magnitude }
                    to[position] = sample * gain
                    position += 1
                    channel += 1
                }
                frame += 1
            }
        }
        // 音を出せなかった回は倍率を進めない(次に出せたときに、いまの倍率からなめらかに変える)。
        if didCopy {
            state.currentGain.pointee = target
        }
        state.inputPeakBits.store(peak.bitPattern, ordering: .relaxed)
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
        guard status == noErr else { throw PassthroughError.coreAudio(step, status) }
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
        guard status == noErr, let result else { throw PassthroughError.coreAudio(step, status) }
        return result.takeRetainedValue() as String
    }

    private static func streamCount(_ id: AudioObjectID, _ scope: AudioObjectPropertyScope) -> Int {
        var address = address(kAudioDevicePropertyStreams, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr else { return 0 }
        return Int(size) / MemoryLayout<AudioObjectID>.size
    }

    private static func findOutputDevices(named name: String) -> [AudioObjectID] {
        var address = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var devices = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &devices) == noErr else { return [] }
        return devices.filter { device in
            (try? string(device, kAudioObjectPropertyName, step: "")) == name
                && streamCount(device, kAudioObjectPropertyScopeOutput) > 0
        }
    }

    private static func describe(_ format: AudioStreamBasicDescription) -> String {
        let kind = format.mFormatFlags & kAudioFormatFlagIsFloat != 0 ? "浮動小数点" : "整数"
        let layout = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0 ? "チャンネル別" : "交互"
        return "\(Int(format.mSampleRate)) Hz / \(format.mChannelsPerFrame)ch / \(format.mBitsPerChannel) ビット \(kind) / \(layout)"
    }
}
