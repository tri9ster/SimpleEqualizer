import SimpleEqualizerCore
import SwiftUI

/// イコライザーのウィンドウ。10 本の縦のスライダーで、バンドごとの値(dB)を変える。
struct EqualizerWindow: View {
    static let id = "equalizer"
    private static let sliderHeight: CGFloat = 200

    @Bindable var model: AppModel
    @State private var isLimiting = false
    /// 矢印キーで動かすバンド。開いた直後は、いちばん左(31 Hz)。
    @State private var selectedBand = 0
    @FocusState private var isKeyboardFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                // 選んだあと(切り替えなかったときも)、矢印キーを受け取れる状態に戻す。
                PresetPicker(model: model) { isKeyboardFocused = true }
                    .frame(width: 300)
                Spacer()
                Toggle("イコライザー", isOn: $model.isEqualizerEnabled)
                    .toggleStyle(.switch)
            }

            HStack(alignment: .top, spacing: 6) {
                scale
                ForEach(0..<EqualizerSettings.bandCount, id: \.self) { band in
                    column(band)
                }
                Text(verbatim: "dB")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(height: Self.sliderHeight)
                    .padding(.top, 6)
            }
            // 切のときは、値を変えられるが、音には効いていないことが分かるよう、薄く出す。
            .opacity(model.isEqualizerEnabled ? 1 : 0.5)

            HStack {
                // ボタンを押したあとは、矢印キーを受け取れる状態に戻す。
                Button("保存") {
                    PresetActions.overwrite(model)
                    isKeyboardFocused = true
                }
                .disabled(!model.canOverwriteSelectedPreset)
                Button("別名で保存…") {
                    PresetActions.saveAs(model)
                    isKeyboardFocused = true
                }
                .disabled(!model.canEditPresets)
                Button("変更を戻す") {
                    model.revertToSelectedPreset()
                    isKeyboardFocused = true
                }
                .disabled(!model.isEqualizerModified)
                .help("保存していない変更を捨てて、選んでいるプリセットの値に戻します。")
                Spacer()
                Button("フラットに戻す") {
                    model.resetEqualizer()
                    isKeyboardFocused = true
                }
                .disabled(model.equalizer.isFlat)
            }
            HStack {
                Button("名前の変更…") {
                    PresetActions.rename(model)
                    isKeyboardFocused = true
                }
                .disabled(!model.canModifySelectedPreset)
                Button("削除…") {
                    PresetActions.delete(model)
                    isKeyboardFocused = true
                }
                .disabled(!model.canModifySelectedPreset)
                Spacer()
                Button("書き出し…") {
                    PresetActions.export(model)
                    isKeyboardFocused = true
                }
                .disabled(!model.canExportPresets)
                Button("読み込み…") {
                    PresetActions.importPresets(model)
                    isKeyboardFocused = true
                }
                .disabled(!model.canEditPresets)
            }

            notes
        }
        .padding(16)
        .fixedSize()
        // 矢印キーを受け取る。左右でバンドを選び、上下で値を変える(Shift を押しながらだと、大きく変える)。
        .focusable()
        .focusEffectDisabled()
        .focused($isKeyboardFocused)
        .onKeyPress(keys: [.leftArrow, .rightArrow, .upArrow, .downArrow]) { press in
            // Shift 以外の修飾キー(Command など)との組み合わせは、ここでは扱わない。
            guard press.modifiers.isDisjoint(with: [.command, .option, .control]) else { return .ignored }
            handleArrowKey(press)
            return .handled
        }
        .defaultFocus($isKeyboardFocused, true)
        // ボタンなどにフォーカスが移ったあと、余白を押すと、矢印キーを受け取れる状態に戻る。
        .contentShape(Rectangle())
        .onTapGesture { isKeyboardFocused = true }
        // ポップアップなど、ほかの場所からプリセットが変わったときも、矢印キーを受け取れる状態に戻す。
        .onChange(of: model.selectedPresetID) { isKeyboardFocused = true }
        .onAppear {
            // 開き直したときも、いちばん左から始める。
            selectedBand = 0
            isKeyboardFocused = true
        }
        .task {
            // 開いた直後は、ウィンドウがまだ手前に出ておらず、フォーカスの設定が効かないことがある。少し待って、もう一度設定する。
            try? await Task.sleep(for: .milliseconds(200))
            if !isKeyboardFocused { isKeyboardFocused = true }
        }
        // ウィンドウを開いている間だけ、いまの様子を調べる。
        .task {
            var indicator = LimiterIndicator()
            let start = ContinuousClock.now
            while !Task.isCancelled {
                // 回数は、経路(出力先)ごとに数えている。どの出力先の回数かを、あわせて渡す
                // (出力先を切り替えただけで、抑えているように出ないようにする)。
                let elapsed = ContinuousClock.now - start
                let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
                let limiting = indicator.update(
                    source: model.isRunning ? model.currentDevice?.uid : nil, count: model.limitCount, time: seconds)
                // 値が変わったときだけ書く(同じ値でも、書くと画面が作り直される)。
                if isLimiting != limiting { isLimiting = limiting }
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
    }

    private func handleArrowKey(_ press: KeyPress) {
        switch press.key {
        case .leftArrow:
            selectedBand = EqualizerSettings.band(selectedBand, movedBy: -1)
        case .rightArrow:
            selectedBand = EqualizerSettings.band(selectedBand, movedBy: 1)
        case .upArrow, .downArrow:
            let delta = EqualizerSettings.keyDelta(
                up: press.key == .upArrow, large: press.modifiers.contains(.shift))
            model.adjustEqualizerGain(band: selectedBand, by: delta)
        default:
            break
        }
    }

    /// バンドを選ぶ。スライダーに触ったときにも呼ぶ。キーを受け取れる状態に戻す。
    private func select(_ band: Int) {
        if selectedBand != band { selectedBand = band }
        if !isKeyboardFocused { isKeyboardFocused = true }
    }

    /// 左端の目盛り。
    private var scale: some View {
        VStack {
            Text(verbatim: "+10")
            Spacer()
            Text(verbatim: "0")
            Spacer()
            Text(verbatim: "-10")
        }
        .font(.caption)
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .frame(width: 28, height: Self.sliderHeight, alignment: .trailing)
        .padding(.top, 6)
    }

    private func column(_ band: Int) -> some View {
        let gain = model.equalizer.gain(at: band)
        let isSelected = band == selectedBand
        return VStack(spacing: 6) {
            BandSlider(
                value: gain,
                range: EqualizerSettings.gainRange,
                label: String(localized: "\(EqualizerSettings.frequencyLabels[band]) ヘルツ"),
                isSelected: isSelected
            ) {
                // つまみを引き始めたときに、そのバンドを選ぶ。
                select(band)
            } onChange: { newValue in
                model.setEqualizerGain(newValue, at: band)
            } onStep: { direction in
                // 読み上げの操作のときは、フォーカスを動かさない(読み上げの位置が、スライダーから外れるため)。
                if selectedBand != band { selectedBand = band }
                model.adjustEqualizerGain(band: band, by: direction * EqualizerSettings.step)
            }
            .frame(width: 36, height: Self.sliderHeight)
            Text(EqualizerSettings.frequencyLabels[band])
                .font(.caption)
                .fontWeight(isSelected ? .bold : .regular)
            Text(EqualizerSettings.label(forGain: gain))
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(gain == 0 ? .secondary : .primary)
        }
        .frame(width: 44)
        .padding(.vertical, 6)
        // 選んでいるバンドを、枠と色で示す。
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.accentColor.opacity(isSelected ? 0.15 : 0))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.accentColor.opacity(isSelected ? 0.8 : 0), lineWidth: 1.5)
        )
        .contentShape(Rectangle())
        // 引かずに押しただけのときも、そのバンドを選ぶ(値は変えない)。
        .simultaneousGesture(TapGesture().onEnded { select(band) })
    }

    @ViewBuilder private var notes: some View {
        VStack(alignment: .leading, spacing: 4) {
            // 音量調整が無効の出力先(macOS の音量で変える出力先)でだけ、自動で下げる設定を出す。
            // 出力先を切り替えると、出たり消えたりして、ウィンドウの大きさが変わる(切り替えは、まれなので、そのままにしている)。
            if !model.isVolumeControlEnabled {
                autoLowerSection
            }
            // 表示が出たり消えたりしても、ウィンドウの大きさが変わらないよう、場所は取っておく。
            Text(limitingMessage)
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
                .opacity(isLimiting ? 1 : 0)
                .accessibilityHidden(!isLimiting)
            Text("音声を加工していません。値は変えられますが、音には反映されません。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .opacity(model.isRunning ? 0 : 1)
                .accessibilityHidden(model.isRunning)
        }
        .frame(maxWidth: 520, alignment: .leading)
    }

    /// リミッターが働いているときの説明。音量調整が無効の出力先では、アプリの音量は使えないので、ほかの直し方を案内する。
    private var limitingMessage: String {
        if model.isVolumeControlEnabled {
            return String(localized: "音量が大きいため、音を抑えています。音がつぶれて聞こえるときは、音量を下げるか、上げているバンドを下げてください。")
        }
        if model.autoLowerEnabled {
            return String(localized: "上げているバンドがあるため、音を抑えています。音がつぶれて聞こえるときは、上げているバンドを下げてください。")
        }
        return String(localized: """
            上げているバンドがあるため、音を抑えています。音がつぶれて聞こえるときは、上げているバンドを下げるか、\
            「増幅した分だけ、全体を自動で下げる」を入にしてください。
            """)
    }

    /// 増幅した分だけ、全体を自動で下げる設定と、いま下げている量。
    private var autoLowerSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            Toggle("増幅した分だけ、全体を自動で下げる", isOn: $model.autoLowerEnabled)
                .toggleStyle(.checkbox)
            Text(autoLowerMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 4)
    }

    private var autoLowerMessage: String {
        let attenuation = model.currentAttenuationDb
        if !model.isRunning {
            return String(localized: "音声を加工していないので、下げていません。")
        }
        if !model.autoLowerEnabled {
            return String(localized: "切にしています。上げているバンドがあると、音がつぶれて聞こえることがあります。スピーカーごとの聴き比べのときに使います。")
        }
        // 表示は小数1桁なので、「0.0 dB 下げています」と出ないよう、0.05 dB 以上から出す。
        if attenuation >= 0.05 {
            return String(localized: "音がつぶれないよう、全体を \(String(format: "%.1f", attenuation)) dB 下げています。小さくなった分は、macOS の音量で上げてください。")
        }
        if !model.isEqualizerEnabled {
            return String(localized: "イコライザーが切なので、下げていません。")
        }
        return String(localized: "いまは、上げているバンドがないので、下げていません。")
    }
}

/// 縦のスライダー1本。上が大きい値。真ん中に 0 の線を出す。
private struct BandSlider: View {
    let value: Double
    let range: ClosedRange<Double>
    let label: String
    /// 矢印キーで動かすバンドとして、選ばれているか。
    let isSelected: Bool
    /// つまみを引き始めたときに呼ぶ。
    let onDragStart: () -> Void
    /// つまみを引いたときに、新しい値を受け取る。
    let onChange: (Double) -> Void
    /// 1刻みぶんの増減(+1 か −1)を受け取る。
    let onStep: (Double) -> Void

    /// つまみを引き始めたときの値。引いている間だけ持つ。
    @State private var dragStartValue: Double?

    private static let knobSize: CGFloat = 16

    var body: some View {
        GeometryReader { geometry in
            let travel = max(geometry.size.height - Self.knobSize, 1)
            let center = geometry.size.width / 2
            ZStack {
                Capsule()
                    .fill(.quaternary)
                    .frame(width: 4)
                // 0 dB の線。
                Rectangle()
                    .fill(.secondary)
                    .frame(width: 14, height: 1)
                    .position(x: center, y: position(for: 0, travel: travel))
                // 0 から、いまの値までを塗る。
                let zero = position(for: 0, travel: travel)
                let current = position(for: value, travel: travel)
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: 4, height: abs(current - zero))
                    .position(x: center, y: (current + zero) / 2)
                Circle()
                    .fill(.white)
                    .shadow(radius: 1, y: 0.5)
                    .overlay(Circle().stroke(.quaternary))
                    .frame(width: Self.knobSize, height: Self.knobSize)
                    .position(x: center, y: current)
            }
            .contentShape(Rectangle())
            // 引いた長さのぶんだけ、値を動かす。押した場所へ値を飛ばさない
            // (ウィンドウを手前に出そうとして押しただけで、急に +10 dB になるのを防ぐ)。
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { drag in
                        let start = dragStartValue ?? value
                        if dragStartValue == nil {
                            dragStartValue = start
                            onDragStart()
                        }
                        let span = range.upperBound - range.lowerBound
                        onChange(start - Double(drag.translation.height / travel) * span)
                    }
                    .onEnded { _ in dragStartValue = nil }
            )
        }
        .accessibilityElement()
        .accessibilityLabel(label)
        .accessibilityValue("\(EqualizerSettings.label(forGain: value)) デシベル")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: onStep(1)
            case .decrement: onStep(-1)
            @unknown default: break
            }
        }
    }

    /// 値に対する、つまみの中心の縦の位置。上が大きい値。
    private func position(for value: Double, travel: CGFloat) -> CGFloat {
        let ratio = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
        return Self.knobSize / 2 + travel * (1 - CGFloat(ratio))
    }
}
