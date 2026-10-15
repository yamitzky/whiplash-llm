# Whiplash

macOS メニューバー常駐アプリ (`whiplash`) と iOS アプリ (`whiplash-ios`)。共通ロジックは SwiftPM パッケージ `WhiplashCore`。OSS として公開している。

## ビルド

```bash
xcodebuild -project whiplash.xcodeproj -scheme whiplash -configuration Release -derivedDataPath build build CODE_SIGNING_ALLOWED=NO -skipMacroValidation
xcodebuild -project whiplash.xcodeproj -scheme whiplash-ios -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath build build CODE_SIGNING_ALLOWED=NO -skipMacroValidation
```

- `-skipMacroValidation` が無いと AnyLanguageModel のマクロ承認で失敗する。
- 成果物は `build/Build/Products/Release/whiplash.app`。

## コミットしてはいけないもの

- **署名チーム (`DEVELOPMENT_TEAM`) を pbxproj に書かない。** 各自の Team ID は gitignore 済みの `Configs/Local.xcconfig` に置く(`Configs/Base.xcconfig` が `#include?` する)。Xcode の Signing & Capabilities で Team を選ぶと pbxproj に書き込まれるので、その差分はコミット前に戻す。
- 依存パッケージのソースをリポジトリ内に clone / vendoring しない。パッチが必要なら upstream に出すか fork を URL で参照する。

## LLM 層 (AnyLanguageModel)

- 全プロバイダーの HTTP は `LLMService.httpSession`(アイドル 300 秒)を通す。既定の 60 秒だと thinking や非ストリーミングの長い生成がタイムアウトする。
- thinking は `snapshot.transcriptEntries` の `.reasoning` で届く。`LLMService.displayText` が `<thinking>…</thinking>\n\n本文` に組み立て、macOS の `StreamingText` / iOS の `StreamingResult` がそのタグで分割して表示する。この形式を変えるときは両方を直す。
- thinking 本文が取れるのは現状 Anthropic のストリーミングのみ。
- Apple 公式スタックへの移行を見送った経緯: `docs/superpowers/specs/2026-07-04-llm-layer-migration-design.md`
