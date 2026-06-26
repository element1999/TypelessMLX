import AVFoundation
import Foundation
import Qwen3ASR

/// Manages Qwen3ASR on-device transcription.
///
/// - `transcribe(url:language:)` — for voice dictation (WAV file from AudioTapFileWriter)
/// - `transcribe(audio:sampleRate:language:)` — for subtitle streaming (raw [Float] from SCStream)
///
/// The `Qwen3ASRModel` instance is loaded lazily on first call and reloaded
/// if `AppState.resolvedModelPath` changes.
actor ASRService {
    static let shared = ASRService()

    private var model: Qwen3ASRModel?
    private var loadTask: Task<Qwen3ASRModel, Error>?
    private var currentModelPath: String = ""

    private init() {}

    // MARK: - Public API

    /// Transcribes the WAV file at `url`. For voice dictation via HotkeyManager.
    func transcribe(url: URL, language: String? = nil) async throws -> String {
        let (samples, sampleRate) = try loadAudio(from: url)
        return try await transcribe(audio: samples, sampleRate: sampleRate, language: language)
    }

    /// Transcribes raw PCM samples. For subtitle streaming via MeetingCaptureEngine.
    func transcribe(audio: [Float], sampleRate: Int = 16000, language: String? = nil) async throws -> String {
        let modelPath = resolveModelPath(await MainActor.run { AppState.shared.resolvedModelPath })
        let m = try await loadedModel(modelPath: modelPath)
        let lang = (language?.isEmpty == false && language != "auto") ? language : nil
        // transcribe() is synchronous and GPU-intensive — run off the cooperative thread pool.
        return try await Task.detached(priority: .userInitiated) {
            m.transcribe(audio: audio, sampleRate: sampleRate, language: lang)
        }.value
    }

    /// Releases the loaded model.
    func stop() {
        model = nil
        loadTask?.cancel()
        loadTask = nil
        currentModelPath = ""
        logInfo("ASRService", "ASRService stopped")
    }

    // MARK: - Model Lifecycle

    private func loadedModel(modelPath: String) async throws -> Qwen3ASRModel {
        if let m = model, currentModelPath == modelPath { return m }
        if let t = loadTask, currentModelPath == modelPath { return try await t.value }

        loadTask?.cancel()
        currentModelPath = modelPath

        let t = Task<Qwen3ASRModel, Error> { [weak self] in
            guard let self else { throw CancellationError() }
            let m = try await self.buildModel(modelPath: modelPath)
            await self.storeModel(m, path: modelPath)
            return m
        }
        loadTask = t
        return try await t.value
    }

    private func storeModel(_ m: Qwen3ASRModel, path: String) {
        model = m
        loadTask = nil
        currentModelPath = path
        logInfo("ASRService", "Qwen3ASR model ready: \(path.split(separator: "/").last ?? Substring(path))")
    }

    private func buildModel(modelPath: String) async throws -> Qwen3ASRModel {
        logInfo("ASRService", "Loading Qwen3ASR model: \(modelPath)")
        // Absolute snapshot path (already on disk) — load offline.
        if modelPath.hasPrefix("/"), FileManager.default.fileExists(atPath: modelPath) {
            let cacheDir = URL(fileURLWithPath: modelPath)
            return try await Qwen3ASRModel.fromPretrained(
                modelId: modelPath,
                cacheDir: cacheDir,
                offlineMode: true
            ) { progress, status in
                logDebug("ASRService", "Load \(Int(progress * 100))% \(status)")
            }
        }
        // HF repo ID — download to speech-swift's own cache.
        let repoId = modelPath.isEmpty ? "mlx-community/Qwen3-ASR-0.6B-8bit" : modelPath
        return try await Qwen3ASRModel.fromPretrained(modelId: repoId) { progress, status in
            logDebug("ASRService", "Download \(Int(progress * 100))% \(status)")
        }
    }

    // MARK: - Helpers

    /// Loads a WAV file produced by AudioTapFileWriter into Float32 samples.
    /// Uses AVAudioFile so any format/sample-rate written by the tap works.
    private func loadAudio(from url: URL) throws -> (samples: [Float], sampleRate: Int) {
        let file = try AVAudioFile(forReading: url)
        let srcFormat = file.processingFormat
        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: srcFormat.sampleRate,
            channels: 1,
            interleaved: false
        )!

        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0 else { return ([], Int(srcFormat.sampleRate)) }

        if srcFormat.channelCount == 1 && srcFormat.commonFormat == .pcmFormatFloat32 {
            let buf = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: frameCount)!
            try file.read(into: buf)
            let count = Int(buf.frameLength)
            let ptr = buf.floatChannelData![0]
            return (Array(UnsafeBufferPointer(start: ptr, count: count)), Int(srcFormat.sampleRate))
        }

        // Convert format (stereo → mono, int16 → float32, etc.)
        let srcBuf = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: frameCount)!
        try file.read(into: srcBuf)

        guard let converter = AVAudioConverter(from: srcFormat, to: targetFormat) else {
            throw NSError(domain: "ASRService", code: -10,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot create audio converter"])
        }
        let outCount = AVAudioFrameCount(
            Double(srcBuf.frameLength) * targetFormat.sampleRate / srcFormat.sampleRate
        ) + 1
        let outBuf = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCount)!
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

    /// Resolves an HF repo ID to the local HF cache snapshot path.
    /// Returns the input unchanged if already absolute or no snapshot found.
    private func resolveModelPath(_ modelPath: String) -> String {
        guard !modelPath.hasPrefix("/") else { return modelPath }
        let sanitized = modelPath.replacingOccurrences(of: "/", with: "--")
        let cacheBase = (NSHomeDirectory() as NSString)
            .appendingPathComponent(".cache/huggingface/hub/models--\(sanitized)/snapshots")
        let snapshots = (try? FileManager.default.contentsOfDirectory(atPath: cacheBase)) ?? []
        if let snapshot = snapshots.sorted().last {
            return (cacheBase as NSString).appendingPathComponent(snapshot)
        }
        return modelPath
    }
}
