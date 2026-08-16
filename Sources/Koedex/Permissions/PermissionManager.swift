import Foundation
import AVFoundation
import Speech
import AppKit
import Combine

/// 権限の統一状態表現。
enum PermissionState: Equatable {
    case notDetermined
    case authorized
    case denied
    case restricted
}

/// Debug.appのプレビューでだけ使う、権限APIを呼ばない状態注入用の値。
struct SimulatedPermissionStates: Equatable {
    var microphone: PermissionState
    var speechRecognition: PermissionState
    var accessibility: PermissionState

    static let initial = SimulatedPermissionStates(
        microphone: .notDetermined,
        speechRecognition: .notDetermined,
        accessibility: .notDetermined
    )

    static let authorized = SimulatedPermissionStates(
        microphone: .authorized,
        speechRecognition: .authorized,
        accessibility: .authorized
    )
}

enum PermissionKind {
    case microphone
    case speechRecognition
    case accessibility
}

/// 権限状態ごとの導線をUIから切り離す。
/// マイク・音声認識は未決定時だけmacOSのネイティブ許可ダイアログを出せる一方、
/// アクセシビリティは未許可状態でもAXのプロンプトを再要求できるため扱いが異なる。
enum PermissionPrimaryAction: Equatable {
    case none
    case request
    case openSystemSettings
}

struct PermissionActionPolicy {
    static func primaryAction(for state: PermissionState, permission: PermissionKind) -> PermissionPrimaryAction {
        switch state {
        case .authorized:
            return .none
        case .notDetermined:
            return .request
        case .denied, .restricted:
            return permission == .accessibility ? .request : .openSystemSettings
        }
    }

    static func showsSystemSettingsSecondaryAction(
        for state: PermissionState,
        permission: PermissionKind
    ) -> Bool {
        permission == .accessibility && state != .authorized
    }
}

/// システム設定への3種のディープリンク定数。
enum SystemSettingsLinks {
    static let microphone = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
    static let speechRecognition = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition")!
    static let accessibility = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
    static let keyboard = URL(string: "x-apple.systempreferences:com.apple.preference.keyboard")!
}

/// マイク・音声認識・アクセシビリティの3権限の状態取得と要求を一元管理する。
/// Combineで状態変化を通知し、オンボーディングUIが監視できるようにする。
@MainActor
final class PermissionManager: ObservableObject {
    @Published private(set) var microphoneState: PermissionState = .notDetermined
    @Published private(set) var speechRecognitionState: PermissionState = .notDetermined
    @Published private(set) var accessibilityState: PermissionState = .notDetermined

    private var refreshTimer: Timer?
    private var simulatedStates: SimulatedPermissionStates?

    init(simulatedStates: SimulatedPermissionStates? = nil) {
        self.simulatedStates = simulatedStates
        refresh()
    }

    deinit {
        refreshTimer?.invalidate()
    }

    /// 3権限すべてが許可済みかどうか。
    func allGranted() -> Bool {
        microphoneState == .authorized && speechRecognitionState == .authorized && accessibilityState == .authorized
    }

    /// 現在の権限状態を再取得する。
    func refresh() {
        if let simulatedStates {
            microphoneState = simulatedStates.microphone
            speechRecognitionState = simulatedStates.speechRecognition
            accessibilityState = simulatedStates.accessibility
            return
        }
        microphoneState = Self.mapAVAuthorizationStatus(AVCaptureDevice.authorizationStatus(for: .audio))
        speechRecognitionState = Self.mapSFSpeechAuthorizationStatus(SFSpeechRecognizer.authorizationStatus())
        accessibilityState = AXIsProcessTrusted() ? .authorized : .denied
    }

    /// アクセシビリティ権限はAPIのpush通知が無いため、オンボーディング表示中のみポーリングで検知する。
    /// 常時ポーリングはTCC IPC呼び出しがログに大量出力される・不要なCPU消費を招くため、
    /// 明示的にstartPolling/stopPollingで制御する。
    func startPolling(interval: TimeInterval = 1.0) {
        guard simulatedStates == nil else { return }
        refreshTimer?.invalidate()
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    func stopPolling() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    // MARK: - リクエスト

    /// マイク権限を明示的に要求する。
    @discardableResult
    func requestMicrophone() async -> PermissionState {
        if simulatedStates != nil {
            setPreviewState(.authorized, for: .microphone)
            return microphoneState
        }
        let current = AVCaptureDevice.authorizationStatus(for: .audio)
        if current == .notDetermined {
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            AppLog.shared.info("マイク権限リクエスト結果: \(granted)")
        }
        refresh()
        return microphoneState
    }

    /// 音声認識権限を明示的に要求する。
    @discardableResult
    func requestSpeechRecognition() async -> PermissionState {
        if simulatedStates != nil {
            setPreviewState(.authorized, for: .speechRecognition)
            return speechRecognitionState
        }
        let current = SFSpeechRecognizer.authorizationStatus()
        if current == .notDetermined {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                SFSpeechRecognizer.requestAuthorization { status in
                    AppLog.shared.info("音声認識権限リクエスト結果: \(status.rawValue)")
                    continuation.resume()
                }
            }
        }
        refresh()
        return speechRecognitionState
    }

    /// アクセシビリティ権限をプロンプト付きで要求する。
    @discardableResult
    func requestAccessibility() -> PermissionState {
        if simulatedStates != nil {
            setPreviewState(.authorized, for: .accessibility)
            return accessibilityState
        }
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true]
        _ = AXIsProcessTrustedWithOptions(options)
        refresh()
        return accessibilityState
    }

    /// プレビュー専用。通常アプリでは何もしないため、実権限の状態を書き換えない。
    func setPreviewState(_ state: PermissionState, for permission: PermissionKind) {
        guard var states = simulatedStates else { return }
        switch permission {
        case .microphone: states.microphone = state
        case .speechRecognition: states.speechRecognition = state
        case .accessibility: states.accessibility = state
        }
        simulatedStates = states
        refresh()
    }

    func setAllPreviewStates(_ states: SimulatedPermissionStates) {
        guard simulatedStates != nil else { return }
        simulatedStates = states
        refresh()
    }

    // MARK: - マッピング

    private static func mapAVAuthorizationStatus(_ status: AVAuthorizationStatus) -> PermissionState {
        switch status {
        case .authorized: return .authorized
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .restricted: return .restricted
        @unknown default: return .denied
        }
    }

    private static func mapSFSpeechAuthorizationStatus(_ status: SFSpeechRecognizerAuthorizationStatus) -> PermissionState {
        switch status {
        case .authorized: return .authorized
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .restricted: return .restricted
        @unknown default: return .denied
        }
    }
}
