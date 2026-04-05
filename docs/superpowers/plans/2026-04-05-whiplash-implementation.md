# Whiplash Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a macOS menu bar app that captures screenshots, runs OCR, sends text to an LLM via configurable backends, and displays results through multiple response patterns (message box, clipboard, overlay).

**Architecture:** Layered architecture — UI layer (menu bar, popover, floating windows, settings), control layer (CaptureFlow pipeline), service layer (OCRService, LLMService, CaptureService), and data layer (JSON + UserDefaults). AnyLanguageModel abstracts multiple LLM backends behind a unified Swift API.

**Tech Stack:** Swift, SwiftUI, AppKit (NSStatusItem, NSPanel, NSWindow), Apple Vision framework (RecognizeTextRequest), AnyLanguageModel package, macOS 26+

**Design Spec:** `docs/superpowers/specs/2026-04-05-whiplash-design.md`

---

## File Map

```
whiplash/
├── whiplashApp.swift              # @main, AppDelegate adaptor setup
├── AppDelegate.swift              # NSStatusItem, global shortcut, activation policy
│
├── Models/
│   ├── Role.swift                 # Role, ResponsePattern
│   ├── BackendConfig.swift        # BackendConfig, BackendProvider
│   └── OCRResult.swift            # OCRResult, TextBlock
│
├── Services/
│   ├── CaptureService.swift       # screencapture command wrapper
│   ├── OCRService.swift           # Apple Vision OCR
│   └── LLMService.swift           # AnyLanguageModel LLM calls
│
├── Stores/
│   ├── RoleStore.swift            # JSON persistence + presets
│   └── SettingsStore.swift        # UserDefaults wrapper
│
├── Flow/
│   └── CaptureFlow.swift          # Full pipeline: capture → role → OCR → LLM → output
│
├── Views/
│   ├── Capture/
│   │   └── RolePopoverView.swift  # Role selection popover after capture
│   ├── Response/
│   │   ├── RichMessageView.swift  # Floating message box
│   │   └── OverlayView.swift      # Translation overlay
│   └── Settings/
│       ├── SettingsView.swift     # Tab container
│       ├── GeneralTab.swift       # Shortcut + launch at login
│       ├── BackendTab.swift       # AI backend selection
│       └── RoleTab.swift          # Role CRUD
│
├── Assets.xcassets/               # App icon, menu bar icon
└── Info.plist                     # Privacy descriptions
```

**Note:** This Xcode project uses `PBXFileSystemSynchronizedRootGroup`. Any `.swift` files created inside `whiplash/` are automatically included in the build — no manual pbxproj editing required.

---

## Task 1: Data Models

**Files:**
- Create: `whiplash/Models/Role.swift`
- Create: `whiplash/Models/BackendConfig.swift`
- Create: `whiplash/Models/OCRResult.swift`

- [ ] **Step 1: Create Role.swift**

```swift
// whiplash/Models/Role.swift
import Foundation

enum ResponsePattern: String, Codable, CaseIterable {
    case richMessage
    case clipboard
    case overlay
}

struct Role: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var icon: String
    var systemPrompt: String
    var responsePatterns: [ResponsePattern]
    var backendOverride: BackendConfig?

    init(
        id: UUID = UUID(),
        name: String,
        icon: String,
        systemPrompt: String,
        responsePatterns: [ResponsePattern],
        backendOverride: BackendConfig? = nil
    ) {
        self.id = id
        self.name = name
        self.icon = icon
        self.systemPrompt = systemPrompt
        self.responsePatterns = responsePatterns
        self.backendOverride = backendOverride
    }
}
```

- [ ] **Step 2: Create BackendConfig.swift**

```swift
// whiplash/Models/BackendConfig.swift
import Foundation

enum BackendProvider: String, Codable, CaseIterable {
    case foundationModels
    case ollama
    case lmStudio
}

struct BackendConfig: Codable, Equatable {
    var provider: BackendProvider
    var modelName: String?
    var endpoint: URL?

    var effectiveEndpoint: URL {
        if let endpoint { return endpoint }
        switch provider {
        case .foundationModels: return URL(string: "local://foundation-models")!
        case .ollama: return URL(string: "http://localhost:11434")!
        case .lmStudio: return URL(string: "http://localhost:1234")!
        }
    }
}
```

- [ ] **Step 3: Create OCRResult.swift**

```swift
// whiplash/Models/OCRResult.swift
import Foundation

struct TextBlock: Equatable {
    let text: String
    let boundingBox: CGRect
    let confidence: Float
}

struct OCRResult: Equatable {
    let fullText: String
    let textBlocks: [TextBlock]
}
```

- [ ] **Step 4: Build to verify compilation**

Run: `xcodebuild -project whiplash.xcodeproj -scheme whiplash build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add whiplash/Models/
git commit -m "feat: add data models (Role, BackendConfig, OCRResult)"
```

---

## Task 2: RoleStore (JSON Persistence)

**Files:**
- Create: `whiplash/Stores/RoleStore.swift`

- [ ] **Step 1: Create RoleStore.swift**

```swift
// whiplash/Stores/RoleStore.swift
import Foundation
import Observation

@Observable
final class RoleStore {
    private(set) var roles: [Role] = []
    private let fileURL: URL

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let appDir = appSupport.appendingPathComponent("whiplash", isDirectory: true)
        self.fileURL = appDir.appendingPathComponent("roles.json")

        try? FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        load()
    }

    func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path()) else {
            roles = Self.presets
            save()
            return
        }
        do {
            let data = try Data(contentsOf: fileURL)
            roles = try JSONDecoder().decode([Role].self, from: data)
        } catch {
            roles = Self.presets
            save()
        }
    }

    func save() {
        do {
            let data = try JSONEncoder().encode(roles)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            print("Failed to save roles: \(error)")
        }
    }

    func add(_ role: Role) {
        roles.append(role)
        save()
    }

    func update(_ role: Role) {
        guard let index = roles.firstIndex(where: { $0.id == role.id }) else { return }
        roles[index] = role
        save()
    }

    func delete(_ role: Role) {
        roles.removeAll { $0.id == role.id }
        save()
    }

    static let presets: [Role] = [
        Role(
            name: "英訳",
            icon: "🌐",
            systemPrompt: "あなたは優秀な翻訳者です。与えられた日本語テキストを自然な英語に翻訳してください。翻訳結果のみを返してください。",
            responsePatterns: [.clipboard]
        ),
        Role(
            name: "和訳",
            icon: "🇯🇵",
            systemPrompt: "あなたは優秀な翻訳者です。与えられた英語テキストを自然な日本語に翻訳してください。翻訳結果のみを返してください。",
            responsePatterns: [.overlay, .clipboard]
        ),
        Role(
            name: "メール返信",
            icon: "✉️",
            systemPrompt: "あなたはビジネスメールの専門家です。与えられたメール内容を読み取り、適切な返信文を日本語で生成してください。丁寧で簡潔��文面にしてください。",
            responsePatterns: [.clipboard]
        ),
        Role(
            name: "要約",
            icon: "📝",
            systemPrompt: "与えられたテキストの内容を簡潔に要約してください。要点を箇条書きで示してください。",
            responsePatterns: [.richMessage]
        ),
    ]
}
```

- [ ] **Step 2: Build to verify compilation**

Run: `xcodebuild -project whiplash.xcodeproj -scheme whiplash build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add whiplash/Stores/RoleStore.swift
git commit -m "feat: add RoleStore with JSON persistence and presets"
```

---

## Task 3: SettingsStore (UserDefaults)

**Files:**
- Create: `whiplash/Stores/SettingsStore.swift`

- [ ] **Step 1: Create SettingsStore.swift**

```swift
// whiplash/Stores/SettingsStore.swift
import Foundation
import Carbon.HIToolbox
import Observation

@Observable
final class SettingsStore {
    var backendConfig: BackendConfig {
        didSet { saveBackendConfig() }
    }
    var shortcutKeyCode: UInt32 {
        didSet { UserDefaults.standard.set(Int(shortcutKeyCode), forKey: "shortcutKeyCode") }
    }
    var shortcutModifiers: UInt32 {
        didSet { UserDefaults.standard.set(Int(shortcutModifiers), forKey: "shortcutModifiers") }
    }

    init() {
        // Load backend config
        if let data = UserDefaults.standard.data(forKey: "backendConfig"),
           let config = try? JSONDecoder().decode(BackendConfig.self, from: data) {
            self.backendConfig = config
        } else {
            self.backendConfig = BackendConfig(provider: .foundationModels)
        }

        // Load shortcut: default Cmd+Shift+X
        let savedKeyCode = UserDefaults.standard.integer(forKey: "shortcutKeyCode")
        let savedModifiers = UserDefaults.standard.integer(forKey: "shortcutModifiers")
        if savedKeyCode != 0 {
            self.shortcutKeyCode = UInt32(savedKeyCode)
            self.shortcutModifiers = UInt32(savedModifiers)
        } else {
            self.shortcutKeyCode = UInt32(kVK_ANSI_X)
            self.shortcutModifiers = UInt32(cmdKey | shiftKey)
        }
    }

    private func saveBackendConfig() {
        if let data = try? JSONEncoder().encode(backendConfig) {
            UserDefaults.standard.set(data, forKey: "backendConfig")
        }
    }
}
```

- [ ] **Step 2: Build to verify compilation**

Run: `xcodebuild -project whiplash.xcodeproj -scheme whiplash build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add whiplash/Stores/SettingsStore.swift
git commit -m "feat: add SettingsStore with backend config and shortcut persistence"
```

---

## Task 4: CaptureService (screencapture wrapper)

**Files:**
- Create: `whiplash/Services/CaptureService.swift`

- [ ] **Step 1: Create CaptureService.swift**

```swift
// whiplash/Services/CaptureService.swift
import Foundation
import AppKit

struct CaptureResult {
    let imageURL: URL
    let image: NSImage
    let captureRect: CGRect  // Screen coordinates where the capture was taken
}

enum CaptureError: Error {
    case cancelled
    case failed(String)
    case noImage
}

final class CaptureService {
    func capture() async throws -> CaptureResult {
        let id = UUID().uuidString
        let path = "/tmp/whiplash-capture-\(id).png"
        let url = URL(fileURLWithPath: path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-i", path]

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw CaptureError.cancelled
        }

        guard FileManager.default.fileExists(atPath: path),
              let image = NSImage(contentsOf: url) else {
            throw CaptureError.noImage
        }

        // Get mouse location as approximate capture position
        // The actual capture rect is estimated from cursor position and image size
        let mouseLocation = NSEvent.mouseLocation
        let imageSize = image.size
        let captureRect = CGRect(
            x: mouseLocation.x - imageSize.width,
            y: mouseLocation.y,
            width: imageSize.width,
            height: imageSize.height
        )

        return CaptureResult(imageURL: url, image: image, captureRect: captureRect)
    }

    func cleanup(url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
```

- [ ] **Step 2: Build to verify compilation**

Run: `xcodebuild -project whiplash.xcodeproj -scheme whiplash build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add whiplash/Services/CaptureService.swift
git commit -m "feat: add CaptureService wrapping screencapture command"
```

---

## Task 5: OCRService (Apple Vision)

**Files:**
- Create: `whiplash/Services/OCRService.swift`

- [ ] **Step 1: Create OCRService.swift**

```swift
// whiplash/Services/OCRService.swift
import Vision
import AppKit

final class OCRService {
    func recognizeText(from imageURL: URL) async throws -> OCRResult {
        guard let nsImage = NSImage(contentsOf: imageURL),
              let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return OCRResult(fullText: "", textBlocks: [])
        }

        let imageWidth = CGFloat(cgImage.width)
        let imageHeight = CGFloat(cgImage.height)

        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate

        let handler = ImageRequestHandler(cgImage)
        let observations = try await handler.perform(request)

        var textBlocks: [TextBlock] = []

        for observation in observations {
            let text = observation.topCandidates(1).first?.string ?? ""
            let confidence = observation.topCandidates(1).first?.confidence ?? 0

            // Convert normalized coordinates (bottom-left origin) to pixel coordinates (top-left origin)
            let bbox = observation.boundingBox
            let screenRect = CGRect(
                x: bbox.origin.x * imageWidth,
                y: (1 - bbox.origin.y - bbox.height) * imageHeight,
                width: bbox.width * imageWidth,
                height: bbox.height * imageHeight
            )

            textBlocks.append(TextBlock(
                text: text,
                boundingBox: screenRect,
                confidence: confidence
            ))
        }

        let fullText = textBlocks.map(\.text).joined(separator: "\n")

        return OCRResult(fullText: fullText, textBlocks: textBlocks)
    }
}
```

**Note:** This uses the new `RecognizeTextRequest` API (macOS 26+). The older `VNRecognizeTextRequest` is deprecated. The exact API surface may need adjustment once compiled against the macOS 26 SDK — the implementer should verify the Vision framework import and request types compile correctly and adjust if needed.

- [ ] **Step 2: Build to verify compilation**

Run: `xcodebuild -project whiplash.xcodeproj -scheme whiplash build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **` (or warnings about Vision API — fix as needed)

- [ ] **Step 3: Commit**

```bash
git add whiplash/Services/OCRService.swift
git commit -m "feat: add OCRService using Apple Vision RecognizeTextRequest"
```

---

## Task 6: Add AnyLanguageModel Dependency

**Files:**
- Modify: Xcode project (add SPM dependency)

- [ ] **Step 1: Add AnyLanguageModel via Xcode SPM**

This must be done through Xcode:
1. Open `whiplash.xcodeproj` in Xcode
2. File → Add Package Dependencies...
3. Enter URL: `https://github.com/mattt/AnyLanguageModel.git`
4. Set version: "Up to Next Major" from `0.4.0`
5. Add to target: `whiplash`

Alternatively, use `xcodebuild` to verify after manual edit:

```bash
# After adding in Xcode, verify it resolves
xcodebuild -resolvePackageDependencies -project whiplash.xcodeproj 2>&1 | tail -10
```

**Important:** AnyLanguageModel is pre-1.0. The exact API (class names like `OllamaLanguageModel`, `LMStudioLanguageModel`) must be verified against the actual package. The implementer should:
1. Check `https://github.com/mattt/AnyLanguageModel` for current API
2. Browse the resolved package sources after adding to see available types
3. Adjust LLMService code in the next task accordingly

- [ ] **Step 2: Build to verify dependency resolves**

Run: `xcodebuild -project whiplash.xcodeproj -scheme whiplash build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add whiplash.xcodeproj/ whiplash.xcworkspace/ 2>/dev/null
git add Package.resolved 2>/dev/null
git commit -m "feat: add AnyLanguageModel package dependency"
```

---

## Task 7: LLMService

**Files:**
- Create: `whiplash/Services/LLMService.swift`

- [ ] **Step 1: Create LLMService.swift**

```swift
// whiplash/Services/LLMService.swift
import Foundation
import AnyLanguageModel

struct LLMResponse {
    let text: String
}

struct OverlayTranslation: Codable {
    let index: Int
    let translation: String
}

final class LLMService {
    private let settingsStore: SettingsStore

    init(settingsStore: SettingsStore) {
        self.settingsStore = settingsStore
    }

    /// Send full text to LLM with role's system prompt. Returns response text.
    func generateResponse(fullText: String, role: Role) async throws -> LLMResponse {
        let config = role.backendOverride ?? settingsStore.backendConfig
        let session = try createSession(config: config, instructions: role.systemPrompt)
        let response = try await session.respond(to: fullText)
        return LLMResponse(text: response.content)
    }

    /// Send text blocks for overlay translation. Returns per-block translations.
    func generateOverlayResponse(textBlocks: [TextBlock], role: Role) async throws -> [OverlayTranslation] {
        let config = role.backendOverride ?? settingsStore.backendConfig

        // Build JSON input for text blocks
        let blockInputs = textBlocks.enumerated().map { index, block in
            ["index": "\(index)", "text": block.text]
        }
        let jsonData = try JSONSerialization.data(withJSONObject: blockInputs)
        let jsonString = String(data: jsonData, encoding: .utf8) ?? "[]"

        let overlayInstructions = """
        \(role.systemPrompt)

        以下のテキストブロックをそれぞれ処理し、JSON配列で返してください。
        フォーマット: [{"index": 0, "translation": "..."}, ...]
        JSON以外のテキストは含めないでください。
        """

        let session = try createSession(config: config, instructions: overlayInstructions)
        let response = try await session.respond(to: jsonString)

        // Parse JSON response
        guard let data = response.content.data(using: .utf8),
              let translations = try? JSONDecoder().decode([OverlayTranslation].self, from: data) else {
            // Fallback: return the whole response as a single translation for index 0
            return [OverlayTranslation(index: 0, translation: response.content)]
        }
        return translations
    }

    private func createSession(config: BackendConfig, instructions: String) throws -> LanguageModelSession {
        // The exact API depends on AnyLanguageModel version.
        // The implementer must check the package source and adjust these calls.
        // Below is the expected pattern based on the HuggingFace blog post.
        switch config.provider {
        case .foundationModels:
            let model = SystemLanguageModel.default
            return LanguageModelSession(model: model, instructions: instructions)
        case .ollama:
            let model = OllamaLanguageModel(
                endpoint: config.effectiveEndpoint,
                model: config.modelName ?? "llama3.2"
            )
            return LanguageModelSession(model: model, instructions: instructions)
        case .lmStudio:
            let model = OpenAILanguageModel(
                endpoint: config.effectiveEndpoint,
                model: config.modelName ?? "default"
            )
            return LanguageModelSession(model: model, instructions: instructions)
        }
    }
}
```

**Critical note for implementer:** The class names (`OllamaLanguageModel`, `OpenAILanguageModel`, `SystemLanguageModel`, `LanguageModelSession`) are based on the AnyLanguageModel blog post. The actual API may differ. After adding the package in Task 6, inspect the package sources at:
```
~/Library/Developer/Xcode/DerivedData/whiplash-*/SourcePackages/checkouts/AnyLanguageModel/Sources/
```
Adjust the `createSession` method to match the actual API.

- [ ] **Step 2: Build to verify compilation**

Run: `xcodebuild -project whiplash.xcodeproj -scheme whiplash build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **` (may need API adjustments based on actual AnyLanguageModel types)

- [ ] **Step 3: Commit**

```bash
git add whiplash/Services/LLMService.swift
git commit -m "feat: add LLMService with AnyLanguageModel backend abstraction"
```

---

## Task 8: AppDelegate + Menu Bar

**Files:**
- Create: `whiplash/AppDelegate.swift`
- Modify: `whiplash/whiplashApp.swift`
- Delete: `whiplash/ContentView.swift`

- [ ] **Step 1: Create AppDelegate.swift**

```swift
// whiplash/AppDelegate.swift
import AppKit
import SwiftUI
import Carbon.HIToolbox

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    let roleStore = RoleStore()
    let settingsStore = SettingsStore()
    lazy var captureFlow = CaptureFlow(
        roleStore: roleStore,
        settingsStore: settingsStore
    )
    private var eventMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide from Dock
        NSApp.setActivationPolicy(.accessory)

        setupMenuBar()
        registerGlobalShortcut()
    }

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "bolt.circle.fill", accessibilityDescription: "Whiplash")
        }

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "⌘⇧X でキャプチャ", action: nil, keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "設定を開く...", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Whiplash を終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem.menu = menu
    }

    private func registerGlobalShortcut() {
        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return }
            let keyCode = UInt32(event.keyCode)
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

            let wantCmd = flags.contains(.command)
            let wantShift = flags.contains(.shift)
            let isX = keyCode == UInt32(kVK_ANSI_X)

            if wantCmd && wantShift && isX {
                Task { @MainActor in
                    await self.captureFlow.start()
                }
            }
        }
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let view = SettingsView(roleStore: roleStore, settingsStore: settingsStore)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.contentView = NSHostingView(rootView: view)
            window.title = "Whiplash 設定"
            window.center()
            window.delegate = self
            settingsWindow = window
        }

        NSApp.setActivationPolicy(.regular)
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

extension AppDelegate: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        settingsWindow = nil
    }
}
```

- [ ] **Step 2: Update whiplashApp.swift**

Replace the entire contents of `whiplash/whiplashApp.swift` with:

```swift
// whiplash/whiplashApp.swift
import SwiftUI

@main
struct WhiplashApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // No visible window at launch — menu bar only
        Settings {
            EmptyView()
        }
    }
}
```

- [ ] **Step 3: Delete ContentView.swift**

```bash
rm whiplash/ContentView.swift
```

- [ ] **Step 4: Build to verify compilation**

This will fail because `CaptureFlow` and `SettingsView` don't exist yet. Create stubs:

Create `whiplash/Flow/CaptureFlow.swift`:
```swift
// whiplash/Flow/CaptureFlow.swift
import Foundation

@MainActor
final class CaptureFlow {
    private let roleStore: RoleStore
    private let settingsStore: SettingsStore

    init(roleStore: RoleStore, settingsStore: SettingsStore) {
        self.roleStore = roleStore
        self.settingsStore = settingsStore
    }

    func start() async {
        // TODO: Implement in Task 12
        print("CaptureFlow started")
    }
}
```

Create `whiplash/Views/Settings/SettingsView.swift`:
```swift
// whiplash/Views/Settings/SettingsView.swift
import SwiftUI

struct SettingsView: View {
    let roleStore: RoleStore
    let settingsStore: SettingsStore

    var body: some View {
        Text("Settings placeholder")
            .frame(width: 700, height: 500)
    }
}
```

Run: `xcodebuild -project whiplash.xcodeproj -scheme whiplash build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add whiplash/AppDelegate.swift whiplash/whiplashApp.swift whiplash/Flow/CaptureFlow.swift whiplash/Views/Settings/SettingsView.swift
git rm whiplash/ContentView.swift 2>/dev/null
git commit -m "feat: add AppDelegate with menu bar, global shortcut, and settings window shell"
```

---

## Task 9: Settings UI — General Tab

**Files:**
- Create: `whiplash/Views/Settings/GeneralTab.swift`

- [ ] **Step 1: Create GeneralTab.swift**

```swift
// whiplash/Views/Settings/GeneralTab.swift
import SwiftUI
import ServiceManagement

struct GeneralTab: View {
    @Bindable var settingsStore: SettingsStore
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section("キーボードショートカット") {
                HStack {
                    Text("キャプチャを開始")
                    Spacer()
                    Text("⌘⇧X")
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.quaternary)
                        .cornerRadius(6)
                }
                Text("現在のバージョンではショートカットは固定です")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("起動") {
                Toggle("ログイン時に起動", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        do {
                            if newValue {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                        } catch {
                            launchAtLogin = !newValue
                        }
                    }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
```

- [ ] **Step 2: Build to verify compilation**

Run: `xcodebuild -project whiplash.xcodeproj -scheme whiplash build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add whiplash/Views/Settings/GeneralTab.swift
git commit -m "feat: add settings General tab with shortcut display and launch at login"
```

---

## Task 10: Settings UI — Backend Tab

**Files:**
- Create: `whiplash/Views/Settings/BackendTab.swift`

- [ ] **Step 1: Create BackendTab.swift**

```swift
// whiplash/Views/Settings/BackendTab.swift
import SwiftUI

struct BackendTab: View {
    @Bindable var settingsStore: SettingsStore

    var body: some View {
        Form {
            Section("AIバックエンド") {
                Picker("プロバイダー", selection: $settingsStore.backendConfig.provider) {
                    Text("Apple Foundation Models").tag(BackendProvider.foundationModels)
                    Text("Ollama").tag(BackendProvider.ollama)
                    Text("LM Studio").tag(BackendProvider.lmStudio)
                }

                switch settingsStore.backendConfig.provider {
                case .foundationModels:
                    Text("オンデバイスモデルを使用します。追加設定は不要です。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                case .ollama:
                    endpointField(defaultPort: "11434")
                    modelNameField(placeholder: "llama3.2")
                case .lmStudio:
                    endpointField(defaultPort: "1234")
                    modelNameField(placeholder: "モデル名")
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func endpointField(defaultPort: String) -> some View {
        LabeledContent("エンドポイント") {
            TextField(
                "http://localhost:\(defaultPort)",
                text: Binding(
                    get: { settingsStore.backendConfig.endpoint?.absoluteString ?? "" },
                    set: { settingsStore.backendConfig.endpoint = URL(string: $0) }
                )
            )
            .textFieldStyle(.roundedBorder)
            .frame(width: 300)
        }
    }

    private func modelNameField(placeholder: String) -> some View {
        LabeledContent("モデル名") {
            TextField(
                placeholder,
                text: Binding(
                    get: { settingsStore.backendConfig.modelName ?? "" },
                    set: { settingsStore.backendConfig.modelName = $0.isEmpty ? nil : $0 }
                )
            )
            .textFieldStyle(.roundedBorder)
            .frame(width: 300)
        }
    }
}
```

- [ ] **Step 2: Build to verify compilation**

Run: `xcodebuild -project whiplash.xcodeproj -scheme whiplash build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add whiplash/Views/Settings/BackendTab.swift
git commit -m "feat: add settings Backend tab with provider selection and config"
```

---

## Task 11: Settings UI — Role Tab + SettingsView Assembly

**Files:**
- Create: `whiplash/Views/Settings/RoleTab.swift`
- Modify: `whiplash/Views/Settings/SettingsView.swift`

- [ ] **Step 1: Create RoleTab.swift**

```swift
// whiplash/Views/Settings/RoleTab.swift
import SwiftUI

struct RoleTab: View {
    @Bindable var roleStore: RoleStore
    @State private var selectedRoleID: UUID?

    private var selectedRole: Binding<Role>? {
        guard let id = selectedRoleID,
              let index = roleStore.roles.firstIndex(where: { $0.id == id }) else {
            return nil
        }
        return Binding(
            get: { roleStore.roles[index] },
            set: { roleStore.update($0) }
        )
    }

    var body: some View {
        HSplitView {
            // Left sidebar: Role list
            VStack(spacing: 0) {
                List(roleStore.roles, selection: $selectedRoleID) { role in
                    HStack(spacing: 8) {
                        Text(role.icon)
                        Text(role.name)
                            .lineLimit(1)
                    }
                    .contextMenu {
                        Button("削除", role: .destructive) {
                            roleStore.delete(role)
                            if selectedRoleID == role.id {
                                selectedRoleID = roleStore.roles.first?.id
                            }
                        }
                    }
                }
                .listStyle(.sidebar)

                Divider()

                Button {
                    let newRole = Role(
                        name: "新しいRole",
                        icon: "⚡",
                        systemPrompt: "",
                        responsePatterns: [.richMessage]
                    )
                    roleStore.add(newRole)
                    selectedRoleID = newRole.id
                } label: {
                    Label("新規Role", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderless)
                .padding(8)
            }
            .frame(minWidth: 180, maxWidth: 220)

            // Right pane: Role editor
            if let binding = selectedRole {
                RoleEditorView(role: binding)
            } else {
                ContentUnavailableView("Roleを選択してください", systemImage: "bolt.circle")
            }
        }
        .onAppear {
            if selectedRoleID == nil {
                selectedRoleID = roleStore.roles.first?.id
            }
        }
    }
}

struct RoleEditorView: View {
    @Binding var role: Role

    var body: some View {
        Form {
            Section("基本設定") {
                HStack {
                    TextField("アイコン", text: $role.icon)
                        .frame(width: 50)
                    TextField("Role名", text: $role.name)
                }
            }

            Section("システムプロンプト") {
                TextEditor(text: $role.systemPrompt)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 120)
            }

            Section("応答パターン") {
                ForEach(ResponsePattern.allCases, id: \.self) { pattern in
                    Toggle(isOn: Binding(
                        get: { role.responsePatterns.contains(pattern) },
                        set: { enabled in
                            if enabled {
                                if !role.responsePatterns.contains(pattern) {
                                    role.responsePatterns.append(pattern)
                                }
                            } else {
                                role.responsePatterns.removeAll { $0 == pattern }
                            }
                        }
                    )) {
                        HStack {
                            Text(pattern.icon)
                            Text(pattern.label)
                        }
                    }
                }
            }

            Section {
                HStack {
                    Text("AIバックエンド")
                    Spacer()
                    Text("アプリのデフォルトを使用")
                        .foregroundStyle(.tertiary)
                }
            } header: {
                Text("AIバックエンド（将来実装）")
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

extension ResponsePattern {
    var icon: String {
        switch self {
        case .richMessage: return "💬"
        case .clipboard: return "📋"
        case .overlay: return "🖼"
        }
    }

    var label: String {
        switch self {
        case .richMessage: return "メッセージボックス"
        case .clipboard: return "クリップボードにコピー"
        case .overlay: return "オーバーレイ"
        }
    }
}
```

- [ ] **Step 2: Update SettingsView.swift with tabs**

Replace the entire contents of `whiplash/Views/Settings/SettingsView.swift` with:

```swift
// whiplash/Views/Settings/SettingsView.swift
import SwiftUI

struct SettingsView: View {
    let roleStore: RoleStore
    let settingsStore: SettingsStore

    var body: some View {
        TabView {
            GeneralTab(settingsStore: settingsStore)
                .tabItem {
                    Label("一般", systemImage: "gear")
                }

            BackendTab(settingsStore: settingsStore)
                .tabItem {
                    Label("AIバックエンド", systemImage: "cpu")
                }

            RoleTab(roleStore: roleStore)
                .tabItem {
                    Label("Role", systemImage: "person.text.rectangle")
                }
        }
        .frame(minWidth: 700, minHeight: 500)
    }
}
```

- [ ] **Step 3: Build to verify compilation**

Run: `xcodebuild -project whiplash.xcodeproj -scheme whiplash build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add whiplash/Views/Settings/RoleTab.swift whiplash/Views/Settings/SettingsView.swift
git commit -m "feat: add Role tab with CRUD editor and assemble settings tabs"
```

---

## Task 12: RolePopoverView

**Files:**
- Create: `whiplash/Views/Capture/RolePopoverView.swift`

- [ ] **Step 1: Create RolePopoverView.swift**

```swift
// whiplash/Views/Capture/RolePopoverView.swift
import SwiftUI

struct RolePopoverView: View {
    let image: NSImage
    let roles: [Role]
    let onSelect: (Role) -> Void
    let onCancel: () -> Void

    @State private var selectedIndex: Int = 0

    var body: some View {
        VStack(spacing: 0) {
            // Thumbnail
            HStack(spacing: 8) {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(height: 40)
                    .cornerRadius(4)
                Text("\(Int(image.size.width))×\(Int(image.size.height))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(10)

            Divider()

            // Role list
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(Array(roles.enumerated()), id: \.element.id) { index, role in
                        RoleRowView(
                            role: role,
                            isSelected: index == selectedIndex
                        )
                        .onTapGesture {
                            onSelect(role)
                        }
                    }
                }
                .padding(6)
            }

            Divider()

            // Keyboard hints
            HStack(spacing: 16) {
                Text("↑↓ 移動")
                Text("⏎ 選択")
                Text("esc キャンセル")
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .padding(6)
        }
        .frame(width: 240)
        .background(.ultraThinMaterial)
        .cornerRadius(10)
        .onKeyPress(.upArrow) {
            if selectedIndex > 0 { selectedIndex -= 1 }
            return .handled
        }
        .onKeyPress(.downArrow) {
            if selectedIndex < roles.count - 1 { selectedIndex += 1 }
            return .handled
        }
        .onKeyPress(.return) {
            if roles.indices.contains(selectedIndex) {
                onSelect(roles[selectedIndex])
            }
            return .handled
        }
        .onKeyPress(.escape) {
            onCancel()
            return .handled
        }
    }
}

struct RoleRowView: View {
    let role: Role
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text(role.icon)
                .font(.system(size: 14))
            VStack(alignment: .leading, spacing: 2) {
                Text(role.name)
                    .font(.system(size: 13, weight: .medium))
                HStack(spacing: 4) {
                    ForEach(role.responsePatterns, id: \.self) { pattern in
                        Text(pattern.icon)
                            .font(.system(size: 10))
                    }
                }
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(isSelected ? Color.accentColor.opacity(0.2) : Color.clear)
        .cornerRadius(6)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isSelected ? Color.accentColor.opacity(0.4) : Color.clear, lineWidth: 1)
        )
    }
}
```

- [ ] **Step 2: Build to verify compilation**

Run: `xcodebuild -project whiplash.xcodeproj -scheme whiplash build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add whiplash/Views/Capture/RolePopoverView.swift
git commit -m "feat: add RolePopoverView with keyboard navigation and role selection"
```

---

## Task 13: RichMessageView (Floating Message Box)

**Files:**
- Create: `whiplash/Views/Response/RichMessageView.swift`

- [ ] **Step 1: Create RichMessageView.swift**

```swift
// whiplash/Views/Response/RichMessageView.swift
import SwiftUI

struct RichMessageView: View {
    let role: Role
    let text: String
    let onCopy: () -> Void
    let onRegenerate: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text(role.icon)
                    .font(.system(size: 13))
                Text(role.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.quaternary.opacity(0.5))

            Divider()

            // Content
            ScrollView {
                Text(try! AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                    .font(.system(size: 13))
                    .textSelection(.enabled)
                    .lineSpacing(4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
            .frame(maxHeight: 400)

            Divider()

            // Actions
            HStack {
                Spacer()
                Button("📋 コピー") {
                    onCopy()
                }
                Button("🔄 再生成") {
                    onRegenerate()
                }
                Button("✕ 閉じる") {
                    onClose()
                }
            }
            .buttonStyle(.borderless)
            .font(.system(size: 11))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .frame(width: 420)
        .background(.ultraThinMaterial)
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
    }
}
```

- [ ] **Step 2: Build to verify compilation**

Run: `xcodebuild -project whiplash.xcodeproj -scheme whiplash build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add whiplash/Views/Response/RichMessageView.swift
git commit -m "feat: add RichMessageView with markdown rendering and action buttons"
```

---

## Task 14: OverlayView (Translation Overlay)

**Files:**
- Create: `whiplash/Views/Response/OverlayView.swift`

- [ ] **Step 1: Create OverlayView.swift**

```swift
// whiplash/Views/Response/OverlayView.swift
import SwiftUI

struct OverlayView: View {
    let imageSize: CGSize
    let textBlocks: [TextBlock]
    let translations: [OverlayTranslation]
    let onClose: () -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Semi-transparent background
            Color.black.opacity(0.3)

            // Translated text blocks positioned at OCR bounding boxes
            ForEach(Array(textBlocks.enumerated()), id: \.offset) { index, block in
                if let translation = translations.first(where: { $0.index == index }) {
                    Text(translation.translation)
                        .font(.system(size: estimatedFontSize(for: block)))
                        .foregroundStyle(.white)
                        .padding(2)
                        .background(Color.black.opacity(0.7))
                        .cornerRadius(2)
                        .position(
                            x: block.boundingBox.origin.x + block.boundingBox.width / 2,
                            y: block.boundingBox.origin.y + block.boundingBox.height / 2
                        )
                }
            }

            // Close hint
            HStack {
                Spacer()
                Text("esc で閉じる")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.black.opacity(0.6))
                    .cornerRadius(4)
                    .padding(8)
            }
        }
        .frame(width: imageSize.width, height: imageSize.height)
        .onKeyPress(.escape) {
            onClose()
            return .handled
        }
        .onTapGesture {
            onClose()
        }
    }

    private func estimatedFontSize(for block: TextBlock) -> CGFloat {
        // Use bounding box height as a rough font size estimate
        let estimated = block.boundingBox.height * 0.7
        return max(10, min(estimated, 24))
    }
}
```

- [ ] **Step 2: Build to verify compilation**

Run: `xcodebuild -project whiplash.xcodeproj -scheme whiplash build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add whiplash/Views/Response/OverlayView.swift
git commit -m "feat: add OverlayView for positioned translation display"
```

---

## Task 15: CaptureFlow (Full Pipeline)

**Files:**
- Modify: `whiplash/Flow/CaptureFlow.swift`

- [ ] **Step 1: Replace CaptureFlow.swift stub with full implementation**

Replace the entire contents of `whiplash/Flow/CaptureFlow.swift` with:

```swift
// whiplash/Flow/CaptureFlow.swift
import SwiftUI
import AppKit

@MainActor
final class CaptureFlow {
    private let roleStore: RoleStore
    private let settingsStore: SettingsStore
    private let captureService = CaptureService()
    private let ocrService = OCRService()
    private lazy var llmService = LLMService(settingsStore: settingsStore)

    private var popoverWindow: NSPanel?
    private var richMessageWindow: NSWindow?
    private var overlayWindow: NSWindow?

    init(roleStore: RoleStore, settingsStore: SettingsStore) {
        self.roleStore = roleStore
        self.settingsStore = settingsStore
    }

    func start() async {
        // Step 1: Capture screenshot
        let captureResult: CaptureResult
        do {
            captureResult = try await captureService.capture()
        } catch CaptureError.cancelled {
            return
        } catch {
            print("Capture failed: \(error)")
            return
        }

        // Step 2: Show role selection popover
        guard let selectedRole = await showRolePopover(
            image: captureResult.image,
            near: captureResult.captureRect
        ) else {
            captureService.cleanup(url: captureResult.imageURL)
            return
        }

        // Step 3: Run OCR
        let ocrResult: OCRResult
        do {
            ocrResult = try await ocrService.recognizeText(from: captureResult.imageURL)
        } catch {
            print("OCR failed: \(error)")
            captureService.cleanup(url: captureResult.imageURL)
            return
        }

        // Step 4: Send to LLM and dispatch results
        await processWithLLM(
            role: selectedRole,
            ocrResult: ocrResult,
            captureResult: captureResult
        )

        // Step 5: Cleanup temp file
        captureService.cleanup(url: captureResult.imageURL)
    }

    // MARK: - Role Selection Popover

    private func showRolePopover(image: NSImage, near rect: CGRect) async -> Role? {
        await withCheckedContinuation { continuation in
            let view = RolePopoverView(
                image: image,
                roles: roleStore.roles,
                onSelect: { [weak self] role in
                    self?.dismissPopover()
                    continuation.resume(returning: role)
                },
                onCancel: { [weak self] in
                    self?.dismissPopover()
                    continuation.resume(returning: nil)
                }
            )

            let hostingView = NSHostingView(rootView: view)
            hostingView.frame.size = hostingView.fittingSize

            let panel = NSPanel(
                contentRect: NSRect(origin: .zero, size: hostingView.fittingSize),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.contentView = hostingView
            panel.isFloatingPanel = true
            panel.level = .floating
            panel.backgroundColor = .clear
            panel.isOpaque = false
            panel.hasShadow = true

            // Position near capture area (below-center)
            let screenFrame = NSScreen.main?.frame ?? .zero
            let x = min(rect.midX - hostingView.fittingSize.width / 2, screenFrame.maxX - hostingView.fittingSize.width)
            let y = rect.minY - hostingView.fittingSize.height - 8
            panel.setFrameOrigin(NSPoint(x: max(0, x), y: max(0, y)))

            panel.makeKeyAndOrderFront(nil)
            popoverWindow = panel
        }
    }

    private func dismissPopover() {
        popoverWindow?.close()
        popoverWindow = nil
    }

    // MARK: - LLM Processing & Response Dispatch

    private func processWithLLM(role: Role, ocrResult: OCRResult, captureResult: CaptureResult) async {
        let hasOverlay = role.responsePatterns.contains(.overlay)
        let hasTextPatterns = role.responsePatterns.contains(.richMessage) || role.responsePatterns.contains(.clipboard)

        // For overlay: use block-level translation
        if hasOverlay {
            do {
                let translations = try await llmService.generateOverlayResponse(
                    textBlocks: ocrResult.textBlocks,
                    role: role
                )

                showOverlay(
                    captureRect: captureResult.captureRect,
                    imageSize: captureResult.image.size,
                    textBlocks: ocrResult.textBlocks,
                    translations: translations
                )

                // If clipboard is also requested, copy the full translated text
                if role.responsePatterns.contains(.clipboard) {
                    let fullTranslation = translations
                        .sorted { $0.index < $1.index }
                        .map(\.translation)
                        .joined(separator: "\n")
                    copyToClipboard(fullTranslation)
                }
            } catch {
                print("Overlay LLM failed: \(error)")
            }
        }

        // For richMessage/clipboard without overlay: use full text
        if hasTextPatterns && !hasOverlay {
            do {
                let response = try await llmService.generateResponse(
                    fullText: ocrResult.fullText,
                    role: role
                )

                if role.responsePatterns.contains(.richMessage) {
                    showRichMessage(role: role, text: response.text, ocrResult: ocrResult)
                }
                if role.responsePatterns.contains(.clipboard) {
                    copyToClipboard(response.text)
                }
            } catch {
                print("LLM failed: \(error)")
            }
        }

        // richMessage without overlay but with overlay already handled clipboard
        if role.responsePatterns.contains(.richMessage) && hasOverlay {
            do {
                let response = try await llmService.generateResponse(
                    fullText: ocrResult.fullText,
                    role: role
                )
                showRichMessage(role: role, text: response.text, ocrResult: ocrResult)
            } catch {
                print("RichMessage LLM failed: \(error)")
            }
        }
    }

    // MARK: - Response Windows

    private func showRichMessage(role: Role, text: String, ocrResult: OCRResult) {
        let view = RichMessageView(
            role: role,
            text: text,
            onCopy: { [weak self] in
                self?.copyToClipboard(text)
            },
            onRegenerate: { [weak self] in
                guard let self else { return }
                Task {
                    let response = try? await self.llmService.generateResponse(
                        fullText: ocrResult.fullText,
                        role: role
                    )
                    if let response {
                        self.showRichMessage(role: role, text: response.text, ocrResult: ocrResult)
                    }
                }
            },
            onClose: { [weak self] in
                self?.richMessageWindow?.close()
                self?.richMessageWindow = nil
            }
        )

        let hostingView = NSHostingView(rootView: view)
        hostingView.frame.size = hostingView.fittingSize

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: hostingView.fittingSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.level = .floating
        window.backgroundColor = .clear
        window.isOpaque = false
        window.isMovableByWindowBackground = true
        window.center()
        window.makeKeyAndOrderFront(nil)

        richMessageWindow?.close()
        richMessageWindow = window
    }

    private func showOverlay(captureRect: CGRect, imageSize: CGSize, textBlocks: [TextBlock], translations: [OverlayTranslation]) {
        let view = OverlayView(
            imageSize: imageSize,
            textBlocks: textBlocks,
            translations: translations,
            onClose: { [weak self] in
                self?.overlayWindow?.close()
                self?.overlayWindow = nil
            }
        )

        let window = NSWindow(
            contentRect: NSRect(
                x: captureRect.origin.x,
                y: captureRect.origin.y,
                width: imageSize.width,
                height: imageSize.height
            ),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        let hostingView = NSHostingView(rootView: view)
        window.contentView = hostingView
        window.level = .floating
        window.backgroundColor = .clear
        window.isOpaque = false
        window.makeKeyAndOrderFront(nil)

        overlayWindow?.close()
        overlayWindow = window
    }

    // MARK: - Clipboard

    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
```

- [ ] **Step 2: Build to verify compilation**

Run: `xcodebuild -project whiplash.xcodeproj -scheme whiplash build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add whiplash/Flow/CaptureFlow.swift
git commit -m "feat: implement CaptureFlow pipeline (capture → role → OCR → LLM → response)"
```

---

## Task 16: Info.plist Privacy Descriptions

**Files:**
- Modify: `whiplash/Info.plist` or Xcode target settings

- [ ] **Step 1: Add privacy descriptions**

In Xcode, select the whiplash target → Info tab → add:
- Key: `NSScreenCaptureUsageDescription`
- Value: `Whiplash uses screen capture to take screenshots for AI processing.`

Alternatively, if `Info.plist` is a file:

```xml
<key>NSScreenCaptureUsageDescription</key>
<string>Whiplash uses screen capture to take screenshots for AI processing.</string>
```

If using Xcode's build settings (no separate Info.plist), add via the target's Info tab in Xcode.

- [ ] **Step 2: Build to verify**

Run: `xcodebuild -project whiplash.xcodeproj -scheme whiplash build 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit**

```bash
git add whiplash/Info.plist 2>/dev/null || git add whiplash.xcodeproj/
git commit -m "feat: add screen capture privacy description to Info.plist"
```

---

## Task 17: End-to-End Manual Test

This is a manual verification task. No code changes.

- [ ] **Step 1: Build and run the app**

Run: Open `whiplash.xcodeproj` in Xcode → Product → Run (⌘R)

- [ ] **Step 2: Verify menu bar**

Expected:
- Whiplash icon appears in menu bar (bolt.circle.fill)
- Click shows: shortcut hint, "設定を開く...", "Whiplash を終了"
- App does NOT appear in Dock

- [ ] **Step 3: Verify settings window**

Click "設定を開く..." in menu bar.
Expected:
- Settings window opens with 3 tabs: 一般, AIバックエンド, Role
- App appears in Dock while settings is open
- 一般 tab: shows ⌘⇧X shortcut, Launch at Login toggle
- AIバックエンド tab: provider dropdown with Foundation Models/Ollama/LM Studio, config fields
- Role tab: preset roles listed, clicking shows editor, can add/edit/delete roles
- Closing settings: app disappears from Dock

- [ ] **Step 4: Verify capture flow**

Press ⌘⇧X.
Expected:
- macOS screenshot selection UI appears (crosshair cursor)
- After dragging a selection: Role popover appears near the capture area
- Popover shows thumbnail, role list with icons, keyboard hints
- Selecting a role: processing begins (OCR → LLM → response)
- Pressing Esc at any point: cancels

- [ ] **Step 5: Verify response patterns**

Test with each response pattern:
- richMessage: floating message box with markdown content, copy/regenerate/close buttons
- clipboard: text is copied to clipboard (verify with ⌘V in a text editor)
- overlay: semi-transparent overlay at capture position with translated text

**Note:** LLM response depends on having a working backend configured. Test with Ollama if Foundation Models is not available.

---

## Task Summary

| Task | Description | Dependencies |
|------|-------------|--------------|
| 1 | Data Models (Role, BackendConfig, OCRResult) | None |
| 2 | RoleStore (JSON persistence) | Task 1 |
| 3 | SettingsStore (UserDefaults) | Task 1 |
| 4 | CaptureService (screencapture wrapper) | None |
| 5 | OCRService (Apple Vision) | Task 1 |
| 6 | Add AnyLanguageModel dependency | None |
| 7 | LLMService | Tasks 1, 3, 6 |
| 8 | AppDelegate + Menu Bar (with stubs) | Tasks 2, 3 |
| 9 | Settings UI — General Tab | Task 3 |
| 10 | Settings UI — Backend Tab | Task 3 |
| 11 | Settings UI — Role Tab + Assembly | Tasks 2, 9, 10 |
| 12 | RolePopoverView | Task 1 |
| 13 | RichMessageView | Task 1 |
| 14 | OverlayView | Task 1 |
| 15 | CaptureFlow (full pipeline) | Tasks 4, 5, 7, 12, 13, 14 |
| 16 | Info.plist privacy descriptions | None |
| 17 | End-to-end manual test | All |
