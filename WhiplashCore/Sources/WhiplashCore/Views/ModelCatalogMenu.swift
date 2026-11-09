import SwiftUI

/// モデル ID 欄の横に置く「一覧から選ぶ」メニュー。自由入力の欄はそのまま残し、これは入力の手助けだけをする。
/// macOS と iOS で同じ項目・同じ文言にしたいので Core に置いている。
public struct ModelCatalogMenu: View {
    let provider: BackendProvider
    let endpoint: URL
    let selectedID: String
    let onSelect: (CatalogModel) -> Void
    let catalog: ModelCatalog

    @State private var state: LoadState = .loading

    enum LoadState: Equatable {
        case loading
        case loaded([CatalogModel])
        case failed
    }

    public init(
        provider: BackendProvider,
        endpoint: URL,
        selectedID: String,
        catalog: ModelCatalog = .shared,
        onSelect: @escaping (CatalogModel) -> Void
    ) {
        self.provider = provider
        self.endpoint = endpoint
        self.selectedID = selectedID
        self.catalog = catalog
        self.onSelect = onSelect
    }

    /// Foundation Models のように選ぶものが無いプロバイダーでは、メニュー自体を出さない。
    public static func isAvailable(for provider: BackendProvider) -> Bool {
        ModelCatalogSource.source(for: provider, endpoint: provider.defaultEndpoint) != nil
    }

    public var body: some View {
        if Self.isAvailable(for: provider) {
            Menu {
                content
            } label: {
                Label("一覧から選ぶ", systemImage: "list.bullet")
            }
            .task(id: LoadKey(provider: provider, endpoint: endpoint)) { await load() }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .loading:
            Text("読み込み中…")
        case .failed:
            Text(failureMessage)
            Button("もう一度読み込む") { Task { await load() } }
        case .loaded(let models) where models.isEmpty:
            Text(emptyMessage)
            Button("もう一度読み込む") { Task { await load() } }
        case .loaded(let models):
            Section(sectionTitle) {
                ForEach(models) { model in
                    Button { onSelect(model) } label: {
                        if model.id == selectedID {
                            Label(model.name, systemImage: "checkmark")
                        } else {
                            Text(model.name)
                        }
                        Text(subtitle(for: model))
                    }
                }
            }
            if !isLocal {
                Text("「画像対応」のモデルはロールの「画像をそのまま送信」で使えます")
            }
        }
    }

    private func load() async {
        state = .loading
        do {
            state = .loaded(try await catalog.models(for: provider, endpoint: endpoint))
        } catch {
            state = .failed
        }
    }

    private func subtitle(for model: CatalogModel) -> String {
        model.acceptsImages == true ? "\(model.id) · 画像対応" : model.id
    }

    private var isLocal: Bool { provider == .ollama || provider == .lmStudio }

    private var sectionTitle: String {
        isLocal
            ? "\(provider.displayName) に入っているモデル"
            : "models.dev の一覧（新しい順）"
    }

    private var failureMessage: String {
        isLocal
            ? "\(provider.displayName) に接続できませんでした。起動しているか確かめてください"
            : "一覧を取得できませんでした。モデル ID は直接入力できます"
    }

    private var emptyMessage: String {
        isLocal
            ? "\(provider.displayName) にモデルが入っていません"
            : "該当するモデルがありません。モデル ID は直接入力できます"
    }

    private struct LoadKey: Equatable {
        var provider: BackendProvider
        var endpoint: URL
    }
}
