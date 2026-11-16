import Foundation
import Dispatch

/// 本文を保持せず、停止から挿入応答までを単調時計で計測する。
struct DictationLatencyTrace {
    var released: UInt64
    var captureDone: UInt64?
    var sttReady: UInt64?
    var cleanupStart: UInt64?
    var cleanupEnd: UInt64?
    var insertionStart: UInt64?
    var insertionEnd: UInt64?
    var inputChars = 0
    var outputChars = 0

    static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    func formatted(session: UUID, mode: String, result: String) -> String {
        func milliseconds(_ start: UInt64?, _ end: UInt64?) -> String {
            guard let start, let end, end >= start else { return "none" }
            return String((end - start) / 1_000_000)
        }
        return "[Telemetry] dictation_e2e session=\(session.uuidString) mode=\(mode) "
            + "releaseToInsertedMs=\(milliseconds(released, insertionEnd)) "
            + "captureMs=\(milliseconds(released, captureDone)) sttMs=\(milliseconds(captureDone, sttReady)) "
            + "cleanupMs=\(milliseconds(cleanupStart, cleanupEnd)) insertionMs=\(milliseconds(insertionStart, insertionEnd)) "
            + "cleanupTurn=none cleanupSkipped=\(cleanupStart == nil) inputChars=\(inputChars) outputChars=\(outputChars) result=\(result)"
    }
}
