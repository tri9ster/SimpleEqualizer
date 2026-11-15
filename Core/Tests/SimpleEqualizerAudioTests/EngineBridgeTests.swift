import CoreAudio
import SimpleEqualizerAudio
import Testing

/// にせのエンジン。受け取った音に、チャンネルごとの倍率を掛けて返す。呼ばれた回数と、受け取った音を覚える。
private final class FakeEngine: @unchecked Sendable {
    let state: OpaquePointer
    var factors: [Float] = [1, 1]
    var status = 0
    var calls = 0
    var received: [[Float]] = []
    /// 返す音の長さを、頼まれた長さより短くする(エンジンが音を作りきれなかった場合)。
    var shortOutput = false

    init(state: OpaquePointer) {
        self.state = state
    }

    var block: SEQEngineRenderBlock {
        { [self] frames, output, _ in
            calls += 1
            guard let input = seq_render_state_engine_input(state, frames) else { return 1 }
            let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            let destination = UnsafeMutableAudioBufferListPointer(output)
            received = []
            for channel in 0..<source.count {
                let from = source[channel].mData!.assumingMemoryBound(to: Float.self)
                let to = destination[channel].mData!.assumingMemoryBound(to: Float.self)
                received.append(Array(UnsafeBufferPointer(start: from, count: Int(frames))))
                for frame in 0..<Int(frames) {
                    to[frame] = from[frame] * factors[channel]
                }
                if shortOutput {
                    destination[channel].mDataByteSize = 0
                }
            }
            return status
        }
    }
}

/// 倍率 1 まで上げ終えた状態に、にせのエンジンをつないだもの。
private final class Bridge {
    let state = State()
    let engine: FakeEngine

    init(channels: UInt32 = 2, capacity: UInt32 = 16) {
        engine = FakeEngine(state: state.pointer)
        seq_render_state_set_target_gain(state.pointer, 1)
        _ = render([0, 0, 0, 0])
        #expect(seq_render_state_attach_engine(state.pointer, channels, capacity, engine.block))
    }

    deinit {
        seq_render_state_detach_engine(state.pointer)
    }

    func render(_ samples: [Float], channels: Int = 2) -> [Float] {
        let input = Buffers([samples], channels: channels)
        let output = Buffers([[Float](repeating: 0.77, count: samples.count)], channels: channels)
        state.render(input, output)
        return output.values()
    }

    var fallbackCount: UInt64 { seq_render_state_engine_fallback_count(state.pointer) }
}

@Suite("エンジンを呼ぶところ")
struct EngineBridgeTests {
    @Test("エンジンをつないでいないときは、取り出した音がそのまま出る")
    func withoutEngine() {
        let state = State()
        #expect(!seq_render_state_has_engine(state.pointer))
        #expect(seq_render_state_engine_fallback_count(state.pointer) == 0)
    }

    @Test("つなげない条件(チャンネル数が 0 や多すぎる、置き場の大きさが 0)では、つながない",
          arguments: [(0, 16), (9, 16), (2, 0)])
    func rejectsInvalidShape(channels: Int, capacity: Int) {
        let state = State()
        let engine = FakeEngine(state: state.pointer)
        #expect(!seq_render_state_attach_engine(state.pointer, UInt32(channels), UInt32(capacity), engine.block))
        #expect(!seq_render_state_has_engine(state.pointer))
    }

    @Test("左右が交互の音を、チャンネル別に並べ替えてエンジンに渡す")
    func deinterleavesInput() {
        let bridge = Bridge()
        _ = bridge.render([0.1, -0.1, 0.2, -0.2, 0.3, -0.3])
        #expect(bridge.engine.calls == 1)
        #expect(bridge.engine.received == [[0.1, 0.2, 0.3], [-0.1, -0.2, -0.3]])
    }

    @Test("エンジンから受け取った音を、左右が交互になるように並べ直して出す")
    func interleavesOutput() {
        let bridge = Bridge()
        bridge.engine.factors = [0.5, 2]
        let output = bridge.render([0.2, 0.1, 0.4, 0.2, 0.6, 0.3])
        #expect(output == [0.1, 0.2, 0.2, 0.4, 0.3, 0.6])
        #expect(bridge.fallbackCount == 0)
    }

    @Test("エンジンを通した音にも、音量が掛かる。倍率は、なめらかに変わる")
    func appliesGainAfterEngine() {
        let bridge = Bridge()
        seq_render_state_set_target_gain(bridge.state.pointer, 0.5)
        let output = bridge.render([Float](repeating: 0.8, count: 8))
        // 4 フレームで、1 から 0.5 へ。
        #expect(abs(output[0] - 0.8 * 0.875) < 1e-6)
        #expect(abs(output[6] - 0.8 * 0.5) < 1e-6)
        #expect(bridge.render([0.8, 0.8]) == [0.4, 0.4])
    }

    @Test("エンジンが加工を断った回は、取り出した音をそのまま使い、回数を数える", arguments: [-1, 1, 2])
    func fallsBackWhenEngineRefuses(status: Int) {
        let bridge = Bridge()
        bridge.engine.factors = [0.5, 0.5]
        bridge.engine.status = status
        #expect(bridge.render([0.2, 0.1, 0.4, 0.2]) == [0.2, 0.1, 0.4, 0.2])
        #expect(bridge.fallbackCount == 1)
        // 次の回にエンジンが応じれば、加工した音に戻る。
        bridge.engine.status = 0
        #expect(bridge.render([0.2, 0.1, 0.4, 0.2]) == [0.1, 0.05, 0.2, 0.1])
        #expect(bridge.fallbackCount == 1)
    }

    @Test("エンジンが返した音が、頼んだ長さより短い回は、取り出した音をそのまま使う")
    func fallsBackOnShortOutput() {
        let bridge = Bridge()
        bridge.engine.factors = [0.5, 0.5]
        bridge.engine.shortOutput = true
        #expect(bridge.render([0.2, 0.1, 0.4, 0.2]) == [0.2, 0.1, 0.4, 0.2])
        #expect(bridge.fallbackCount == 1)
    }

    @Test("1回のフレーム数が置き場より多い回は、エンジンを呼ばずに、取り出した音をそのまま使う")
    func fallsBackWhenTooManyFrames() {
        let bridge = Bridge(capacity: 2)
        bridge.engine.factors = [0.5, 0.5]
        let samples: [Float] = [0.2, 0.1, 0.4, 0.2, 0.6, 0.3]
        #expect(bridge.render(samples) == samples)
        #expect(bridge.engine.calls == 0)
        #expect(bridge.fallbackCount == 1)
        // 置き場に収まる回は、エンジンを通る。
        #expect(bridge.render([0.2, 0.1, 0.4, 0.2]) == [0.1, 0.05, 0.2, 0.1])
    }

    @Test("チャンネル数が、つないだときと違う回は、エンジンを呼ばずに、取り出した音をそのまま使う")
    func fallsBackOnChannelMismatch() {
        let bridge = Bridge()
        bridge.engine.factors = [0.5, 0.5]
        #expect(bridge.render([0.2, 0.4, 0.6], channels: 1) == [0.2, 0.4, 0.6])
        #expect(bridge.engine.calls == 0)
        #expect(bridge.fallbackCount == 1)
    }

    @Test("断られた回にも、音量とリミッターは掛かる")
    func fallbackStillAppliesGain() {
        let bridge = Bridge()
        bridge.engine.status = 2
        seq_render_state_set_target_gain(bridge.state.pointer, 0.5)
        _ = bridge.render([0, 0])
        #expect(bridge.render([0.8, 0.8, 3, 3]) == [0.4, 0.4, 1, 1])
    }

    @Test("数でない値や無限大は、エンジンに渡す前に無音に置き換える")
    func sanitizesInputBeforeEngine() {
        let bridge = Bridge()
        _ = bridge.render([Float.nan, 0.1, Float.infinity, -Float.infinity])
        #expect(bridge.engine.received == [[0, 0], [0.1, 0]])
    }

    @Test("エンジンが数でない値を返しても、出力は無音になる(雑音にしない)")
    func sanitizesEngineOutput() {
        let bridge = Bridge()
        bridge.engine.factors = [Float.nan, Float.infinity]
        #expect(bridge.render([0.5, 0.5, 0.5, 0.5]) == [0, 0, 0, 0])
    }

    @Test("エンジンが音を大きくしても、出力はフルスケールを超えない(リミッターが働く)")
    func limitsBoostedOutput() {
        let bridge = Bridge()
        bridge.engine.factors = [4, 4]
        for value in bridge.render([Float](repeating: 0.5, count: 16)) {
            #expect(abs(value) <= 1)
        }
        #expect(seq_render_state_limit_count(bridge.state.pointer) == 1)
    }

    @Test("音を受け取ったかどうかは、エンジンを通す前の音で決める")
    func tracksInputSignal() {
        let bridge = Bridge()
        bridge.engine.factors = [0, 0]
        #expect(!seq_render_state_has_received_signal(bridge.state.pointer))
        _ = bridge.render([0.25, -0.5])
        #expect(seq_render_state_has_received_signal(bridge.state.pointer))
        #expect(seq_render_state_input_peak(bridge.state.pointer) == 0.5)
    }

    @Test("エンジンが音を受け取るための入口は、加工の最中に、頼んだ長さのときだけ音を返す")
    func inputIsOnlyAvailableWhileRendering() {
        let bridge = Bridge()
        #expect(seq_render_state_engine_input(bridge.state.pointer, 2) == nil)
        _ = bridge.render([0.1, 0.1, 0.2, 0.2])
        #expect(seq_render_state_engine_input(bridge.state.pointer, 2) == nil)
    }

    @Test("エンジンが、頼んだのと違う長さの音を求めたら、渡さない(その回は、取り出した音をそのまま使う)")
    func refusesWrongFrameCount() {
        let state = State()
        seq_render_state_set_target_gain(state.pointer, 1)
        let pointer = state.pointer
        let block: SEQEngineRenderBlock = { frames, _, _ in
            seq_render_state_engine_input(pointer, frames + 1) == nil ? 1 : 0
        }
        #expect(seq_render_state_attach_engine(pointer, 2, 16, block))
        defer { seq_render_state_detach_engine(pointer) }
        let input = Buffers([[0, 0, 0, 0]])
        let output = Buffers([[0.77, 0.77, 0.77, 0.77]])
        state.render(input, output)
        #expect(seq_render_state_engine_fallback_count(pointer) == 1)
    }

    @Test("エンジンを外すと、取り出した音がそのまま出る")
    func detaches() {
        let bridge = Bridge()
        bridge.engine.factors = [0.5, 0.5]
        seq_render_state_detach_engine(bridge.state.pointer)
        #expect(!seq_render_state_has_engine(bridge.state.pointer))
        #expect(bridge.render([0.2, 0.1]) == [0.2, 0.1])
        #expect(bridge.engine.calls == 0)
        #expect(bridge.fallbackCount == 0)
    }

    @Test("つなぎ直せる(前のエンジンは外れる)")
    func reattaches() {
        let bridge = Bridge()
        bridge.engine.factors = [0.5, 0.5]
        let second = FakeEngine(state: bridge.state.pointer)
        second.factors = [0.25, 0.25]
        #expect(seq_render_state_attach_engine(bridge.state.pointer, 2, 16, second.block))
        #expect(bridge.render([0.4, 0.4]) == [0.1, 0.1])
        #expect(bridge.engine.calls == 0)
    }

    @Test("始め直すと、断られた回数が 0 に戻る。エンジンは、つないだまま")
    func resetClearsFallbackCount() {
        let bridge = Bridge()
        bridge.engine.status = 2
        _ = bridge.render([0.1, 0.1])
        seq_render_state_reset(bridge.state.pointer)
        #expect(bridge.fallbackCount == 0)
        #expect(seq_render_state_has_engine(bridge.state.pointer))
    }
}
