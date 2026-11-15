import AVFAudio
import CoreAudio

/// 試作(TICKET-004): 取り出した音を AVAudioEngine に通せるかを確かめる。
/// エンジンは「手動レンダリング(リアルタイム)」で動かし、音声のコールバックの中から呼ぶ。

/// エンジンに渡す音と、エンジンから受け取る音の置き場(チャンネル別)。
/// 開始のときに確保し、コールバックの中では確保しない。
final class EngineBuffers: @unchecked Sendable {
    let channels: Int
    /// 1回に扱えるフレーム数の上限。
    let capacity: Int
    /// チャンネル c の音は、先頭から c × capacity の位置に置く。
    let inputData: UnsafeMutablePointer<Float>
    let outputData: UnsafeMutablePointer<Float>
    let inputList: UnsafeMutableAudioBufferListPointer
    let outputList: UnsafeMutableAudioBufferListPointer

    init(channels: Int, capacity: Int) {
        self.channels = channels
        self.capacity = capacity
        inputData = .allocate(capacity: channels * capacity)
        inputData.initialize(repeating: 0, count: channels * capacity)
        outputData = .allocate(capacity: channels * capacity)
        outputData.initialize(repeating: 0, count: channels * capacity)
        inputList = AudioBufferList.allocate(maximumBuffers: channels)
        outputList = AudioBufferList.allocate(maximumBuffers: channels)
        for channel in 0..<channels {
            inputList[channel] = AudioBuffer(
                mNumberChannels: 1, mDataByteSize: 0, mData: inputData + channel * capacity)
            outputList[channel] = AudioBuffer(
                mNumberChannels: 1, mDataByteSize: 0, mData: outputData + channel * capacity)
        }
    }

    deinit {
        free(inputList.unsafeMutablePointer)
        free(outputList.unsafeMutablePointer)
        inputData.deallocate()
        outputData.deallocate()
    }
}

@MainActor
final class EngineProcessor {
    static let maximumFrames = 4096

    let buffers: EngineBuffers
    private let engine = AVAudioEngine()
    private let equalizer = AVAudioUnitEQ(numberOfBands: 1)

    /// 音声のコールバックから呼ぶ、加工の入口。
    var renderBlock: AVAudioEngineManualRenderingBlock { engine.manualRenderingBlock }

    init(sampleRate: Double, channels: Int) throws {
        guard channels > 0,
              let format = AVAudioFormat(
                standardFormatWithSampleRate: sampleRate, channels: AVAudioChannelCount(channels))
        else {
            throw PassthroughError.unsupportedFormat("\(Int(sampleRate)) Hz / \(channels)ch")
        }
        buffers = EngineBuffers(channels: channels, capacity: Self.maximumFrames)

        // エンジンのほかの部品に触る前に、手動レンダリングに切り替える。
        try engine.enableManualRenderingMode(
            .realtime, format: format, maximumFrameCount: AVAudioFrameCount(Self.maximumFrames))

        // 確認用の1バンド。増幅はしない(リミッターがまだないため)。
        let band = equalizer.bands[0]
        band.filterType = .parametric
        band.frequency = 1000
        band.bandwidth = 1
        band.gain = 0
        band.bypass = false
        engine.attach(equalizer)

        guard engine.inputNode.setManualRenderingInputPCMFormat(
            format, inputBlock: Self.makeInputBlock(buffers: buffers))
        else {
            throw PassthroughError.coreAudio("エンジンの入力の設定", 0)
        }
        // つなげないときにエラーを返す、新しい関数を使う(古い関数は、アプリを落とす)。
        try engine.connectNode(engine.inputNode, to: equalizer, format: format)
        try engine.connectNode(equalizer, to: engine.mainMixerNode, format: format)
        engine.prepare()
        try engine.start()
    }

    /// 1 kHz を −10 dB にする(確認用)。
    func setCut(_ enabled: Bool) {
        equalizer.bands[0].gain = enabled ? -10 : 0
    }

    func shutdown() {
        engine.stop()
    }

    /// エンジンが音を受け取るときに呼ぶブロック。音声のスレッドで呼ばれるので、
    /// メインスレッド専用ではない関数の中で作る(`docs/failures.md` の 2026-10-12)。
    private nonisolated static func makeInputBlock(buffers: EngineBuffers) -> AVAudioIONodeInputBlock {
        { _ in UnsafePointer(buffers.inputList.unsafeMutablePointer) }
    }
}
