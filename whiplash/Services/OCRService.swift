import Vision
import ImageIO
import CoreGraphics

final class OCRService {
    func recognizeText(from imageURL: URL) async throws -> OCRResult {
        print("[OCR] Starting with URL: \(imageURL.path)")

        // Load and eagerly decode the image into owned memory
        guard let imageSource = CGImageSourceCreateWithURL(imageURL as CFURL, nil),
              let srcImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            print("[OCR] FAIL: Could not load image from file")
            return OCRResult(fullText: "", textBlocks: [])
        }

        let width = srcImage.width
        let height = srcImage.height
        print("[OCR] Source image: \(width)x\(height)")

        guard let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            print("[OCR] FAIL: Could not create CGContext")
            return OCRResult(fullText: "", textBlocks: [])
        }
        context.draw(srcImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let cgImage = context.makeImage() else {
            print("[OCR] FAIL: Could not create decoded CGImage")
            return OCRResult(fullText: "", textBlocks: [])
        }
        print("[OCR] Decoded CGImage: \(cgImage.width)x\(cgImage.height)")

        // Use VNRecognizeTextRequest (proven, stable API) on a background thread
        print("[OCR] Running VNRecognizeTextRequest...")
        let imageWidth = CGFloat(width)
        let imageHeight = CGFloat(height)

        let textBlocks: [TextBlock] = try await Task.detached {
            let handler = VNImageRequestHandler(cgImage: cgImage)
            let request = VNRecognizeTextRequest()
            request.recognitionLanguages = ["ja", "en"]
            request.recognitionLevel = .accurate
            try handler.perform([request])

            let observations = request.results ?? []
            return observations.map { obs in
                let text = obs.topCandidates(1).first?.string ?? ""
                let confidence = obs.topCandidates(1).first?.confidence ?? 0
                let bbox = obs.boundingBox
                let screenRect = CGRect(
                    x: bbox.origin.x * imageWidth,
                    y: (1 - bbox.origin.y - bbox.height) * imageHeight,
                    width: bbox.width * imageWidth,
                    height: bbox.height * imageHeight
                )
                return TextBlock(text: text, boundingBox: screenRect, confidence: confidence)
            }
        }.value

        let fullText = textBlocks.map(\.text).joined(separator: "\n")
        print("[OCR] Done: \(textBlocks.count) blocks, text length: \(fullText.count)")

        return OCRResult(fullText: fullText, textBlocks: textBlocks)
    }
}
