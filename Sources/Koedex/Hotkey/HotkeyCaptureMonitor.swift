import AppKit
import Combine

/// `HotkeyCaptureSession`をmacOSのローカルキーイベントへ接続する薄いアダプタ。
/// 候補の構文判定はSessionに集約し、保存や既存設定との衝突判定は各UIが担当する。
@MainActor
final class HotkeyCaptureMonitor: ObservableObject {
    @Published private(set) var status: HotkeyCaptureStatus = .cancelled
    @Published private(set) var isCapturing = false

    private var session: HotkeyCaptureSession?
    private var monitor: Any?
    private var completion: ((HotkeyCaptureStatus) -> Void)?

    deinit {
        if let monitor {
            NSEvent.removeMonitor(monitor)
        }
    }

    func start(
        policy: HotkeyCapturePolicy,
        onFinish: @escaping (HotkeyCaptureStatus) -> Void
    ) {
        stop()
        let session = HotkeyCaptureSession(policy: policy)
        status = session.status
        self.session = session
        completion = onFinish
        isCapturing = true

        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            self.consume(event)
            // 設定待受中の入力は、操作中の画面や前面アプリに渡さない。
            return nil
        }
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        session = nil
        completion = nil
        isCapturing = false
    }

    func cancel() {
        guard var session else {
            stop()
            return
        }
        let result = session.cancel()
        self.session = session
        finish(with: result)
    }

    private func consume(_ event: NSEvent) {
        guard var session, let captureEvent = Self.captureEvent(from: event) else { return }
        let result = session.consume(captureEvent)
        self.session = session
        status = result
        if result.isTerminal {
            finish(with: result)
        }
    }

    private func finish(with result: HotkeyCaptureStatus) {
        let completion = completion
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        session = nil
        self.completion = nil
        isCapturing = false
        status = result
        completion?(result)
    }

    private static func captureEvent(from event: NSEvent) -> HotkeyCaptureEvent? {
        let kind: HotkeyCaptureEvent.Kind
        switch event.type {
        case .flagsChanged: kind = .flagsChanged
        case .keyDown: kind = .keyDown
        case .keyUp: kind = .keyUp
        default: return nil
        }
        return HotkeyCaptureEvent(
            kind: kind,
            keyCode: event.keyCode,
            modifiers: modifierFlags(from: event.modifierFlags)
        )
    }

    private static func modifierFlags(from flags: NSEvent.ModifierFlags) -> HotkeyCaptureModifierFlags {
        var result: HotkeyCaptureModifierFlags = []
        if flags.contains(.function) { result.insert(.function) }
        if flags.contains(.command) { result.insert(.command) }
        if flags.contains(.option) { result.insert(.option) }
        if flags.contains(.control) { result.insert(.control) }
        if flags.contains(.shift) { result.insert(.shift) }
        return result
    }
}
