# android (Android アプリ)

Pixel 向けの Android アプリ。画面は Jetpack Compose で書き、画面以外のロジックは `shared/` (Kotlin Multiplatform の共有コア) を使う。
ロール、モデル、接続設定は Mac と iOS と同じ形式で保存する。

## できること

- 入力: 直接入力、貼り付け、写真選択 (Photo Picker、権限不要)
- 入口: ランチャー、ほかのアプリの文字選択メニュー (`ACTION_PROCESS_TEXT`)、共有シート (テキストと画像)、クイック設定のタイル
- ロール: プリセット (英訳、和訳、メール返信、要約、文字起こし)、追加、編集、削除、並べ替え。ロールごとにモデル、自動コピー、画像の入力方式 (画像のまま / OCR) を選ぶ
- 「質問する」: ロールを使わず、既定のモデルに本文と質問を送る
- 結果: 少しずつ表示、Markdown、thinking の表示、コピー、再生成、追加の指示 (フォローアップ)
- プロバイダー: Gemini Nano (端末内)、OpenAI、Anthropic、Google Gemini、OpenRouter、Ollama、LM Studio

## 構成

- `android/` は独立した Gradle のルートで、`shared/` を composite build (`includeBuild("../shared")`) でつなぐ。
  - `shared/` は Xcode 向けの framework も作る単独の Gradle ルートなので、`android/` の settings には取り込まない。
  - `shared/` のルートプロジェクトには group が無いので、`com.yamitzky.whiplash:shared` という座標を決めて差し替えている。
- 保存先: ロールと設定は SharedPreferences (`whiplash.defaults`)。API キーは Android Keystore の AES-GCM 鍵で暗号化して `whiplash.secrets` に置く。
- プロバイダーの対応 (`AppContainer`):
  - `OpenAI`、`Ollama`、`LmStudio`、`OpenResponses` (OpenRouter): `shared` の `OpenAiChatCompletionsProvider`
  - `Anthropic`: `shared` の `AnthropicMessagesProvider`
  - `Gemini`: `shared` の `GeminiProvider`
  - `FoundationModels`: アプリの `GeminiNanoProvider` (ML Kit GenAI Prompt API)。保存形式に値を足さないよう、Apple Foundation Models の枠を Android では Gemini Nano に使う。プリセットの先頭のモデルがそのまま Gemini Nano になり、API キー無しで使える。
- OCR は ML Kit の日本語の文字認識 (モデルを APK に同梱)。

## ビルドと実機への入れ方

JDK 21 と Android SDK (platform 37) が要る。

```bash
cd android
export JAVA_HOME=/opt/homebrew/opt/openjdk@21
export ANDROID_HOME=/opt/homebrew/share/android-commandlinetools
./gradlew :app:testDebugUnitTest :app:assembleRelease
adb install -r app/build/outputs/apk/release/app-release.apk
```

デバッグ版は `:app:assembleDebug` で `app/build/outputs/apk/debug/app-debug.apk` に出る。デバッグ版とリリース版は署名が違うので、入れ替えるときは先に `adb uninstall com.yamitzky.whiplash.android` が要る (保存した設定も消える)。

## リリース署名

`android/keystore.properties` (gitignore 済み) から鍵を読む。無ければリリース版は署名されないまま作られる。

```properties
storeFile=/Users/<you>/.android/whiplash-release.jks
storePassword=...
keyAlias=whiplash
keyPassword=...
```

鍵を新しく作るときは次のコマンドを使う。一度配ったアプリは同じ鍵でしか更新できないので、鍵とパスワードは失くさないようにする。

```bash
keytool -genkeypair -keystore ~/.android/whiplash-release.jks -storetype PKCS12 \
  -alias whiplash -keyalg RSA -keysize 4096 -validity 36500 -dname "CN=Whiplash"
```

リリース版は R8 で縮める。ML Kit のクラスは R8 で最適化すると NullPointerException になったので、`app/proguard-rules.pro` で外している。

## 接続先

- Gemini Nano は設定の「接続設定」>「Gemini Nano (端末内)」からモデルをダウンロードして使う。推論はアプリが前面にあるときだけ許される (AICore の制限)。ブートローダーのロックを外した端末では使えない。
- スマートフォンの localhost はスマートフォン自身。Mac で動かしている LM Studio や Ollama には、Mac の LAN の IP アドレスを書くか、USB / ワイヤレスデバッグ中なら `adb reverse` で実機の localhost を Mac に向ける。

```bash
adb reverse tcp:1234 tcp:1234
```
