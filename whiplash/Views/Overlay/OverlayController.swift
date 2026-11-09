import SwiftUI
import AppKit
import WhiplashCore

/// AppKit の座標（左下原点）と CG のグローバル座標（プライマリ画面の左上原点）の変換。
enum ScreenSpace {
    static var appKitUnion: CGRect {
        NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }
    }

    private static var primaryHeight: CGFloat {
        NSScreen.screens.first?.frame.height ?? 0
    }

    static func globalPoint(fromAppKit point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: primaryHeight - point.y)
    }

    /// union の左上を原点とする、パネル内のローカル座標へ変換する。
    static func toPanel(_ global: CGRect) -> CGRect {
        let origin = globalPoint(fromAppKit: CGPoint(x: appKitUnion.minX, y: appKitUnion.maxY))
        return global.offsetBy(dx: -origin.x, dy: -origin.y)
    }
}

struct OverlayItem: Identifiable {
    let id = UUID()
    let block: OverlayBlock
    let streamingText: StreamingText
}

@MainActor
final class OverlayController {
    private var panel: NSPanel?
    private var monitors: [Any] = []
    private var onDismiss: (() -> Void)?
    private var canvas: OverlayCanvas?

    /// 表示直後の慣性スクロールで閉じてしまわないよう、この間のスクロールは無視する。
    private static let scrollGracePeriod: TimeInterval = 0.4

    func show(items: [OverlayItem], returningFocusTo pid: pid_t?, onDismiss: @escaping () -> Void) {
        dismiss()
        self.onDismiss = onDismiss

        let frames = items.map { ScreenSpace.toPanel($0.block.frame) }
        let canvas = OverlayCanvas(items: items, frames: frames)
        self.canvas = canvas
        let hosting = NSHostingView(rootView: canvas)
        hosting.sizingOptions = []

        // マウスを通して元アプリを操作できるようにする。閉じる判定はグローバルモニターで行う。
        let panel = NSPanel(contentRect: ScreenSpace.appKitUnion, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.contentView = hosting
        // contentRect はメイン画面に合わせて補正されることがあるので、明示的に戻す。
        panel.setFrame(ScreenSpace.appKitUnion, display: false)
        panel.orderFrontRegardless()
        self.panel = panel

        // ロール選択で Whiplash に移った前面を戻さないと、Esc もスクロールも元アプリに届かない。
        if let pid {
            NSRunningApplication(processIdentifier: pid)?.activate()
        }
        installMonitors()
    }

    /// スクリーンショット権限なしで表示内容を確認するための書き出し。
    /// cacheDisplay は NSHostingView の中身を描かないので、SwiftUI 側で描き直す。
    func writeSnapshot(to url: URL) {
        guard let canvas else { return }
        let size = ScreenSpace.appKitUnion.size
        let renderer = ImageRenderer(content: canvas.frame(width: size.width, height: size.height).background(Color.gray.opacity(0.3)))
        renderer.scale = 1
        guard let tiff = renderer.nsImage?.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]),
              (try? png.write(to: url)) != nil else {
            print("[TEST] snapshot: failed")
            return
        }
        print("[TEST] snapshot written")
    }

    func dismiss() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        panel?.close()
        panel = nil
        let callback = onDismiss
        onDismiss = nil
        callback?()
    }

    private func installMonitors() {
        let shownAt = Date()
        let handler: (NSEvent) -> Void = { [weak self] event in
            switch event.type {
            case .keyDown where event.keyCode == 53:
                self?.dismiss()
            case .leftMouseDown, .rightMouseDown:
                self?.dismiss()
            case .scrollWheel where Date().timeIntervalSince(shownAt) > Self.scrollGracePeriod:
                // 追従しないので、スクロールしたら本文と位置がずれる前に閉じる。
                self?.dismiss()
            default:
                break
            }
        }
        let mask: NSEvent.EventTypeMask = [.keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: handler) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { event in
            handler(event)
            return event
        }) {
            monitors.append(local)
        }
    }
}

private struct OverlayCanvas: View {
    let items: [OverlayItem]
    let frames: [CGRect]

    var body: some View {
        OverlayCanvasLayout(frames: frames) {
            ForEach(items) { item in
                OverlayBox(streamingText: item.streamingText, fontSize: item.block.fontSize)
            }
        }
    }
}

private struct OverlayCanvasLayout: Layout {
    let frames: [CGRect]

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let heights = subviews.indices.map { index in
            subviews[index].sizeThatFits(ProposedViewSize(width: frames[index].width, height: nil)).height
        }
        let placed = OverlayPlacement.place(frames: frames, contentHeights: heights, containerHeight: bounds.height)
        for index in subviews.indices {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + placed[index].minX, y: bounds.minY + placed[index].minY),
                anchor: .topLeading,
                proposal: ProposedViewSize(placed[index].size)
            )
        }
    }
}

private struct OverlayBox: View {
    let streamingText: StreamingText
    let fontSize: CGFloat

    var body: some View {
        Group {
            if let error = streamingText.error {
                filled(Text(error).foregroundStyle(.red))
            } else if streamingText.responseText.isEmpty {
                // 結果が届くまでは原文を読めるよう、隠さずに処理中だけを示す。
                ProgressView()
                    .controlSize(.small)
                    .padding(2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            } else {
                filled(Text(streamingText.responseText))
            }
        }
    }

    private func filled(_ text: some View) -> some View {
        text
            .font(.system(size: fontSize))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 2)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color(nsColor: .textBackgroundColor))
                    .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
            )
    }
}
