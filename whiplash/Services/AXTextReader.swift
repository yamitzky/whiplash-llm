import AppKit
import ApplicationServices
import WhiplashCore

nonisolated struct OverlayTargetWindow: Sendable {
    let pid: pid_t
    let bounds: CGRect

    /// CGWindowList は前面から順に返るので、最初に点を含む通常ウィンドウが見えているウィンドウ。
    static func under(_ point: CGPoint) -> OverlayTargetWindow? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return nil }
        let ownPID = ProcessInfo.processInfo.processIdentifier

        for info in list {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID,
                  let dict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dict),
                  bounds.contains(point) else { continue }
            return OverlayTargetWindow(pid: pid, bounds: bounds)
        }
        return nil
    }
}

nonisolated enum AXTextReader {
    /// インライン要素はたどり続け、最も近いブロック要素を段落として扱う。
    private static let inlineRoles: Set<String> = ["AXStaticText", "AXLink", "AXInlineTextBox"]
    private static let accessibilityFlags = ["AXManualAccessibility", "AXEnhancedUserInterface"]

    static func readBlocks(target: OverlayTargetWindow, selection: CGRect) -> [OverlayBlock] {
        let app = AXUIElementCreateApplication(target.pid)
        AXUIElementSetMessagingTimeout(app, 1)

        // フラグを立てるとツリーが作り直されて数秒かかるので、読めているアプリには触らない。
        // ツリーはあるのに文字がないのは画像や描画領域を囲んだ場合で、待っても増えないので OCR に任せる。
        let bundleID = NSRunningApplication(processIdentifier: target.pid)?.bundleIdentifier
        if let bundleID, unreadableApps.contains(bundleID) { return [] }

        let first = read(app: app, target: target, selection: selection)
        if !first.blocks.isEmpty || first.nodes > populatedTreeNodes { return first.blocks }

        // 戻すと次の起動でまたツリーの作り直しを待つことになるので、立てたままにする。
        for flag in accessibilityFlags {
            AXUIElementSetAttributeValue(app, flag as CFString, kCFBooleanTrue)
        }
        var previousCount = -1
        var latest: [OverlayBlock] = []
        // 待ちすぎるより、先に終わっている OCR で重ねる方が早い。
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.2)
            latest = read(app: app, target: target, selection: selection).blocks
            if !latest.isEmpty, latest.count == previousCount { break }
            previousCount = latest.count
        }
        // ターミナルのように文章を公開しないアプリで、毎回 2 秒待たせない。
        if latest.isEmpty, let bundleID { unreadableApps.insert(bundleID) }
        return latest
    }

    /// 起動中だけ覚える。アプリの更新で読めるようになることもあるので保存はしない。
    private static let unreadableAppsLock = NSLock()
    nonisolated(unsafe) private static var _unreadableApps: Set<String> = []
    private static var unreadableApps: Set<String> {
        get { unreadableAppsLock.withLock { _unreadableApps } }
        set { unreadableAppsLock.withLock { _unreadableApps = newValue } }
    }

    /// 範囲の枝だけを歩くので、文字が無くてもこの数を超えればツリーは作られている。
    private static let populatedTreeNodes = 30

    /// 選択範囲の位置。文字単位で取れないアプリでは、選択を終えた地点の要素で代用する。
    static func selectionRect(pid: pid_t, mouse: CGPoint) -> CGRect? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1)

        if let rect = boundsOfSelection(app: app) { return rect }
        let afterEnabling = withAccessibilityEnabled(app) { () -> CGRect? in
            Thread.sleep(forTimeInterval: 0.5)
            return boundsOfSelection(app: app)
        }
        return afterEnabling ?? blockFrame(at: mouse)
    }

    private static func withAccessibilityEnabled<T>(_ app: AXUIElement, _ body: () -> T) -> T {
        // AXEnhancedUserInterface はエラーを返しても読み戻すと true になるので、戻り値を見ない。
        for flag in accessibilityFlags {
            AXUIElementSetAttributeValue(app, flag as CFString, kCFBooleanTrue)
        }
        defer {
            // 立てたままだとウィンドウのアニメーションが乱れるアプリがある。
            for flag in accessibilityFlags {
                AXUIElementSetAttributeValue(app, flag as CFString, kCFBooleanFalse)
            }
        }
        return body()
    }

    private static func read(app: AXUIElement, target: OverlayTargetWindow, selection: CGRect) -> (blocks: [OverlayBlock], nodes: Int) {
        guard let window = bestWindow(app: app, bounds: target.bounds) else { return ([], 0) }
        let walked = walk(window: window, selection: selection)
        return (OverlayBlockBuilder.blocks(from: walked.items, selection: selection, window: target.bounds), walked.nodes)
    }

    private static func bestWindow(app: AXUIElement, bounds: CGRect) -> AXUIElement? {
        let windows = attribute(app, kAXWindowsAttribute) as? [AXUIElement] ?? []
        return windows
            .map { (window: $0, overlap: overlapArea($0, bounds)) }
            .filter { $0.overlap > 0 }
            .max { $0.overlap < $1.overlap }?
            .window
    }

    private static func overlapArea(_ element: AXUIElement, _ bounds: CGRect) -> CGFloat {
        guard let frame = frame(of: element) else { return 0 }
        let overlap = frame.intersection(bounds)
        return overlap.isNull ? 0 : overlap.width * overlap.height
    }

    private static func walk(window: AXUIElement, selection: CGRect) -> (items: [OverlayTextItem], nodes: Int) {
        var items: [OverlayTextItem] = []
        var stack: [(element: AXUIElement, block: Int, parentBlock: Int)] = [(window, 0, 0)]
        var nextBlockID = 1
        var nodes = 0
        let deadline = Date().addingTimeInterval(3)

        while let (element, inheritedBlock, inheritedParent) = stack.popLast(), nodes < 30000, Date() < deadline {
            nodes += 1
            let elementFrame = frame(of: element)

            // ページ全体を歩くと表の多い画面で遅くなるので、範囲の外の枝は降りない。
            if let elementFrame, elementFrame.width > 0, elementFrame.height > 0, !elementFrame.intersects(selection) {
                continue
            }

            let role = attribute(element, kAXRoleAttribute) as? String ?? ""
            let block: Int
            let parentBlock: Int
            if inlineRoles.contains(role) {
                block = inheritedBlock
                parentBlock = inheritedParent
            } else {
                block = nextBlockID
                parentBlock = inheritedBlock
                nextBlockID += 1
            }

            if role == "AXStaticText" || role == "AXTextArea",
               let value = attribute(element, kAXValueAttribute) as? String,
               !value.isEmpty,
               let elementFrame, elementFrame.width > 0, elementFrame.height > 0 {
                items.append(OverlayTextItem(frame: elementFrame, text: value, blockID: block, parentBlockID: parentBlock, order: items.count))
                // 子にも同じ文字列が入っていて二重に訳すことになるので降りない。
                if role == "AXTextArea" { continue }
            }

            // スタックは後ろから取り出すので、読み順を保つため逆順に積む。
            let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
            for child in children.reversed() {
                stack.append((child, block, parentBlock))
            }
        }
        return (items, nodes)
    }

    private static func boundsOfSelection(app: AXUIElement) -> CGRect? {
        guard let focused = attribute(app, kAXFocusedUIElementAttribute) else { return nil }
        let element = focused as! AXUIElement

        if let range = attribute(element, kAXSelectedTextRangeAttribute),
           let bounds = parameterized(element, kAXBoundsForRangeParameterizedAttribute, range),
           let rect = rect(from: bounds) {
            return rect
        }
        // Chromium 系は CFRange ではなく TextMarker で選択範囲を表す。
        if let range = attribute(element, "AXSelectedTextMarkerRange"),
           let bounds = parameterized(element, "AXBoundsForTextMarkerRange", range),
           let rect = rect(from: bounds) {
            return rect
        }
        return nil
    }

    private static func blockFrame(at point: CGPoint) -> CGRect? {
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(AXUIElementCreateSystemWide(), Float(point.x), Float(point.y), &hit) == .success,
              var element = hit else { return nil }
        for _ in 0..<5 {
            let role = attribute(element, kAXRoleAttribute) as? String ?? ""
            if !inlineRoles.contains(role) { break }
            guard let parent = attribute(element, kAXParentAttribute) else { break }
            element = parent as! AXUIElement
        }
        return frame(of: element)
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
    }

    private static func parameterized(_ element: AXUIElement, _ name: String, _ parameter: CFTypeRef) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyParameterizedAttributeValue(element, name as CFString, parameter, &value) == .success ? value : nil
    }

    private static func rect(from value: CFTypeRef) -> CGRect? {
        var rect = CGRect.zero
        guard CFGetTypeID(value) == AXValueGetTypeID(),
              AXValueGetValue(value as! AXValue, .cgRect, &rect),
              rect.width > 1, rect.height > 1 else { return nil }
        return rect
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        guard let position = attribute(element, kAXPositionAttribute),
              let size = attribute(element, kAXSizeAttribute) else { return nil }
        var origin = CGPoint.zero
        var extent = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &origin),
              AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
        return CGRect(origin: origin, size: extent)
    }
}
