import SwiftUI
import Photos
import WhiplashCore
import Observation

@Observable
@MainActor
final class InputFlow {
    var attachments: [Attachment] = []
    var isProcessing = false
    var sceneIsActive = false

    private let ocrService = OCRService()
    private var lastCheckedScreenshotId: String?

    func checkForRecentScreenshot() {
        sceneIsActive = true

        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else {
            if status == .notDetermined {
                Task {
                    let newStatus = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
                    if newStatus == .authorized || newStatus == .limited {
                        checkForRecentScreenshot()
                    }
                }
            }
            return
        }

        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = 1
        options.predicate = NSPredicate(format: "(mediaSubtype & %d) != 0", PHAssetMediaSubtype.photoScreenshot.rawValue)

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

    private func addImageAttachment(_ image: UIImage) {
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

    func processWithRole(
        _ role: Role,
        additionalInstructions: String,
        settingsStore: SettingsStore
    ) async -> StreamingResult {
        isProcessing = true
        defer { isProcessing = false }

        let ocrText = await gatherText()
        let llmService = LLMService(settingsStore: settingsStore)
        let result = StreamingResult()

        Task {
            do {
                _ = try await llmService.generateStreamingResponse(
                    fullText: ocrText,
                    role: role,
                    additionalInstructions: additionalInstructions.isEmpty ? nil : additionalInstructions
                ) { @MainActor text in
                    result.text = text
                }
                result.isStreaming = false
            } catch {
                result.isStreaming = false
                result.error = error.localizedDescription
            }
        }

        return result
    }

    func processFreeQuestion(
        _ question: String,
        settingsStore: SettingsStore
    ) async -> StreamingResult {
        isProcessing = true
        defer { isProcessing = false }

        let ocrText = await gatherText()
        let inputText = ocrText.isEmpty ? question : "\(ocrText)\n\n---\n\(question)"
        let llmService = LLMService(settingsStore: settingsStore)
        let result = StreamingResult()

        Task {
            do {
                _ = try await llmService.generateStreamingResponse(
                    fullText: inputText
                ) { @MainActor text in
                    result.text = text
                }
                result.isStreaming = false
            } catch {
                result.isStreaming = false
                result.error = error.localizedDescription
            }
        }

        return result
    }

    private func gatherText() async -> String {
        var parts: [String] = []
        for attachment in attachments {
            switch attachment.kind {
            case .text(let text):
                parts.append(text)
            case .image(let url):
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
        return parts.joined(separator: "\n\n")
    }
}

@Observable
@MainActor
final class StreamingResult {
    var text: String = ""
    var isStreaming: Bool = true
    var error: String?
}
