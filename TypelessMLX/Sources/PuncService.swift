import Foundation
import CSherpaOnnx

/// Wraps the sherpa-onnx offline CT-Punc model for punctuation restoration.
/// The model is lazy-loaded on first use and held for the lifetime of the process.
final class PuncService {
    static let shared = PuncService()
    private init() {}

    private var handle: OpaquePointer?
    private var loadAttempted = false
    private let lock = NSLock()

    private static let modelPath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.cache/sherpa-onnx/" +
            "sherpa-onnx-punct-ct-transformer-zh-en-vocab272727-2024-04-12-int8/model.int8.onnx"
    }()

    /// Returns the loaded handle, loading on first call. Thread-safe.
    private func getHandle() -> OpaquePointer? {
        lock.lock()
        defer { lock.unlock() }
        guard !loadAttempted else { return handle }
        loadAttempted = true

        let path = PuncService.modelPath
        guard FileManager.default.fileExists(atPath: path) else {
            logWarn("PuncService", "CT-Punc model not found at \(path); punctuation disabled")
            return nil
        }

        path.withCString { ctPath in
            "cpu".withCString { cpuStr in
                let modelCfg = SherpaOnnxOfflinePunctuationModelConfig(
                    ct_transformer: ctPath,
                    num_threads: 1,
                    debug: 0,
                    provider: cpuStr
                )
                var cfg = SherpaOnnxOfflinePunctuationConfig(model: modelCfg)
                handle = SherpaOnnxCreateOfflinePunctuation(&cfg)
            }
        }

        if handle != nil {
            logInfo("PuncService", "CT-Punc model loaded from \(path)")
        } else {
            logWarn("PuncService", "SherpaOnnxCreateOfflinePunctuation returned nil")
        }
        return handle
    }

    /// Adds punctuation to `text`. Returns `text` unchanged if the model is unavailable.
    func restore(_ text: String) -> String {
        guard !text.isEmpty, let h = getHandle() else { return text }
        guard let raw = SherpaOfflinePunctuationAddPunct(h, text) else { return text }
        let out = String(cString: raw)
        SherpaOfflinePunctuationFreeText(raw)
        return out
    }

    deinit {
        if let h = handle {
            SherpaOnnxDestroyOfflinePunctuation(h)
        }
    }
}
