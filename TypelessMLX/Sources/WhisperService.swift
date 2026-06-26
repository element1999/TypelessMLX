import Foundation
import CoreML
import WhisperKit

/// Wraps WhisperKit for on-device CoreML Whisper transcription.
actor WhisperService {
    static let shared = WhisperService()

    private var whisperKit: WhisperKit?
    private var currentModelKey: String = ""

    private init() {}

    // MARK: - Public API

    func transcribe(url: URL, language: String? = nil) async throws -> String {
        let selected = await MainActor.run { AppState.shared.selectedModel }
        guard let variant = AppState.whisperKitVariant(for: selected.id) else {
            throw whisperError("不支持的 WhisperKit 模型：\(selected.id)")
        }

        let modelKey = "\(selected.id):\(variant)"
        if whisperKit == nil || currentModelKey != modelKey {
            try await loadModel(modelID: selected.id, variant: variant)
        }

        guard let wk = whisperKit else {
            throw whisperError("WhisperKit 未初始化")
        }

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

    func unload() {
        whisperKit = nil
        currentModelKey = ""
        logInfo("WhisperService", "WhisperKit unloaded")
    }

    // MARK: - Model Loading

    private func loadModel(modelID: String, variant: String) async throws {
        whisperKit = nil

        guard let modelFolder = resolveLocalWhisperKitModelFolder(variant: variant) else {
            throw whisperError("WhisperKit 模型未安装：\(modelID)。请先安装对应模型包，或在设置中下载。")
        }
        guard let tokenizerBase = resolveBundledTokenizerBase(for: modelID) else {
            throw whisperError("Whisper tokenizer 未内置或不完整：\(modelID)。请重新安装包含 tokenizer 的新版应用。")
        }

        logInfo("WhisperService", "Loading WhisperKit variant '\(variant)' from local folder: \(modelFolder.path)")
        let coreMLFolder = try materializedWhisperKitModelFolder(source: modelFolder, variant: variant)
        logInfo("WhisperService", "Using materialized WhisperKit CoreML folder: \(coreMLFolder.path)")

        do {
            logInfo("WhisperService", "Creating WhisperKit instance (load=false, download=false)")
            let wk = try await WhisperKit(
                model: variant,
                modelFolder: coreMLFolder.path,
                tokenizerFolder: tokenizerBase,
                computeOptions: ModelComputeOptions(
                    melCompute: .cpuAndGPU,
                    audioEncoderCompute: .cpuAndGPU,
                    textDecoderCompute: .cpuAndGPU
                ),
                verbose: false,
                logLevel: .error,
                prewarm: false,
                load: false,
                download: false
            )

            logInfo("WhisperService", "WhisperKit instance created; loading CoreML models...")
            try await wk.loadModels()

            whisperKit = wk
            currentModelKey = "\(modelID):\(variant)"
            logInfo("WhisperService", "WhisperKit ready (variant: \(variant))")
        } catch {
            logError("WhisperService", "Failed to load WhisperKit variant '\(variant)': \(error)")
            throw error
        }
    }

    private func resolveLocalWhisperKitModelFolder(variant: String) -> URL? {
        let repoRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub/models--argmaxinc--whisperkit-coreml/snapshots")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: repoRoot.path) else {
            return nil
        }

        let folders = names.map { repoRoot.appendingPathComponent($0).appendingPathComponent(variant) }
            .filter { isUsableWhisperKitFolder($0) }
        return folders.max { lhs, rhs in
            let lDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let rDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return lDate < rDate
        }
    }

    private func isUsableWhisperKitFolder(_ folder: URL) -> Bool {
        Self.hasWhisperKitCoreMLFiles(in: folder)
    }

    private func materializedWhisperKitModelFolder(source: URL, variant: String) throws -> URL {
        let fm = FileManager.default
        let appSupport = try fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let root = appSupport
            .appendingPathComponent("TypelessMLX", isDirectory: true)
            .appendingPathComponent("WhisperKit", isDirectory: true)
        let destination = root.appendingPathComponent(variant, isDirectory: true)

        if Self.hasWhisperKitCoreMLFiles(in: destination) {
            return destination
        }

        logInfo("WhisperService", "Materializing WhisperKit model files from HF snapshot into app support cache...")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        let temporaryDestination = root.appendingPathComponent(".\(variant).tmp-\(UUID().uuidString)", isDirectory: true)
        if fm.fileExists(atPath: temporaryDestination.path) {
            try fm.removeItem(at: temporaryDestination)
        }

        do {
            try copyMaterializingSymlinks(from: source, to: temporaryDestination)
            guard Self.hasWhisperKitCoreMLFiles(in: temporaryDestination) else {
                throw whisperError("WhisperKit 模型物化后仍不完整：\(variant)")
            }

            if fm.fileExists(atPath: destination.path) {
                try fm.removeItem(at: destination)
            }
            try fm.moveItem(at: temporaryDestination, to: destination)
            logInfo("WhisperService", "Materialized WhisperKit model cache ready: \(destination.path)")
            return destination
        } catch {
            try? fm.removeItem(at: temporaryDestination)
            throw error
        }
    }

    private func copyMaterializingSymlinks(from source: URL, to destination: URL) throws {
        let fm = FileManager.default
        let attributes = try fm.attributesOfItem(atPath: source.path)
        if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
            let target = try fm.destinationOfSymbolicLink(atPath: source.path)
            let resolved = URL(fileURLWithPath: target, relativeTo: source.deletingLastPathComponent()).standardizedFileURL
            try copyMaterializingSymlinks(from: resolved, to: destination)
            return
        }

        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: source.path, isDirectory: &isDirectory) else {
            throw whisperError("WhisperKit 模型文件不存在：\(source.path)")
        }

        if isDirectory.boolValue {
            try fm.createDirectory(at: destination, withIntermediateDirectories: true)
            let children = try fm.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
            for child in children {
                try copyMaterializingSymlinks(
                    from: child,
                    to: destination.appendingPathComponent(child.lastPathComponent, isDirectory: false)
                )
            }
        } else {
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: destination.path) {
                try fm.removeItem(at: destination)
            }
            try fm.copyItem(at: source, to: destination)
        }
    }

    private func resolveBundledTokenizerBase(for modelID: String) -> URL? {
        guard let resourcePath = Bundle.main.resourcePath else { return nil }
        let base = URL(fileURLWithPath: resourcePath)
            .appendingPathComponent("whisper-tokenizers", isDirectory: true)
        guard let folder = bundledTokenizerFolder(for: modelID, base: base) else { return nil }
        let tokenizer = folder.appendingPathComponent("tokenizer.json")
        let config = folder.appendingPathComponent("tokenizer_config.json")
        return FileManager.default.fileExists(atPath: tokenizer.path)
            && FileManager.default.fileExists(atPath: config.path) ? base : nil
    }

    private func bundledTokenizerFolder(for modelID: String, base: URL? = nil) -> URL? {
        guard let subpath = AppState.whisperKitTokenizerResourceSubpath(for: modelID) else { return nil }
        let root: URL
        if let base {
            root = base
        } else if let resourcePath = Bundle.main.resourcePath {
            root = URL(fileURLWithPath: resourcePath).appendingPathComponent("whisper-tokenizers", isDirectory: true)
        } else {
            return nil
        }
        return root.appendingPathComponent(subpath, isDirectory: true)
    }

    static func requiredWhisperKitDownloadFiles(for variant: String) -> [String] {
        var files = ["config.json", "generation_config.json"]

        let compiledModelFiles = [
            "analytics/coremldata.bin",
            "coremldata.bin",
            "metadata.json",
            "model.mil",
            "weights/weight.bin"
        ]
        let components = requiredWhisperKitComponents(for: variant)

        for component in components {
            files.append(contentsOf: compiledModelFiles.map { "\(component).mlmodelc/\($0)" })
        }

        if variant == "openai_whisper-small_216MB" {
            files.append("AudioEncoder.mlmodelc/model.mlmodel")
            files.append("TextDecoder.mlmodelc/model.mlmodel")
        }

        return files
    }

    static func hasWhisperKitCoreMLFiles(in folder: URL) -> Bool {
        let variant = folder.lastPathComponent
        let metadataFiles = ["config.json", "generation_config.json"]
        let hasMetadata = metadataFiles.allSatisfy { file in
            FileManager.default.fileExists(atPath: folder.appendingPathComponent(file).path)
        }

        return hasMetadata && requiredWhisperKitComponents(for: variant).allSatisfy { name in
            let compiled = folder.appendingPathComponent("\(name).mlmodelc")
            let packaged = folder.appendingPathComponent("\(name).mlpackage/Data/com.apple.CoreML/model.mlmodel")
            if FileManager.default.fileExists(atPath: packaged.path) { return true }

            let requiredFiles = [
                "analytics/coremldata.bin",
                "coremldata.bin",
                "metadata.json",
                "model.mil",
                "weights/weight.bin"
            ]
            return FileManager.default.fileExists(atPath: compiled.path)
                && requiredFiles.allSatisfy { relativePath in
                    FileManager.default.fileExists(atPath: compiled.appendingPathComponent(relativePath).path)
                }
        }
    }

    private static func requiredWhisperKitComponents(for variant: String) -> [String] {
        var components = ["MelSpectrogram", "AudioEncoder", "TextDecoder"]
        if variant == "openai_whisper-large-v3-v20240930_turbo_632MB" {
            components.append("TextDecoderContextPrefill")
        }
        return components
    }

    private func whisperError(_ message: String) -> NSError {
        NSError(domain: "WhisperService", code: -1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }
}
