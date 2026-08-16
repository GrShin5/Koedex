import AppKit
import SwiftUI

/// 設定ウィンドウに必要なAppKitの標準挙動だけを設定する。
/// ドラッグ、交通信号ボタン、ズームはすべてmacOSへ委ねる。
struct SettingsWindowBehaviorBridge: NSViewRepresentable {
    func makeCoordinator() -> SettingsWindowBehaviorCoordinator {
        SettingsWindowBehaviorCoordinator()
    }

    func makeNSView(context: Context) -> SettingsWindowBehaviorView {
        let view = SettingsWindowBehaviorView()
        view.behaviorCoordinator = context.coordinator
        return view
    }

    func updateNSView(_ nsView: SettingsWindowBehaviorView, context: Context) {
        nsView.behaviorCoordinator = context.coordinator
        DispatchQueue.main.async {
            context.coordinator.attach(to: nsView.window)
        }
    }
}

/// 表示も操作も持たないため、背景ドラッグやSwiftUIの操作を横取りしない。
final class SettingsWindowBehaviorView: NSView {
    weak var behaviorCoordinator: SettingsWindowBehaviorCoordinator?

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}

@MainActor
final class SettingsWindowBehaviorCoordinator {
    private weak var observedWindow: NSWindow?

    func attach(to window: NSWindow?) {
        guard let window, observedWindow !== window else { return }
        observedWindow = window
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        window.isMovableByWindowBackground = true
    }
}
