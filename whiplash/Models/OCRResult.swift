import Foundation

struct TextBlock: Equatable {
    let text: String
    let boundingBox: CGRect
    let confidence: Float
}

struct OCRResult: Equatable {
    let fullText: String
    let textBlocks: [TextBlock]
}
