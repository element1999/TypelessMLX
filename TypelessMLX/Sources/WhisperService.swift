import Foundation
import WhisperKit

/// Wraps WhisperKit for on-device CoreML Whisper transcription.
///
/// Usage:
///   let text = try await WhisperService.shared.transcribe(url: wavURL, language: "zh")
///
/// WhisperKit downloads CoreML Whisper models from `argmaxinc/whisperkit-coreml`
/// into the standard HF cache. The model variant is derived from AppState's
/// resolvedModelPath (e.g., "mlx-community/whisper-large-v3-mlx" → "large-v3").
actor WhisperService {
    static let shared = WhisperService()

    private var whisperKit: WhisperKit?
    private var currentModelPath: String = ""

    private init() {}

    // MARK: - Public API

    /// Transcribes the WAV file at `url`.
    /// Lazily loads WhisperKit on first call; reloads when the resolved model path changes.
    func transcribe(url: URL, language: String? = nil) async throws -> String {
        let modelPath = await MainActor.run { AppState.shared.resolvedModelPath }

        if whisperKit == nil || currentModelPath != modelPath {
            try await loadModel(modelPath: modelPath)
        }

        guard let wk = whisperKit else {
            throw NSError(domain: "WhisperService", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "WhisperKit not initialised"])
        }

        let variant = whisperKitVariant(for: modelPath)
        logInfo("WhisperService", "Transcribing \(url.lastPathComponent) with variant '\(variant)'")

        var options = DecodingOptions()
        if let lang = language, !lang.isEmpty, lang != "auto" {
            options.language = lang
        }

        let results = try await wk.transcribe(audioPath: url.path, decodeOptions: options)
        let text = results.map { $0.text }.joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)

        logInfo("WhisperService", "Transcription (\(text.count) chars): \(text.prefix(80))")
        return text
    }

    /// Releases the WhisperKit instance and frees model memory.
    func unload() {
        whisperKit = nil
        currentModelPath = ""
        logInfo("WhisperService", "WhisperKit unloaded")
    }

    // MARK: - Model Loading

    private func loadModel(modelPath: String) async throws {
        // Release previous instance before loading a new one
        whisperKit = nil

        let variant = whisperKitVariant(for: modelPath)
        logInfo("WhisperService", "Loading WhisperKit variant '\(variant)' (resolvedModelPath: \(modelPath))")

        do {
            let wk = try await WhisperKit(
                model: variant,
                verbose: false,
                logLevel: .error,
                prewarm: false,
                load: true,
                download: true
            )
            whisperKit = wk
            currentModelPath = modelPath
            logInfo("WhisperService", "WhisperKit ready (variant: \(variant))")
        } catch {
            logError("WhisperService", "Failed to load WhisperKit variant '\(variant)': \(error)")
            throw error
        }
    }

    // MARK: - Model Variant Resolution

    /// Maps an AppState resolvedModelPath to a WhisperKit variant name.
    ///
    /// AppState returns paths/IDs such as:
    ///   - "mlx-community/whisper-large-v3-mlx"   → "large-v3"
    ///   - "mlx-community/whisper-medium-mlx"      → "medium"
    ///   - "mlx-community/whisper-small-mlx"       → "small"
    ///   - "/path/to/bundled/whisper-large-v3"     → "large-v3"
    ///
    /// Falls back to "large-v3" for unrecognised strings.
    private func whisperKitVariant(for modelPath: String) -> String {
        let lower = modelPath.lowercased()
        if lower.contains("large-v3") { return "large-v3" }
        if lower.contains("large-v2") { return "large-v2" }
        if lower.contains("large")    { return "large" }
        if lower.contains("medium")   { return "medium" }
        if lower.contains("small")    { return "small" }
        if lower.contains("base")     { return "base" }
        if lower.contains("tiny")     { return "tiny" }
        logWarn("WhisperService", "Cannot derive variant from '\(modelPath)', defaulting to large-v3")
        return "large-v3"
    }
}
