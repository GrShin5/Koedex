import Foundation

/// 「AIに指示」モードのモデル入力ソース。開始時のラッチ確定で一度だけ決まり、
/// 録音完了後も変わらない。
enum AICommandInputSource: String, Codable, Equatable {
    case selection
    case clipboard
}
