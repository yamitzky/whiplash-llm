# Whiplash

画面に映っているものについて、アプリを切り替えずにLLMに聞けるmacOSメニューバーアプリ。

グローバルショートカットを押して、画面の一部をキャプチャ（またはクリップボードの内容を使って）、「英訳」「要約」などのRoleを選ぶと、フローティングウィンドウに応答が表示される。それだけ。

## できること

- **画面キャプチャ → OCR → LLM**: 画面の任意の範囲をキャプチャすると、Apple VisionでOCRしてからLLMに送る。Roleごとにシステムプロンプトを設定できる。
- **クリップボード入力**: キャプチャの代わりにクリップボードのテキストや画像を使う。
- **Role**: 翻訳、要約、メール返信など、用途ごとにプロンプトと応答方法を設定したプリセット。自分で追加・編集もできる。
- **@メンション**: 入力欄で `@英訳` と打つとRoleをインラインで指定できる。チップとして入力欄の上に表示される。
- **添付**: キャプチャや貼り付けた内容は「添付」として扱われる。後から追加も削除もできるし、何も付けずに起動もできる。
- **URL取得**: 入力欄にURLを入れると、ページの内容を自動取得してコンテキストに含める。
- **フォローアップ**: 応答ウィンドウからそのまま追加の質問ができる。

## 対応バックエンド

| プロバイダー | 種別 | 備考 |
|---|---|---|
| Apple Foundation Models | オンデバイス | macOS 26+、設定不要 |
| Ollama | ローカル | `localhost:11434` |
| LM Studio | ローカル | `localhost:1234` |
| OpenAI | クラウド | APIキーが必要 |
| Anthropic | クラウド | APIキーが必要 |
| Google Gemini | クラウド | APIキーが必要 |
| OpenRouter | クラウド | APIキーが必要 |

モデルは複数登録でき、Roleごとに使い分けられる。

## 動作環境

- macOS 26+ (Tahoe)
- Apple Silicon

## ビルド

Xcode で `whiplash.xcodeproj` を開いてビルド。SPMの依存は自動で解決される。

依存パッケージ:
- [AnyLanguageModel](https://github.com/huggingface/AnyLanguageModel) — マルチバックエンドLLM抽象化
- [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) — グローバルショートカット
- [MarkdownView](https://github.com/LiYanan2004/MarkdownView) — 応答のマークダウンレンダリング

## デフォルトショートカット

| 操作 | ショートカット |
|---|---|
| キャプチャ | `Cmd+Shift+X` |
| クリップボードキャプチャ | `Cmd+Shift+V` |
| 新規入力 | 設定で割り当て |

ショートカットは設定画面から変更できる。

## ライセンス

MIT
