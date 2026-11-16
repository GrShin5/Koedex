import Foundation

enum DictationLatencyTraceRegressionTests {
    static func run() -> [(passed: Bool, name: String)] {
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let trace = DictationLatencyTrace(
            released: 0, captureDone: 2_000_000, sttReady: 12_000_000,
            cleanupStart: 13_000_000, cleanupEnd: 33_000_000,
            insertionStart: 34_000_000, insertionEnd: 39_000_000,
            inputChars: 4, outputChars: 5
        )
        let full = trace.formatted(session: id, mode: "normal", result: "inserted")
        let missing = DictationLatencyTrace(released: 0).formatted(
            session: id, mode: "handsFree", result: "result_window_shown"
        )
        return [
            (full == "[Telemetry] dictation_e2e session=\(id.uuidString) mode=normal releaseToInsertedMs=39 captureMs=2 sttMs=10 cleanupMs=20 insertionMs=5 cleanupTurn=none cleanupSkipped=false inputChars=4 outputChars=5 result=inserted", "dictation latency all stages"),
            (missing == "[Telemetry] dictation_e2e session=\(id.uuidString) mode=handsFree releaseToInsertedMs=none captureMs=none sttMs=none cleanupMs=none insertionMs=none cleanupTurn=none cleanupSkipped=true inputChars=0 outputChars=0 result=result_window_shown", "dictation latency missing stages"),
            (full.split(separator: " ").dropFirst(2).allSatisfy {
                let key = $0.split(separator: "=").first.map(String.init) ?? ""
                return ["session", "mode", "releaseToInsertedMs", "captureMs", "sttMs", "cleanupMs", "insertionMs", "cleanupTurn", "cleanupSkipped", "inputChars", "outputChars", "result"].contains(key)
            }, "dictation latency has no text payload field")
        ]
    }
}
