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

    private static let maxRollingBufferSamples = 30 * 16000  // 30 s

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

        // Load Silero VAD model asynchronously
        Task { [weak self] in
            guard let self else { return }
            do {
                let vad = try await SileroVADModel.fromPretrained()
                let processor = StreamingVADProcessor(model: vad)
                self.subtitleQueue.async {
                    guard self.canProceed(token: token) else { return }
                    self.vadModel = vad
                    self.vadProcessor = processor
                    logInfo("MeetingCaptureEngine", "Silero VAD ready")
                }
            } catch {
                logError("MeetingCaptureEngine", "Failed to load Silero VAD: \(error)")
            }
        }
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
    }

    // MARK: - VAD Event Handling (subtitleQueue)

    private func handleVADEvent(_ event: VADEvent, token: UInt64) {
        switch event {
        case .speechStarted(let time):
            let absSample = Int(time * Float(SileroVADModel.sampleRate))
            speechStartSample = absSample - rollingBufferStart
            logDebug("MeetingCaptureEngine", "VAD speech start \(String(format: "%.2f", time))s")

        case .speechEnded(let segment):
            guard let startIdx = speechStartSample else { return }
            speechStartSample = nil

            let endAbs = Int(segment.endTime * Float(SileroVADModel.sampleRate))
            let startBuf = max(0, startIdx)
            let endBuf = min(endAbs - rollingBufferStart, rollingBuffer.count)
            guard startBuf < endBuf else { return }

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
                    await MainActor.run { SubtitleBar.shared.updateLive(clean) }

                    let zh = (try? await LLMService.shared.translate(clean)) ?? ""
                    guard self.canProceed(token: token) else { return }

                    await MainActor.run {
                        SubtitleBar.shared.commitSentence(english: clean, chinese: zh)
                        self.transcriptOverlay?.commitEntry(english: clean, chinese: zh)
                    }
                } catch {
                    logError("MeetingCaptureEngine", "ASR error: \(error)")
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
