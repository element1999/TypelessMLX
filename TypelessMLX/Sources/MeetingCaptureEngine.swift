import ScreenCaptureKit
import AVFoundation
import AppKit
import Foundation

/// Captures all system audio via ScreenCaptureKit, sends 0.5s PCM chunks to the native
/// ASRService (Rust/MLX), and implements the subtitle VAD + translation pipeline in Swift.
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
    private var lastPartialText: String = ""
    private var subtitleInFlight: Bool = false
    private var chunkSeq: Int = 0

    // Subtitle VAD pipeline state — main thread only
    private var subtitlePrevText: String = ""
    private var subtitleStableCount: Int = 0
    private var subtitleCommittedPrefix: String = ""
    private var subtitleUtteranceSentences: [(en: String, zh: String)] = []
    private static let subtitleStableThreshold = 2
    private static let subtitleMaxSamples = 15 * 16000

    private static let chunkInterval: TimeInterval = 0.5
    private static let minChunkSamples = 8000        // 0.5s at 16kHz

    // Guards async permission/start callbacks so "stop" cannot be raced by delayed callbacks.
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
            guard let self = self else { return }
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
            guard let self = self else { return }
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
                self.startSubtitleStreaming()
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
            self?.chunkTimer = nil
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
        subtitlePrevText = ""
        subtitleStableCount = 0
        subtitleCommittedPrefix = ""
        subtitleUtteranceSentences = []

        chunkTimer = Timer.scheduledTimer(withTimeInterval: Self.chunkInterval, repeats: true) { [weak self] _ in
            self?.sendNextChunk()
        }
        logInfo("MeetingCaptureEngine", "Subtitle streaming started (ASRService)")
    }

    private var subtitleModelPath: String {
        return "mlx-community/Qwen3-ASR-0.6B-8bit"
    }

    private func sendNextChunk() {
        guard !subtitleInFlight else { return }

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
        Task { [weak self] in
            guard let self = self else { return }
            do {
                let text = try await ASRService.shared.transcribe(url: url)
                await MainActor.run { self.processSubtitleASRResult(text) }
            } catch {
                logError("MeetingCaptureEngine", "ASR error: \(error.localizedDescription)")
            }
            try? FileManager.default.removeItem(at: url)
            await MainActor.run { self.subtitleInFlight = false }
        }
    }

    // MARK: - Subtitle Pipeline Helpers

    /// Split punctuated text into (completeSentences, incompleteTail).
    /// Uses \.(?=\s) — NOT \.(?=\s|$) to avoid false positives from Qwen3-ASR terminal period.
    private func getCompletedSentences(_ text: String) -> ([String], String) {
        guard !text.isEmpty else { return ([], "") }
        var sentences: [String] = []
        var remaining = text
        let pattern = try! NSRegularExpression(pattern: "[。！？!?]+|\\.(?=\\s)")
        var searchRange = remaining.startIndex..<remaining.endIndex
        while let match = pattern.firstMatch(in: remaining, range: NSRange(searchRange, in: remaining)) {
            let matchEnd = Range(match.range, in: remaining)!.upperBound
            let sentence = String(remaining[..<matchEnd]).trimmingCharacters(in: .whitespaces)
            if !sentence.isEmpty { sentences.append(sentence) }
            searchRange = matchEnd..<remaining.endIndex
        }
        let tail = String(remaining[searchRange]).trimmingCharacters(in: .whitespaces)
        return (sentences, tail)
    }

    /// Return true if ASR echoed its own system prompt (silence/noise output).
    private func isSilenceHallucination(_ text: String) -> Bool {
        let known = [
            "请以简体中文输出语音识别结果，加上适当标点符号，不要使用繁体中文。",
            "请输出语音识别结果，保持原始语言，不要添加解释。"
        ]
        let t = text.trimmingCharacters(in: .whitespaces)
        return known.contains { t == $0 || t.hasPrefix($0) || $0.hasPrefix(t) }
    }

    // MARK: - Subtitle ASR Result Processing (main thread)

    @MainActor
    private func processSubtitleASRResult(_ rawText: String) {
        let text = isSilenceHallucination(rawText) ? "" : rawText
        logDebug("MeetingCaptureEngine", "Subtitle ASR: \(text.prefix(60))")

        // Find new complete sentences in suffix after committed prefix
        let suffix: String
        if !subtitleCommittedPrefix.isEmpty && text.hasPrefix(subtitleCommittedPrefix) {
            suffix = String(text.dropFirst(subtitleCommittedPrefix.count)).trimmingCharacters(in: .whitespaces)
        } else {
            subtitleCommittedPrefix = ""
            suffix = text
        }

        let (newSentences, tail) = getCompletedSentences(suffix)

        // Eagerly translate new complete sentences
        for raw in newSentences {
            let clean = PuncService.shared.restore(raw)
            subtitleCommittedPrefix += raw
            let idx = subtitleUtteranceSentences.count
            subtitleUtteranceSentences.append((en: clean, zh: ""))
            SubtitleBar.shared.updateLive(clean)
            Task { [weak self, clean, idx] in
                guard let self = self else { return }
                let zh = (try? await LLMService.shared.translate(clean)) ?? ""
                await MainActor.run {
                    if idx < self.subtitleUtteranceSentences.count {
                        self.subtitleUtteranceSentences[idx].zh = zh
                    }
                    SubtitleBar.shared.commitSentence(english: clean, chinese: zh)
                }
            }
        }

        // VAD stability check
        let forceCommit = pcmBuffer.count >= Self.subtitleMaxSamples
        if text == subtitlePrevText {
            subtitleStableCount += 1
        } else {
            subtitleStableCount = 0
            subtitlePrevText = text
        }
        let shouldCommit = (subtitleStableCount >= Self.subtitleStableThreshold && !text.isEmpty) || forceCommit

        if shouldCommit {
            let tailClean = tail.isEmpty ? "" : PuncService.shared.restore(tail)
            let allSentences = subtitleUtteranceSentences
            // Reset state
            subtitlePrevText = ""
            subtitleStableCount = 0
            subtitleCommittedPrefix = ""
            subtitleUtteranceSentences = []
            lastPartialText = ""

            // Write all utterance sentences to transcript
            for pair in allSentences {
                transcriptOverlay?.commitEntry(english: pair.en, chinese: pair.zh)
            }
            // Translate and commit tail
            if !tailClean.isEmpty {
                Task { [weak self, tailClean] in
                    guard let self = self else { return }
                    let zh = (try? await LLMService.shared.translate(tailClean)) ?? ""
                    await MainActor.run {
                        self.transcriptOverlay?.commitEntry(english: tailClean, chinese: zh)
                        SubtitleBar.shared.commitSentence(english: tailClean, chinese: zh)
                    }
                }
            }
        } else {
            // Show partial tail as live preview
            if !tail.isEmpty, tail != lastPartialText {
                lastPartialText = tail
                SubtitleBar.shared.updateLive(tail)
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
