import XCTest
@testable import WhiplashCore

final class OverlayGeometryTests: XCTestCase {
    private let window = CGRect(x: 0, y: 0, width: 1000, height: 1000)
    private let wholeWindow = CGRect(x: 0, y: 0, width: 1000, height: 1000)

    private func item(_ text: String, y: CGFloat, block: Int, parent: Int = 0, order: Int, x: CGFloat = 10, width: CGFloat = 300) -> OverlayTextItem {
        OverlayTextItem(frame: CGRect(x: x, y: y, width: width, height: 20), text: text, blockID: block, parentBlockID: parent, order: order)
    }

    func test_別々の段落はそれぞれ独立したブロックになる() {
        let blocks = OverlayBlockBuilder.blocks(
            from: [item("first", y: 10, block: 1, order: 0), item("second", y: 100, block: 2, order: 1)],
            selection: wholeWindow, window: window
        )
        XCTAssertEqual(blocks.map(\.text), ["first", "second"])
    }

    func test_段落の途中の太字は親の段落に読み順どおり戻される() {
        let blocks = OverlayBlockBuilder.blocks(
            from: [
                item("本イベントでは", y: 10, block: 1, order: 0),
                item("太字", y: 10, block: 2, parent: 1, order: 1, x: 320, width: 40),
                item("をテーマに", y: 10, block: 1, order: 2, x: 370, width: 100),
            ],
            selection: wholeWindow, window: window
        )
        XCTAssertEqual(blocks.map(\.text), ["本イベントでは太字をテーマに"])
    }

    func test_親子関係が切れていても段落の矩形に収まる要素は段落に含まれる() {
        let blocks = OverlayBlockBuilder.blocks(
            from: [
                OverlayTextItem(frame: CGRect(x: 10, y: 10, width: 400, height: 60), text: "長い段落", blockID: 1, parentBlockID: 0, order: 0),
                OverlayTextItem(frame: CGRect(x: 20, y: 30, width: 50, height: 20), text: "内側", blockID: 2, parentBlockID: 99, order: 1),
            ],
            selection: wholeWindow, window: window
        )
        XCTAssertEqual(blocks.map(\.text), ["長い段落内側"])
    }

    func test_範囲の端にかすっただけの要素は除外される() {
        let selection = CGRect(x: 0, y: 0, width: 1000, height: 12)
        let blocks = OverlayBlockBuilder.blocks(
            from: [item("含む", y: 0, block: 1, order: 0), item("かする", y: 11, block: 2, order: 1)],
            selection: selection, window: window
        )
        XCTAssertEqual(blocks.map(\.text), ["含む"])
    }

    func test_ウィンドウの外にある要素は除外される() {
        let blocks = OverlayBlockBuilder.blocks(
            from: [item("外", y: 5000, block: 1, order: 0)],
            selection: CGRect(x: 0, y: 0, width: 1000, height: 9000), window: window
        )
        XCTAssertTrue(blocks.isEmpty)
    }

    func test_文字を含まない要素はブロックにしない() {
        let blocks = OverlayBlockBuilder.blocks(
            from: [item("123 ・", y: 10, block: 1, order: 0)],
            selection: wholeWindow, window: window
        )
        XCTAssertTrue(blocks.isEmpty)
    }

    func test_OCRの座標はRetina画像からポイントのグローバル座標へ変換される() {
        let line = TextBlock(text: "hello", boundingBox: CGRect(x: 100, y: 200, width: 400, height: 40), confidence: 1)
        let blocks = OverlayBlockBuilder.blocks(
            fromOCR: [line],
            imageSize: CGSize(width: 1000, height: 1000),
            screenRect: CGRect(x: 50, y: 60, width: 500, height: 500)
        )
        XCTAssertEqual(blocks.first?.frame, CGRect(x: 100, y: 160, width: 200, height: 20))
    }

    func test_OCRの近い行は段落にまとまり離れた行は分かれる() {
        func line(_ text: String, y: CGFloat) -> TextBlock {
            TextBlock(text: text, boundingBox: CGRect(x: 0, y: y, width: 100, height: 20), confidence: 1)
        }
        let blocks = OverlayBlockBuilder.blocks(
            fromOCR: [line("one", y: 0), line("two", y: 25), line("三", y: 200), line("四", y: 225)],
            imageSize: CGSize(width: 100, height: 300),
            screenRect: CGRect(x: 0, y: 0, width: 100, height: 300)
        )
        XCTAssertEqual(blocks.map(\.text), ["one two", "三四"])
    }

    func test_文字サイズは本文相当に収まり極端な値にならない() {
        let body = OverlayBlockBuilder.estimatedFontSize(
            frame: CGRect(x: 0, y: 0, width: 700, height: 60),
            text: String(repeating: "あ", count: 100)
        )
        XCTAssertEqual(body, 17.3, accuracy: 1)
        XCTAssertEqual(OverlayBlockBuilder.estimatedFontSize(frame: CGRect(x: 0, y: 0, width: 2000, height: 400), text: "a"), 24)
        XCTAssertEqual(OverlayBlockBuilder.estimatedFontSize(frame: CGRect(x: 0, y: 0, width: 10, height: 5), text: "あいう"), 11)
    }

    func test_長くなった結果は下の段落を押し下げる() {
        let placed = OverlayPlacement.place(
            frames: [CGRect(x: 0, y: 0, width: 100, height: 20), CGRect(x: 0, y: 30, width: 100, height: 20)],
            contentHeights: [50, 20],
            containerHeight: 1000
        )
        XCTAssertEqual(placed[0].height, 50)
        XCTAssertEqual(placed[1].minY, 52)
    }

    func test_横に離れた段落は押し下げない() {
        let placed = OverlayPlacement.place(
            frames: [CGRect(x: 0, y: 0, width: 100, height: 20), CGRect(x: 200, y: 10, width: 100, height: 20)],
            contentHeights: [50, 20],
            containerHeight: 1000
        )
        XCTAssertEqual(placed[1].minY, 10)
    }

    func test_画面の下にはみ出すと全体を持ち上げ上端は超えない() {
        let placed = OverlayPlacement.place(
            frames: [CGRect(x: 0, y: 5, width: 100, height: 20), CGRect(x: 0, y: 90, width: 100, height: 20)],
            contentHeights: [20, 50],
            containerHeight: 100
        )
        XCTAssertEqual(placed[0].minY, 0)
        XCTAssertEqual(placed[1].maxY, 100)
    }

    func test_重ねて表示はロールの応答パターンの選択肢に出ない() {
        XCTAssertFalse(ResponsePattern.selectableCases.contains(.overlay))
        XCTAssertTrue(ResponsePattern.selectableCases.contains(.richMessage))
    }
}
