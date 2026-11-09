import SwiftUI
import UIKit

/// iOS の `Text` に `.textSelection(.enabled)` を付けても、長押しで全文のコピーしかできない。
/// 一部だけ選んでコピーできるよう、編集できない `UITextView` で表示する。
struct SelectableText: UIViewRepresentable {
    let text: String
    var textStyle: UIFont.TextStyle = .body
    var color: UIColor = .label

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.isEditable = false
        view.isSelectable = true
        // 親の ScrollView でスクロールさせ、ここは内容の高さに合わせる。
        view.isScrollEnabled = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.adjustsFontForContentSizeCategory = true
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        // ストリーミング中は毎回届くので、同じ内容なら選択範囲を消さないよう触らない。
        guard view.text != text || view.textColor != color else { return }
        view.text = text
        view.font = .preferredFont(forTextStyle: textStyle)
        view.textColor = color
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
        // 幅が決まらないうちは高さも決められないので、SwiftUI に任せる。
        guard let width = proposal.width else { return nil }
        let size = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: size.height)
    }
}
