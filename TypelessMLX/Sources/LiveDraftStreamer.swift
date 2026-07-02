import AVFoundation
import Foundation
@preconcurrency import SpeechVAD

final class LiveDraftStreamer {
    static let shared = LiveDraftStreamer()

    private let queue = DispatchQueue(label: "com.typelessmlx.live-draft", qos: .userInitiated)

    private var buffer: [Float] = []
    private var sampleRate: Int = 16000
    private var task: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var lastSampleCount: Int = 0
    private var inFlight = false
    private var forceRequestPending = false
    private var modelType = ""
    private var language: String?
    private var usingVAD = false
    private var processor: StreamingVADProcessor?
    private var speechActive = false
    private var speechBuffer: [Float] = []
    private var rollingBuffer: [Float] = []
    private var lastPartialSampleCount: Int = 0
    private var segmentID: UInt64 = 0
    private var committedSegments: [(id: UInt64, text: String)] = []
    private var currentText = ""
    private var pendingFinalizeSegmentID: UInt64?
    private var pendingFinalizeWorkItem: DispatchWorkItem?
    private var textHandler: ((String) -> Void)?

    private static let fallbackMaxWindowSeconds: Double = 8
    private static let fallbackMinIntervalSeconds: Double = 0.8
    private static let fallbackMinDeltaSeconds: Double = 0.35
    private static let vadSampleRate = 16000
    private static let partialIntervalSeconds: Double = 0.5
    private static let partialMinDeltaSeconds: Double = 0.25
    private static let preSpeechSeconds: Double = 0.6
    private static let maxSegmentSeconds: Double = 8.0
    private static let finalizeDelaySeconds: Double = 2.0

    private init() {}

    func start(modelType: String, language: String?, textHandler: @escaping (String) -> Void) {
        stop(clearText: false)
        queue.sync {
            self.textHandler = textHandler
            buffer.removeAll(keepingCapacity: true)
            sampleRate = 16000
            lastSampleCount = 0
            inFlight = false
            forceRequestPending = false
            self.modelType = modelType
            self.language = language
            usingVAD = modelType == "qwen3"
            processor = nil
            speechActive = false
            speechBuffer.removeAll(keepingCapacity: true)
            rollingBuffer.removeAll(keepingCapacity: true)
            lastPartialSampleCount = 0
            pendingFinalizeWorkItem?.cancel()
            pendingFinalizeWorkItem = nil
            pendingFinalizeSegmentID = nil
            segmentID = 0
            committedSegments.removeAll(keepingCapacity: true)
            currentText = ""
            generation &+= 1
        }

        let currentGeneration = queue.sync { generation }
        if modelType == "qwen3" {
            startQwen3VAD(language: language, generation: currentGeneration)
        } else {
            startFixedWindow(modelType: modelType, language: language, generation: currentGeneration)
        }
    }

    func stop(clearText: Bool = true) {
        task?.cancel()
        task = nil
        queue.sync {
            generation &+= 1
            buffer.removeAll(keepingCapacity: true)
            sampleRate = 16000
            lastSampleCount = 0
            inFlight = false
            forceRequestPending = false
            modelType = ""
            language = nil
            usingVAD = false
            processor = nil
            speechActive = false
            speechBuffer.removeAll(keepingCapacity: true)
            rollingBuffer.removeAll(keepingCapacity: true)
            lastPartialSampleCount = 0
            pendingFinalizeWorkItem?.cancel()
            pendingFinalizeWorkItem = nil
            pendingFinalizeSegmentID = nil
            segmentID = 0
            committedSegments.removeAll(keepingCapacity: true)
            currentText = ""
        }
        if clearText { emit("") }
    }

    func appendBuffer(_ audioBuffer: AVAudioPCMBuffer) {
        let sourceRate = Int(audioBuffer.format.sampleRate.rounded())
        let frameCount = Int(audioBuffer.frameLength)
        let channelCount = Int(audioBuffer.format.channelCount)
        guard sourceRate > 0, frameCount > 0, channelCount > 0,
              let channelData = audioBuffer.floatChannelData else { return }

        var samples = [Float](repeating: 0, count: frameCount)
        if channelCount == 1 {
            samples.withUnsafeMutableBufferPointer { dst in
                guard let base = dst.baseAddress else { return }
                base.update(from: channelData[0], count: frameCount)
            }
        } else {
            let divisor = Float(channelCount)
            for frame in 0..<frameCount {
                var sum: Float = 0
                for channel in 0..<channelCount { sum += channelData[channel][frame] }
                samples[frame] = sum / divisor
            }
        }

        queue.async { [weak self] in
            guard let self else { return }
            if self.usingVAD {
                let resampled = Self.resampleLinear(samples, from: sourceRate, to: Self.vadSampleRate)
                self.appendQwen3VADSamples(resampled)
            } else {
                self.appendFixedWindowSamples(samples, sampleRate: sourceRate)
            }
        }
    }

    private func startQwen3VAD(language: String?, generation: UInt64) {
        guard let sileroCacheDir = bundledSileroVADDirectory() else {
            logError("LiveDraftStreamer", "Bundled Silero VAD not found; falling back to fixed-window live draft")
            AppState.shared.showModelCacheAlert(feature: "实时字幕", modelId: SileroVADModel.defaultModelId)
            queue.async { [weak self] in
                guard let self, self.generation == generation else { return }
                self.usingVAD = false
            }
            startFixedWindow(modelType: "qwen3", language: language, generation: generation)
            return
        }

        task = Task { [weak self] in
            do {
                let vad = try await SileroVADModel.fromPretrained(
                    modelId: SileroVADModel.defaultModelId,
                    cacheDir: sileroCacheDir,
                    offlineMode: true
                )
                let config = VADConfig(
                    onset: 0.5,
                    offset: 0.35,
                    minSpeechDuration: 0.18,
                    minSilenceDuration: 0.16,
                    windowDuration: 0.032,
                    stepRatio: 1.0
                )
                let processor = StreamingVADProcessor(model: vad, config: config)
                guard let self else { return }
                nonisolated(unsafe) let streamer = self
                nonisolated(unsafe) let vadProcessor = processor
                streamer.queue.async {
                    guard streamer.generation == generation else { return }
                    streamer.processor = vadProcessor
                    logInfo("LiveDraftStreamer", "Qwen3 VAD live draft ready")
                }
            } catch {
                logError("LiveDraftStreamer", "Failed to load Silero VAD for live draft: \(error)")
                await MainActor.run {
                    AppState.shared.showModelCacheAlert(feature: "实时字幕", modelId: SileroVADModel.defaultModelId)
                }
                guard let self else { return }
                nonisolated(unsafe) let streamer = self
                streamer.queue.async {
                    guard streamer.generation == generation else { return }
                    streamer.usingVAD = false
                    streamer.processor = nil
                }
                streamer.startFixedWindow(modelType: "qwen3", language: language, generation: generation)
            }
        }
    }

    private func startFixedWindow(modelType: String, language: String?, generation: UInt64) {
        task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.fallbackMinIntervalSeconds * 1_000_000_000))
                guard !Task.isCancelled else { break }
                self?.requestFixedWindow(modelType: modelType, language: language, generation: generation)
            }
        }
    }

    private func appendQwen3VADSamples(_ samples: [Float]) {
        guard !samples.isEmpty else { return }

        rollingBuffer.append(contentsOf: samples)
        let preSpeechSamples = max(1, Int(Self.preSpeechSeconds * Double(Self.vadSampleRate)))
        if rollingBuffer.count > preSpeechSamples {
            rollingBuffer.removeFirst(rollingBuffer.count - preSpeechSamples)
        }

        guard let processor else { return }
        let events = processor.process(samples: samples)
        var startedInThisChunk = false

        for event in events {
            switch event {
            case .speechStarted:
                if pendingFinalizeSegmentID != nil {
                    cancelPendingFinalize()
                    speechActive = true
                    speechBuffer.append(contentsOf: rollingBuffer)
                } else {
                    speechActive = true
                    speechBuffer = rollingBuffer
                    lastPartialSampleCount = 0
                    currentText = ""
                    segmentID &+= 1
                }
                startedInThisChunk = true

            case .speechEnded:
                if speechActive {
                    upsertCommittedSegment(id: segmentID, text: currentText)
                    currentText = ""
                    requestQwen3VAD(force: true)
                    schedulePendingFinalize(segmentID: segmentID)
                }
                speechActive = false
                lastPartialSampleCount = min(lastPartialSampleCount, speechBuffer.count)
            }
        }

        if speechActive && !startedInThisChunk { speechBuffer.append(contentsOf: samples) }

        let maxSegmentSamples = max(1, Int(Self.maxSegmentSeconds * Double(Self.vadSampleRate)))
        if speechBuffer.count > maxSegmentSamples {
            let excess = speechBuffer.count - maxSegmentSamples
            speechBuffer.removeFirst(excess)
            lastPartialSampleCount = max(0, lastPartialSampleCount - excess)
        }

        if speechActive { requestQwen3VAD(force: false) }
    }

    private func requestQwen3VAD(force: Bool) {
        if inFlight {
            if force { forceRequestPending = true }
            return
        }
        let minSamples = Int(Self.partialIntervalSeconds * Double(Self.vadSampleRate))
        let minDelta = Int(Self.partialMinDeltaSeconds * Double(Self.vadSampleRate))
        guard speechBuffer.count >= minSamples else { return }
        guard force || speechBuffer.count - lastPartialSampleCount >= minDelta else { return }

        let audio = speechBuffer
        let language = language
        let generation = generation
        let segmentID = segmentID
        let isFinalSegment = force
        lastPartialSampleCount = speechBuffer.count
        inFlight = true

        Task.detached(priority: .userInitiated) { [weak self] in
            do {
                let text = try await ASRService.shared.transcribe(
                    audio: audio,
                    sampleRate: Self.vadSampleRate,
                    language: language
                )
                guard let self else { return }
                let displayText = self.queue.sync { () -> String? in
                    guard self.generation == generation else { return nil }
                    let rawCleaned = Self.cleanText(text)
                    let cleaned = AppState.shared.removeFillers ? FillerCleaner.clean(rawCleaned) : rawCleaned
                    guard !cleaned.isEmpty else {
                        let combined = self.combinedText()
                        return combined.isEmpty ? nil : combined
                    }

                    if isFinalSegment {
                        self.upsertCommittedSegment(id: segmentID, text: cleaned)
                        if self.segmentID == segmentID { self.currentText = "" }
                    } else if self.speechActive && self.segmentID == segmentID {
                        self.currentText = cleaned
                    }

                    return self.combinedText()
                }
                guard let displayText, !displayText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                self.emit(displayText)
            } catch is CancellationError {
            } catch {
                logDebug("LiveDraftStreamer", "Qwen3 VAD live draft failed: \(error.localizedDescription)")
            }

            guard let self else { return }
            nonisolated(unsafe) let streamer = self
            streamer.queue.async {
                guard streamer.generation == generation else { return }
                streamer.inFlight = false
                if streamer.forceRequestPending {
                    streamer.forceRequestPending = false
                    streamer.requestQwen3VAD(force: true)
                }
            }
        }
    }

    private func upsertCommittedSegment(id: UInt64, text: String) {
        let cleaned = Self.cleanText(text)
        guard !cleaned.isEmpty else { return }

        if let index = committedSegments.firstIndex(where: { $0.id == id }) {
            committedSegments[index].text = cleaned
        } else if committedSegments.last?.text != cleaned {
            committedSegments.append((id: id, text: cleaned))
        }
    }

    private func combinedText() -> String {
        var segments = committedSegments.map { ($0.id, Self.cleanText($0.text)) }
            .filter { !$0.1.isEmpty }
        let current = Self.cleanText(currentText)
        if !current.isEmpty {
            if let last = segments.last, last.0 == segmentID {
                segments[segments.count - 1].1 = current
            } else if segments.last?.1 != current {
                segments.append((segmentID, current))
            }
        }
        return segments.map { $0.1 }.joined(separator: " ")
    }

    private func cancelPendingFinalize() {
        pendingFinalizeWorkItem?.cancel()
        pendingFinalizeWorkItem = nil
        pendingFinalizeSegmentID = nil
    }

    private func schedulePendingFinalize(segmentID: UInt64) {
        pendingFinalizeWorkItem?.cancel()
        pendingFinalizeSegmentID = segmentID

        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard self.pendingFinalizeSegmentID == segmentID else { return }
            guard !self.speechActive else { return }
            if self.inFlight || self.forceRequestPending {
                self.schedulePendingFinalize(segmentID: segmentID)
                return
            }
            self.pendingFinalizeSegmentID = nil
            self.pendingFinalizeWorkItem = nil
            self.speechBuffer.removeAll(keepingCapacity: true)
            self.lastPartialSampleCount = 0
        }

        pendingFinalizeWorkItem = work
        queue.asyncAfter(deadline: .now() + Self.finalizeDelaySeconds, execute: work)
    }

    private static func cleanText(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    }

    private func appendFixedWindowSamples(_ samples: [Float], sampleRate: Int) {
        if self.sampleRate != sampleRate {
            buffer.removeAll(keepingCapacity: true)
            lastSampleCount = 0
            self.sampleRate = sampleRate
        }

        buffer.append(contentsOf: samples)
        let maxSamples = max(1, Int(Self.fallbackMaxWindowSeconds * Double(sampleRate)))
        if buffer.count > maxSamples {
            let excess = buffer.count - maxSamples
            buffer.removeFirst(excess)
            lastSampleCount = max(0, lastSampleCount - excess)
        }
    }

    private func requestFixedWindow(modelType: String, language: String?, generation: UInt64) {
        queue.async { [weak self] in
            guard let self,
                  self.generation == generation,
                  !self.inFlight else { return }

            let minSamples = Int(Self.fallbackMinIntervalSeconds * Double(self.sampleRate))
            let minDelta = Int(Self.fallbackMinDeltaSeconds * Double(self.sampleRate))
            guard self.buffer.count >= minSamples,
                  self.buffer.count - self.lastSampleCount >= minDelta else { return }

            let audio = self.buffer
            let sampleRate = self.sampleRate
            self.lastSampleCount = self.buffer.count
            self.inFlight = true

            Task.detached(priority: .userInitiated) { [weak self] in
                do {
                    let text: String
                    switch modelType {
                    case "qwen3":
                        text = try await ASRService.shared.transcribe(audio: audio, sampleRate: sampleRate, language: language)
                    case "whisper":
                        text = try await WhisperService.shared.transcribe(audio: audio, sampleRate: sampleRate, language: language)
                    default:
                        text = ""
                    }

                    guard let self else { return }
                    let isCurrent = self.queue.sync { self.generation == generation }
                    guard isCurrent else { return }
                    let cleaned = Self.cleanText(text)
                    guard !cleaned.isEmpty else { return }
                    self.emit(cleaned)
                } catch is CancellationError {
                } catch {
                    logDebug("LiveDraftStreamer", "Live draft failed: \(error.localizedDescription)")
                }

                guard let self else { return }
                nonisolated(unsafe) let streamer = self
                streamer.queue.async {
                    guard streamer.generation == generation else { return }
                    streamer.inFlight = false
                }
            }
        }
    }

    private func bundledSileroVADDirectory() -> URL? {
        guard let resourceURL = Bundle.main.resourceURL else { return nil }
        let dir = resourceURL
            .appendingPathComponent("silero-vad", isDirectory: true)
            .appendingPathComponent("Silero-VAD-v5-MLX", isDirectory: true)
        guard FileManager.default.fileExists(atPath: dir.path) else { return nil }
        return dir
    }

    private static func resampleLinear(_ samples: [Float], from sourceRate: Int, to targetRate: Int) -> [Float] {
        guard !samples.isEmpty, sourceRate > 0, targetRate > 0, sourceRate != targetRate else { return samples }
        let ratio = Double(targetRate) / Double(sourceRate)
        let outputCount = max(1, Int(Double(samples.count) * ratio))
        var output = [Float](repeating: 0, count: outputCount)
        for i in 0..<outputCount {
            let sourcePosition = Double(i) / ratio
            let lower = Int(sourcePosition)
            let upper = min(lower + 1, samples.count - 1)
            let fraction = Float(sourcePosition - Double(lower))
            output[i] = samples[lower] * (1 - fraction) + samples[upper] * fraction
        }
        return output
    }

    private func emit(_ text: String) {
        DispatchQueue.main.async { [weak self] in self?.textHandler?(text) }
    }
}
