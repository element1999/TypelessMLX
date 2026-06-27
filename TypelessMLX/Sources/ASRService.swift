import AVFoundation
import Foundation
import MLX
import Qwen3ASR

/// Manages Qwen3ASR on-device transcription.
///
/// - `transcribe(url:language:)` — for voice dictation (WAV file from AudioTapFileWriter)
/// - `transcribe(audio:sampleRate:language:)` — for subtitle streaming (raw [Float] from SCStream)
actor ASRService {
    static let shared = ASRService()

    private var model: Qwen3ASRModel?
    private var loadTask: Task<Qwen3ASRModel, Error>?
    private var currentModelKey: String = ""

    private init() {}

    // MARK: - Public API

    /// Transcribes the WAV file at `url`. For voice dictation via HotkeyManager.
    func transcribe(url: URL, language: String? = nil) async throws -> String {
        let (samples, sampleRate) = try loadAudio(from: url)
        let request = await dictationModelRequest()
        return try await transcribe(audio: samples, sampleRate: sampleRate, language: language, request: request)
    }

    /// Transcribes raw PCM samples. For subtitle streaming via MeetingCaptureEngine.
    func transcribe(audio: [Float], sampleRate: Int = 16000, language: String? = nil) async throws -> String {
        let request = subtitleModelRequest()
        return try await transcribe(audio: audio, sampleRate: sampleRate, language: language, request: request)
    }

    private func transcribe(
        audio: [Float],
        sampleRate: Int,
        language: String?,
        request: ModelLoadRequest
    ) async throws -> String {
        let loaded = try await loadedModel(
            modelKey: request.modelKey,
            requestedModelId: request.requestedModelId,
            localSnapshotPath: request.localSnapshotPath
        )
        let lang = (language?.isEmpty == false && language != "auto") ? language : nil
        let device = preferredMLXDevice()
        // transcribe() is synchronous and GPU-intensive — run off the cooperative thread pool.
        return await Task.detached(priority: .userInitiated) {
            Device.withDefaultDevice(device) {
                loaded.transcribe(audio: audio, sampleRate: sampleRate, language: lang)
            }
        }.value
    }

    private struct ModelLoadRequest {
        let requestedModelId: String
        let localSnapshotPath: String?
        let modelKey: String
    }

    private func dictationModelRequest() async -> ModelLoadRequest {
        let selectedModel = await MainActor.run { AppState.shared.selectedModel }
        let requestedModelId = selectedModel.repoOrPath
        let localSnapshotPath = resolveLocalSnapshotPath(requestedModelId)
        return ModelLoadRequest(
            requestedModelId: requestedModelId,
            localSnapshotPath: localSnapshotPath,
            modelKey: localSnapshotPath ?? requestedModelId
        )
    }

    private func subtitleModelRequest() -> ModelLoadRequest {
        let fallbackRepo = "mlx-community/Qwen3-ASR-0.6B-8bit"
        guard let subtitleModel = AppState.availableModels.first(where: { $0.id == "qwen3-asr-0.6b" }) else {
            let localSnapshotPath = resolveLocalSnapshotPath(fallbackRepo)
            return ModelLoadRequest(
                requestedModelId: fallbackRepo,
                localSnapshotPath: localSnapshotPath,
                modelKey: localSnapshotPath ?? fallbackRepo
            )
        }

        let requestedModelId = AppState.bundledModelPath(for: subtitleModel) ?? subtitleModel.repoOrPath
        let localSnapshotPath = resolveLocalSnapshotPath(requestedModelId)
        return ModelLoadRequest(
            requestedModelId: requestedModelId,
            localSnapshotPath: localSnapshotPath,
            modelKey: localSnapshotPath ?? requestedModelId
        )
    }

    /// Releases the loaded model.
    func stop() {
        model = nil
        loadTask?.cancel()
        loadTask = nil
        currentModelKey = ""
        logInfo("ASRService", "ASRService stopped")
    }

    // MARK: - Model Lifecycle

    private func loadedModel(
        modelKey: String,
        requestedModelId: String,
        localSnapshotPath: String?
    ) async throws -> Qwen3ASRModel {
        if let m = model, currentModelKey == modelKey { return m }
        if let t = loadTask, currentModelKey == modelKey { return try await t.value }

        loadTask?.cancel()
        currentModelKey = modelKey

        let t = Task<Qwen3ASRModel, Error> { [weak self] in
            guard let self else { throw CancellationError() }
            let m = try await self.buildModel(requestedModelId: requestedModelId, localSnapshotPath: localSnapshotPath)
            await self.storeModel(m, key: modelKey)
            return m
        }
        loadTask = t
        return try await t.value
    }

    private func storeModel(_ m: Qwen3ASRModel, key: String) {
        guard currentModelKey == key else {
            logDebug("ASRService", "Discarding stale model load for \(key.split(separator: "/").last ?? Substring(key))")
            return
        }
        model = m
        loadTask = nil
        logInfo("ASRService", "Qwen3ASR model ready: \(key.split(separator: "/").last ?? Substring(key))")
    }

    private func buildModel(requestedModelId: String, localSnapshotPath: String?) async throws -> Qwen3ASRModel {
        let modelId = requestedModelId.isEmpty ? "mlx-community/Qwen3-ASR-0.6B-8bit" : requestedModelId

        if let localSnapshotPath = localSnapshotPath {
            logInfo("ASRService", "Loading Qwen3ASR model (local): \(localSnapshotPath)")
            let cacheDir = URL(fileURLWithPath: localSnapshotPath)
            return try await Device.withDefaultDevice(preferredMLXDevice()) {
                try await Qwen3ASRModel.fromPretrained(
                    modelId: modelId,
                    cacheDir: cacheDir,
                    offlineMode: true
                ) { progress, status in
                    let normalized = status.contains("Downloading") ? "Loading local files..." : status
                    logDebug("ASRService", "Load \(Int(progress * 100))% \(normalized)")
                }
            }
        }

        // HF repo ID — download/cache via speech-swift.
        logInfo("ASRService", "Loading Qwen3ASR model (remote/cache): \(modelId)")
        return try await Device.withDefaultDevice(preferredMLXDevice()) {
            try await Qwen3ASRModel.fromPretrained(modelId: modelId) { progress, status in
                logDebug("ASRService", "Download \(Int(progress * 100))% \(status)")
            }
        }
    }

    // MARK: - Helpers

    /// Loads a WAV file produced by AudioTapFileWriter into Float32 samples.
    /// Uses AVAudioFile so any format/sample-rate written by the tap works.
    private func loadAudio(from url: URL) throws -> (samples: [Float], sampleRate: Int) {
        let file = try AVAudioFile(forReading: url)
        let srcFormat = file.processingFormat
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: srcFormat.sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw NSError(domain: "ASRService", code: -11,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot create target audio format"])
        }

        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0 else { return ([], Int(srcFormat.sampleRate)) }

        if srcFormat.channelCount == 1 && srcFormat.commonFormat == .pcmFormatFloat32 {
            guard let buf = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: frameCount) else {
                throw NSError(domain: "ASRService", code: -12,
                              userInfo: [NSLocalizedDescriptionKey: "Cannot create audio buffer"])
            }
            try file.read(into: buf)
            let count = Int(buf.frameLength)
            let ptr = buf.floatChannelData![0]
            return (Array(UnsafeBufferPointer(start: ptr, count: count)), Int(srcFormat.sampleRate))
        }

        // Convert format (stereo -> mono, int16 -> float32, etc.)
        guard let srcBuf = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: frameCount) else {
            throw NSError(domain: "ASRService", code: -13,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot create audio buffer"])
        }
        try file.read(into: srcBuf)

        guard let converter = AVAudioConverter(from: srcFormat, to: targetFormat) else {
            throw NSError(domain: "ASRService", code: -10,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot create audio converter"])
        }
        let outCount = AVAudioFrameCount(
            Double(srcBuf.frameLength) * targetFormat.sampleRate / srcFormat.sampleRate
        ) + 1
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCount) else {
            throw NSError(domain: "ASRService", code: -14,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot create audio buffer"])
        }
        var convError: NSError?
        var didProvide = false
        converter.convert(to: outBuf, error: &convError) { _, outStatus in
            if didProvide { outStatus.pointee = .noDataNow; return nil }
            outStatus.pointee = .haveData
            didProvide = true
            return srcBuf
        }
        if let e = convError { throw e }

        let count = Int(outBuf.frameLength)
        let ptr = outBuf.floatChannelData![0]
        return (Array(UnsafeBufferPointer(start: ptr, count: count)), Int(targetFormat.sampleRate))
    }

    /// Resolves an HF repo ID to the newest valid local HF snapshot path.
    /// Returns nil if no suitable local snapshot exists.
    private func resolveLocalSnapshotPath(_ modelId: String) -> String? {
        guard !modelId.isEmpty else { return nil }
        guard !modelId.hasPrefix("/") else {
            return FileManager.default.fileExists(atPath: modelId) ? modelId : nil
        }

        let sanitized = modelId.replacingOccurrences(of: "/", with: "--")
        let cacheBase = (NSHomeDirectory() as NSString)
            .appendingPathComponent(".cache/huggingface/hub/models--\(sanitized)/snapshots")
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: cacheBase) else {
            return nil
        }

        let snapshots: [URL] = names.map { name in
            URL(fileURLWithPath: cacheBase).appendingPathComponent(name, isDirectory: true)
        }.filter { isUsableSnapshot($0.path) }

        let newest = snapshots.max { lhs, rhs in
            let lDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let rDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return lDate < rDate
        }
        return newest?.path
    }

    private func isUsableSnapshot(_ path: String) -> Bool {
        let required = ["config.json", "model.safetensors", "tokenizer.json", "vocab.json"]
        return required.allSatisfy { file in
            FileManager.default.fileExists(atPath: (path as NSString).appendingPathComponent(file))
        }
    }

    private func preferredMLXDevice() -> Device {
        hasBundledMLXMetallib() ? .gpu : .cpu
    }

    private func hasBundledMLXMetallib() -> Bool {
        let bundle = Bundle.main
        let candidates = [
            bundle.bundleURL.appendingPathComponent("Contents/MacOS/mlx.metallib"),
            bundle.resourceURL?.appendingPathComponent("mlx.metallib"),
            bundle.resourceURL?.appendingPathComponent("default.metallib"),
        ].compactMap { $0 }
        return candidates.contains { FileManager.default.fileExists(atPath: $0.path) }
    }
}
