import Foundation

public struct TextBlock: Equatable, Sendable {
    public let text: String
    public let boundingBox: CGRect
    public let confidence: Float

    public init(text: String, boundingBox: CGRect, confidence: Float) {
        self.text = text
        self.boundingBox = boundingBox
        self.confidence = confidence
    }
}

public struct OCRResult: Equatable, Sendable {
    public let fullText: String
    public let textBlocks: [TextBlock]

    public init(fullText: String, textBlocks: [TextBlock]) {
        self.fullText = fullText
        self.textBlocks = textBlocks
    }
}
