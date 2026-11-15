import Testing
@testable import SimpleEqualizerCore

@Suite("リミッターが働いていることの表示")
struct LimiterIndicatorTests {
    @Test("回数が増えていなければ、表示しない")
    func hiddenWhenCountDoesNotGrow() {
        var indicator = LimiterIndicator()
        do { let shown = indicator.update(source: "A", count: 5, time: 0); #expect(!shown) }
        do { let shown = indicator.update(source: "A", count: 5, time: 0.3); #expect(!shown) }
    }

    @Test("回数が増えたら、表示する")
    func shownWhenCountGrows() {
        var indicator = LimiterIndicator()
        _ = indicator.update(source: "A", count: 5, time: 0)
        do { let shown = indicator.update(source: "A", count: 6, time: 0.3); #expect(shown) }
    }

    @Test("最後に増えたときから 2 秒は、表示を保つ(保たないと、音の山に合わせて点滅する)")
    func holdsForTwoSeconds() {
        var indicator = LimiterIndicator()
        _ = indicator.update(source: "A", count: 5, time: 0)
        _ = indicator.update(source: "A", count: 6, time: 1)
        do { let shown = indicator.update(source: "A", count: 6, time: 2.9); #expect(shown) }
        do { let shown = indicator.update(source: "A", count: 6, time: 3.1); #expect(!shown) }
    }

    @Test("出力先が変わって、回数が大きいほうへ跳んでも、表示しない(別の経路の回数と比べない)")
    func ignoresJumpWhenSourceChanges() {
        var indicator = LimiterIndicator()
        _ = indicator.update(source: "内蔵", count: 0, time: 0)
        // 切り替え先の経路は、前に 120 回抑えたことがある。いまは、抑えていない。
        do { let shown = indicator.update(source: "SPDIF", count: 120, time: 0.3); #expect(!shown) }
        do { let shown = indicator.update(source: "SPDIF", count: 120, time: 0.6); #expect(!shown) }
        // 切り替えたあとに、実際に増えたら、表示する。
        do { let shown = indicator.update(source: "SPDIF", count: 121, time: 0.9); #expect(shown) }
    }

    @Test("出力先が変わったら、前の出力先で出していた表示は、すぐに消す")
    func clearsWhenSourceChanges() {
        var indicator = LimiterIndicator()
        _ = indicator.update(source: "A", count: 5, time: 0)
        do { let shown = indicator.update(source: "A", count: 6, time: 0.3); #expect(shown) }
        do { let shown = indicator.update(source: "B", count: 0, time: 0.6); #expect(!shown) }
    }

    @Test("加工を始め直して、回数が 0 に戻っても、表示しない")
    func ignoresReset() {
        var indicator = LimiterIndicator()
        _ = indicator.update(source: "A", count: 50, time: 0)
        do { let shown = indicator.update(source: "A", count: 0, time: 5); #expect(!shown) }
        do { let shown = indicator.update(source: "A", count: 1, time: 5.3); #expect(shown) }
    }

    @Test("出力先がないとき(加工していないとき)は、表示しない")
    func hiddenWithoutSource() {
        var indicator = LimiterIndicator()
        _ = indicator.update(source: "A", count: 5, time: 0)
        _ = indicator.update(source: "A", count: 6, time: 0.3)
        do { let shown = indicator.update(source: nil, count: 0, time: 0.6); #expect(!shown) }
        do { let shown = indicator.update(source: "A", count: 6, time: 0.9); #expect(!shown) }
    }
}
