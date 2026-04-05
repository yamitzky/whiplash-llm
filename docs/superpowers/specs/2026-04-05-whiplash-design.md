# Whiplash — Design Spec

**Date:** 2026-04-05
**Status:** Approved
**Platform:** macOS 26+ (Apple Silicon)
**Language:** Swift / SwiftUI
**Distribution:** Personal use only (no App Store)

---

## 1. Product Overview

### Why

画面上にあるものについて、さっとAIに聞きたい。それだけのことなのに、今は「テキストをコピー → ChatGPTなどのアプリに切り替え → 貼り付けて質問 → 待つ」という手順を踏む必要がある。コピーできないもの（画像内のテキスト、スクリーンショットでしか残せない画面）はさらに面倒。そしてChatGPT等のWebアプリは重くて遅い。

### Vision

**ショートカット一発で、画面上のあらゆるものに対してAIが即座に応答する。** アプリを切り替えず、今見ている画面のコンテキストを保ったまま。名前の通り「Whiplash（むちうち）」のような速さで。

### What

Whiplash は、スクリーンショットを撮影し、その内容に対してAIが即座に対応するmacOSアプリ。キーボードショートカットでキャプチャモードに入り、画面の任意の範囲を撮影すると、事前に設定された「Role」に基づいてAIが処理を行い、結果を返す。

### ユースケース例

- 英語のメールをスクリーンショット → 和訳してオーバーレイ表示
- 受信メールをスクリーンショット → AIが返信文を生成してクリップボードにコピー
- 複雑なコードをスクリーンショット → 要約をメッセージボックスに表示
- 英語のドキュメントをスクリーンショット → 翻訳をオーバーレイ＋クリップボードにコピー

---

## 2. Architecture

レイヤード構成で、各層が明確に分離される。

```
┌─────────────────────────────────────────────────────┐
│                      UI層                            │
│  MenuBarController / OverlayWindow / SettingsWindow  │
│  RolePopover / RichMessageBox                        │
└──────────────────────┬──────────────────────────────┘
                       │
┌──────────────────────▼──────────────────────────────┐
│                     制御層                            │
│  CaptureFlow: 撮影→Role選択→処理→応答表示            │
└──────────┬───────────────────────┬───────────────────┘
           │                       │
┌──────────▼──────────┐ ┌─────────▼───────────────────┐
│    OCRService        │ │       LLMService             │
│  Apple Vision        │ │  AnyLanguageModel            │
│  RecognizeTextRequest│ │  (Foundation Models /        │
│  (テキスト+位置情報)  │ │   Ollama / LM Studio)       │
└─────────────────────┘ └─────────────────────────────┘
                       │
┌──────────────────────▼──────────────────────────────┐
│                    データ層                           │
│  RoleStore (JSON)  /  SettingsStore (UserDefaults)   │
└─────────────────────────────────────────────────────┘
```

### 層の責務

| 層 | 責務 | 主なコンポーネント |
|---|---|---|
| UI層 | ユーザーとの接点。表示・入力 | MenuBarController, OverlayWindow, SettingsWindow, RolePopover, RichMessageBox |
| 制御層 | キャプチャ→AI処理→応答表示のパイプライン管理 | CaptureFlow |
| 処理層 | OCRとLLM呼び出し | OCRService, LLMService |
| データ層 | Roleと設定の永続化 | RoleStore, SettingsStore |

---

## 3. Data Model

### 3.1 Role

```swift
struct Role: Codable, Identifiable {
    let id: UUID
    var name: String                          // "英訳", "メール返信" など
    var icon: String                          // SF Symbol名 or 絵文字
    var systemPrompt: String                  // LLMへのシステムプロンプト
    var responsePatterns: [ResponsePattern]   // 応答パターン（複数選択可）
    var backendOverride: BackendConfig?       // nil = アプリ全体のデフォルトを使う（v1では未実装、設計上の考慮）
}
```

- プリセットRole（英訳、和訳、メール返信、要約など）は初回起動時にJSONファイルが存在しなければ初期データとして作成される
- プリセットとユーザー作成のRoleに区別はない。プリセットも編集・削除可能
- `backendOverride` はv1では使用しない。UIでもグレーアウト表示。設計上はRoleごとにバックエンドを切り替え可能にする

### 3.2 ResponsePattern

```swift
enum ResponsePattern: String, Codable {
    case richMessage    // 画面上のフローティングメッセージボックスに表示
    case clipboard      // クリップボードにコピー
    case overlay        // スクリーンショット位置にオーバーレイ表示（翻訳等）
}
```

- 1つのRoleに対して複数のResponsePatternを設定可能
- 例：和訳 → `[.overlay, .clipboard]`（オーバーレイ表示しつつクリップボードにもコピー）
- 全パターンが同時に実行される（排他ではない）
- 複数パターン併用時の clipboard の内容: LLMの応答テキスト全文をコピーする（overlay併用時は翻訳テキスト全文）

### 3.3 BackendConfig

```swift
struct BackendConfig: Codable {
    var provider: BackendProvider
    var modelName: String?     // "llama3.2" など。nilならプロバイダーのデフォルト
    var endpoint: URL?         // Ollama/LM Studio用。nilならデフォルトポート
}

enum BackendProvider: String, Codable {
    case foundationModels  // Apple Foundation Models（オンデバイス）
    case ollama            // localhost:11434
    case lmStudio          // localhost:1234
}
```

### 3.4 OCR結果

```swift
struct OCRResult {
    let fullText: String                    // 全テキスト結合
    let textBlocks: [TextBlock]             // 位置情報付きテキストブロック
}

struct TextBlock {
    let text: String
    let boundingBox: CGRect                 // 正規化座標 (0-1) からスクリーンショット座標に変換済み
    let confidence: Float
}
```

- `fullText` は richMessage / clipboard パターンで使用（LLMにテキスト全体を送る）
- `textBlocks` は overlay パターンで使用（位置ごとにLLM応答を配置する）

### 3.5 永続化

| データ | 保存先 | 形式 |
|---|---|---|
| Role一覧 | `~/Library/Application Support/whiplash/roles.json` | JSON（`[Role]`の配列） |
| アプリ設定（バックエンド選択、ショートカットキー、起動設定等） | UserDefaults | Key-Value |

---

## 4. Core Flow: Capture → AI → Response

### 4.1 フロー全体

```
ユーザー: グローバルショートカット押下（例: Cmd+Shift+X）
    │
    ▼
① screencapture -i コマンド起動
    │  ユーザーがドラッグで範囲選択
    │  → 一時ファイル（/tmp/whiplash-capture-<UUID>.png）に保存
    │  Escでキャンセル → 終了コードで検知、何もしない
    ▼
② Role選択ポップオーバーを撮影範囲の近くに表示
    │  スクリーンショットのサムネイル + Role一覧
    │  キーボード（↑↓ + Enter）またはクリックで選択
    │  Escでキャンセル → 一時ファイル削除、何もしない
    ▼
③ 処理開始（非同期）
    │
    ├─ Apple Vision OCR でテキスト+位置情報を抽出
    │
    ├─ responsePatterns に応じてLLMリクエストを構築:
    │   ├─ richMessage / clipboard: fullText + systemPrompt → LLM
    │   └─ overlay: textBlocks（位置情報付き）+ systemPrompt → LLM
    │
    ▼
④ 応答パターンごとに結果を出力（複数同時実行）
    ├─ richMessage: フローティングメッセージボックスを表示
    ├─ clipboard: NSPasteboard にテキストをコピー
    └─ overlay: 撮影位置にオーバーレイウィンドウを表示
    │
    ▼
⑤ 一時ファイル削除
```

### 4.2 screencapture コマンド詳細

```bash
screencapture -i /tmp/whiplash-capture-<UUID>.png
```

- `-i` : インタラクティブモード（ドラッグで範囲選択、スペースでウィンドウ選択）
- 終了コード 0: 成功（ファイルが作成される）
- 終了コード 非0: キャンセル（Escキー）
- ファイルパスに UUID を含めて一意性を保証

### 4.3 OCR処理詳細

```swift
// Apple Vision framework
let request = RecognizeTextRequest()
// request.recognitionLanguages は自動検出に任せる（日本語・英語等）

let handler = VNImageRequestHandler(url: screenshotURL)
let observations = try await handler.perform(request)

// observations から TextBlock の配列を構築
// 各 observation は boundingBox（正規化座標 0-1）を持つ
// スクリーンショットの実ピクセルサイズに変換して TextBlock を生成
```

### 4.4 LLMリクエスト構築

**richMessage / clipboard パターン:**

```
System: {role.systemPrompt}
User: {ocrResult.fullText}
```

テキスト全体をまとめてLLMに送信。LLMの応答テキストをそのまま表示/コピーする。

**overlay パターン:**

```
System: {role.systemPrompt}
        以下のテキストブロックをそれぞれ翻訳し、JSON配列で返してください。
        [{"index": 0, "translation": "..."}, ...]
User: [
        {"index": 0, "text": "Project Update - Q3 Review"},
        {"index": 1, "text": "Hi team, I wanted to share..."},
        ...
      ]
```

位置情報付きテキストブロックを個別に送信し、対応する翻訳をJSON形式で受け取る。AnyLanguageModel の `@Generable` マクロ（構造化出力）を活用して型安全にパースできる。

---

## 5. UI Components

### 5.1 MenuBarController（メニューバー常駐）

- アプリアイコンをmacOSメニューバーに常駐表示
- クリックでドロップダウンメニュー:
  - ショートカットキーの表示（例: "⌘⇧X でキャプチャ"）
  - 「設定を開く...」
  - 「Whiplash を終了」
- `NSStatusItem` を使用
- `NSApp.activationPolicy = .accessory` をデフォルトにし、設定ウィンドウ表示時のみ `.regular` に切り替え（Dock表示制御）

### 5.2 RolePopover（Role選択ポップオーバー）

- スクリーンショット撮影後、撮影範囲の下辺付近に表示
- 構成:
  - 上部: スクリーンショットの小さなサムネイル + サイズ情報
  - 中部: Role一覧（フラットなリスト、各Roleにアイコン + 名前 + 応答パターンアイコン表示）
  - 下部: キーボードヒント（↑↓ 移動 / ⏎ 選択 / esc キャンセル）
- 幅: 約240px
- キーボード操作に完全対応（↑↓でフォーカス移動、Enterで選択）
- クリックでも選択可能
- Escでキャンセル（一時ファイル削除）
- `NSPanel` (フローティング、非アクティブ化で自動クローズ) で実装

### 5.3 RichMessageBox（応答パターン: richMessage）

- フローティングウィンドウ（常に最前面 `NSWindow.Level.floating`）
- 構成:
  - ヘッダー: Role名 + アイコン
  - 本文: マークダウンレンダリング（`AttributedString` + SwiftUI `Text`）
  - フッター: アクションボタン（📋 コピー / 🔄 再生成 / ✕ 閉じる）
- ドラッグで移動可能
- ユーザーが明示的に閉じるまで表示し続ける（自動消去なし）
- LLM応答のストリーミングに対応（テキストが順次表示される）
- 最大幅は約420px、高さはコンテンツに合わせて可変

### 5.4 OverlayWindow（応答パターン: overlay）

- スクリーンショットの撮影位置と同じ座標・サイズの半透明ウィンドウ
- 背景: 半透明（元画面が薄く透けて見える）
- OCRで検出された各テキスト領域のバウンディングボックスの**左上座標を基準**に翻訳テキストを配置
- フォントサイズ: 元テキスト領域のサイズに近い値を使用するが、**はみ出しは許容する**（ピクセルパーフェクトは目指さない）
- 右上に「esc で閉じる」のヒント表示
- Escキーまたはクリックで閉じる
- `NSWindow.Level.floating` + `isOpaque = false` + `backgroundColor = .clear` で実装

### 5.5 SettingsWindow（設定画面）

通常の `NSWindow`。表示時に `NSApp.activationPolicy = .regular` に切り替えてDockにアイコンを表示。閉じたら `.accessory` に戻す。

**3タブ構成:**

#### 一般タブ
- グローバルショートカットキー設定（キーバインディングUI）
- ログイン時に起動（`SMAppService` で Launch at Login）

#### AIバックエンドタブ
- プロバイダー選択（ドロップダウン: Apple Foundation Models / Ollama / LM Studio）
- プロバイダー別設定:
  - Foundation Models: 設定なし（オンデバイス自動）
  - Ollama: エンドポイントURL（デフォルト `http://localhost:11434`）、モデル名（デフォルト空 = プロバイダーデフォルト）
  - LM Studio: エンドポイントURL（デフォルト `http://localhost:1234`）、モデル名

#### Roleタブ
- 左サイドバー: Role一覧（フラットリスト、区分なし）+ 「＋ 新規Role」ボタン
- 右ペイン: 選択中Roleの編集フォーム
  - Role名（テキストフィールド）
  - アイコン（絵文字ピッカーまたはテキスト入力）
  - システムプロンプト（複数行テキストエディタ）
  - 応答パターン（チェックボックス、複数選択可）
  - AIバックエンドオーバーライド（v1ではグレーアウト、「アプリのデフォルトを使用」と表示）
- Role削除: サイドバーのコンテキストメニューまたは右ペインの削除ボタン
- プリセットもカスタムも同じ扱い。すべて編集・削除可能

---

## 6. AI Backend: AnyLanguageModel

### 6.1 概要

[AnyLanguageModel](https://github.com/mattt/AnyLanguageModel) は、Apple Foundation Models と同じ `LanguageModelSession` APIで複数バックエンドを統一的に扱えるSwiftパッケージ。

対応バックエンド:
- Apple Foundation Models（macOS 26+、オンデバイス）
- Ollama（`http://localhost:11434`、OpenAI互換API）
- LM Studio（`http://localhost:1234`、OpenAI互換API）
- MLX / Core ML / llama.cpp（将来的に追加可能）
- OpenAI / Anthropic / Google Gemini（将来的に追加可能）

### 6.2 v1の実装範囲

- アプリ全体で1つのバックエンドを選択（設定画面で切り替え）
- 対応プロバイダー: Apple Foundation Models / Ollama / LM Studio
- Roleごとのバックエンドオーバーライドはv1では実装しない（データモデルには `backendOverride` フィールドを持つ）

### 6.3 利用方法

```swift
import AnyLanguageModel

// バックエンド選択に応じてモデルを生成
func createModel(config: BackendConfig) -> some LanguageModel {
    switch config.provider {
    case .foundationModels:
        return SystemLanguageModel.default
    case .ollama:
        return OllamaLanguageModel(
            endpoint: config.endpoint ?? URL(string: "http://localhost:11434")!,
            model: config.modelName ?? "llama3.2"
        )
    case .lmStudio:
        return LMStudioLanguageModel(
            endpoint: config.endpoint ?? URL(string: "http://localhost:1234")!,
            model: config.modelName
        )
    }
}

// セッション作成・応答取得
let model = createModel(config: currentBackendConfig)
let session = LanguageModelSession(model: model, instructions: role.systemPrompt)
let response = try await session.respond(to: ocrResult.fullText)
```

### 6.4 Swift Package依存

```swift
// Package.swift (or Xcode SPM)
dependencies: [
    .package(
        url: "https://github.com/mattt/AnyLanguageModel.git",
        from: "0.4.0"
    )
]
```

AnyLanguageModel は pre-1.0 のため、破壊的変更のリスクがある。LLM呼び出し箇所はアプリ内で実質1箇所（CaptureFlow内）なので、変更時の影響は限定的。

---

## 7. OCR: Apple Vision Framework

### 7.1 概要

macOS標準のVision frameworkを使用。追加依存なし。

- `RecognizeTextRequest`（新API、Swift Concurrency対応）を使用
- 日本語・英語を含む18言語に対応
- テキスト内容 + バウンディングボックス（位置情報）を取得可能
- 完全オンデバイス処理

### 7.2 OCRService インターフェース

```swift
class OCRService {
    /// スクリーンショット画像からテキストと位置情報を抽出
    func recognizeText(from imageURL: URL) async throws -> OCRResult

    /// OCRResult:
    /// - fullText: 全テキスト結合（richMessage/clipboard用）
    /// - textBlocks: 位置情報付きテキストブロック配列（overlay用）
}
```

### 7.3 座標系の変換

Vision frameworkのバウンディングボックスは正規化座標（0-1、左下原点）で返される。これをスクリーンショットのピクセル座標（左上原点）に変換する必要がある:

```
screenX = boundingBox.origin.x * imageWidth
screenY = (1 - boundingBox.origin.y - boundingBox.height) * imageHeight
screenWidth = boundingBox.width * imageWidth
screenHeight = boundingBox.height * imageHeight
```

---

## 8. App Lifecycle

### 8.1 常駐形態

- メニューバー常駐（`NSStatusItem`）
- `NSApp.activationPolicy`:
  - 通常時: `.accessory`（Dockに表示なし）
  - 設定ウィンドウ表示時: `.regular`（Dockに表示）
  - 設定ウィンドウ閉じたとき: `.accessory` に戻る

### 8.2 初回起動

1. アクセシビリティ権限の確認（スクリーンキャプチャに必要）
2. `roles.json` が存在しなければプリセットRoleを初期データとして作成
3. メニューバーにアイコンを表示
4. グローバルショートカットを登録

### 8.3 プリセットRole（初期データ）

以下のRoleを初回起動時に作成:

| 名前 | アイコン | システムプロンプト概要 | 応答パターン |
|---|---|---|---|
| 英訳 | 🌐 | 日本語テキストを自然な英語に翻訳 | `[.clipboard]` |
| 和訳 | 🇯🇵 | 英語テキストを自然な日本語に翻訳 | `[.overlay, .clipboard]` |
| メール返信 | ✉️ | メール内容を読み取り、適切な返信文を生成 | `[.clipboard]` |
| 要約 | 📝 | テキスト内容を簡潔に要約 | `[.richMessage]` |

### 8.4 権限

- **Screen Recording** (`NSScreenCaptureUsageDescription`): screencaptureコマンドの実行に必要
- キーボードショートカット: `CGEvent` タップまたは `NSEvent.addGlobalMonitorForEvents` でグローバルショートカットを登録

---

## 9. Future Considerations (v1では実装しない)

以下はデータモデル・設計上は考慮するが、v1では実装しない項目:

1. **Roleごとのバックエンドオーバーライド** — `backendOverride` フィールドは存在するが、UIはグレーアウト
2. **Roleごとの個別ショートカット** — 頻用Roleを一発で起動。Role選択ステップをスキップ
3. **追加のAIバックエンド** — OpenAI / Anthropic / Google Gemini等のクラウドプロバイダー
4. **追加の応答パターン** — 現時点では3種（richMessage / clipboard / overlay）。将来的に追加の可能性あり
5. **マルチモーダルパス** — スクリーンショット画像を直接Vision対応LLMに送信（OCRを経由しない）。Apple Foundation Modelsの画像入力API公開待ち

---

## 10. Technical Decisions & Rationale

| 決定 | 理由 |
|---|---|
| screencapture コマンドでキャプチャ | macOS標準の範囲選択UIをそのまま利用。ユーザーの馴染みのある操作感。学習コストゼロ |
| Apple Vision OCR → テキストをLLMに送信 | ローカルVLMは重くUXに影響する。OCRパスならテキストモデルで済み高速 |
| AnyLanguageModel 採用 | 複数バックエンドの抽象化が既に実装済み。pre-1.0リスクはあるが、LLM呼び出し箇所が限定的なので影響小 |
| JSON + UserDefaults で永続化 | Role数は数十件程度。SwiftDataはオーバースペック。JSONは人間可読でデバッグしやすい |
| 応答パターンを配列で持つ | 1Roleに対して複数の出力を同時実行可能（例: オーバーレイ＋クリップボード） |
| プリセットとカスタムRoleの区別なし | プリセットは初期データとして投入されるだけ。ユーザーが自由に編集・削除可能 |
| オーバーレイのはみ出し許容 | ピクセルパーフェクトな配置は実装コストが高く、価値に見合わない。位置の目安として十分 |
| macOS 26+ 限定 | Foundation Models API を使用するため。個人利用なので後方互換性は不要 |

---

## 11. File Structure (想定)

```
whiplash/
├── whiplashApp.swift              # @main、AppDelegateアダプタ
├── AppDelegate.swift              # NSStatusItem、グローバルショートカット登録、activationPolicy制御
│
├── Models/
│   ├── Role.swift                 # Role, ResponsePattern
│   ├── BackendConfig.swift        # BackendConfig, BackendProvider
│   └── OCRResult.swift            # OCRResult, TextBlock
│
├── Services/
│   ├── OCRService.swift           # Apple Vision OCR ラッパー
│   ├── LLMService.swift           # AnyLanguageModel を使ったLLM呼び出し
│   └── CaptureService.swift       # screencapture コマンド実行
│
├── Flow/
│   └── CaptureFlow.swift          # 撮影→Role選択→OCR→LLM→応答のパイプライン
│
├── Stores/
│   ├── RoleStore.swift            # JSON読み書き、プリセット初期化
│   └── SettingsStore.swift        # UserDefaults ラッパー
│
├── Views/
│   ├── MenuBar/
│   │   └── MenuBarView.swift      # メニューバードロップダウン
│   ├── Capture/
│   │   └── RolePopover.swift      # Role選択ポップオーバー
│   ├── Response/
│   │   ├── RichMessageBox.swift   # フローティングメッセージボックス
│   │   └── OverlayWindow.swift    # 翻訳オーバーレイ
│   └── Settings/
│       ├── SettingsWindow.swift   # 設定ウィンドウ（タブコンテナ）
│       ├── GeneralTab.swift       # 一般タブ
│       ├── BackendTab.swift       # AIバックエンドタブ
│       └── RoleTab.swift          # Roleタブ（一覧+編集）
│
├── Assets.xcassets/               # アプリアイコン、メニューバーアイコン
└── Info.plist                     # 権限記述
```
