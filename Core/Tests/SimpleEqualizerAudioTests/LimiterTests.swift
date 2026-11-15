import CoreAudio
import SimpleEqualizerAudio
import Testing

/// 倍率 1(元の音量)まで上げ終えた状態を作り、テストの終わりに捨てる。
private final class Limiter {
    let pointer = seq_render_state_create()

    init(sampleRate: Double = 48000) {
        seq_render_state_set_sample_rate(pointer, sampleRate)
        seq_render_state_set_target_gain(pointer, 1)
        // 倍率は、1回の呼び出しの中で 0 から 1 へ上がる。無音を1回通して、上げ終える。
        _ = render([Float](repeating: 0, count: 16))
    }

    deinit { seq_render_state_destroy(pointer) }

    /// 左右交互の音を通し、出てきた音を返す。
    func render(_ samples: [Float]) -> [Float] {
        let input = Buffers([samples])
        let output = Buffers([[Float](repeating: 0.77, count: samples.count)])
        seq_render(pointer, input.list.unsafePointer, output.list.unsafeMutablePointer)
        return output.values()
    }

    /// チャンネル別の2本(左、右)の音を通し、出てきた音を返す。
    func renderSeparate(left: [Float], right: [Float]) -> (left: [Float], right: [Float]) {
        let input = Buffers([left, right], channels: 1)
        let output = Buffers(
            [[Float](repeating: 0.77, count: left.count), [Float](repeating: 0.77, count: right.count)],
            channels: 1)
        seq_render(pointer, input.list.unsafePointer, output.list.unsafeMutablePointer)
        return (output.values(0), output.values(1))
    }

    var limitCount: UInt64 { seq_render_state_limit_count(pointer) }
}

private let ceiling = seq_limiter_ceiling()

/// 左右とも同じ値が `frames` フレーム続く音。
private func constant(_ value: Float, frames: Int) -> [Float] {
    [Float](repeating: value, count: frames * 2)
}

@Suite("リミッター")
struct LimiterTests {
    @Test("上限はフルスケール(増幅していない音は、フルスケールまで使っていても変えない)")
    func ceilingIsFullScale() {
        #expect(ceiling == 1)
    }

    @Test("上限を超えない音は、1サンプルも変わらない")
    func passesQuietSignalUnchanged() {
        let limiter = Limiter()
        let samples: [Float] = [0.5, -0.25, 0.9, -0.9, 0, 0.001, ceiling, -ceiling]
        #expect(limiter.render(samples) == samples)
        #expect(limiter.limitCount == 0)
    }

    @Test("上限を超える音は、上限以下になる")
    func limitsLoudSignal() {
        let limiter = Limiter()
        let output = limiter.render(constant(2, frames: 64))
        for value in output {
            #expect(abs(value) <= ceiling + 1e-6)
        }
        // 抑えすぎていない(上限のすぐ近くまで出ている)。
        #expect(abs(output[0]) > ceiling - 1e-3)
    }

    @Test("左右は同じ倍率で下がる(音の位置が動かない)")
    func keepsChannelBalance() {
        let limiter = Limiter()
        // 左が 2.0、右が 0.5。比は 4 対 1。
        let output = limiter.render([2, 0.5, 2, 0.5, 2, 0.5, 2, 0.5])
        var frame = 0
        while frame < 4 {
            let left = output[frame * 2]
            let right = output[frame * 2 + 1]
            #expect(abs(left / right - 4) < 1e-4)
            #expect(abs(left) <= ceiling + 1e-6)
            frame += 1
        }
    }

    @Test("負の側に超えた音も、上限以下になる")
    func limitsNegativePeaks() {
        let limiter = Limiter()
        for value in limiter.render(constant(-3, frames: 32)) {
            #expect(abs(value) <= ceiling + 1e-6)
            #expect(value < 0)
        }
    }

    @Test("超えたあと、小さい音が続くと、倍率がだんだん 1 に戻る")
    func recoversGradually() {
        let limiter = Limiter()
        _ = limiter.render(constant(4, frames: 16))
        // 0.1 の音を 1 秒ぶん通す。出てくる値は、だんだん大きくなり、最後は 0.1 に戻る。
        let output = limiter.render(constant(0.1, frames: 48000))
        #expect(output[0] < 0.05)
        var frame = 1
        var decreased = false
        while frame < 48000 {
            if output[frame * 2] < output[(frame - 1) * 2] { decreased = true }
            frame += 1
        }
        #expect(!decreased)
        #expect(output[output.count - 1] == 0.1)
    }

    @Test("すぐには戻らない(戻るのが速すぎると、音が揺れて聞こえる)")
    func doesNotRecoverInstantly() {
        let limiter = Limiter()
        _ = limiter.render(constant(4, frames: 16))
        // 10 ミリ秒たっても、まだ半分も戻っていない。
        let output = limiter.render(constant(0.1, frames: 480))
        #expect(output[output.count - 1] < 0.05)
    }

    @Test("戻る時間は、サンプリング周波数が変わってもほぼ同じ")
    func recoveryTimeDoesNotDependOnSampleRate() {
        func levelAfter(seconds: Double, sampleRate: Double) -> Float {
            let limiter = Limiter(sampleRate: sampleRate)
            _ = limiter.render(constant(4, frames: 16))
            let output = limiter.render(constant(0.1, frames: Int(seconds * sampleRate)))
            return output[output.count - 1]
        }
        let at48 = levelAfter(seconds: 0.1, sampleRate: 48000)
        let at44 = levelAfter(seconds: 0.1, sampleRate: 44100)
        let at96 = levelAfter(seconds: 0.1, sampleRate: 96000)
        #expect(abs(at48 - at44) < 0.002)
        #expect(abs(at48 - at96) < 0.002)
    }

    @Test("使えない周波数を渡されたら、48 kHz として扱う", arguments: [0.0, -1.0, Double.nan, Double.infinity])
    func fallsBackOnInvalidSampleRate(rate: Double) {
        let reference = Limiter(sampleRate: 48000)
        _ = reference.render(constant(4, frames: 16))
        let expected = reference.render(constant(0.1, frames: 4800))

        let limiter = Limiter(sampleRate: rate)
        _ = limiter.render(constant(4, frames: 16))
        #expect(limiter.render(constant(0.1, frames: 4800)) == expected)
    }

    @Test("とても大きな値を入れても、出力は上限に収まる")
    func survivesHugeValues() {
        let limiter = Limiter()
        for value in limiter.render([100, -100, 1e30, -1e30, Float.greatestFiniteMagnitude, 1, 0.5, -0.5]) {
            #expect(value.isFinite)
            #expect(abs(value) <= 1)
        }
    }

    @Test("数でない値や無限大を入れても、出力は数のまま上限に収まる")
    func survivesNonFiniteValues() {
        let limiter = Limiter()
        for value in limiter.render([Float.nan, 2, Float.infinity, -2, -Float.infinity, Float.nan, 3, 3]) {
            #expect(value.isFinite)
            #expect(abs(value) <= ceiling + 1e-6)
        }
    }

    @Test("壊れた大きな値が1サンプル混ざっても、そのあと長く無音にならない(下げる倍率に下限がある)")
    func doesNotGoSilentAfterOneHugeSample() {
        let limiter = Limiter()
        _ = limiter.render([1e30, 1e30, 0, 0])
        // 直後の 0.5 の音は、下限(−40 dB)より小さくはならない。
        let output = limiter.render(constant(0.5, frames: 4))
        #expect(output[0] >= 0.5 * 0.01)
        // 1 秒たてば、元に戻っている。
        let later = limiter.render(constant(0.5, frames: 48000))
        #expect(later[later.count - 1] == 0.5)
    }

    @Test("チャンネル別の2本でも、左右は同じ倍率で下がる")
    func linksSeparateBuffers() {
        let limiter = Limiter()
        let output = limiter.renderSeparate(left: [2, 2, 2, 2], right: [0.5, 0.5, 0.5, 0.5])
        var frame = 0
        while frame < 4 {
            #expect(abs(output.left[frame]) <= ceiling + 1e-6)
            #expect(abs(output.left[frame] / output.right[frame] - 4) < 1e-4)
            frame += 1
        }
    }

    @Test("チャンネル別の2本で長さが違っても、範囲の外を読み書きしない")
    func handlesBuffersOfDifferentLength() {
        let limiter = Limiter()
        // 右だけ 2 フレーム長い。長い側の後ろも、上限に収まる。
        let output = limiter.renderSeparate(left: [2, 2], right: [3, 3, 3, 3])
        #expect(output.left.count == 2)
        for value in output.left + output.right {
            #expect(abs(value) <= ceiling + 1e-6)
        }
    }

    @Test("抑えていた回を数える(戻している途中の回も含む)")
    func countsLimitedCalls() {
        let limiter = Limiter()
        _ = limiter.render(constant(0.5, frames: 8))
        #expect(limiter.limitCount == 0)
        _ = limiter.render(constant(2, frames: 8))
        #expect(limiter.limitCount == 1)
        // 戻っている途中の回も、働いた回として数える。
        _ = limiter.render(constant(0.5, frames: 8))
        #expect(limiter.limitCount == 2)
    }

    @Test("音量を下げていれば、大きな入力でも働かない")
    func doesNotActWhenVolumeIsLow() {
        let limiter = Limiter()
        seq_render_state_set_target_gain(limiter.pointer, 0.25)
        _ = limiter.render(constant(0, frames: 8))
        let output = limiter.render(constant(2, frames: 8))
        #expect(output == constant(0.5, frames: 8))
        #expect(limiter.limitCount == 0)
    }

    @Test("始め直すと、下げていた倍率と回数が元に戻る")
    func resetRestoresLimiter() {
        let limiter = Limiter()
        _ = limiter.render(constant(4, frames: 8))
        seq_render_state_reset(limiter.pointer)
        #expect(limiter.limitCount == 0)
        seq_render_state_set_target_gain(limiter.pointer, 1)
        _ = limiter.render(constant(0, frames: 8))
        #expect(limiter.render(constant(0.5, frames: 8)) == constant(0.5, frames: 8))
    }
}
