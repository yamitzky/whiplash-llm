# LLM Layer Migration: AnyLanguageModel → Apple FoundationModels Stack

> **Status: 不採用 (2026-10-15)**
> AnyLanguageModel 0.16.0 で `Transcript.Entry.reasoning` が入り、Claude の thinking がストリーム中に取れるようになったため、移行の主動機が消えた。
> 一方 Apple 公式経路(外部モデル向け `LanguageModel`、ClaudeForFoundationModels)は iOS 27 / macOS 27 必須で、ClaudeForFoundationModels はベータ。
> そのため AnyLanguageModel 1.0.0 への更新を選び、この移行は行っていない。OS 27 を最低要件にできた時点で再評価する。

## Overview

AnyLanguageModel (huggingface) を Apple 公式の FoundationModels スタックに移行する。主な動機は thinking/reasoning content のストリーム表示対応。AnyLanguageModel は全プロバイダーで thinking delta を無視しており、修正の見込みがない。

## Dependencies

### Remove
- `huggingface/AnyLanguageModel` (0.8.0)

### Add
- `apple/foundation-models-utilities` — `ChatCompletionsLanguageModel` (OAI Chat Completions API 互換エンドポイント汎用アダプタ)
- `anthropics/ClaudeForFoundationModels` — `ClaudeLanguageModel` (Claude 専用。thinking content の完全なストリーム対応)
- `FoundationModels` — OS 組み込み。`SystemLanguageModel`, `LanguageModelSession` 等

### Platform Requirements
- macOS 26+ / iOS 26+ (現状も同等なので影響なし)
- WhiplashCore の platforms を `.macOS(.v26), .iOS(.v26)` に引き上げ
- `#available(macOS 26, iOS 26, *)` ガードは不要になる

## Architecture

### 3 Model Backends

| Backend | Package | Model Type | 用途 |
|---|---|---|---|
| Apple on-device | FoundationModels (OS組み込み) | `SystemLanguageModel` | Apple Intelligence モデル |
| Claude | ClaudeForFoundationModels | `ClaudeLanguageModel` | Anthropic Claude。thinking 完全対応 |
| OAI Compatible | foundation-models-utilities | `ChatCompletionsLanguageModel` | OpenAI, Gemini, Ollama, LM Studio, OpenRouter 等 |

全て Apple の `LanguageModel` プロトコルに準拠。`LanguageModelSession` で統一的に扱える。

### Why not OAI-compatible for Claude?

Anthropic の OAI 互換レイヤーは extended thinking の内容を返さない (公式ドキュメントに明記)。`reasoning_effort` も `response_format` も `Ignored`。テスト用途であり本番向けではない。

### Why not Firebase SDK for Gemini?

Gemini は Google の OAI 互換エンドポイント経由で `ChatCompletionsLanguageModel` で使える。Firebase SDK は追加の依存とセットアップ (App Check 等) が必要で、現時点では過剰。

## BackendProvider Redesign

### Before (7 variants)
```swift
enum BackendProvider: String, Codable, CaseIterable {
    case foundationModels, ollama, lmStudio, openAI, anthropic, gemini, openResponses
}
```

### After (3 variants)
```swift
enum BackendProvider: String, Codable, CaseIterable {
    case apple
    case claude
    case openAICompatible
}
```

### Presets (UI convenience)

ユーザーがモデル追加時にわかりやすいよう、プリセットを提供:

| Preset | Provider | Default Endpoint |
|---|---|---|
| Apple Foundation Models | `.apple` | (なし/ローカル) |
| Claude | `.claude` | `https://api.anthropic.com/` |
| OpenAI | `.openAICompatible` | `https://api.openai.com/v1/` |
| Google Gemini | `.openAICompatible` | `https://generativelanguage.googleapis.com/v1beta/openai/` |
| Ollama | `.openAICompatible` | `http://localhost:11434/v1/` |
| LM Studio | `.openAICompatible` | `http://localhost:1234/v1/` |
| OpenRouter | `.openAICompatible` | `https://openrouter.ai/api/v1/` |
| Custom | `.openAICompatible` | (ユーザー入力) |

プリセットは `BackendProvider` とデフォルトURL を自動設定するだけで、`ModelConfig` の構造自体は変えない。

## LLMService Rewrite

### Public Interface (変更なし)
```swift
public func generateStreamingResponse(
    fullText: String,
    role: Role,
    additionalInstructions: String?,
    imageData: [(Data, String)]?,
    onPartialResponse: @Sendable @escaping (String) async -> Void
) async throws -> LLMResponse
```

### LLMResponse Extension
```swift
public struct LLMResponse: Sendable {
    public let text: String
    public let reasoning: String?  // NEW: thinking/reasoning content
}
```

### createSession (内部)
```swift
private func createSession(instructions: String, modelConfig: ModelConfig?) -> LanguageModelSession {
    guard let modelConfig else {
        return LanguageModelSession(model: SystemLanguageModel.default, instructions: instructions)
    }
    let model: any LanguageModel = switch modelConfig.provider {
    case .apple:
        SystemLanguageModel.default
    case .claude:
        ClaudeLanguageModel(name: modelConfig.modelIdentifier, auth: .apiKey(apiKey))
    case .openAICompatible:
        ChatCompletionsLanguageModel(
            name: modelConfig.modelIdentifier,
            url: endpoint,
            additionalHeaders: apiKey.isEmpty ? [:] : ["Authorization": "Bearer \(apiKey)"]
        )
    }
    return LanguageModelSession(model: model, instructions: instructions)
}
```

`#available` ガード不要（platforms が macOS 26+ / iOS 26+）。`throws` も不要になる（プロバイダー非対応エラーがなくなる）。

### Thinking/Reasoning の取得

ストリーミング完了後、`session.transcript` から `.reasoning` エントリを取得:
```swift
let reasoningText = session.transcript
    .compactMap(\.reasoning)
    .flatMap(\.segments)
    .compactMap { if case .text(let t) = $0 { return t.content } else { return nil } }
    .joined()
```

### ThinkingConfig の適用

`ChatCompletionsLanguageModel` は capabilities に `.reasoning` を含んでおり、`reasoning_content` フィールドを自動的にパースする。Claude は `ClaudeForFoundationModels` が thinking パラメータを処理する。

具体的な thinking 有効化の方法は各パッケージの API を確認して実装時に決定する。

## Settings Migration

UserDefaults に保存済みの `ModelConfig` データの `provider` フィールドをマイグレーション:

```swift
// BackendProvider.init(from:) でのマッピング
"anthropic"       → .claude
"foundationModels" → .apple
"openAI"          → .openAICompatible
"gemini"          → .openAICompatible  // エンドポイントURLはそのまま引き継ぎ
"ollama"          → .openAICompatible
"lmStudio"        → .openAICompatible
"openResponses"   → .openAICompatible
```

Gemini のエンドポイントは旧APIキー直接方式から OAI 互換エンドポイントに変わるため、マイグレーション時にデフォルトURLを更新する。

API キー (Keychain) は `apiKey-{旧provider名}` で保存されている。openAICompatible に統合すると OpenAI と Gemini で別の API キーが必要なのに1つに潰れる問題がある。解決策: API キーをプリセット名 (openAI, gemini, ollama 等) で管理し続ける。`BackendProvider` は内部分類 (3種)、プリセット名は UI 表示とキー管理に使う別の概念として分離する。

## UI Changes

### Model Add Flow
1. プリセットから選択 (Claude / OpenAI / Gemini / Ollama / Custom...)
2. プリセットに応じて provider とデフォルト URL が自動設定
3. モデル ID / 表示名 / Thinking 設定を入力
4. API キーは接続設定で管理

### Settings
- 接続設定: provider ごとではなく、プリセット (Claude / OpenAI / Gemini 等) ごとに APIキーとエンドポイントを管理
- 内部的には `.claude` と `.openAICompatible` の2種 + `.apple` (設定不要)

## Affected Files

| File | Change |
|---|---|
| `WhiplashCore/Package.swift` | 依存差し替え、platforms 引き上げ |
| `BackendConfig.swift` | enum 再設計 + preset + マイグレーション |
| `LLMService.swift` | 全面書き換え |
| `SettingsStore.swift` | マイグレーション追加、APIキー管理見直し |
| `ResponsePattern+UI.swift` | `BackendProvider` 関連の extension 更新 |
| `iOSSettingsView.swift` | プリセット UI、モデル追加フロー |
| `BackendTab.swift` | 同上 (macOS) |
| `CaptureFlow.swift` | reasoning 表示対応 |
| `InputFlow.swift` | reasoning 表示対応 |
| `RichMessageView.swift` | thinking 折りたたみ表示 |
| `InputView.swift` | thinking 折りたたみ表示 |

## Out of Scope

- Firebase SDK による Gemini 統合 (将来必要になったら追加)
- Apple Private Cloud Compute モデル対応 (将来)
- MCP (Model Context Protocol) 対応
