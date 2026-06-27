import Foundation
import WhisperKit

/// WhisperKit-backed transcription for Whisper models.
actor WhisperService {
    static let shared = WhisperService()

    private var whisperKit: WhisperKit?
    private var currentVariant: String = ""

    private init() {}

    func transcribe(url: URL, modelID: String, language: String? = nil) async throws -> String {
        let variant = whisperKitVariant(for: modelID)

        if whisperKit == nil || currentVariant != variant {
            try await loadModel(variant: variant)
        }

        guard let wk = whisperKit else {
            throw NSError(domain: "WhisperService", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "WhisperKit not initialized"])
        }

        var options = DecodingOptions()
        if let lang = language, !lang.isEmpty, lang != "auto" {
            options.language = lang
        }

        let results = try await wk.transcribe(audioPath: url.path, decodeOptions: options)
        return results.map { $0.text }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func unload() {
        whisperKit = nil
        currentVariant = ""
    }

    private func loadModel(variant: String) async throws {
        whisperKit = nil

        // Re-enable model prewarm/load so WhisperKit compiles NN graphs during startup.
        let wk = try await WhisperKit(
            model: variant,
            verbose: false,
            logLevel: .error,
            prewarm: true,
            load: true,
            download: true
        )

        whisperKit = wk
        currentVariant = variant
    }

    private func whisperKitVariant(for modelID: String) -> String {
        switch modelID {
        case "whisper-large-v3": return "large-v3"
        case "whisper-medium": return "medium"
        case "whisper-small": return "small"
        default: return "large-v3"
        }
    }
}
