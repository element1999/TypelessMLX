import AVFoundation
import AppKit
import Foundation
import ScreenCaptureKit
import SpeechVAD

/// Captures all system audio via ScreenCaptureKit, detects speech boundaries with
/// Silero VAD, and runs Qwen3-ASR + translation on each confirmed speech segment.
class MeetingCaptureEngine: NSObject {
    static let shared = MeetingCaptureEngine()

    private weak var appState: AppState?
    private var transcriptOverlay: TranscriptOverlay?

    // SCStream
    private let streamLock = NSLock()
    private var activeStream: SCStream?

    // PCM accumulation (written from SCStream callback, drained on subtitleQueue)
    private let pcmLock = NSLock()
    private var pcmBuffer: [Float] = []
    private static let maxBufferSamples = 16000 * 10  // 10 s safety cap

    // Subtitle VAD — accessed only on subtitleQueue
    private let subtitleQueue = DispatchQueue(label: "me.typelessmlx.subtitle-vad",
                                              qos: .userInteractive)
    private var vadModel: SileroVADModel?
    private var vadProcessor: StreamingVADProcessor?
    private var rollingBuffer: [Float] = []
    private var rollingBufferStart: Int = 0   // cumulative samples removed from buffer front
    private var speechStartSample: Int? = nil  // rolling-buffer-relative index when speech started
    private var livePreviewInFlight = false
    private var livePreviewLastEmitAbsSample = 0
    private var livePreviewLastText = ""
    private var livePreviewGeneration: UInt64 = 0
    private var liveTranslationInFlight = false
    private var liveTranslationRequestedKey = ""
    private var liveTranslationBestKey = ""
    private var liveTranslationBestChinese = ""
    private var useEnergyVADFallback = false
    private var fallbackSilenceSamples = 0

    private static let maxRollingBufferSamples = 30 * 16000  // 30 s
    private static let livePreviewIntervalSamples = 16000 / 2  // 0.5 s
    private static let livePreviewMinAudioSamples = 16000 / 3  // ~0.33 s
    private static let livePreviewMaxWindowSamples = 16000 * 6 // 6 s tail window
    private static let liveTranslationMaxChars = 120
    private static let fallbackMinSpeechSamples = 16000 / 2   // 0.5 s
    private static let fallbackMaxSpeechSamples = 16000 * 12  // 12 s
    private static let fallbackEndSilenceSamples = 16000 / 2  // 0.5 s
    private static let fallbackStartRMS: Float = 0.010
    private static let fallbackEndRMS: Float = 0.006

    // Enable/stop guard — mirrors existing pattern
    private let enableStateLock = NSLock()
    private var subtitleEnabled = false
    private var enableToken: UInt64 = 0

    private override init() { super.init() }

    // MARK: - Lifecycle

    func setup(appState: AppState) {
        self.appState = appState
        self.transcriptOverlay = TranscriptOverlay()
        appState.meetingSubtitleEnabled = false
        logInfo("MeetingCaptureEngine", "Setup complete")
    }

    func stop() {
        stopAll()
        transcriptOverlay?.hide()
        SubtitleBar.shared.hide()
    }

    func setEnabled(_ enabled: Bool) {
        enableStateLock.lock()
        subtitleEnabled = enabled
        enableToken &+= 1
        let token = enableToken
        enableStateLock.unlock()

        if enabled {
            checkPermissionsAndStart(token: token)
        } else {
            stopAll()
            transcriptOverlay?.hide()
        }
    }

    private func canProceed(token: UInt64) -> Bool {
        enableStateLock.lock()
        let ok = subtitleEnabled && enableToken == token
        enableStateLock.unlock()
        return ok
    }

    // MARK: - Permission

    private func checkPermissionsAndStart(token: UInt64) {
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { [weak self] content, error in
            guard let self else { return }
            guard self.canProceed(token: token) else { return }

            if let error = error {
                logError("MeetingCaptureEngine", "Screen capture access denied: \(error.localizedDescription)")
                DispatchQueue.main.async { self.appState?.hasScreenCapturePermission = false }
                return
            }
            DispatchQueue.main.async { self.appState?.hasScreenCapturePermission = true }
            guard let display = content?.displays.first(where: { $0.displayID == CGMainDisplayID() })
                                ?? content?.displays.first else {
                logError("MeetingCaptureEngine", "No display found")
                return
            }
            self.startStream(display: display, token: token)
        }
    }

    // MARK: - SCStream

    private func startStream(display: SCDisplay, token: UInt64) {
        guard canProceed(token: token) else { return }
        streamLock.lock()
        guard activeStream == nil else { streamLock.unlock(); return }
        streamLock.unlock()

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.sampleRate = 16000
        config.channelCount = 1
        config.excludesCurrentProcessAudio = true
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.width = 2
        config.height = 2

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        do {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: .global(qos: .userInteractive))
        } catch {
            logError("MeetingCaptureEngine", "addStreamOutput failed: \(error)")
            return
        }

        stream.startCapture { [weak self] error in
            guard let self else { return }
            guard self.canProceed(token: token) else {
                stream.stopCapture { _ in }
                return
            }

            if let error = error {
                logError("MeetingCaptureEngine", "startCapture failed: \(error)")
                return
            }
            self.streamLock.lock()
            self.activeStream = stream
            self.streamLock.unlock()
            logInfo("MeetingCaptureEngine", "Capturing all system audio")
            DispatchQueue.main.async {
                self.appState?.isTeamsMeetingActive = true
                self.startSubtitleStreaming(token: token)
            }
        }
    }

    private func stopStream() {
        streamLock.lock()
        let stream = activeStream
        activeStream = nil
        streamLock.unlock()
        stream?.stopCapture { error in
            if let error = error { logError("MeetingCaptureEngine", "stopCapture: \(error)") }
        }
        DispatchQueue.main.async { self.appState?.isTeamsMeetingActive = false }
    }

    private func stopAll() {
        stopStream()
        pcmLock.lock()
        pcmBuffer.removeAll()
        pcmLock.unlock()
        subtitleQueue.async { [weak self] in
            guard let self else { return }
            // Flush any pending VAD speech segment before teardown
            if let vad = self.vadProcessor {
                let events = vad.flush()
                for event in events { self.handleVADEvent(event, token: 0) }  // token=0 → canProceed fails
            }
            self.vadProcessor = nil
            self.vadModel = nil
            self.rollingBuffer.removeAll()
            self.rollingBufferStart = 0
            self.speechStartSample = nil
            self.livePreviewInFlight = false
            self.livePreviewLastEmitAbsSample = 0
            self.livePreviewLastText = ""
            self.livePreviewGeneration &+= 1
            self.liveTranslationInFlight = false
            self.liveTranslationRequestedKey = ""
            self.liveTranslationBestKey = ""
            self.liveTranslationBestChinese = ""
        }
    }

    // MARK: - Subtitle Streaming

    private func startSubtitleStreaming(token: UInt64) {
        // Reset rolling buffer on subtitle queue
        subtitleQueue.async { [weak self] in
            guard let self else { return }
            self.rollingBuffer.removeAll()
            self.rollingBufferStart = 0
            self.speechStartSample = nil
        }

        guard let sileroCacheDir = bundledSileroVADDirectory() else {
            logError("MeetingCaptureEngine", "Bundled Silero VAD not found in app resources")
            DispatchQueue.main.async {
                self.appState?.showModelCacheAlert(feature: "会议字幕", modelId: SileroVADModel.defaultModelId)
            }
            return
        }

        // Load Silero VAD model from bundled local cache only (offline)
        Task { [weak self] in
            guard let self else { return }
            do {
                let vad = try await SileroVADModel.fromPretrained(
                    modelId: SileroVADModel.defaultModelId,
                    cacheDir: sileroCacheDir,
                    offlineMode: true
                )
                let processor = StreamingVADProcessor(model: vad)
                self.subtitleQueue.async {
                    guard self.canProceed(token: token) else { return }
                    self.vadModel = vad
                    self.vadProcessor = processor
                    logInfo("MeetingCaptureEngine", "Silero VAD ready (bundled)")
                }
            } catch {
                logError("MeetingCaptureEngine", "Failed to load bundled Silero VAD: \(error)")
                DispatchQueue.main.async {
                    self.appState?.showModelCacheAlert(feature: "会议字幕", modelId: SileroVADModel.defaultModelId)
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

    // MARK: - PCM Ingestion (called from subtitleQueue)

    private func drainAndProcess(token: UInt64) {
        guard let vad = vadProcessor else { return }

        pcmLock.lock()
        guard !pcmBuffer.isEmpty else { pcmLock.unlock(); return }
        let chunk = pcmBuffer
        pcmBuffer.removeAll(keepingCapacity: true)
        pcmLock.unlock()

        // Append to rolling buffer
        rollingBuffer.append(contentsOf: chunk)
        if rollingBuffer.count > Self.maxRollingBufferSamples {
            let excess = rollingBuffer.count - Self.maxRollingBufferSamples
            rollingBuffer.removeFirst(excess)
            rollingBufferStart += excess
            if let s = speechStartSample { speechStartSample = s - excess }
        }

        // Feed through Silero VAD
        let events = vad.process(samples: chunk)
        for event in events { handleVADEvent(event, token: token) }

        // Subtitle-only low-latency preview while user is still speaking.
        maybeEmitLivePreview(token: token)
    }

    // MARK: - VAD Event Handling (subtitleQueue)

private func handleVADEvent(_ event: VADEvent, token: UInt64) {
    switch event {
    case .speechStarted(let time):
        let absSample = Int(time * Float(SileroVADModel.sampleRate))
        speechStartSample = absSample - rollingBufferStart
        livePreviewInFlight = false
        livePreviewLastEmitAbsSample = absSample
        livePreviewLastText = ""
        livePreviewGeneration &+= 1
        liveTranslationInFlight = false
        liveTranslationRequestedKey = ""
        liveTranslationBestKey = ""
        liveTranslationBestChinese = ""
        logDebug("MeetingCaptureEngine", "VAD speech start \(String(format: "%.2f", time))s")

    case .speechEnded(let segment):
        guard let startIdx = speechStartSample else { return }
        speechStartSample = nil

        let endAbs = Int(segment.endTime * Float(SileroVADModel.sampleRate))
        let startBuf = max(0, startIdx)
        let endBuf = min(endAbs - rollingBufferStart, rollingBuffer.count)
        guard startBuf < endBuf else { return }

        livePreviewInFlight = false
        livePreviewLastEmitAbsSample = endAbs
        livePreviewLastText = ""
        livePreviewGeneration &+= 1

        let audio = Array(rollingBuffer[startBuf..<endBuf])
        logDebug("MeetingCaptureEngine",
                 "VAD speech end \(String(format: "%.2f", segment.startTime))–\(String(format: "%.2f", segment.endTime))s, \(audio.count) samples")

        Task { [weak self, audio, token] in
            guard let self, self.canProceed(token: token) else { return }
            do {
                let raw = try await ASRService.shared.transcribe(audio: audio)
                guard self.canProceed(token: token) else { return }

                let text = self.isSilenceHallucination(raw) ? "" : raw
                guard !text.isEmpty else { return }

                let clean = PuncService.shared.restore(text)
                var subtitleZh = await self.prefetchedChineseAsync(for: clean)
                let initialSubtitleZh = subtitleZh

                await MainActor.run {
                    // Commit English immediately; if prefetched Chinese exists, show it without waiting.
                    SubtitleBar.shared.commitSentence(english: clean, chinese: initialSubtitleZh)
                }

                // If no prefetched Chinese is ready, do a short-tail fast translation first for subtitle UX.
                if subtitleZh.isEmpty {
                    let quickChunk = String(clean.suffix(Self.liveTranslationMaxChars))
                    let quickZh = (try? await LLMService.shared.translate(quickChunk)) ?? ""
                    if !quickZh.isEmpty {
                        subtitleZh = quickZh
                        guard self.canProceed(token: token) else { return }
                        await MainActor.run {
                            SubtitleBar.shared.commitSentence(english: clean, chinese: quickZh)
                        }
                    }
                }

                let fullZh = (try? await LLMService.shared.translate(clean)) ?? subtitleZh
                guard self.canProceed(token: token) else { return }

                await MainActor.run {
                    SubtitleBar.shared.commitSentence(english: clean, chinese: fullZh)
                    self.transcriptOverlay?.commitEntry(english: clean, chinese: fullZh)
                }
            } catch {
                logError("MeetingCaptureEngine", "ASR error: \(error)")
            }
        }
    }
}

private func maybeEmitLivePreview(token: UInt64) {
    guard let startIdx = speechStartSample else { return }
    guard !livePreviewInFlight else { return }

    let endAbs = rollingBufferStart + rollingBuffer.count
    guard endAbs - livePreviewLastEmitAbsSample >= Self.livePreviewIntervalSamples else { return }

    let startBuf = max(0, startIdx)
    let endBuf = rollingBuffer.count
    guard startBuf < endBuf else { return }
    guard endBuf - startBuf >= Self.livePreviewMinAudioSamples else { return }

    let windowStart = max(startBuf, endBuf - Self.livePreviewMaxWindowSamples)
    let audio = Array(rollingBuffer[windowStart..<endBuf])
    let generation = livePreviewGeneration
    livePreviewInFlight = true
    livePreviewLastEmitAbsSample = endAbs

    Task { [weak self, audio, generation, token] in
        guard let self else { return }

        do {
            let raw = try await ASRService.shared.transcribe(audio: audio)
            let filtered = self.isSilenceHallucination(raw) ? "" : raw
            let clean = PuncService.shared.restore(filtered)

            self.subtitleQueue.async {
                guard self.canProceed(token: token) else {
                    self.livePreviewInFlight = false
                    return
                }
                guard self.livePreviewGeneration == generation else {
                    self.livePreviewInFlight = false
                    return
                }
                self.livePreviewInFlight = false
                guard !clean.isEmpty else { return }
                guard clean != self.livePreviewLastText else { return }
                self.livePreviewLastText = clean
                DispatchQueue.main.async {
                    SubtitleBar.shared.updateLive(clean)
                }
                self.prefetchLiveTranslation(for: clean, token: token, generation: generation)
            }
        } catch {
            self.subtitleQueue.async {
                guard self.livePreviewGeneration == generation else { return }
                self.livePreviewInFlight = false
            }
        }
    }
}

private func normalizeTranslationKey(_ text: String) -> String {
    text
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
}

private func prefetchedChinese(for english: String) -> String {
    let key = normalizeTranslationKey(english)
    guard !key.isEmpty else { return "" }
    if liveTranslationBestKey == key { return liveTranslationBestChinese }
    if liveTranslationBestKey.hasSuffix(key) || key.hasSuffix(liveTranslationBestKey) {
        return liveTranslationBestChinese
    }
    return ""
}

private func prefetchedChineseAsync(for english: String) async -> String {
    await withCheckedContinuation { continuation in
        subtitleQueue.async {
            continuation.resume(returning: self.prefetchedChinese(for: english))
        }
    }
}

private func prefetchLiveTranslation(for clean: String, token: UInt64, generation: UInt64) {
    let key = normalizeTranslationKey(clean)
    guard !key.isEmpty else { return }
    guard canProceed(token: token) else { return }
    guard livePreviewGeneration == generation else { return }
    guard key != liveTranslationBestKey else { return }
    guard key != liveTranslationRequestedKey else { return }
    guard !liveTranslationInFlight else { return }

    liveTranslationInFlight = true
    liveTranslationRequestedKey = key
    let chunk = String(key.suffix(Self.liveTranslationMaxChars))

    Task { [weak self, key, chunk, generation, token] in
        guard let self else { return }
        let zh = (try? await LLMService.shared.translate(chunk)) ?? ""
        self.subtitleQueue.async {
            guard self.canProceed(token: token) else {
                self.liveTranslationInFlight = false
                return
            }
            guard self.livePreviewGeneration == generation else {
                self.liveTranslationInFlight = false
                return
            }
            self.liveTranslationInFlight = false
            guard !zh.isEmpty else { return }
            self.liveTranslationBestKey = key
            self.liveTranslationBestChinese = zh

            // While speech is ongoing, push prefetched Chinese to subtitle immediately
            // so users don't wait for end-of-segment translation.
            guard self.speechStartSample != nil else { return }
            let liveEnglish = self.livePreviewLastText
            guard !liveEnglish.isEmpty else { return }
            let liveKey = self.normalizeTranslationKey(liveEnglish)
            guard liveKey == key || liveKey.hasSuffix(key) || key.hasSuffix(liveKey) else { return }
            DispatchQueue.main.async {
                SubtitleBar.shared.commitSentence(english: liveEnglish, chinese: zh)
            }
        }
    }
}

    // MARK: - Silence Hallucination Filter

    /// Returns true if ASR output verbatim echoes a known system-prompt fragment
    /// (Qwen3-ASR hallucination on silence/noise).
    private func isSilenceHallucination(_ text: String) -> Bool {
        let known = [
            "请以简体中文输出语音识别结果，加上适当标点符号，不要使用繁体中文。",
            "请输出语音识别结果，保持原始语言，不要添加解释。"
        ]
        let t = text.trimmingCharacters(in: .whitespaces)
        return known.contains { t == $0 || t.hasPrefix($0) || $0.hasPrefix(t) }
    }

    deinit {}
}

// MARK: - SCStreamOutput

extension MeetingCaptureEngine: SCStreamOutput {
    func stream(_ stream: SCStream,
                didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == .audio else { return }
        let samples = extractPCM(from: sampleBuffer)
        guard !samples.isEmpty else { return }

        // Accumulate in pcmBuffer (same as before)
        pcmLock.lock()
        pcmBuffer.append(contentsOf: samples)
        if pcmBuffer.count > MeetingCaptureEngine.maxBufferSamples {
            pcmBuffer.removeFirst(pcmBuffer.count - MeetingCaptureEngine.maxBufferSamples)
        }
        pcmLock.unlock()

        // Capture token before dispatching
        enableStateLock.lock()
        let token = enableToken
        let enabled = subtitleEnabled
        enableStateLock.unlock()
        guard enabled else { return }

        subtitleQueue.async { [weak self] in self?.drainAndProcess(token: token) }
    }

    private func extractPCM(from sampleBuffer: CMSampleBuffer) -> [Float] {
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc) else { return [] }
        let isFloat = (asbd.pointee.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        guard isFloat else {
            logWarn("MeetingCaptureEngine", "Unexpected audio format (not Float32)")
            return []
        }

        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return [] }
        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0,
                                          lengthAtOffsetOut: nil,
                                          totalLengthOut: &totalLength,
                                          dataPointerOut: &dataPointer) == kCMBlockBufferNoErr,
              let ptr = dataPointer, totalLength > 0 else { return [] }

        let floatCount = totalLength / MemoryLayout<Float32>.size
        guard floatCount > 0 else { return [] }
        return Array(UnsafeBufferPointer(
            start: UnsafeRawPointer(ptr).assumingMemoryBound(to: Float32.self),
            count: floatCount
        ))
    }
}

// MARK: - SCStreamDelegate

extension MeetingCaptureEngine: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        logError("MeetingCaptureEngine", "Stream stopped unexpectedly: \(error)")
        streamLock.lock()
        if activeStream === stream { activeStream = nil }
        streamLock.unlock()
        DispatchQueue.main.async { self.appState?.isTeamsMeetingActive = false }
    }
}
