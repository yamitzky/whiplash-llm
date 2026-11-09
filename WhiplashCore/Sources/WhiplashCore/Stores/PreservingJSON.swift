import Foundation

/// 保存された JSON 配列を要素ごとに読む。読めない要素は原本の JSON のまま持ち、保存時に書き戻す。
/// 配列ごと decode すると、別のバージョンが書いた 1 要素(未知のプロバイダーなど)で全体が読めなくなり、
/// 既定値で上書きして利用者の設定を消してしまう。
struct PreservingArray<Element: Codable> {
    var elements: [Element] = []
    var unreadable: [Data] = []

    /// JSON の配列として読めなければ nil。
    init?(data: Data) {
        guard let array = (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) as? [Any] else {
            return nil
        }
        let decoder = JSONDecoder()
        for item in array {
            guard let itemData = try? JSONSerialization.data(withJSONObject: item, options: [.fragmentsAllowed]) else { continue }
            if let element = try? decoder.decode(Element.self, from: itemData) {
                elements.append(element)
            } else {
                unreadable.append(itemData)
            }
        }
    }

    static func encode(_ elements: [Element], preserving unreadable: [Data]) throws -> Data {
        let encoder = JSONEncoder()
        return joinJSONArray(try elements.map { try encoder.encode($0) } + unreadable)
    }
}

/// `[BackendProvider: ProviderConnection]` を読む。JSONEncoder はこの辞書を
/// `["openAI", {...}, "ollama", {...}]` と鍵と値を交互に並べた配列で書く。
/// 読めない組(未知のプロバイダーなど)は原本のまま持ち、保存時に書き戻す。
struct PreservingConnections {
    var connections: [BackendProvider: ProviderConnection] = [:]
    /// 鍵と値それぞれの原本の JSON。
    var unreadable: [(key: Data, value: Data)] = []

    /// 鍵と値が交互に並んだ配列として読めなければ nil。
    init?(data: Data) {
        guard let array = (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) as? [Any],
              array.count % 2 == 0 else {
            return nil
        }
        let decoder = JSONDecoder()
        for index in stride(from: 0, to: array.count, by: 2) {
            guard let keyData = try? JSONSerialization.data(withJSONObject: array[index], options: [.fragmentsAllowed]),
                  let valueData = try? JSONSerialization.data(withJSONObject: array[index + 1], options: [.fragmentsAllowed]) else { continue }
            if let provider = try? decoder.decode(BackendProvider.self, from: keyData),
               let connection = try? decoder.decode(ProviderConnection.self, from: valueData) {
                connections[provider] = connection
            } else {
                unreadable.append((keyData, valueData))
            }
        }
    }

    static func encode(_ connections: [BackendProvider: ProviderConnection], preserving unreadable: [(key: Data, value: Data)]) throws -> Data {
        let encoder = JSONEncoder()
        var parts: [Data] = []
        for (provider, connection) in connections.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            parts.append(try encoder.encode(provider))
            parts.append(try encoder.encode(connection))
        }
        let decoder = JSONDecoder()
        for pair in unreadable {
            // 読めなかった組と同じプロバイダーを利用者が設定し直したら、新しい方だけを残す。
            if let provider = try? decoder.decode(BackendProvider.self, from: pair.key), connections[provider] != nil { continue }
            parts.append(pair.key)
            parts.append(pair.value)
        }
        return joinJSONArray(parts)
    }
}

private func joinJSONArray(_ parts: [Data]) -> Data {
    var data = Data("[".utf8)
    for (index, part) in parts.enumerated() {
        if index > 0 { data.append(contentsOf: Array(",".utf8)) }
        data.append(part)
    }
    data.append(contentsOf: Array("]".utf8))
    return data
}

extension UserDefaults {
    /// 読めなかった値を `<key>.unreadable.<時刻>` に残す。同じ中身が残っていれば重ねて残さない
    /// (読めないまま起動を繰り返すたびに増えないように)。
    @discardableResult
    func backUpUnreadable(_ data: Data, forKey key: String) -> String {
        let prefix = "\(key).unreadable."
        if let existing = dictionaryRepresentation().first(where: { $0.key.hasPrefix(prefix) && ($0.value as? Data) == data }) {
            return existing.key
        }
        let backupKey = prefix + String(Int(Date().timeIntervalSince1970))
        set(data, forKey: backupKey)
        return backupKey
    }
}
