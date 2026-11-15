import AppKit
import SwiftUI

/// 音量キーを押したときに、画面の下寄りに少しの間だけ出す、音量の表示。
@MainActor
final class VolumeHUD {
    private static let visibleTime: Duration = .milliseconds(1500)
    private static let size = NSSize(width: 260, height: 56)

    private var panel: NSPanel?
    private var hostingView: NSHostingView<VolumeHUDView>?
    private var hideTask: Task<Void, Never>?

    func show(volume: Double, isMuted: Bool) {
        let panel = panel ?? makePanel()
        self.panel = panel
        // キーを押し続けている間は、中身だけを書き換える(画面の部品を、毎回作り直さない)。
        let view = VolumeHUDView(volume: volume, isMuted: isMuted)
        if let hostingView {
            hostingView.rootView = view
        } else {
            let newView = NSHostingView(rootView: view)
            hostingView = newView
            panel.contentView = newView
        }
        if !panel.isVisible {
            position(panel)
        }
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: Self.visibleTime)
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    func hide() {
        hideTask?.cancel()
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        // 操作の邪魔をしない表示にする(手前に出るが、キーもマウスも受け取らない)。
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        return panel
    }

    /// メインの画面の、下寄りの中央に置く。
    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let frame = screen.visibleFrame
        let origin = NSPoint(
            x: frame.midX - Self.size.width / 2,
            y: frame.minY + frame.height * 0.12)
        panel.setFrame(NSRect(origin: origin, size: Self.size), display: true)
    }
}

private struct VolumeHUDView: View {
    let volume: Double
    let isMuted: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isMuted || volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.title2)
                .frame(width: 30)
            ProgressView(value: isMuted ? 0 : volume, total: 100)
                .progressViewStyle(.linear)
            (isMuted ? Text("消音中") : Text(verbatim: "\(Int(volume.rounded()))"))
                .monospacedDigit()
                .frame(width: 44, alignment: .trailing)
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isMuted ? Text("消音中") : Text("音量 \(Int(volume.rounded()))"))
    }
}
