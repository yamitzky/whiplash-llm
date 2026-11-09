import Foundation
import CoreGraphics

/// Accessibility API から読んだ文字要素。座標は CG のグローバル座標（プライマリ画面の左上が原点）。
public struct OverlayTextItem: Equatable, Sendable {
    public let frame: CGRect
    public let text: String
    public let blockID: Int
    public let parentBlockID: Int
    public let order: Int

    public init(frame: CGRect, text: String, blockID: Int, parentBlockID: Int, order: Int) {
        self.frame = frame
        self.text = text
        self.blockID = blockID
        self.parentBlockID = parentBlockID
        self.order = order
    }
}

public struct OverlayBlock: Equatable, Sendable {
    public let frame: CGRect
    public let text: String
    public let fontSize: CGFloat

    public init(frame: CGRect, text: String) {
        self.frame = frame
        self.text = text
        self.fontSize = OverlayBlockBuilder.estimatedFontSize(frame: frame, text: text)
    }
}

public enum OverlayBlockBuilder {
    /// 範囲の端にかすっただけの要素まで訳すと、囲んでいない行に結果が重なってしまう。
    private static let minimumOverlapRatio: CGFloat = 0.2

    public static func blocks(from items: [OverlayTextItem], selection: CGRect, window: CGRect) -> [OverlayBlock] {
        let selected = items.filter { item in
            guard item.frame.intersects(window) else { return false }
            let overlap = item.frame.intersection(selection)
            guard !overlap.isNull else { return false }
            let area = item.frame.width * item.frame.height
            return area > 0 && (overlap.width * overlap.height) / area >= minimumOverlapRatio
        }

        var groups = Dictionary(grouping: selected, by: \.blockID)

        // 太字などのインライン装飾は親の段落の途中にある別要素として届くので、親へ戻す。
        let parents = Dictionary(selected.map { ($0.blockID, $0.parentBlockID) }, uniquingKeysWith: { first, _ in first })
        for id in groups.keys.sorted(by: >) {
            guard let parent = parents[id], parent != id, groups[parent] != nil, let moved = groups[id] else { continue }
            groups[parent, default: []].append(contentsOf: moved)
            groups[id] = nil
        }

        // 親子関係が途中で切れていても、段落の矩形に収まる要素は同じ段落の一部として扱う。
        let byArea = groups.keys.sorted { area(of: groups[$0]!) > area(of: groups[$1]!) }
        for id in byArea.reversed() {
            guard let members = groups[id] else { continue }
            let frame = union(of: members)
            let container = byArea.first { other in
                other != id && groups[other] != nil
                    && area(of: groups[other]!) > frame.width * frame.height
                    && union(of: groups[other]!).insetBy(dx: -2, dy: -2).contains(frame)
            }
            if let container {
                groups[container, default: []].append(contentsOf: members)
                groups[id] = nil
            }
        }

        return groups.values
            .map { $0.sorted { $0.order < $1.order } }
            .sorted { $0[0].order < $1[0].order }
            .compactMap { members in
                let text = members.map(\.text).joined()
                guard text.contains(where: \.isLetter) else { return nil }
                return OverlayBlock(frame: union(of: members), text: text)
            }
    }

    /// OCR は行単位で返るので、行間と左端の近さから段落へまとめ直す。
    public static func blocks(fromOCR lines: [TextBlock], imageSize: CGSize, screenRect: CGRect) -> [OverlayBlock] {
        guard imageSize.width > 0, imageSize.height > 0 else { return [] }
        let scaleX = screenRect.width / imageSize.width
        let scaleY = screenRect.height / imageSize.height

        let converted: [(frame: CGRect, text: String)] = lines
            .filter { !$0.text.isEmpty }
            .map { line in
                let box = line.boundingBox
                return (
                    CGRect(
                        x: screenRect.minX + box.minX * scaleX,
                        y: screenRect.minY + box.minY * scaleY,
                        width: box.width * scaleX,
                        height: box.height * scaleY
                    ),
                    line.text
                )
            }
            .sorted { $0.frame.minY < $1.frame.minY }

        var paragraphs: [(frame: CGRect, text: String)] = []
        for line in converted {
            if let last = paragraphs.last,
               line.frame.minY - last.frame.maxY < line.frame.height * 0.8,
               abs(line.frame.minX - last.frame.minX) < line.frame.height * 1.5 {
                paragraphs[paragraphs.count - 1] = (last.frame.union(line.frame), joinLines(last.text, line.text))
            } else {
                paragraphs.append(line)
            }
        }
        return paragraphs
            .filter { $0.text.contains(where: \.isLetter) }
            .map { OverlayBlock(frame: $0.frame, text: $0.text) }
    }

    /// 元アプリのフォントは取れないので、矩形の面積と文字数から逆算する。
    public static func estimatedFontSize(frame: CGRect, text: String) -> CGFloat {
        guard !text.isEmpty, frame.width > 0, frame.height > 0 else { return 13 }
        let widthInEm = text.reduce(CGFloat(0)) { $0 + ($1.isASCII ? 0.55 : 1.0) }
        let fromArea = ((frame.width * frame.height) / (widthInEm * 1.4)).squareRoot()
        return min(max(min(fromArea, frame.height * 0.8), 11), 24)
    }

    private static func joinLines(_ first: String, _ second: String) -> String {
        // 日本語の行末に空白を入れると、訳文に不要な空白が残る。
        first.last?.isASCII == true ? first + " " + second : first + second
    }

    private static func union(of items: [OverlayTextItem]) -> CGRect {
        items.reduce(CGRect.null) { $0.union($1.frame) }
    }

    private static func area(of items: [OverlayTextItem]) -> CGFloat {
        let frame = union(of: items)
        return frame.width * frame.height
    }
}

public enum OverlayPlacement {
    /// 結果は元の段落より長くなることがあるので、下の段落を押し下げて重なりを防ぐ。
    public static func place(frames: [CGRect], contentHeights: [CGFloat], containerHeight: CGFloat) -> [CGRect] {
        var placed = frames
        var done: [CGRect] = []
        for index in frames.indices.sorted(by: { frames[$0].minY < frames[$1].minY }) {
            let frame = frames[index]
            var y = frame.minY
            for previous in done where previous.minX < frame.maxX && frame.minX < previous.maxX {
                y = max(y, previous.maxY + 2)
            }
            let rect = CGRect(x: frame.minX, y: y, width: frame.width, height: max(contentHeights[index], frame.height))
            placed[index] = rect
            done.append(rect)
        }

        // 画面の下にはみ出すと読めないので、全体を持ち上げる。
        let overflow = (placed.map(\.maxY).max() ?? 0) - containerHeight
        guard overflow > 0 else { return placed }
        return placed.map { $0.offsetBy(dx: 0, dy: -min(overflow, $0.minY)) }
    }
}
