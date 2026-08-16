import Foundation
import CoreGraphics
import AppKit

/// グローバルホットキー監視。通常入力、「AIに指示」、ハンズフリー送信をサポートする:
///
/// - 修飾キー系（`isModifier == true`。fn・右⌘等）: `flagsChanged`を監視し、
///   「単独押し検出」アルゴリズムで押下→他のキーを挟まず解放、を1回の「押し」として検知する。
///   holdモードでは押下でonKeyDown、解放でonKeyUpを呼ぶ（従来通り）。
/// - 通常キー系（`isModifier == false`。F13等）: `keyDown`/`keyUp`を監視し、
///   該当イベントはtap内で`nil`を返すことで最前面アプリへ渡さず消費する。
///   toggleモードではkeyDown 1回でonSinglePressを呼び、holdモードでは押下開始・解放停止。
///
/// 設定変更（`SettingsStore`）を監視し、tapを作り直す。
@MainActor
final class HotkeyManager {
    var targetKeyCode: UInt16
    var isModifierKey: Bool
    var recordingMode: RecordingMode
    var aiCommandEnabled = false
    var aiCommandStartBinding: HotkeyBinding = .aiCommandStart
    var aiCommandStopBinding: HotkeyBinding = .aiCommandStop
    /// クリップボード入力バリアントの追加修飾キー。`nil`ならバリアント無効で、
    /// C-2は常に`.selection`を返す。
    var aiCommandClipboardModifier: AICommandClipboardModifier?
    /// 「AIに指示」と独立した、ハンズフリー送信の設定と活動状態。
    /// App側はsessionの開始・終了に合わせて`handsFreeSendIsActive`を更新する。
    var handsFreeSendEnabled = false
    /// 開始と停止を兼ねる単一のトグルChord。停止専用bindingは持たない。
    var handsFreeSendBinding: HotkeyBinding = .handsFreeSend
    var handsFreeSendIsActive = false

    /// hold モード用: 押下/解放
    var onKeyDown: (() -> Void)?
    var onKeyUp: (() -> Void)?
    /// toggle モード用: 単独押し（修飾キー系）/ keyDown 1回（通常キー系）で1回発火
    var onSinglePress: (() -> Void)?
    var onAICommandStart: ((AICommandInputSource) -> Void)?
    /// Return true when an active M5 recording consumed the stop binding.
    var onAICommandStop: (() -> Bool)?
    /// ハンズフリー送信のトグル。録音中なら停止、そうでなければ開始する。
    /// 戻り値はAppが要求を受理したかどうか（現状は情報用途）。
    var onHandsFreeSendToggle: (() -> Bool)?
    /// Escape押下時に録音キャンセル等を試みる。trueを返した場合のみイベントを消費する。
    var onEscape: (() -> Bool)?
    /// event tapがOSに無効化された直後に呼ぶ。取りこぼした押下・解放があるため、
    /// 進行中のハンズフリー送信は不可逆な擬似送信まで進めない。
    var onEventTapDisabled: (() -> Void)?
    /// 長押しの物理キー状態を安全に追跡できなくなった時、開始中の録音をIdleへ戻す。
    var onHoldTrackingInterrupted: (() -> Void)?
    var onPermissionDenied: (() -> Void)?

    /// 設定画面でキーを割り当てている間は、同じイベントを録音開始へ流さない。
    /// CGEvent tapはNSEventのローカルmonitorとは別経路なので、ここで明示的に遮断する。
    private var recordingTriggersSuppressed = false
    /// キー設定を確定した直後、そのキーが解放されるまで抑止を維持する。
    private var suppressionReleaseKeys: Set<HotkeyKey> = []

    var isRecordingTriggersSuppressed: Bool { recordingTriggersSuppressed }

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    // 修飾キー系: hold用の状態
    private var isModifierKeyDown = false
    // 修飾キー系: 単独押し検出用の状態
    private var monitoringModifierPress = false
    private var modifierPressStartedAt: Date?
    private var otherKeyPressedDuringModifier = false
    private let singlePressMaxDurationSeconds: TimeInterval = 0.5

    // 通常キー系: hold用の状態（重複keyDownの多重発火防止）
    private var isNormalKeyDown = false
    private let escapeKeyCode: UInt16 = 0x35

    private var aiPressedKeys: Set<HotkeyKey> = []
    private var aiStartLatched = false
    private var aiStopModifierMonitoring = false
    private var aiStopOtherKeyPressed = false
    private var aiConsumedStopKeyCode: UInt16?

    private var handsFreeSendPressedKeys: Set<HotkeyKey> = []
    /// Chord成立で1回だけトグルするためのラッチ。構成キーが離れたら解除する。
    private var handsFreeSendChordLatched = false
    /// 通常録音が先に開始した押下は、全キー解放までハンズフリーへ転用しない。
    private var ignoredHandsFreeSendChordUntilRelease = false

    /// 通常開始キーが特殊開始Chordの前方一致になる場合、長いChordを優先する短い判定待ち。
    private let normalHoldChordResolutionDelayNanoseconds: UInt64 = 150_000_000
    private var deferredNormalHoldStartTask: Task<Void, Never>?
    private var deferredNormalHoldStartToken: UUID?
    private var normalHoldStartDelivered = false
    /// 通常録音が先に始まった後に同じChordが完成しても、AI開始へ切り替えない。
    private var ignoredAIStartChordUntilRelease = false

    init(targetKeyCode: UInt16, isModifierKey: Bool, recordingMode: RecordingMode) {
        self.targetKeyCode = targetKeyCode
        self.isModifierKey = isModifierKey
        self.recordingMode = recordingMode
    }

    /// Accessibility権限を確認し、無ければプロンプトを出す。
    func checkAccessibilityPermission(promptIfNeeded: Bool) -> Bool {
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: promptIfNeeded]
        return AXIsProcessTrustedWithOptions(options)
    }

    func start() {
        guard checkAccessibilityPermission(promptIfNeeded: true) else {
            AppLog.shared.warn("[HotkeyManager] Accessibility権限が無いため、ホットキー監視を開始できません")
            onPermissionDenied?()
            return
        }

        let eventMask: CGEventMask
        // キー設定の確定後にkeyUpを待って抑止を解除するため、常にkeyUpも監視する。
        eventMask = (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)

        let callback: CGEventTapCallBack = { proxy, type, event, refcon in
            guard let refcon else { return Unmanaged.passRetained(event) }
            let manager = Unmanaged<HotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
            return manager.handle(proxy: proxy, type: type, event: event)
        }

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: callback,
            userInfo: selfPtr
        ) else {
            AppLog.shared.error("[HotkeyManager] CGEventTap作成失敗（権限不足の可能性）")
            onPermissionDenied?()
            return
        }

        self.eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        AppLog.shared.info("[HotkeyManager] ホットキー監視を開始しました（keyCode=\(targetKeyCode), isModifier=\(isModifierKey), mode=\(recordingMode.rawValue)）")
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        resetRecordingTriggerTracking()
        if !recordingTriggersSuppressed {
            suppressionReleaseKeys.removeAll()
        }
    }

    /// 設定変更を受けてtapを作り直す。
    func restart() {
        interruptHoldTrackingIfNeeded()
        stop()
        start()
    }

    /// キーキャプチャ中の録音トリガーを抑止する。切替時に途中のChord状態も破棄する。
    func setRecordingTriggersSuppressed(_ suppressed: Bool) {
        guard recordingTriggersSuppressed != suppressed else { return }
        if suppressed {
            interruptHoldTrackingIfNeeded()
        }
        recordingTriggersSuppressed = suppressed
        suppressionReleaseKeys.removeAll()
        resetRecordingTriggerTracking()
    }

    /// キー設定に使ったキーの解放を確認してから録音トリガーを再開する。
    /// すでに解放済みなら、この呼び出し時点で安全に再開する。
    func resumeRecordingTriggers(afterReleasing keys: [HotkeyKey]) {
        guard recordingTriggersSuppressed else { return }
        suppressionReleaseKeys = Set(keys.filter { isPhysicallyPressed($0) })
        guard suppressionReleaseKeys.isEmpty else { return }
        recordingTriggersSuppressed = false
        resetRecordingTriggerTracking()
    }

    private nonisolated func handle(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = MainActor.assumeIsolated({ self.eventTap }) {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            MainActor.assumeIsolated {
                // 無効化の痕跡が無いと切り分けに時間がかかる（2026-07-30の障害調査）。
                // タイムアウトはMainActorが塞がっている兆候なので、必ず記録する。
                let reason = type == .tapDisabledByTimeout ? "timeout" : "userInput"
                AppLog.shared.warn(
                    "[HotkeyManager] event tapが無効化されました（\(reason)）。再有効化し押下追跡をリセットします"
                )
                self.resetRecordingTriggerTracking()
                self.interruptHoldTrackingIfNeeded()
                // tapが落ちた状態のまま擬似送信まで走らせない。
                self.onEventTapDisabled?()
            }
            return Unmanaged.passRetained(event)
        }

        // Koedex自身が送った擬似Returnは、通常／AIに指示のホットキー判定や
        // 録音トリガー追跡を通さず、そのまま前面アプリへ渡す。
        if SyntheticInputEventTag.matches(event) {
            return Unmanaged.passRetained(event)
        }

        return MainActor.assumeIsolated {
            if self.recordingTriggersSuppressed {
                // キー割り当て中のEscはローカルmonitorへ渡し、設定入力の取消を最優先する。
                // この時点で録音トリガーは既に抑止済みなので、録音取消へ誤送信しない。
                if type == .keyDown,
                   UInt16(event.getIntegerValueField(.keyboardEventKeycode)) == self.escapeKeyCode {
                    return Unmanaged.passRetained(event)
                }
                // 通常ホットキーとAIに指示のChordを全て通過させる。
                // 毎イベントで状態を空にし、キャプチャ終了直後の誤発火を防ぐ。
                self.observeSuppressionRelease(type: type, event: event)
                self.resetRecordingTriggerTracking()
                return Unmanaged.passRetained(event)
            }

            if type == .keyDown, self.handleEscapeIfNeeded(event: event) {
                return nil
            }

            // 活動中のハンズフリー停止を最優先にする。同じFnがAI停止にも設定されていても、
            // 1つの物理イベントを複数モードへ配送しない。
            let handsFreeHandling = self.handleHandsFreeSendEvent(type: type, event: event)
            if handsFreeHandling.skipRegular {
                return handsFreeHandling.consume ? nil : Unmanaged.passRetained(event)
            }

            let aiHandling = self.handleAICommandEvent(type: type, event: event)
            if aiHandling.skipRegular {
                return aiHandling.consume ? nil : Unmanaged.passRetained(event)
            }

            if self.isModifierKey {
                if type == .keyDown {
                    self.noteOtherKeyDown()
                } else {
                    self.handleModifierKeyEvent(type: type, event: event)
                }
                // 修飾キー系は対象修飾キー以外のイベント伝播を妨げる必要はない。
                return Unmanaged.passRetained(event)
            } else {
                return self.handleNormalKeyEvent(type: type, event: event)
            }
        }
    }

    /// 開始と停止を同じChordでトグルする単一のラッチだけを持つ。
    ///
    /// 旧実装は停止専用bindingがFn単独（＝通常モードと同じ物理キー）だったため、
    /// 拘束フラグ・停止用modifier監視・消費keyCode追跡という3系統の状態を必要としていた。
    /// それらが解除されないと全ホットキーが停止する事故につながったため
    /// （2026-07-30の実機障害）、キーを1本化して状態そのものを消した。
    private func handleHandsFreeSendEvent(
        type: CGEventType,
        event: CGEvent
    ) -> (skipRegular: Bool, consume: Bool) {
        guard handsFreeSendEnabled || handsFreeSendIsActive else { return (false, false) }
        guard handsFreeSendBinding.isValid else { return (false, false) }

        let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        guard let key = handsFreeSendBinding.keySet.first(where: { $0.keyCode == code }) else {
            return (false, false)
        }

        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        if type == .keyDown, isRepeat {
            let consumesRepeat = handsFreeSendChordLatched && !key.isModifier
            return (consumesRepeat, consumesRepeat)
        }

        guard let isPress = pressState(for: key, type: type, event: event) else {
            return (false, false)
        }

        let chordWasLatched = handsFreeSendChordLatched
        if isPress {
            handsFreeSendPressedKeys.insert(key)
        } else {
            handsFreeSendPressedKeys.remove(key)
        }
        let chordIsComplete = handsFreeSendBinding.keySet.isSubset(of: handsFreeSendPressedKeys)
        if !chordIsComplete {
            // 構成キーが1つでも離れたらラッチを解除する。次の完成でまたトグルできる。
            handsFreeSendChordLatched = false
        }

        if normalHoldStartDelivered,
           regularHotkeyBinding.isStrictPrefix(of: handsFreeSendBinding),
           chordIsComplete {
            // 150ms後に通常holdが始まった押下は、途中から別モードへ切り替えない。
            ignoredHandsFreeSendChordUntilRelease = true
            let consumes = !key.isModifier
            return (consumes, consumes)
        }
        if ignoredHandsFreeSendChordUntilRelease {
            if !chordIsComplete {
                ignoredHandsFreeSendChordUntilRelease = false
            }
            let consumes = !key.isModifier
            return (consumes, consumes)
        }

        var toggled = false
        let chordHasNormalKey = handsFreeSendBinding.keys.contains { !$0.isModifier }
        if !handsFreeSendChordLatched,
           chordIsComplete,
           !chordHasNormalKey || !key.isModifier {
            handsFreeSendChordLatched = true
            toggled = true
            resetRegularHotkeyTracking()
            resetAICommandTracking()
            _ = onHandsFreeSendToggle?()
        }

        // ハンズフリー録音中は、Chordを構成するキーを通常／AIハンドラへ配送しない。
        // 既定の `fn+右Shift` は通常モードの `fn` を前方一致で含むため、素通しすると
        // fn単独の押下が通常モードの単独押し判定へ流れ、`showBusyMessage()` の
        // アニメーションが録音中の波形を一瞬置き換えてしまう。修飾キーは消費せず
        // 前面アプリへは渡す。
        if handsFreeSendIsActive {
            let consumes = !key.isModifier && (toggled || chordWasLatched)
            return (true, consumes)
        }

        let consumes = !key.isModifier && (toggled || chordWasLatched)
        return (toggled || chordWasLatched || consumes, consumes)
    }

    private func pressState(
        for key: HotkeyKey,
        type: CGEventType,
        event: CGEvent
    ) -> Bool? {
        if type == .flagsChanged, key.isModifier {
            return modifierKeyIsPressed(key, flags: event.flags)
        }
        if type == .keyDown, !key.isModifier {
            return true
        }
        if type == .keyUp, !key.isModifier {
            return false
        }
        return nil
    }

    private func eventRepresentsPress(type: CGEventType, event: CGEvent) -> Bool {
        if type == .keyDown { return true }
        guard type == .flagsChanged,
              let key = modifierKey(for: eventKeyCode(event)) else { return false }
        return modifierKeyIsPressed(key, flags: event.flags)
    }

    private func eventKeyCode(_ event: CGEvent) -> UInt16 {
        UInt16(event.getIntegerValueField(.keyboardEventKeycode))
    }

    private func modifierKey(for keyCode: UInt16) -> HotkeyKey? {
        switch keyCode {
        case HotkeyDefaults.fnKeyCode:
            return .function
        case 0x36, 0x37:
            return HotkeyKey(keyCode: keyCode, isModifier: true, modifierMask: 0x100000)
        case 0x3A, 0x3D:
            return HotkeyKey(keyCode: keyCode, isModifier: true, modifierMask: 0x080000)
        case 0x3B, 0x3E:
            return HotkeyKey(keyCode: keyCode, isModifier: true, modifierMask: 0x040000)
        case 0x38, 0x3C:
            return HotkeyKey(keyCode: keyCode, isModifier: true, modifierMask: 0x020000)
        default:
            return nil
        }
    }

    private func handleAICommandEvent(type: CGEventType, event: CGEvent) -> (skipRegular: Bool, consume: Bool) {
        guard aiCommandEnabled else { return (false, false) }
        let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        if aiConsumedStopKeyCode == code, type == .keyDown || type == .keyUp {
            if type == .keyUp { aiConsumedStopKeyCode = nil }
            return (true, true)
        }

        let allKeys = aiCommandStartBinding.keySet.union(aiCommandStopBinding.keySet)
        guard let key = allKeys.first(where: { $0.keyCode == code }) else {
            if type == .keyDown, aiStopModifierMonitoring { aiStopOtherKeyPressed = true }
            return (false, false)
        }
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        if type == .keyDown && isRepeat {
            let consumeRepeat = aiStartLatched
                && !key.isModifier
                && aiCommandStartBinding.keySet.contains(key)
            return (consumeRepeat, consumeRepeat)
        }

        let isPress: Bool
        if type == .flagsChanged, key.isModifier {
            isPress = modifierKeyIsPressed(key, flags: event.flags)
        } else if type == .keyDown, !key.isModifier {
            isPress = true
        } else if type == .keyUp, !key.isModifier {
            isPress = false
        } else {
            return (false, false)
        }

        if aiCommandStopBinding.keys.count == 1, aiCommandStopBinding.keys[0] == key {
            if key.isModifier {
                if isPress {
                    aiStopModifierMonitoring = true
                    aiStopOtherKeyPressed = false
                } else if aiStopModifierMonitoring {
                    aiStopModifierMonitoring = false
                    let shouldStop = !aiStopOtherKeyPressed
                    aiStopOtherKeyPressed = false
                    if shouldStop, onAICommandStop?() == true {
                        aiPressedKeys.remove(key)
                        resetRegularHotkeyTracking()
                        return (true, false)
                    }
                }
            } else if isPress, onAICommandStop?() == true {
                aiConsumedStopKeyCode = code
                return (true, true)
            }
        }

        let chordWasLatched = aiStartLatched
        if isPress {
            aiPressedKeys.insert(key)
            if aiStopModifierMonitoring,
               !aiCommandStopBinding.keySet.contains(key) {
                aiStopOtherKeyPressed = true
            }
        } else {
            aiPressedKeys.remove(key)
            if !aiCommandStartBinding.keySet.isSubset(of: aiPressedKeys) {
                aiStartLatched = false
            }
        }

        let startChordIsComplete = aiCommandStartBinding.keySet.isSubset(of: aiPressedKeys)
        if normalHoldStartDelivered,
           regularHotkeyBinding.isStrictPrefix(of: aiCommandStartBinding),
           startChordIsComplete {
            // 150msを越えて通常の長押しが始まった後は、同じ押下をAI開始へ転用しない。
            // 全キーが解放されるまでChordとして消費し、残ったFnで通常録音が再発火しないようにする。
            ignoredAIStartChordUntilRelease = true
            return (true, true)
        }
        if ignoredAIStartChordUntilRelease {
            if !startChordIsComplete {
                ignoredAIStartChordUntilRelease = false
            }
            let consumes = !key.isModifier && aiCommandStartBinding.keySet.contains(key)
            return (consumes, consumes)
        }

        var activatedChord = false
        let startHasNormalKey = aiCommandStartBinding.keys.contains { !$0.isModifier }
        if !aiStartLatched,
           aiCommandStartBinding.isValid,
           startChordIsComplete,
           !startHasNormalKey || !key.isModifier {
            aiStartLatched = true
            activatedChord = true
            resetRegularHotkeyTracking()
            let inputSource = AICommandClipboardChordPolicy.inputSource(
                extraModifier: aiCommandClipboardModifier,
                latchingKey: key,
                eventFlags: event.flags
            )
            AppLog.shared.info("[Telemetry] ai_command_input_source source=\(inputSource.rawValue)")
            // 「AIに指示」は複数キーChordでも常にワンタップ開始する。
            // 構成キーを離しても、開始済みの選択取得・録音はここでは止めない。
            onAICommandStart?(inputSource)
        }

        let consumes = !key.isModifier
            && aiCommandStartBinding.keySet.contains(key)
            && (activatedChord || chordWasLatched)
        return (consumes, consumes)
    }

    private var regularHotkeyBinding: HotkeyBinding {
        HotkeyBinding(keys: [HotkeyKey(
            keyCode: targetKeyCode,
            isModifier: isModifierKey,
            modifierMask: modifierMaskFromSettings
        )])
    }

    private var shouldDeferNormalHoldStart: Bool {
        recordingMode == .hold
            && (
                aiCommandEnabled
                    && regularHotkeyBinding.isStrictPrefix(of: aiCommandStartBinding)
                || handsFreeSendEnabled
                    && !handsFreeSendIsActive
                    && regularHotkeyBinding.isStrictPrefix(of: handsFreeSendBinding)
            )
    }

    private var isRegularHoldKeyDown: Bool {
        isModifierKey ? isModifierKeyDown : isNormalKeyDown
    }

    private func beginRegularHold() {
        normalHoldStartDelivered = false
        if shouldDeferNormalHoldStart {
            scheduleDeferredNormalHoldStart()
        } else {
            normalHoldStartDelivered = true
            onKeyDown?()
        }
    }

    private func endRegularHold() {
        cancelDeferredNormalHoldStart()
        guard normalHoldStartDelivered else { return }
        normalHoldStartDelivered = false
        onKeyUp?()
    }

    private func scheduleDeferredNormalHoldStart() {
        cancelDeferredNormalHoldStart()
        let token = UUID()
        deferredNormalHoldStartToken = token
        deferredNormalHoldStartTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: self?.normalHoldChordResolutionDelayNanoseconds ?? 0)
            guard !Task.isCancelled,
                  let self,
                  self.deferredNormalHoldStartToken == token,
                  self.isRegularHoldKeyDown,
                  !self.aiStartLatched,
                  !self.ignoredAIStartChordUntilRelease,
                  !self.handsFreeSendChordLatched,
                  !self.ignoredHandsFreeSendChordUntilRelease else { return }
            self.deferredNormalHoldStartTask = nil
            self.deferredNormalHoldStartToken = nil
            self.normalHoldStartDelivered = true
            self.onKeyDown?()
        }
    }

    private func cancelDeferredNormalHoldStart() {
        deferredNormalHoldStartTask?.cancel()
        deferredNormalHoldStartTask = nil
        deferredNormalHoldStartToken = nil
    }

    private func resetRegularHotkeyTracking() {
        cancelDeferredNormalHoldStart()
        isModifierKeyDown = false
        isNormalKeyDown = false
        normalHoldStartDelivered = false
        monitoringModifierPress = false
        modifierPressStartedAt = nil
        otherKeyPressedDuringModifier = false
    }

    private func resetRecordingTriggerTracking() {
        resetRegularHotkeyTracking()
        resetAICommandTracking()
        resetHandsFreeSendTracking()
    }

    private func resetAICommandTracking() {
        aiPressedKeys.removeAll()
        aiStartLatched = false
        aiStopModifierMonitoring = false
        aiStopOtherKeyPressed = false
        aiConsumedStopKeyCode = nil
        ignoredAIStartChordUntilRelease = false
    }

    private func resetHandsFreeSendTracking() {
        handsFreeSendPressedKeys.removeAll()
        handsFreeSendChordLatched = false
        ignoredHandsFreeSendChordUntilRelease = false
    }

    private func interruptHoldTrackingIfNeeded() {
        // 設定監視側は新しい録音方式を代入してからrestartする。
        // 旧設定が長押しだった場合でも、ここで方式を見て絞ると押下中の
        // セッションを取り残すため、AppDelegate側の実際の保留状態に委ねる。
        onHoldTrackingInterrupted?()
    }

    private func observeSuppressionRelease(type: CGEventType, event: CGEvent) {
        guard !suppressionReleaseKeys.isEmpty else { return }
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        guard let key = suppressionReleaseKeys.first(where: { $0.keyCode == keyCode }) else { return }

        let didRelease: Bool
        if key.isModifier {
            didRelease = type == .flagsChanged && !modifierKeyIsPressed(key, flags: event.flags)
        } else {
            didRelease = type == .keyUp
        }
        guard didRelease else { return }

        suppressionReleaseKeys.remove(key)
        guard suppressionReleaseKeys.isEmpty else { return }
        recordingTriggersSuppressed = false
        resetRecordingTriggerTracking()
    }

    private func isPhysicallyPressed(_ key: HotkeyKey) -> Bool {
        if key.isModifier {
            if key.keyCode == HotkeyDefaults.fnKeyCode {
                return NSEvent.modifierFlags.contains(.function)
            }
            return CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(key.keyCode))
        }
        return CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(key.keyCode))
    }

    private func modifierKeyIsPressed(_ key: HotkeyKey, flags: CGEventFlags) -> Bool {
        HotkeyModifierFlagsPolicy.isPressed(key, flags: flags)
    }

    private func handleEscapeIfNeeded(event: CGEvent) -> Bool {
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        guard keyCode == escapeKeyCode else { return false }
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        guard !isRepeat else { return false }
        return onEscape?() == true
    }

    // MARK: - 修飾キー系（fn・右⌘等）

    private func handleModifierKeyEvent(type: CGEventType, event: CGEvent) {
        guard type == .flagsChanged else { return }

        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        guard keyCode == targetKeyCode else {
            // 対象キー以外のflagsChanged。単独押し監視中であれば「他のキーが押された」とはみなさない
            // （flagsChangedは修飾キー変化のみで通常キーのkeyDownとは別イベントのため）。
            return
        }

        let flags = event.flags
        let isPressed = isModifierFlagPressed(flags)

        switch recordingMode {
        case .hold:
            if isPressed && !isModifierKeyDown {
                isModifierKeyDown = true
                beginRegularHold()
            } else if !isPressed && isModifierKeyDown {
                isModifierKeyDown = false
                endRegularHold()
            }
        case .toggle:
            handleModifierTogglePress(isPressed: isPressed)
        }
    }

    /// 単独押し検出アルゴリズム:
    /// - フラグが押下方向に変化 → 監視開始（開始タイムスタンプ記録、otherKeyPressed=false）
    /// - 監視中に他のkeyDownが来たら otherKeyPressed=true（`noteOtherKeyDown`経由）
    /// - フラグが解放方向に変化してotherKeyPressed==falseかつ経過時間 < 500msなら「単独押し1回」として発火
    private func handleModifierTogglePress(isPressed: Bool) {
        if isPressed && !monitoringModifierPress {
            monitoringModifierPress = true
            modifierPressStartedAt = Date()
            otherKeyPressedDuringModifier = false
        } else if !isPressed && monitoringModifierPress {
            monitoringModifierPress = false
            let startedAt = modifierPressStartedAt
            modifierPressStartedAt = nil
            let elapsed = startedAt.map { Date().timeIntervalSince($0) } ?? .greatestFiniteMagnitude

            if !otherKeyPressedDuringModifier && elapsed < singlePressMaxDurationSeconds {
                onSinglePress?()
            }
            otherKeyPressedDuringModifier = false
        }
    }

    /// 修飾キー監視中に他のkeyDownを検知した場合に呼ぶ。
    /// fn+他キーを「fn単独押し」と誤判定しないため、修飾キー系でもkeyDownを購読してここへ流す。
    private func noteOtherKeyDown() {
        if monitoringModifierPress {
            otherKeyPressedDuringModifier = true
        }
    }

    private func isModifierFlagPressed(_ flags: CGEventFlags) -> Bool {
        if targetKeyCode == HotkeyDefaults.fnKeyCode {
            return flags.contains(.maskSecondaryFn)
        }
        switch targetKeyCode {
        case 0x36, 0x37, 0x3A, 0x3D, 0x38, 0x3C, 0x3B, 0x3E:
            return CGEventSource.keyState(.combinedSessionState, key: CGKeyCode(targetKeyCode))
        default:
            return (flags.rawValue & modifierMaskFromSettings) != 0
        }
    }

    /// 上記switchでカバーされない修飾キーコード用のフォールバック判定に使うマスク。
    /// SettingsStoreの`hotkeyModifierMask`をそのまま反映するプレースホルダ（現状は.function相当固定）。
    var modifierMaskFromSettings: UInt64 = HotkeyDefaults.functionModifierMask

    // MARK: - 通常キー系（F13等）

    private func handleNormalKeyEvent(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        guard type == .keyDown || type == .keyUp else { return Unmanaged.passRetained(event) }

        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        guard keyCode == targetKeyCode else { return Unmanaged.passRetained(event) }

        // キーリピートによる連続keyDownで多重発火しないようにする。
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0

        switch recordingMode {
        case .toggle:
            if type == .keyDown && !isRepeat {
                onSinglePress?()
            }
        case .hold:
            if type == .keyDown && !isNormalKeyDown {
                isNormalKeyDown = true
                beginRegularHold()
            } else if type == .keyUp {
                isNormalKeyDown = false
                endRegularHold()
            }
        }

        // 最前面アプリへイベントを漏らさないよう消費する（nilを返す）。
        return nil
    }

    deinit {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
    }
}
