import Foundation

enum Constants {
    static let serviceType = "sbcodex"
    static let sessionTimeout: TimeInterval = 60
    static let silenceTimeout: TimeInterval = 0.8
    static let utteranceTimeout: TimeInterval = 30
    static let rotationWarning: TimeInterval = 55
    static let overlapDuration: TimeInterval = 2
    static let defaultFontSize: CGFloat = 36
    static let minFontSize: CGFloat = 24
    static let maxFontSize: CGFloat = 96
    static let fontSizeStep: CGFloat = 4

    // MARK: - LLM Cleaner
    static let cleanerModelDir = "qwen2.5-3b-4bit"
    static let cleanerMaxTokens = 256
    static let cleanerTemperature: Float = 0.1
}
