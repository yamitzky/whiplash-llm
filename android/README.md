# android (Android アプリ)

Pixel 向けの Android アプリ。画面は Jetpack Compose で書き、画面以外のロジックは `shared/` (Kotlin Multiplatform の共有コア) を使う。

今の版は 1 画面だけ。テキストを入れて送ると、OpenAI 互換の Chat Completions API の返答が届いた分から表示される。

## 構成

- `android/` は独立した Gradle のルートで、`shared/` を composite build (`includeBuild("../shared")`) でつなぐ。
  - `shared/` は Xcode 向けの framework も作る単独の Gradle ルートなので、`android/` の settings には取り込まない。
  - `shared/` のルートプロジェクトには group が無いので、`com.yamitzky.whiplash:shared` という座標を決めて差し替えている。
- 設定は `shared` の `SettingsStore` に保存する。保存先の `KeyValueStore` は SharedPreferences (`whiplash.defaults`) で実装した。
- API キーは `SecretStore` に入れる。実装は Android Keystore の AES-GCM 鍵で暗号化し、SharedPreferences (`whiplash.secrets`) に置く。
- 接続先は `BackendProvider.OpenAI` の endpoint と API キー、名前が `Android (OpenAI 互換)` のモデル 1 つだけを使う。

## ビルドと実機への入れ方

JDK 21 と Android SDK (platform 37) が要る。

```bash
cd android
export JAVA_HOME=/opt/homebrew/opt/openjdk@21
export ANDROID_HOME=/opt/homebrew/share/android-commandlinetools
./gradlew :app:testDebugUnitTest :app:assembleDebug
adb install -r app/build/outputs/apk/debug/app-debug.apk
adb shell am start -n com.yamitzky.whiplash.android/.MainActivity
```

初回の起動で接続先のダイアログが開く。URL には `http://localhost:1234/v1` のように `/v1` までを書く。末尾が `/v1` でなければ `/v1/chat/completions` を足して送る。

Mac で動かしている OpenAI 互換サーバー (LM Studio など) に実機から送るときは、adb で実機の localhost を Mac に向ける。

```bash
adb reverse tcp:1234 tcp:1234
```
