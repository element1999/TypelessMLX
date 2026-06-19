import ScreenCaptureKit
import AVFoundation
import AppKit
import Foundation

/// Captures all system audio via ScreenCaptureKit, sends 0.5s PCM chunks to Python
/// Qwen3-ASR (with built-in VAD) for real-time subtitles, and translates to Chinese via Qwen.
class MeetingCaptureEngine: NSObject {
    static let shared = MeetingCaptureEngine()

    private weak var appState: AppState?
    private var transcriptOverlay: TranscriptOverlay?

    // SCStream
    private let streamLock = NSLock()
    private var activeStream: SCStream?

    // PCM accumulation (written from SCStream callback queue, read from timer)
    private let pcmLock = NSLock()
    private var pcmBuffer: [Float] = []
    private static let maxBufferSamples = 16000 * 10  // 10s cap to prevent unbounded growth

    // Subtitle streaming state — main thread only
    private var chunkTimer: Timer?
    private var translationTimer: Timer?
    private var translationGeneration: Int = 0
    private var lastPartialText: String = ""
    private var lastEnglishSentForTranslation: String = ""
    private var subtitleInFlight: Bool = false
    private var chunkSeq: Int = 0

    private static let chunkInterval: TimeInterval = 0.5
    private static let minChunkSamples = 8000        // 0.5s at 16kHz
    private static let translationDebounce: TimeInterval = 1.0
    private static let maxTranslationChars: Int = 150

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
    }

    func setEnabled(_ enabled: Bool) {
        if enabled {
            checkPermissionsAndStart()
        } else {
            stopAll()
            transcriptOverlay?.hide()
        }
    }

    // MARK: - Permission

    private func checkPermissionsAndStart() {
        SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { [weak self] content, error in
            if let error = error {
                logError("MeetingCaptureEngine", "Screen capture access denied: \(error.localizedDescription)")
                DispatchQueue.main.async { self?.appState?.hasScreenCapturePermission = false }
                return
            }
            DispatchQueue.main.async { self?.appState?.hasScreenCapturePermission = true }
            guard let display = content?.displays.first(where: { $0.displayID == CGMainDisplayID() })
                                ?? content?.displays.first else {
                logError("MeetingCaptureEngine", "No display found")
                return
            }
            self?.startStream(display: display)
        }
    }

    // MARK: - SCStream

    private func startStream(display: SCDisplay) {
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
            if let error = error {
                logError("MeetingCaptureEngine", "startCapture failed: \(error)")
                return
            }
            self?.streamLock.lock()
            self?.activeStream = stream
            self?.streamLock.unlock()
            logInfo("MeetingCaptureEngine", "Capturing all system audio")
            DispatchQueue.main.async {
                self?.appState?.isTeamsMeetingActive = true
                self?.startSubtitleStreaming()
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
        DispatchQueue.main.async { [weak self] in
            self?.chunkTimer?.invalidate()
            self?.translationTimer?.invalidate()
            self?.chunkTimer = nil
            self?.translationTimer = nil
        }
        stopStream()
        pcmLock.lock()
        pcmBuffer.removeAll()
        pcmLock.unlock()
    }

    // MARK: - Subtitle Streaming (main thread)

    private func startSubtitleStreaming() {
        subtitleInFlight = false
        lastPartialText = ""
        lastEnglishSentForTranslation = ""
        translationGeneration += 1

        if appState?.hasPythonBackend == true {
            WhisperBridge.shared.streamSubtitle(audioURL: nil, modelPath: subtitleModelPath, reset: true) { _ in }
        }

        chunkTimer = Timer.scheduledTimer(withTimeInterval: Self.chunkInterval, repeats: true) { [weak self] _ in
            self?.sendNextChunk()
        }
        logInfo("MeetingCaptureEngine", "Subtitle streaming started (Qwen3-ASR)")
    }

    private var subtitleModelPath: String {
        let model = AppState.shared.selectedModel
        if model.modelType == "qwen3" { return AppState.shared.resolvedModelPath }
        return "mlx-community/Qwen3-ASR-0.6B-8bit"
    }

    private func sendNextChunk() {
        guard !subtitleInFlight else { return }
        guard appState?.hasPythonBackend == true else { return }

        pcmLock.lock()
        guard pcmBuffer.count >= Self.minChunkSamples else {
            pcmLock.unlock()
            return
        }
        let chunk = Array(pcmBuffer)
        pcmBuffer.removeAll()
        pcmLock.unlock()

        chunkSeq += 1
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("typelessmlx_sub_\(chunkSeq).wav")
        guard writeWAV(samples: chunk, to: url) else { return }

        subtitleInFlight = true
        WhisperBridge.shared.streamSubtitle(audioURL: url, modelPath: subtitleModelPath) { [weak self] result in
            guard let self = self else { return }
            self.subtitleInFlight = false
            try? FileManager.default.removeItem(at: url)
            switch result {
            case .success(let (text, committed)):
                DispatchQueue.main.async { self.handleSubtitleResult(text: text, committed: committed) }
            case .failure(let error):
                logError("MeetingCaptureEngine", "Subtitle stream error: \(error.localizedDescription)")
            }
        }
    }

    private func handleSubtitleResult(text: String, committed: Bool) {
        if committed {
            guard !text.isEmpty else { return }
            transcriptOverlay?.updateLiveEnglish(text)
            lastPartialText = text
            triggerTranslation(for: text)
        } else {
            guard !text.isEmpty, text != lastPartialText else { return }
            lastPartialText = text
            transcriptOverlay?.updateLiveEnglish(text)
        }
    }

    private func triggerTranslation(for text: String) {
        guard appState?.hasPythonBackend == true else {
            transcriptOverlay?.commitEntry(english: text, chinese: "")
            lastPartialText = ""
            return
        }
        let chunk = String(text.suffix(Self.maxTranslationChars))
        guard chunk != lastEnglishSentForTranslation else { return }
        lastEnglishSentForTranslation = chunk

        translationGeneration += 1
        let gen = translationGeneration
        let displayText = text
        logDebug("MeetingCaptureEngine", "Translating (\(chunk.count) chars, gen=\(gen))")

        WhisperBridge.shared.translate(text: chunk) { [weak self] result in
            guard let self = self else { return }
            DispatchQueue.main.async {
                guard gen == self.translationGeneration else {
                    logDebug("MeetingCaptureEngine", "Translation gen \(gen) stale, discarding")
                    return
                }
                switch result {
                case .success(let chinese) where !chinese.isEmpty:
                    logInfo("MeetingCaptureEngine", "Translation: '\(chinese.prefix(40))'")
                    self.transcriptOverlay?.commitEntry(english: displayText, chinese: chinese)
                    self.lastPartialText = ""
                    self.lastEnglishSentForTranslation = ""
                case .success:
                    logWarn("MeetingCaptureEngine", "Translation returned empty")
                    self.transcriptOverlay?.commitEntry(english: displayText, chinese: "")
                    self.lastPartialText = ""
                    self.lastEnglishSentForTranslation = ""
                case .failure(let error):
                    logError("MeetingCaptureEngine", "Translation failed: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - WAV Writing

    private func writeWAV(samples: [Float], to url: URL, sampleRate: Int = 16000) -> Bool {
        let dataSize = samples.count * 2
        var data = Data(capacity: 44 + dataSize)

        func appendLE<T: FixedWidthInteger>(_ value: T) {
            var v = value.littleEndian
            data.append(Data(bytes: &v, count: MemoryLayout<T>.size))
        }

        data.append(contentsOf: "RIFF".utf8)
        appendLE(UInt32(36 + dataSize))
        data.append(contentsOf: "WAVE".utf8)
        data.append(contentsOf: "fmt ".utf8)
        appendLE(UInt32(16))
        appendLE(UInt16(1))           // PCM
        appendLE(UInt16(1))           // mono
        appendLE(UInt32(sampleRate))
        appendLE(UInt32(sampleRate * 2))  // byte rate
        appendLE(UInt16(2))           // block align
        appendLE(UInt16(16))          // bits per sample
        data.append(contentsOf: "data".utf8)
        appendLE(UInt32(dataSize))
        for s in samples {
            appendLE(Int16(max(-32768, min(32767, Int(s * 32767)))))
        }

        do {
            try data.write(to: url)
            return true
        } catch {
            logError("MeetingCaptureEngine", "WAV write failed: \(error)")
            return false
        }
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

        pcmLock.lock()
        pcmBuffer.append(contentsOf: samples)
        if pcmBuffer.count > MeetingCaptureEngine.maxBufferSamples {
            pcmBuffer.removeFirst(pcmBuffer.count - MeetingCaptureEngine.maxBufferSamples)
        }
        pcmLock.unlock()
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
