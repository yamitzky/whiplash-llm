import Foundation
import AppKit
import ImageIO

struct CaptureResult {
    let imageURL: URL
    let imageSize: CGSize
    let captureRect: CGRect
}

enum CaptureError: Error {
    case cancelled
    case failed(String)
    case noImage
}

final class CaptureService {
    func capture() async throws -> CaptureResult {
        let id = UUID().uuidString
        let path = "/tmp/whiplash-capture-\(id).png"
        let url = URL(fileURLWithPath: path)

        // Run screencapture off the main thread to avoid blocking UI
        let status = try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-i", path]
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        }.value

        guard status == 0 else {
            throw CaptureError.cancelled
        }

        guard FileManager.default.fileExists(atPath: path) else {
            throw CaptureError.noImage
        }

        // Get image size from CGImageSource (no NSImage needed)
        guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [String: Any],
              let pixelWidth = properties[kCGImagePropertyPixelWidth as String] as? Int,
              let pixelHeight = properties[kCGImagePropertyPixelHeight as String] as? Int else {
            throw CaptureError.noImage
        }

        let imageSize = CGSize(width: pixelWidth, height: pixelHeight)
        let mouseLocation = NSEvent.mouseLocation
        let captureRect = CGRect(
            x: mouseLocation.x - imageSize.width,
            y: mouseLocation.y,
            width: imageSize.width,
            height: imageSize.height
        )

        return CaptureResult(imageURL: url, imageSize: imageSize, captureRect: captureRect)
    }

    func cleanup(url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
