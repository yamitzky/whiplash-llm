import Foundation
import AppKit
import ImageIO
import WhiplashCore

struct CaptureResult {
    let imageURL: URL
    let imageSize: CGSize
    let captureRect: CGRect
    /// 画面上の実際の範囲（CG のグローバル座標）。特定できなければ nil。
    var screenRect: CGRect? = nil
}

/// screencapture -i は選択した範囲を返さないので、その間のマウス操作から範囲を割り出す。
/// 選択中のクリックは screencapture が奪い、グローバルモニターには届かない（実測）。
/// ボタンの状態とカーソル位置は権限なしで読めるので、短い間隔で見張る。
private final class CaptureDragTracker {
    private var timer: Timer?
    private var downPoint: CGPoint?
    private var upPoint: CGPoint?
    private var wasPressed = false

    func start() {
        let timer = Timer(timeInterval: 0.01, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        let pressed = CGEventSource.buttonState(.combinedSessionState, button: .left)
        let location = NSEvent.mouseLocation
        if pressed && !wasPressed {
            downPoint = location
            upPoint = nil
        } else if !pressed && wasPressed {
            upPoint = location
        }
        wasPressed = pressed
    }

    func screenRect(imageSize: CGSize) -> CGRect? {
        print("[Whiplash] captureRange: down=\(String(describing: downPoint)) up=\(String(describing: upPoint)) image=\(imageSize)")
        guard let up = upPoint else { return nil }
        guard let down = downPoint, hypot(up.x - down.x, up.y - down.y) > 4 else {
            // ドラッグなしはウィンドウ選択モード。画像には影が入るのでサイズでは照合できない。
            return OverlayTargetWindow.under(ScreenSpace.globalPoint(fromAppKit: up))?.bounds
        }

        let scale = NSScreen.screens.first { $0.frame.contains(up) }?.backingScaleFactor ?? 2
        let width = abs(up.x - down.x)
        let height = abs(up.y - down.y)
        // スペースキーでドラッグ中に範囲を動かすとマウスの軌跡と一致しないので、画像と照合する。
        let tolerance = 4 * scale
        guard abs(imageSize.width - width * scale) <= tolerance,
              abs(imageSize.height - height * scale) <= tolerance else {
            print("[Whiplash] captureRange: drag \(width)x\(height) @\(scale)x does not match image \(imageSize)")
            return nil
        }

        let top = ScreenSpace.globalPoint(fromAppKit: CGPoint(x: min(up.x, down.x), y: max(up.y, down.y)))
        return CGRect(x: top.x, y: top.y, width: width, height: height)
    }
}

enum CaptureError: Error {
    case cancelled
    case failed(String)
    case noImage
}

final class CaptureService {
    func capture() async throws -> CaptureResult {
        let id = UUID().uuidString
        // 機微なスクリーンショットを world-readable な /tmp ではなく、
        // ユーザー専用の一時ディレクトリ（mode 0700）に書き出す。
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("whiplash-capture-\(id).png")
        let path = url.path

        let tracker = CaptureDragTracker()
        tracker.start()
        defer { tracker.stop() }

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

        return CaptureResult(imageURL: url, imageSize: imageSize, captureRect: captureRect, screenRect: tracker.screenRect(imageSize: imageSize))
    }

    func cleanup(url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
