# shared (Kotlin Multiplatform の共有コア)

Android 版のために、WhiplashCore (Swift) の画面以外のロジックを Kotlin Multiplatform で書き直したもの。
macOS と iOS のアプリにはまだつないでいない。画面は共有しない (Mac と iOS は SwiftUI、Android は Jetpack Compose)。

ターゲット: `android` (AGP の `com.android.kotlin.multiplatform.library`)、`macosArm64`、`iosArm64`、`iosSimulatorArm64`。

## 構成

| パッケージ | 中身 | 依存 |
| --- | --- | --- |
| `model` | `Role`、`ModelConfig`、`BackendProvider`、`ThinkingConfig` などの型 | なし |
| `store` | `RoleStore`、`SettingsStore`、保存形式の読み書き (`StoredJson`)、保存先のインターフェース (`KeyValueStore`、`SecretStore`) | kotlinx-serialization-json (JsonElement だけ) |
| `llm` | `LlmProvider` インターフェース、`LlmService`、プロンプトの組み立て (`Prompt`)、SSE の行の読み分け (`SseDecoder`) | kotlinx-coroutines |
| `llm.openai` | OpenAI 互換 Chat Completions のストリーミング (`OpenAiChatCompletionsProvider`) | Ktor |
| `llm.anthropic` | Anthropic Messages API のストリーミング (`AnthropicMessagesProvider`) | Ktor |
| `llm.gemini` | Gemini API の streamGenerateContent (`GeminiProvider`) | Ktor |

`model`、`store`、`llm` は Ktor を import しない。プロバイダーの実装は `LlmProvider` を実装すればよく、OS ごとに置ける。
Swift から呼ぶ API は、コールバックと suspend 関数だけで使える形にしている (SKIE を前提にしない)。

## ビルドとテスト

JDK 21 と Android SDK が要る。SDK の場所は `local.properties` の `sdk.dir` か `ANDROID_HOME` で渡す。

```bash
cd shared
./gradlew testAndroidHostTest                 # Android (JVM) のユニットテスト
./gradlew macosArm64Test                      # Kotlin/Native (macOS) のテスト
./gradlew linkDebugFrameworkIosArm64 linkDebugFrameworkIosSimulatorArm64  # iOS 向け framework
```

## Swift が書いた fixture

`src/commonTest/fixtures/swift/` は、今の WhiplashCore の `RoleStore` と `SettingsStore` が UserDefaults に書いた値そのもの。
`WhiplashCore/Tests/WhiplashCoreTests/SharedCoreFixtureExport.swift` が書き出す。
各シナリオは操作前 (`before`) と操作後 (`after`) を持ち、`SwiftFixtureReplayTest` が before から同じ操作をして after と同じ内容になるか確かめる。

Swift 側の保存形式を変えたら、書き出し直して Kotlin のテストを流す。

```bash
shared/scripts/export-swift-fixtures.sh
```

ビルド時に `embedSwiftFixtures` タスクが fixture を Kotlin のソースに埋め込む。commonTest には JVM と Native の両方で使えるファイル読み込みが無いため。

## Swift と違うところ

- 保存された `defaultModelId` が `null` のとき、Swift は `UUID?` として読めずに `defaultModelId.unreadable.<時刻>` へ退避する。Kotlin は退避せず、先頭のモデルを既定にする。既定になるモデルはどちらも同じ。
- `connections` が無いときの、古いキー (`apiKeys`、`providerConfig`、`backendConfig`) からの移行はしない。古い macOS のビルドだけが書いたキーで、Android には無い。
