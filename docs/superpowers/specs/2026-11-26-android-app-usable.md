# Android アプリを使える状態にする

2026-11-26 に決めた範囲。PR #3 (thread/android-app-mvp) に積む。

## 範囲

1. ロール: `RoleStore` を使う。初回は Mac/iOS と同じプリセット。入力画面でロールを選んで送る。ロールの追加、編集、削除、並べ替え。
2. プロバイダーとモデル: 6 つのプロバイダーと端末内モデル。モデルの一覧、追加、編集、削除、既定のモデル。ロールごとのモデル。thinking の設定。
3. 入口: ランチャー、文字選択メニュー (`ACTION_PROCESS_TEXT`)、共有シート (`ACTION_SEND` / `ACTION_SEND_MULTIPLE` のテキストと画像)、クイック設定のタイル。
4. 結果: Markdown 表示、thinking の表示、コピー、再生成、フォローアップ、新規。ロールの「自動でコピー」。
5. 画像の入力: 共有シートと写真選択 (Photo Picker、権限不要)。ロールの画像入力方式が OCR なら ML Kit の文字認識でテキストにする。
6. Gemini Nano: 端末内のモデル。
7. リリース署名: gitignore 済みの `android/keystore.properties` から鍵を読む設定。鍵はユーザーの了承を得て `~/.android/whiplash-release.jks` に作った (2026-11-27)。

ウィジェットは作らない (ユーザーが不要と判断。代わりにタイル)。

## 決めたこと

- 保存形式は変えない。`BackendProvider` に値を足さない。
  - Android では `FoundationModels` の枠を Gemini Nano に使う。画面の表示名は「Gemini Nano (端末内)」。プリセットの先頭のモデル `Foundation Models` がそのまま Gemini Nano になり、キー無しで最初から使える。
- プロバイダーと実装の対応:
  - `OpenAI`、`Ollama`、`LmStudio`、`OpenResponses` (OpenRouter): 共有コアの `OpenAiChatCompletionsProvider`
  - `Anthropic`: 共有コアに足す `AnthropicMessagesProvider`
  - `Gemini`: 共有コアに足す `GeminiProvider`
  - `FoundationModels`: アプリ側の Gemini Nano の実装
- 共有コアの既存の API の形 (コールバックと suspend 関数) は変えない。足すだけ。
- タイルは `TileService`。押すと入力画面を開く。タイルの追加は端末の設定なので、アプリの設定画面から `StatusBarManager.requestAddTileService` でユーザーに追加を頼む。
- 実機の確認はスクリーンショット。OpenAI 互換、Anthropic、Gemini はそれぞれの形を返すスタブのサーバで確かめる。有料 API と実際の API キーは使わない。Gemini Nano は実機で動かす。

## 実装中に分かったこと

- ML Kit (GenAI と文字認識) は R8 で最適化すると NullPointerException になる。`com.google.mlkit.**` を keep している。
- Play 開発者サービス経由の OCR のモデルは、インストール直後に届いておらず最初の OCR が失敗した。モデルを APK に同梱する版にした。
- 画像だけを送ると本文が空になる。Anthropic は空の text ブロックを受け付けないので、Anthropic、Gemini、Gemini Nano では空の本文を送らない。
- `shared/` の compileSdk は 37 にした。依存の okhttp 5.5 が 37 を要り、リリースビルドの AAR メタデータの検査で止まったため。
