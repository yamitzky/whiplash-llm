# Whiplash

A macOS menu bar app that lets you query LLMs about whatever's on your screen — without switching apps.

Hit a global shortcut, capture a region (or use clipboard contents), pick a role like "Translate to English" or "Summarize", and get a response in a floating window. That's it.

## What it does

- **Screen capture → OCR → LLM**: Capture any region, the text gets extracted via Apple Vision, and sent to the LLM with your chosen role's system prompt.
- **Clipboard input**: Same flow, but grabs text/images from your clipboard instead of capturing the screen.
- **Roles**: Preconfigured personas (translator, summarizer, etc.) with customizable system prompts and response behavior. You can add your own.
- **@mentions**: Type `@translate` in the input field to pick a role inline, shown as a chip above the input.
- **Attachments**: Captures and clipboard content are treated as removable attachments — add more, remove any, or start with none.
- **URL fetching**: Drop a URL in the input and it auto-fetches the page content as context.
- **Follow-up**: Ask follow-up questions in the response window without starting over.

## Supported backends

| Provider | Type | Notes |
|---|---|---|
| Apple Foundation Models | On-device | macOS 26+, no setup needed |
| Ollama | Local | `localhost:11434` |
| LM Studio | Local | `localhost:1234` |
| OpenAI | Cloud | API key required |
| Anthropic | Cloud | API key required |
| Google Gemini | Cloud | API key required |
| OpenRouter | Cloud | API key required |

You can register multiple models and assign different ones to different roles.

## Requirements

- macOS 26+ (Tahoe)
- Apple Silicon

## Building

Open `whiplash.xcodeproj` in Xcode and build. SPM dependencies resolve automatically.

Dependencies:
- [AnyLanguageModel](https://github.com/huggingface/AnyLanguageModel) — multi-backend LLM abstraction
- [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) — global hotkeys
- [MarkdownView](https://github.com/LiYanan2004/MarkdownView) — markdown rendering in responses

## Default shortcuts

| Action | Shortcut |
|---|---|
| Screen capture | `Cmd+Shift+X` |
| Clipboard capture | `Cmd+Shift+V` |
| New input (empty) | Configurable in settings |

All shortcuts are customizable from the settings window.

## License

MIT
