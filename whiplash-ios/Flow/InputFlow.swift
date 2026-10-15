import SwiftUI
import Photos
import WhiplashCore
import Observation

@Observable
@MainActor
final class InputFlow {
    var attachments: [Attachment] = []
    var isProcessing = false
    var hasNewClipboard = false
    private let ocrService = OCRService()
    private var lastCheckedScreenshotId: String?
    private var lastSeenChangeCount: Int = UIPasteboard.general.changeCount

    var hasContent: Bool {
        !attachments.isEmpty
    }

    func pickUpContext() {
        pickUpRecentScreenshot()
        checkClipboardChange()
    }

    private func checkClipboardChange() {
        let current = UIPasteboard.general.changeCount
        if current != lastSeenChangeCount {
            lastSeenChangeCount = current
            let pb = UIPasteboard.general
            hasNewClipboard = pb.hasStrings || pb.hasImages
        }
    }

    func clipboardConsumed() {
        hasNewClipboard = false
    }

    func pasteFromClipboard() {
        if let text = UIPasteboard.general.string, !text.isEmpty {
            addTextAttachment(text)
        }
    }

    private func pickUpRecentScreenshot() {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else {
            if status == .notDetermined {
                Task {
                    let newStatus = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
                    if newStatus == .authorized || newStatus == .limited {
                        pickUpRecentScreenshot()
                    }
                }
            }
            return
        }

        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = 1
        let result = PHAsset.fetchAssets(with: .image, options: options)
        guard let asset = result.firstObject,
              let creationDate = asset.creationDate,
              Date().timeIntervalSince(creationDate) < 60,
              asset.localIdentifier != lastCheckedScreenshotId else {
            return
        }

        lastCheckedScreenshotId = asset.localIdentifier
        loadScreenshot(asset: asset)
    }

    private func loadScreenshot(asset: PHAsset) {
        let imageManager = PHImageManager.default()
        let options = PHImageRequestOptions()
        options.isSynchronous = false
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true

        imageManager.requestImage(
            for: asset,
            targetSize: PHImageManagerMaximumSize,
            contentMode: .default,
            options: options
        ) { [weak self] image, _ in
            guard let self, let image else { return }
            Task { @MainActor in
                self.addImageAttachment(image)
            }
        }
    }

    func addImageAttachment(_ image: UIImage) {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("whiplash-ios-\(UUID().uuidString).png")
        guard let data = image.pngData() else { return }
        do {
            try data.write(to: tempURL)
            let attachment = Attachment(kind: .image(tempURL))
            if !attachments.contains(where: { if case .image = $0.kind { return true } else { return false } }) {
                attachments.insert(attachment, at: 0)
            }
        } catch {
            print("[Whiplash iOS] Failed to save screenshot: \(error)")
        }
    }

    func addTextAttachment(_ text: String) {
        guard !text.isEmpty else { return }
        attachments.append(Attachment(kind: .text(text)))
    }

    func removeAttachment(_ attachment: Attachment) {
        if case .image(let url) = attachment.kind {
            try? FileManager.default.removeItem(at: url)
        }
        attachments.removeAll { $0.id == attachment.id }
    }

    func clearAttachments() {
        for attachment in attachments {
            if case .image(let url) = attachment.kind {
                try? FileManager.default.removeItem(at: url)
            }
        }
        attachments.removeAll()
        lastCheckedScreenshotId = nil
    }

    private var lastInputText: String = ""
    private var lastImageData: [(Data, String)] = []
    private var lastRole: Role?
    private var lastAdditionalInstructions: String = ""
    private var lastSettingsStore: SettingsStore?
    private var lastResponseText: String = ""

    func processWithRole(
        _ role: Role,
        additionalInstructions: String,
        settingsStore: SettingsStore
    ) async -> StreamingResult {
        isProcessing = true
        defer { isProcessing = false }

        let input = await gatherInput(imageInputMode: role.imageInputMode)
        lastInputText = input.text
        lastImageData = input.imageData
        lastRole = role
        lastAdditionalInstructions = additionalInstructions
        lastSettingsStore = settingsStore

        return startStreaming(
            fullText: input.text,
            imageData: input.imageData.isEmpty ? nil : input.imageData,
            role: role,
            additionalInstructions: additionalInstructions,
            settingsStore: settingsStore
        )
    }

    func processFreeQuestion(
        _ question: String,
        settingsStore: SettingsStore
    ) async -> StreamingResult {
        isProcessing = true
        defer { isProcessing = false }

        let input = await gatherInput(imageInputMode: .image)
        let inputText = input.text.isEmpty ? question : "\(input.text)\n\n---\n\(question)"
        lastInputText = inputText
        lastImageData = input.imageData
        lastRole = nil
        lastAdditionalInstructions = ""
        lastSettingsStore = settingsStore

        return startStreaming(
            fullText: inputText,
            imageData: input.imageData.isEmpty ? nil : input.imageData,
            settingsStore: settingsStore
        )
    }

    func regenerate() -> StreamingResult? {
        guard let settingsStore = lastSettingsStore else { return nil }
        return startStreaming(
            fullText: lastInputText,
            imageData: lastImageData.isEmpty ? nil : lastImageData,
            role: lastRole,
            additionalInstructions: lastAdditionalInstructions,
            settingsStore: settingsStore
        )
    }

    func followUp(_ text: String, previousResponse: String) -> StreamingResult? {
        guard let settingsStore = lastSettingsStore else { return nil }
        let contextText = "\(lastInputText)\n\n---\n前回の応答:\n\(previousResponse)\n\n---\n追加指示: \(text)"
        lastAdditionalInstructions = text
        return startStreaming(
            fullText: contextText,
            role: lastRole,
            settingsStore: settingsStore
        )
    }

    private func startStreaming(
        fullText: String,
        imageData: [(Data, String)]? = nil,
        role: Role? = nil,
        additionalInstructions: String = "",
        settingsStore: SettingsStore
    ) -> StreamingResult {
        let llmService = LLMService(settingsStore: settingsStore)
        let result = StreamingResult()

        Task {
            do {
                let response: LLMResponse
                if let role {
                    response = try await llmService.generateStreamingResponse(
                        fullText: fullText,
                        role: role,
                        additionalInstructions: additionalInstructions.isEmpty ? nil : additionalInstructions,
                        imageData: imageData
                    ) { @MainActor text in
                        result.text = text
                    }
                } else {
                    response = try await llmService.generateStreamingResponse(
                        fullText: fullText,
                        imageData: imageData
                    ) { @MainActor text in
                        result.text = text
                    }
                }
                result.isStreaming = false
                lastResponseText = response.text
            } catch {
                result.isStreaming = false
                result.error = error.localizedDescription
            }
        }

        return result
    }

    struct GatheredInput {
        var text: String
        var imageData: [(Data, String)]
    }

    private func gatherInput(imageInputMode: ImageInputMode = .image) async -> GatheredInput {
        var parts: [String] = []
        var images: [(Data, String)] = []
        for attachment in attachments {
            switch attachment.kind {
            case .text(let text):
                parts.append(text)
            case .image(let url):
                if imageInputMode == .image, let data = try? Data(contentsOf: url) {
                    let mimeType = url.pathExtension == "png" ? "image/png" : "image/jpeg"
                    images.append((data, mimeType))
                } else {
                    do {
                        let ocr = try await ocrService.recognizeText(from: url)
                        if !ocr.fullText.isEmpty {
                            parts.append(ocr.fullText)
                        }
                    } catch {
                        print("[Whiplash iOS] OCR failed: \(error)")
                    }
                }
            }
        }
        return GatheredInput(text: parts.joined(separator: "\n\n"), imageData: images)
    }
}

@Observable
@MainActor
final class StreamingResult {
    var text: String = ""
    var isStreaming: Bool = true
    var error: String?

    var thinkingText: String? {
        guard let start = text.range(of: "<thinking>"),
              let end = text.range(of: "</thinking>") else { return nil }
        return String(text[start.upperBound..<end.lowerBound])
    }

    var responseText: String {
        guard let end = text.range(of: "</thinking>") else {
            if text.hasPrefix("<thinking>") { return "" }
            return text
        }
        return text[end.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
