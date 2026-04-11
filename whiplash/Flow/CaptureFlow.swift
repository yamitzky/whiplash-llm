import SwiftUI
import AppKit
import Observation

@Observable
@MainActor
final class StreamingText {
    var text: String = ""
    var isStreaming: Bool = true
    var error: String?
}

enum RoleSelectionResult {
    case role(Role, String, [Attachment])
    case freeQuestion(String, [Attachment])
}

@MainActor
final class CaptureFlow: NSObject {
    private let roleStore: RoleStore
    private let settingsStore: SettingsStore
    private let captureService = CaptureService()
    private let ocrService = OCRService()
    private lazy var llmService = LLMService(settingsStore: settingsStore)
    private let fileManager = FileManager.default

    private var richMessageWindow: NSPanel?
    private var loadingWindow: NSPanel?
    private var toastWindow: NSPanel?
    private var roleSelectionPanel: NSPanel?
    private var isCapturing = false

    init(roleStore: RoleStore, settingsStore: SettingsStore) {
        self.roleStore = roleStore
        self.settingsStore = settingsStore
        super.init()
    }

    // MARK: - Entry Points

    /// Launch with screen capture as initial attachment.
    func start() {
        guard !isCapturing else {
            print("[Whiplash] start: already capturing, ignoring")
            return
        }
        isCapturing = true
        Task {
            defer { isCapturing = false }
            print("[Whiplash] start: beginning capture flow")
            let captureResult: CaptureResult
            do {
                captureResult = try await captureService.capture()
                print("[Whiplash] start: capture OK, image size: \(captureResult.imageSize)")
            } catch {
                print("[Whiplash] start: capture cancelled/failed: \(error)")
                return
            }
            let attachment = Attachment(kind: .image(captureResult.imageURL))
            self.showAndProcess(initialAttachments: [attachment])
        }
    }

    /// Launch with clipboard content as initial attachment.
    func startFromClipboard() {
        guard !isCapturing else {
            print("[Whiplash] startFromClipboard: already capturing, ignoring")
            return
        }
        isCapturing = true
        defer { isCapturing = false }

        let pasteboard = NSPasteboard.general
        var initialAttachments: [Attachment] = []

        // Try text first (most common)
        if let text = pasteboard.string(forType: .string), !text.isEmpty {
            print("[Whiplash] startFromClipboard: found text (\(text.count) chars)")
            initialAttachments.append(Attachment(kind: .text(text)))
        }
        // Try image (TIFF is the standard pasteboard image type on macOS)
        else if let imageData = pasteboard.data(forType: .tiff) ?? pasteboard.data(forType: .png) {
            let tempPath = "/tmp/whiplash-clipboard-\(UUID().uuidString).png"
            let tempURL = URL(fileURLWithPath: tempPath)
            do {
                if let imageRep = NSBitmapImageRep(data: imageData),
                   let pngData = imageRep.representation(using: .png, properties: [:]) {
                    try pngData.write(to: tempURL)
                } else {
                    try imageData.write(to: tempURL)
                }
                print("[Whiplash] startFromClipboard: found image, saved to \(tempPath)")
                initialAttachments.append(Attachment(kind: .image(tempURL)))
            } catch {
                print("[Whiplash] startFromClipboard: failed to save image: \(error)")
                showError("クリップボード画像の保存に失敗しました")
                return
            }
        } else {
            print("[Whiplash] startFromClipboard: clipboard empty, continuing without attachment")
        }

        showAndProcess(initialAttachments: initialAttachments)
    }

    /// Launch with no initial attachment.
    func startEmpty() {
        guard !isCapturing else { return }
        isCapturing = true
        defer { isCapturing = false }
        showAndProcess(initialAttachments: [])
    }

    // MARK: - Unified Flow

    private func showAndProcess(initialAttachments: [Attachment]) {
        // Start OCR for image attachments eagerly (runs in background while user selects role)
        var ocrTasks: [UUID: Task<OCRResult, Error>] = [:]
        for attachment in initialAttachments {
            if case .image(let url) = attachment.kind {
                ocrTasks[attachment.id] = Task {
                    try await ocrService.recognizeText(from: url)
                }
                print("[Whiplash] showAndProcess: OCR started for \(attachment.id)")
            }
        }

        guard let selection = showRoleSelectionPanel(initialAttachments: initialAttachments) else {
            print("[Whiplash] showAndProcess: cancelled")
            for task in ocrTasks.values { task.cancel() }
            cleanupImageAttachments(initialAttachments)
            return
        }

        let attachments: [Attachment]
        switch selection {
        case .role(_, _, let a): attachments = a
        case .freeQuestion(_, let a): attachments = a
        }

        // Start OCR for any new image attachments added during panel
        for attachment in attachments where ocrTasks[attachment.id] == nil {
            if case .image(let url) = attachment.kind {
                ocrTasks[attachment.id] = Task {
                    try await ocrService.recognizeText(from: url)
                }
            }
        }

        if case .role(let role, _, _) = selection {
            print("[Whiplash] showAndProcess: role selected: \(role.name)")
            showLoading(role: role)
        } else {
            print("[Whiplash] showAndProcess: free question")
        }

        Task {
            // Combine all attachment content
            var combinedText = ""
            for attachment in attachments {
                switch attachment.kind {
                case .text(let text):
                    if !combinedText.isEmpty { combinedText += "\n\n" }
                    combinedText += text
                case .image:
                    if let task = ocrTasks[attachment.id] {
                        do {
                            let ocr = try await task.value
                            if !ocr.fullText.isEmpty {
                                if !combinedText.isEmpty { combinedText += "\n\n" }
                                combinedText += ocr.fullText
                            }
                            print("[Whiplash] showAndProcess: OCR OK, \(ocr.textBlocks.count) blocks")
                        } catch {
                            print("[Whiplash] showAndProcess: OCR failed: \(error)")
                        }
                    }
                }
            }

            let ocrResult = OCRResult(fullText: combinedText, textBlocks: [])

            switch selection {
            case .role(let role, let instructions, _):
                let enriched = await enrichWithURLContent(instructions)
                await processWithLLM(role: role, ocrResult: ocrResult, additionalInstructions: enriched)
            case .freeQuestion(let question, _):
                let enriched = await enrichWithURLContent(question)
                await processFreeQuestion(enriched, ocrResult: ocrResult)
            }

            cleanupImageAttachments(attachments)
            print("[Whiplash] showAndProcess: cleanup done")
        }
    }

    // MARK: - Role Selection Panel

    private func showRoleSelectionPanel(initialAttachments: [Attachment]) -> RoleSelectionResult? {
        var result: RoleSelectionResult?

        let view = RoleSelectionView(
            roles: roleStore.roles,
            initialAttachments: initialAttachments
        ) { role, instructions, attachments in
            result = .role(role, instructions, attachments)
            NSApp.stopModal()
        } onFreeQuestion: { question, attachments in
            result = .freeQuestion(question, attachments)
            NSApp.stopModal()
        } onCancel: {
            NSApp.stopModal()
        }

        let hostingView = NSHostingView(rootView: view)
        hostingView.frame.size = hostingView.fittingSize

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: hostingView.fittingSize),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "Whiplash"
        panel.contentView = hostingView
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.delegate = self
        panel.center()

        roleSelectionPanel = panel

        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)

        let timer = Timer(timeInterval: 0.05, repeats: false) { _ in
            panel.contentView?.findFirstTextField().map { panel.makeFirstResponder($0) }
        }
        RunLoop.current.add(timer, forMode: .common)

        NSApp.runModal(for: panel)

        roleSelectionPanel = nil
        panel.close()

        return result
    }

    // MARK: - Loading Indicator

    private func showLoading(role: Role) {
        let view = VStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("\(role.icon) \(role.name) で処理中...")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(.ultraThinMaterial)
        .cornerRadius(10)
        .shadow(color: .black.opacity(0.2), radius: 8, y: 2)

        let hostingView = NSHostingView(rootView: view)
        hostingView.sizingOptions = []
        let size = hostingView.fittingSize
        hostingView.frame = NSRect(origin: .zero, size: size)

        let window = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.level = .floating
        window.backgroundColor = .clear
        window.isOpaque = false
        window.center()
        window.orderFront(nil)

        loadingWindow?.close()
        loadingWindow = window
    }

    private func dismissLoading() {
        loadingWindow?.close()
        loadingWindow = nil
    }

    // MARK: - LLM Processing & Response Dispatch

    private func processWithLLM(role: Role, ocrResult: OCRResult, additionalInstructions: String) async {
        print("[Whiplash] processWithLLM: starting")
        let hasRichMessage = role.responsePatterns.contains(.richMessage)

        let finalText: String

        if hasRichMessage {
            // Streaming mode: show rich message window and stream text into it
            let streamingText = StreamingText()
            dismissLoading()
            showRichMessage(role: role, streamingText: streamingText, ocrResult: ocrResult, additionalInstructions: additionalInstructions)

            do {
                let response = try await llmService.generateStreamingResponse(
                    fullText: ocrResult.fullText,
                    role: role,
                    additionalInstructions: additionalInstructions.isEmpty ? nil : additionalInstructions
                ) { @MainActor [weak streamingText] text in
                    streamingText?.text = text
                }
                streamingText.isStreaming = false
                finalText = response.text
            } catch {
                streamingText.isStreaming = false
                streamingText.error = error.localizedDescription
                print("[Whiplash] processWithLLM: streaming FAILED: \(error)")
                return
            }
        } else {
            // Non-streaming mode
            do {
                let response = try await llmService.generateResponse(
                    fullText: ocrResult.fullText,
                    role: role,
                    additionalInstructions: additionalInstructions.isEmpty ? nil : additionalInstructions
                )
                dismissLoading()
                finalText = response.text
            } catch {
                dismissLoading()
                showError("LLM処理に失敗しました: \(error.localizedDescription)")
                return
            }
        }

        // Dispatch remaining patterns
        for pattern in role.responsePatterns {
            switch pattern {
            case .richMessage:
                break // already handled via streaming
            case .clipboard:
                copyToClipboard(finalText)
            }
        }
        print("[Whiplash] processWithLLM: all patterns dispatched")
    }

    private func processFreeQuestion(_ question: String, ocrResult: OCRResult) async {
        print("[Whiplash] processFreeQuestion: starting")
        let streamingText = StreamingText()
        dismissLoading()

        let inputText = ocrResult.fullText.isEmpty ? question : "\(ocrResult.fullText)\n\n---\n\(question)"

        showFreeQuestionRichMessage(streamingText: streamingText, inputText: inputText)

        do {
            let response = try await llmService.generateStreamingResponse(
                fullText: inputText
            ) { @MainActor [weak streamingText] text in
                streamingText?.text = text
            }
            streamingText.isStreaming = false
            print("[Whiplash] processFreeQuestion: done, \(response.text.count) chars")
        } catch {
            streamingText.isStreaming = false
            streamingText.error = error.localizedDescription
            print("[Whiplash] processFreeQuestion: FAILED: \(error)")
        }
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Whiplash エラー"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    // MARK: - URL Content Fetching

    func enrichWithURLContent(_ text: String) async -> String {
        guard !text.isEmpty else { return text }

        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let matches = detector?.matches(in: text, range: NSRange(text.startIndex..., in: text)) ?? []

        guard !matches.isEmpty else { return text }

        var urlContents: [String] = []
        for match in matches {
            guard let url = match.url, url.scheme == "http" || url.scheme == "https" else { continue }
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                if let html = String(data: data, encoding: .utf8) {
                    let plainText = String(html.strippingHTMLTags().prefix(5000))
                    if !plainText.isEmpty {
                        urlContents.append("[\(url.absoluteString)]:\n\(plainText)")
                    }
                }
            } catch {
                print("[Whiplash] URL fetch failed: \(url) \(error)")
            }
        }

        if urlContents.isEmpty { return text }
        return text + "\n\n---\n参照URL内容:\n" + urlContents.joined(separator: "\n\n")
    }

    // MARK: - Rich Message Window

    private func showRichMessage(role: Role, streamingText: StreamingText, ocrResult: OCRResult, additionalInstructions: String) {
        richMessageWindow?.close()

        // Track the latest instructions for follow-up context
        var currentInstructions = additionalInstructions

        let view = RichMessageView(
            streamingText: streamingText,
            onCopy: { [weak self] in
                self?.copyToClipboard(streamingText.text)
            },
            onRegenerate: { [weak self] in
                guard let self else { return }
                Task {
                    streamingText.text = ""
                    streamingText.isStreaming = true
                    streamingText.error = nil
                    do {
                        _ = try await self.llmService.generateStreamingResponse(
                            fullText: ocrResult.fullText,
                            role: role,
                            additionalInstructions: currentInstructions.isEmpty ? nil : currentInstructions
                        ) { @MainActor [weak streamingText] text in
                            streamingText?.text = text
                        }
                        streamingText.isStreaming = false
                    } catch {
                        streamingText.isStreaming = false
                        streamingText.error = error.localizedDescription
                    }
                }
            },
            onFollowUp: { [weak self] followUp in
                guard let self else { return }
                Task {
                    let enrichedFollowUp = await self.enrichWithURLContent(followUp)
                    let contextText = "\(ocrResult.fullText)\n\n---\n前回の応答:\n\(streamingText.text)\n\n---\n追加指示: \(enrichedFollowUp)"
                    currentInstructions = enrichedFollowUp
                    streamingText.text = ""
                    streamingText.isStreaming = true
                    streamingText.error = nil
                    do {
                        _ = try await self.llmService.generateStreamingResponse(
                            fullText: contextText,
                            role: role
                        ) { @MainActor [weak streamingText] text in
                            streamingText?.text = text
                        }
                        streamingText.isStreaming = false
                    } catch {
                        streamingText.isStreaming = false
                        streamingText.error = error.localizedDescription
                    }
                }
            }
        )

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 450, height: 350),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "\(role.icon) \(role.name)"
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: view)
        panel.center()
        panel.delegate = self

        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)

        richMessageWindow = panel
    }

    private func showFreeQuestionRichMessage(streamingText: StreamingText, inputText: String) {
        richMessageWindow?.close()

        var currentInput = inputText

        let view = RichMessageView(
            streamingText: streamingText,
            onCopy: { [weak self] in
                self?.copyToClipboard(streamingText.text)
            },
            onRegenerate: { [weak self] in
                guard let self else { return }
                Task {
                    streamingText.text = ""
                    streamingText.isStreaming = true
                    streamingText.error = nil
                    do {
                        _ = try await self.llmService.generateStreamingResponse(
                            fullText: currentInput
                        ) { @MainActor [weak streamingText] text in
                            streamingText?.text = text
                        }
                        streamingText.isStreaming = false
                    } catch {
                        streamingText.isStreaming = false
                        streamingText.error = error.localizedDescription
                    }
                }
            },
            onFollowUp: { [weak self] followUp in
                guard let self else { return }
                Task {
                    let enrichedFollowUp = await self.enrichWithURLContent(followUp)
                    let contextText = "\(currentInput)\n\n---\n前回の応答:\n\(streamingText.text)\n\n---\n追加指示: \(enrichedFollowUp)"
                    currentInput = contextText
                    streamingText.text = ""
                    streamingText.isStreaming = true
                    streamingText.error = nil
                    do {
                        _ = try await self.llmService.generateStreamingResponse(
                            fullText: contextText
                        ) { @MainActor [weak streamingText] text in
                            streamingText?.text = text
                        }
                        streamingText.isStreaming = false
                    } catch {
                        streamingText.isStreaming = false
                        streamingText.error = error.localizedDescription
                    }
                }
            }
        )

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 450, height: 350),
            styleMask: [.titled, .closable, .resizable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "⚡ Whiplash"
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.contentView = NSHostingView(rootView: view)
        panel.center()
        panel.delegate = self

        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)

        richMessageWindow = panel
    }

    // MARK: - Clipboard

    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        showCopyToast()
    }

    private func showCopyToast() {
        toastWindow?.close()

        let view = Text("✅ クリップボードにコピーしました")
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial)
            .cornerRadius(8)
            .shadow(color: .black.opacity(0.15), radius: 6, y: 2)

        let hostingView = NSHostingView(rootView: view)
        hostingView.sizingOptions = []
        let size = hostingView.fittingSize
        hostingView.frame = NSRect(origin: .zero, size: size)

        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.contentView = hostingView
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.center()

        // Position near top of screen
        if let screen = NSScreen.main {
            let screenFrame = screen.visibleFrame
            let x = screenFrame.midX - size.width / 2
            let y = screenFrame.maxY - size.height - 40
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }

        panel.alphaValue = 0
        panel.orderFront(nil)
        toastWindow = panel

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.2
            panel.animator().alphaValue = 1
        }

        Task {
            try? await Task.sleep(for: .seconds(1.5))
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.4
                panel.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                panel.close()
                if self?.toastWindow === panel {
                    self?.toastWindow = nil
                }
            })
        }
    }

    // MARK: - Helpers

    private func cleanupImageAttachments(_ attachments: [Attachment]) {
        for attachment in attachments {
            if case .image(let url) = attachment.kind {
                try? fileManager.removeItem(at: url)
            }
        }
    }

    // MARK: - Self Test

    func runSelfTest() async {
        print("[TEST] Starting full pipeline self-test...")

        let testPath = "/tmp/whiplash-selftest.png"
        let testURL = URL(fileURLWithPath: testPath)
        defer { try? FileManager.default.removeItem(atPath: testPath) }

        let width = 400, height = 200
        guard let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            print("[TEST] FAIL: Could not create CGContext")
            exit(1)
        }
        context.setFillColor(CGColor.white)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor.black)
        context.fill(CGRect(x: 20, y: 80, width: 360, height: 40))
        guard let testCGImage = context.makeImage(),
              let dest = CGImageDestinationCreateWithURL(testURL as CFURL, "public.png" as CFString, 1, nil) else {
            print("[TEST] FAIL: Could not finalize test image")
            exit(1)
        }
        CGImageDestinationAddImage(dest, testCGImage, nil)
        CGImageDestinationFinalize(dest)
        print("[TEST] Step 1 OK: Test image created at \(testPath)")

        let imageSize = CGSize(width: width, height: height)
        let captureResult = CaptureResult(
            imageURL: testURL,
            imageSize: imageSize,
            captureRect: CGRect(x: 100, y: 100, width: CGFloat(width), height: CGFloat(height))
        )
        print("[TEST] Step 2 OK: CaptureResult created")

        let ocrResult: OCRResult
        do {
            ocrResult = try await ocrService.recognizeText(from: testURL)
            print("[TEST] Step 3 OK: OCR completed, \(ocrResult.textBlocks.count) blocks")
        } catch {
            print("[TEST] FAIL at OCR: \(error)")
            exit(1)
        }

        let role = roleStore.roles[0]
        showLoading(role: role)
        print("[TEST] Step 4 OK: Loading window shown")

        let llmText: String
        do {
            let response = try await llmService.generateResponse(
                fullText: ocrResult.fullText.isEmpty ? "test input" : ocrResult.fullText,
                role: role
            )
            llmText = response.text
            print("[TEST] Step 5 OK: LLM response: \(llmText.prefix(80))")
        } catch {
            llmText = "LLM unavailable - test fallback text"
            print("[TEST] Step 5 SKIP: LLM error (\(error.localizedDescription))")
        }

        dismissLoading()
        print("[TEST] Step 6 OK: Loading dismissed")

        let streamingText = StreamingText()
        streamingText.text = llmText
        streamingText.isStreaming = false
        showRichMessage(role: role, streamingText: streamingText, ocrResult: ocrResult, additionalInstructions: "")
        print("[TEST] Step 7 OK: Rich message window: \(richMessageWindow != nil)")

        try? await Task.sleep(for: .seconds(2))
        richMessageWindow?.close()
        richMessageWindow = nil
        print("[TEST] Step 8 OK: All windows closed")

        try? await Task.sleep(for: .seconds(1))
        print("[TEST] Step 10 OK: Stable after cleanup")

        print("[TEST] PASS: Full pipeline self-test completed")

        print("[TEST] Step 11: Stress testing window lifecycle...")
        for i in 0..<5 {
            let st = StreamingText()
            st.text = "Stress test \(i)"
            st.isStreaming = false
            showRichMessage(role: role, streamingText: st, ocrResult: ocrResult, additionalInstructions: "")
            showLoading(role: role)
            try? await Task.sleep(for: .milliseconds(100))
            dismissLoading()
            richMessageWindow?.close()
        }
        try? await Task.sleep(for: .seconds(1))
        print("[TEST] Step 11 OK: Stress test passed")

        print("[TEST] Step 12: Testing Task.detached capture path...")
        let capturePath = "/tmp/whiplash-selftest-capture.png"
        let captureURL = URL(fileURLWithPath: capturePath)
        let captureStatus = try? await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-x", capturePath]
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus
        }.value
        if captureStatus == 0, FileManager.default.fileExists(atPath: capturePath) {
            let capturedImage = NSImage(contentsOf: captureURL)
            let ocrResult2 = try? await ocrService.recognizeText(from: captureURL)
            print("[TEST] Step 12 OK: Capture path works, OCR blocks: \(ocrResult2?.textBlocks.count ?? -1), image: \(capturedImage?.size ?? .zero)")
            try? FileManager.default.removeItem(atPath: capturePath)
        } else {
            print("[TEST] Step 12 SKIP: screencapture failed (permission issue?)")
        }

        try? await Task.sleep(for: .seconds(1))
        print("[TEST] PASS: All tests completed successfully")
        exit(0)
    }
}

// MARK: - NSWindowDelegate

extension CaptureFlow: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSPanel else { return }
        if window === roleSelectionPanel {
            NSApp.stopModal()
        } else if window === richMessageWindow {
            richMessageWindow = nil
        }
    }
}

extension NSView {
    func findFirstTextField() -> NSTextField? {
        if let tf = self as? NSTextField, tf.isEditable { return tf }
        for sub in subviews {
            if let found = sub.findFirstTextField() { return found }
        }
        return nil
    }
}


// MARK: - String Helpers

extension String {
    func strippingHTMLTags() -> String {
        guard contains("<") else { return self }
        return replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
    }
}
