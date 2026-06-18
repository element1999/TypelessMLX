import ScreenCaptureKit
import AVFoundation
import AppKit
import Foundation

/// Captures all system audio output via ScreenCaptureKit and feeds 5-second chunks
/// to WhisperBridge for English transcription + Chinese translation.
class MeetingCaptureEngine: NSObject {
    static let shared = MeetingCaptureEngine()

    private weak var appState: AppState?
    private var transcriptOverlay: TranscriptOverlay?

    private let streamLock = NSLock()
    private var activeStream: SCStream?

    // Audio accumulation — only accessed on audioQueue
    private let audioQueue = DispatchQueue(label: "com.typelessmlx.meetingaudio", qos: .userInteractive)
    private var accumulatedSamples: [Float] = []
    private var isProcessingChunk = false

    // Paragraph break detection
    private var silentChunkCount = 0
    private static let newParagraphThreshold = 2   // 2 silent chunks (~10s) = new paragraph

    private static let sampleRate: Double = 16000
    private static let chunkFrames: Int = 80_000      // 5s × 16 000
    private static let maxBufferFrames: Int = 160_000  // 10s cap

    private override init() { super.init() }

    // MARK: - Lifecycle

    func setup(appState: AppState) {
        self.appState = appState
        self.transcriptOverlay = TranscriptOverlay()
        appState.meetingSubtitleEnabled = false  // always start disabled; user enables manually
        logInfo("MeetingCaptureEngine", "Setup complete")
    }

    func stop() {
        stopStream()
        transcriptOverlay?.hide()
    }

    // MARK: - Feature toggle

    func setEnabled(_ enabled: Bool) {
        if enabled {
            checkPermissionsAndStart()
        } else {
            stopStream()
            transcriptOverlay?.hide()
        }
    }

    // MARK: - Permission & content enumeration

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

    // MARK: - SCStream management

    private func startStream(display: SCDisplay) {
        streamLock.lock()
        guard activeStream == nil else {
            streamLock.unlock()
            logDebug("MeetingCaptureEngine", "Stream already active")
            return
        }
        streamLock.unlock()

        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.sampleRate = Int(Self.sampleRate)
        config.channelCount = 1
        config.excludesCurrentProcessAudio = true
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.width = 2
        config.height = 2

        let newStream = SCStream(filter: filter, configuration: config, delegate: self)
        do {
            try newStream.addStreamOutput(self, type: SCStreamOutputType.audio, sampleHandlerQueue: audioQueue)
        } catch {
            logError("MeetingCaptureEngine", "addStreamOutput failed: \(error)")
            return
        }

        newStream.startCapture { [weak self] (error: Error?) in
            if let error = error {
                logError("MeetingCaptureEngine", "startCapture failed: \(error)")
                return
            }
            self?.streamLock.lock()
            self?.activeStream = newStream
            self?.streamLock.unlock()
            logInfo("MeetingCaptureEngine", "Capturing all system audio")
            DispatchQueue.main.async { self?.appState?.isTeamsMeetingActive = true }
        }
    }

    private func stopStream() {
        streamLock.lock()
        let stream = activeStream
        activeStream = nil
        streamLock.unlock()

        stream?.stopCapture { (error: Error?) in
            if let error = error { logError("MeetingCaptureEngine", "stopCapture: \(error)") }
            logInfo("MeetingCaptureEngine", "Stream stopped")
        }
        audioQueue.async { [weak self] in
            self?.accumulatedSamples.removeAll()
            self?.isProcessingChunk = false
            self?.silentChunkCount = 0
        }
        DispatchQueue.main.async { self.appState?.isTeamsMeetingActive = false }
    }

    // MARK: - Audio accumulation (on audioQueue)

    private func processSampleBuffer(_ sampleBuffer: CMSampleBuffer) {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }

        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<CChar>?
        let status = CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0,
                                                  lengthAtOffsetOut: nil,
                                                  totalLengthOut: &totalLength,
                                                  dataPointerOut: &dataPointer)
        guard status == kCMBlockBufferNoErr, let ptr = dataPointer else { return }

        let frameCount = totalLength / MemoryLayout<Float32>.size
        guard frameCount > 0 else { return }

        let floatPtr = UnsafeRawPointer(ptr).assumingMemoryBound(to: Float32.self)
        accumulatedSamples.append(contentsOf: UnsafeBufferPointer(start: floatPtr, count: frameCount))

        if accumulatedSamples.count > Self.maxBufferFrames {
            accumulatedSamples.removeFirst(accumulatedSamples.count - Self.maxBufferFrames)
            logWarn("MeetingCaptureEngine", "Buffer capped — processing falling behind")
        }

        if accumulatedSamples.count >= Self.chunkFrames && !isProcessingChunk {
            let chunk = Array(accumulatedSamples.prefix(Self.chunkFrames))
            accumulatedSamples.removeFirst(Self.chunkFrames)
            processChunk(chunk)
        }
    }

    private func processChunk(_ samples: [Float]) {
        guard appState?.meetingSubtitleEnabled == true else { return }

        let rms = sqrt(samples.map { $0 * $0 }.reduce(0, +) / Float(samples.count))
        guard rms > 0.003 else {
            silentChunkCount += 1
            isProcessingChunk = false
            return
        }
        guard appState?.hasPythonBackend == true else {
            logDebug("MeetingCaptureEngine", "Python backend not ready — dropping chunk")
            return
        }

        // Mark paragraph break after sufficient silence
        let isNewParagraph = silentChunkCount >= Self.newParagraphThreshold
        silentChunkCount = 0
        isProcessingChunk = true

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("typelessmlx_subtitle_\(UUID().uuidString).wav")

        guard let format = AVAudioFormat(standardFormatWithSampleRate: Self.sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(samples.count)) else {
            isProcessingChunk = false
            return
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        guard let channelData = buffer.floatChannelData?[0] else { isProcessingChunk = false; return }
        for (i, s) in samples.enumerated() { channelData[i] = s }

        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        } catch {
            logError("MeetingCaptureEngine", "WAV write failed: \(error)")
            isProcessingChunk = false
            return
        }

        let model = appState?.resolvedSubtitleModelPath
        logDebug("MeetingCaptureEngine", "Sending 5s chunk (newParagraph=\(isNewParagraph))")

        WhisperBridge.shared.transcribeForSubtitle(audioURL: url, model: model) { [weak self] result in
            try? FileManager.default.removeItem(at: url)
            switch result {
            case .success(let pair):
                let english = pair.english.trimmingCharacters(in: .whitespacesAndNewlines)
                let chinese = pair.chinese.trimmingCharacters(in: .whitespacesAndNewlines)
                logInfo("MeetingCaptureEngine", "Transcript EN: '\(english.prefix(60))'")
                if !english.isEmpty {
                    self?.transcriptOverlay?.appendEntry(english: english, chinese: chinese,
                                                        newParagraph: isNewParagraph)
                }
            case .failure(let error):
                logWarn("MeetingCaptureEngine", "Subtitle failed: \(error.localizedDescription)")
            }
            self?.audioQueue.async { self?.isProcessingChunk = false }
        }
    }

    deinit {}
}

// MARK: - SCStreamOutput

extension MeetingCaptureEngine: SCStreamOutput {
    func stream(_ stream: SCStream,
                didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                of type: SCStreamOutputType) {
        guard type == SCStreamOutputType.audio else { return }
        processSampleBuffer(sampleBuffer)
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
