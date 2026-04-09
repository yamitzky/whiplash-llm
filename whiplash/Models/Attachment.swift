import Foundation

struct Attachment: Identifiable {
    let id = UUID()
    let kind: Kind

    enum Kind {
        case text(String)
        case image(URL)
    }

    var label: String {
        switch kind {
        case .text(let s):
            let preview = String(s.prefix(30))
            return "📋 \(preview)\(s.count > 30 ? "…" : "")"
        case .image:
            return "📷 キャプチャ"
        }
    }
}
