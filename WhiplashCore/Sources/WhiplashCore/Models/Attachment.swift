import Foundation

public struct Attachment: Identifiable, Sendable {
    public let id = UUID()
    public let kind: Kind

    public enum Kind: Sendable {
        case text(String)
        case image(URL)
    }

    public init(kind: Kind) {
        self.kind = kind
    }

    public var label: String {
        switch kind {
        case .text(let s):
            let preview = String(s.prefix(30))
            return "📋 \(preview)\(s.count > 30 ? "…" : "")"
        case .image:
            return "📷 キャプチャ"
        }
    }
}
