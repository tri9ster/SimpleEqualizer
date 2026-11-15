import CoreAudio
import SimpleEqualizerAudio
import Testing

/// テスト用の、音の入れ物。左右交互の1本、またはチャンネル別の複数本を作る。
final class Buffers {
    let list: UnsafeMutableAudioBufferListPointer
    private var storage: [UnsafeMutablePointer<Float>] = []

    /// `samples[i]` が i 本目の中身。`channels` は、その1本に入っているチャンネル数。
    init(_ samples: [[Float]], channels: Int = 2) {
        list = AudioBufferList.allocate(maximumBuffers: max(samples.count, 1))
        list.count = samples.count
        for (index, values) in samples.enumerated() {
            let data = UnsafeMutablePointer<Float>.allocate(capacity: max(values.count, 1))
            data.initialize(repeating: 0, count: max(values.count, 1))
            for (offset, value) in values.enumerated() { data[offset] = value }
            storage.append(data)
            list[index] = AudioBuffer(
                mNumberChannels: UInt32(channels),
                mDataByteSize: UInt32(values.count * MemoryLayout<Float>.size),
                mData: data)
        }
    }

    deinit {
        storage.forEach { $0.deallocate() }
        free(list.unsafeMutablePointer)
    }

    func values(_ index: Int = 0) -> [Float] {
        let count = Int(list[index].mDataByteSize) / MemoryLayout<Float>.size
        return Array(UnsafeBufferPointer(start: storage[index], count: count))
    }
}

/// 状態を作り、テストの終わりに捨てる。
final class State {
    let pointer = seq_render_state_create()
    deinit { seq_render_state_destroy(pointer) }

    func render(_ input: Buffers, _ output: Buffers) {
        seq_render(pointer, input.list.unsafePointer, output.list.unsafeMutablePointer)
    }
}

private let frames = 8
private func ones() -> [Float] { [Float](repeating: 1, count: frames * 2) }
private func garbage() -> [Float] { [Float](repeating: 0.77, count: frames * 2) }

@Suite("倍率の受け渡し")
struct TargetGainTests {
    @Test("はじめの倍率は 0(無音)")
    func initialGainIsZero() {
        let state = State()
        #expect(seq_render_state_target_gain(state.pointer) == 0)
    }

    @Test("決めた倍率を読み出せる")
    func storesGain() {
        let state = State()
        seq_render_state_set_target_gain(state.pointer, 0.25)
        #expect(seq_render_state_target_gain(state.pointer) == 0.25)
    }

    @Test("倍率は 0 以上 1 以下に収める(元の音量を超えない)", arguments: [
        (Float(1.5), Float(1)), (100, 1), (.infinity, 1), (-0.5, 0), (-.infinity, 0), (.nan, 0),
    ])
    func clampsGain(gain: Float, expected: Float) {
        let state = State()
        seq_render_state_set_target_gain(state.pointer, gain)
        #expect(seq_render_state_target_gain(state.pointer) == expected)
    }
}

@Suite("音声のコールバックの計算")
struct RenderTests {
    @Test("倍率 0 では、無音を出す")
    func zeroGainIsSilent() {
        let state = State()
        let output = Buffers([garbage()])
        state.render(Buffers([ones()]), output)
        #expect(output.values().allSatisfy { $0 == 0 })
    }

    @Test("倍率が落ち着いたあとは、入力に倍率を掛けたものが出る")
    func steadyStateAppliesGain() {
        let state = State()
        seq_render_state_set_target_gain(state.pointer, 0.5)
        let input = Buffers([[0.2, -0.4, 0.6, -0.8, 1.0, -1.0, 0.1, 0.3]])
        state.render(input, Buffers([[Float](repeating: 0, count: 8)]))
        let output = Buffers([[Float](repeating: 9, count: 8)])
        state.render(input, output)
        #expect(output.values() == [0.1, -0.2, 0.3, -0.4, 0.5, -0.5, 0.05, 0.15])
    }

    @Test("倍率 1 では、入力がそのまま出る")
    func unityGainPassesThrough() {
        let state = State()
        seq_render_state_set_target_gain(state.pointer, 1)
        let samples: [Float] = [0.2, -0.4, 0.6, -0.8]
        state.render(Buffers([samples]), Buffers([[0, 0, 0, 0]]))
        let output = Buffers([[9, 9, 9, 9]])
        state.render(Buffers([samples]), output)
        #expect(output.values() == samples)
    }

    @Test("はじめの1回は、0 から目標へなめらかに上げる(いきなり大きな音を出さない)")
    func firstCallRampsUpFromZero() {
        let state = State()
        seq_render_state_set_target_gain(state.pointer, 1)
        let output = Buffers([garbage()])
        state.render(Buffers([ones()]), output)
        let values = output.values()
        // 左右は同じ倍率。フレームごとに、少しずつ大きくなる。
        for frame in 0..<frames {
            #expect(values[frame * 2] == values[frame * 2 + 1])
            #expect(abs(values[frame * 2] - Float(frame + 1) / Float(frames)) < 1e-6)
        }
        #expect(values[0] < 0.2)
        #expect(values.last == 1)
    }

    @Test("倍率を下げたときも、1回の中でなめらかに下げる")
    func rampsDown() {
        let state = State()
        seq_render_state_set_target_gain(state.pointer, 1)
        state.render(Buffers([ones()]), Buffers([garbage()]))
        seq_render_state_set_target_gain(state.pointer, 0)
        let output = Buffers([garbage()])
        state.render(Buffers([ones()]), output)
        let values = output.values()
        #expect(values[0] < 1)
        #expect(values[0] > 0.8)
        for frame in 1..<frames {
            #expect(values[frame * 2] < values[(frame - 1) * 2])
        }
        #expect(values.last == 0)
    }

    @Test("出力は、入力に 1 を超える倍率を掛けたものにならない")
    func neverAmplifies() {
        let state = State()
        seq_render_state_set_target_gain(state.pointer, 50)
        state.render(Buffers([ones()]), Buffers([garbage()]))
        let output = Buffers([garbage()])
        state.render(Buffers([ones()]), output)
        #expect(output.values().allSatisfy { $0 <= 1 })
    }

    @Test("大きさが合わないときは、無音を出し、回数を数える")
    func sizeMismatchIsSilent() {
        let state = State()
        seq_render_state_set_target_gain(state.pointer, 1)
        let output = Buffers([garbage()])
        state.render(Buffers([[Float](repeating: 1, count: frames)]), output)
        #expect(output.values().allSatisfy { $0 == 0 })
        #expect(seq_render_state_mismatch_count(state.pointer) == 1)
    }

    @Test("チャンネル数が合わないときは、無音を出す")
    func channelMismatchIsSilent() {
        let state = State()
        seq_render_state_set_target_gain(state.pointer, 1)
        let output = Buffers([garbage()], channels: 2)
        state.render(Buffers([ones()], channels: 1), output)
        #expect(output.values().allSatisfy { $0 == 0 })
        #expect(seq_render_state_mismatch_count(state.pointer) == 1)
    }

    @Test("入力が出力より少ないときは、無音を出す")
    func tooFewInputsIsSilent() {
        let state = State()
        seq_render_state_set_target_gain(state.pointer, 1)
        let output = Buffers([garbage(), garbage()])
        state.render(Buffers([ones()]), output)
        #expect(output.values(0).allSatisfy { $0 == 0 })
        #expect(output.values(1).allSatisfy { $0 == 0 })
        #expect(seq_render_state_mismatch_count(state.pointer) == 1)
    }

    @Test("入力がないときは、無音を出す")
    func noInputIsSilent() {
        let state = State()
        seq_render_state_set_target_gain(state.pointer, 1)
        let output = Buffers([garbage()])
        state.render(Buffers([]), output)
        #expect(output.values().allSatisfy { $0 == 0 })
    }

    @Test("音を出せなかった回は、倍率を進めない(次に出せたときに、0 から上げる)")
    func mismatchDoesNotAdvanceGain() {
        let state = State()
        seq_render_state_set_target_gain(state.pointer, 1)
        state.render(Buffers([[Float](repeating: 1, count: frames)]), Buffers([garbage()]))
        let output = Buffers([garbage()])
        state.render(Buffers([ones()]), output)
        #expect(output.values()[0] < 0.2)
        #expect(output.values().last == 1)
    }

    @Test("入力が出力より多いときは、後ろの入力を使う(タップは最後に並ぶ)")
    func usesTrailingInputs() {
        let state = State()
        seq_render_state_set_target_gain(state.pointer, 1)
        let other = [Float](repeating: 0.9, count: frames * 2)
        let tap = [Float](repeating: 0.3, count: frames * 2)
        state.render(Buffers([other, tap]), Buffers([garbage()]))
        let output = Buffers([garbage()])
        state.render(Buffers([other, tap]), output)
        #expect(output.values().allSatisfy { $0 == 0.3 })
    }

    @Test("チャンネル別の複数本も、それぞれ写す")
    func handlesMultipleBuffers() {
        let state = State()
        seq_render_state_set_target_gain(state.pointer, 1)
        let left: [Float] = [0.1, 0.2, 0.3, 0.4]
        let right: [Float] = [-0.1, -0.2, -0.3, -0.4]
        state.render(Buffers([left, right], channels: 1), Buffers([[0, 0, 0, 0], [0, 0, 0, 0]], channels: 1))
        let output = Buffers([[9, 9, 9, 9], [9, 9, 9, 9]], channels: 1)
        state.render(Buffers([left, right], channels: 1), output)
        #expect(output.values(0) == left)
        #expect(output.values(1) == right)
    }

    @Test("取り出した音の大きさは、倍率を掛ける前の最大値")
    func measuresInputPeak() {
        let state = State()
        seq_render_state_set_target_gain(state.pointer, 0.1)
        state.render(Buffers([[0.2, -0.75, 0.5, 0.1]]), Buffers([[0, 0, 0, 0]]))
        #expect(seq_render_state_input_peak(state.pointer) == 0.75)
    }

    @Test("呼ばれた回数を数える")
    func countsCallbacks() {
        let state = State()
        #expect(seq_render_state_callback_count(state.pointer) == 0)
        state.render(Buffers([ones()]), Buffers([garbage()]))
        state.render(Buffers([ones()]), Buffers([garbage()]))
        #expect(seq_render_state_callback_count(state.pointer) == 2)
        #expect(seq_render_state_mismatch_count(state.pointer) == 0)
    }

    @Test("戻すと、倍率は 0 から、回数は 0 からになる。目標の倍率は残る")
    func resetClearsProgress() {
        let state = State()
        seq_render_state_set_target_gain(state.pointer, 1)
        state.render(Buffers([ones()]), Buffers([garbage()]))
        seq_render_state_reset(state.pointer)
        #expect(seq_render_state_callback_count(state.pointer) == 0)
        #expect(seq_render_state_input_peak(state.pointer) == 0)
        #expect(seq_render_state_target_gain(state.pointer) == 1)
        let output = Buffers([garbage()])
        state.render(Buffers([ones()]), output)
        #expect(output.values()[0] < 0.2)
    }

    @Test("Core Audio に登録するコールバックも、同じ計算をする")
    func ioProcRenders() {
        let state = State()
        seq_render_state_set_target_gain(state.pointer, 1)
        var time = AudioTimeStamp()
        let input = Buffers([ones()])
        let output = Buffers([garbage()])
        let status = seq_io_proc(
            0, &time, input.list.unsafePointer, &time, output.list.unsafeMutablePointer, &time,
            UnsafeMutableRawPointer(state.pointer))
        #expect(status == 0)
        #expect(output.values().last == 1)
        #expect(seq_render_state_callback_count(state.pointer) == 1)
    }

    @Test("状態を渡されなかったコールバックは、無音を出す")
    func ioProcWithoutStateIsSilent() {
        var time = AudioTimeStamp()
        let output = Buffers([garbage()])
        _ = seq_io_proc(0, &time, Buffers([ones()]).list.unsafePointer, &time,
                        output.list.unsafeMutablePointer, &time, nil)
        #expect(output.values().allSatisfy { $0 == 0 })
    }

    // MARK: - 見直しで足したテスト

    @Test("数でない値や無限大のサンプルは、無音として出す(倍率 0 でも雑音にしない)", arguments: [Float(0), 0.5, 1])
    func nonFiniteSamplesBecomeSilence(gain: Float) {
        let state = State()
        seq_render_state_set_target_gain(state.pointer, gain)
        let samples: [Float] = [.nan, .infinity, -.infinity, 0.5]
        state.render(Buffers([samples]), Buffers([[9, 9, 9, 9]]))
        let output = Buffers([[9, 9, 9, 9]])
        state.render(Buffers([samples]), output)
        #expect(output.values() == [0, 0, 0, 0.5 * gain])
        #expect(seq_render_state_input_peak(state.pointer) == 0.5)
    }

    @Test("複数本のうち一部だけ形が合わないときは、合う分だけ写し、合わない分は無音にして数える")
    func partialMismatch() {
        let state = State()
        seq_render_state_set_target_gain(state.pointer, 1)
        let good: [Float] = [0.1, 0.2, 0.3, 0.4]
        func input() -> Buffers { Buffers([good, [0.5, 0.5]], channels: 1) }
        state.render(input(), Buffers([[0, 0, 0, 0], [0, 0, 0, 0]], channels: 1))
        let output = Buffers([[9, 9, 9, 9], [9, 9, 9, 9]], channels: 1)
        state.render(input(), output)
        #expect(output.values(0) == good)
        #expect(output.values(1) == [0, 0, 0, 0])
        #expect(seq_render_state_mismatch_count(state.pointer) == 2)
    }

    @Test("大きさがフレームの倍数でないときは、端数を無音のままにする")
    func trailingPartialFrameIsSilent() {
        let state = State()
        seq_render_state_set_target_gain(state.pointer, 1)
        let samples: [Float] = [0.1, 0.2, 0.3, 0.4, 0.5]
        state.render(Buffers([samples]), Buffers([[0, 0, 0, 0, 0]]))
        let output = Buffers([[9, 9, 9, 9, 9]])
        state.render(Buffers([samples]), output)
        #expect(output.values() == [0.1, 0.2, 0.3, 0.4, 0])
    }

    @Test("消している途中は、目標の倍率に関係なく 0 へ下げる。目標の倍率は残る")
    func fadingOutOverridesTarget() {
        let state = State()
        seq_render_state_set_target_gain(state.pointer, 1)
        state.render(Buffers([ones()]), Buffers([garbage()]))
        #expect(!seq_render_state_is_silent(state.pointer))

        seq_render_state_set_fading_out(state.pointer, true)
        let fading = Buffers([garbage()])
        state.render(Buffers([ones()]), fading)
        #expect(fading.values()[0] < 1)
        #expect(fading.values().last == 0)
        #expect(seq_render_state_is_silent(state.pointer))
        #expect(seq_render_state_target_gain(state.pointer) == 1)

        let silent = Buffers([garbage()])
        state.render(Buffers([ones()]), silent)
        #expect(silent.values().allSatisfy { $0 == 0 })
    }

    @Test("消すのをやめると、目標の倍率へなめらかに戻る")
    func fadingOutCanBeCancelled() {
        let state = State()
        seq_render_state_set_target_gain(state.pointer, 1)
        seq_render_state_set_fading_out(state.pointer, true)
        state.render(Buffers([ones()]), Buffers([garbage()]))
        seq_render_state_set_fading_out(state.pointer, false)
        let output = Buffers([garbage()])
        state.render(Buffers([ones()]), output)
        #expect(output.values()[0] < 0.2)
        #expect(output.values().last == 1)
    }

    @Test("はじめは音が消えている。戻すと、消している途中もやめる")
    func resetClearsFadingOut() {
        let state = State()
        #expect(seq_render_state_is_silent(state.pointer))
        seq_render_state_set_target_gain(state.pointer, 1)
        seq_render_state_set_fading_out(state.pointer, true)
        seq_render_state_reset(state.pointer)
        #expect(seq_render_state_is_silent(state.pointer))
        let output = Buffers([garbage()])
        state.render(Buffers([ones()]), output)
        #expect(output.values().last == 1)
    }

    @Test("無音でない音を受け取ったかを覚える(許可がないと、ずっと無音のままになる)")
    func remembersReceivedSignal() {
        let state = State()
        #expect(!seq_render_state_has_received_signal(state.pointer))

        let silence = [Float](repeating: 0, count: frames * 2)
        state.render(Buffers([silence]), Buffers([garbage()]))
        #expect(!seq_render_state_has_received_signal(state.pointer), "無音だけでは、受け取ったことにしない")

        state.render(Buffers([[.nan, .infinity, 0, 0]]), Buffers([[9, 9, 9, 9]]))
        #expect(!seq_render_state_has_received_signal(state.pointer), "壊れた値は、受け取ったことにしない")

        state.render(Buffers([[0, 0, 0.001, 0]]), Buffers([[9, 9, 9, 9]]))
        #expect(seq_render_state_has_received_signal(state.pointer))

        state.render(Buffers([silence]), Buffers([garbage()]))
        #expect(seq_render_state_has_received_signal(state.pointer), "あとで無音になっても、覚えている")

        seq_render_state_reset(state.pointer)
        #expect(!seq_render_state_has_received_signal(state.pointer))
    }

    @Test("倍率 0(消音)でも、音を受け取ったことは分かる")
    func receivedSignalDoesNotDependOnGain() {
        let state = State()
        state.render(Buffers([ones()]), Buffers([garbage()]))
        #expect(seq_render_state_has_received_signal(state.pointer))
    }
}
