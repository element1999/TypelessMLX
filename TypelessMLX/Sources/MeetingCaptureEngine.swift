import ScreenCaptureKit
import AVFoundation
import AppKit
import Foundation
import Speech

/// Captures all system audio via ScreenCaptureKit, streams it to SFSpeechRecognizer
/// for real-time English subtitles, and asynchronously translates to Chinese via Qwen.
class MeetingCaptureEngine: NSObject {
    static let shared = MeetingCaptureEngine()

    private weak var appState: AppState?
    private var transcriptOverlay: TranscriptOverlay?

    // SCStream
    private let streamLock = NSLock()
    private var activeStream: SCStream?

    // Speech recognition — requestLock guards cross-thread access to _recognitionRequest
    private let requestLock = NSLock()
    private var _recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var speechRecognizer: SFSpeechRecognizer?

    // Session state — main thread only
    private var restartTimer: Timer?
    private var translationTimer: Timer?
    private var translationGeneration: Int = 0
    private var lastPartialText: String = ""
    private var lastEnglishSentForTranslation: String = ""
    private var lastRestartTime: Date = .distantPast

    private static let sessionDuration: TimeInterval = 50.0
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
                self?.startRecognition()
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
            self?.restartTimer?.invalidate()
            self?.translationTimer?.invalidate()
            self?.restartTimer = nil
            self?.translationTimer = nil
        }
        stopRecognition()
        stopStream()
    }

    // MARK: - Speech recognition (main thread)

    private func startRecognition() {
        // Guard against rapid-fire restarts (e.g. immediate error loop)
        let now = Date()
        guard now.timeIntervalSince(lastRestartTime) > 1.0 else { return }
        lastRestartTime = now

        restartTimer?.invalidate()
        translationTimer?.invalidate()
        restartTimer = nil
        translationTimer = nil

        // Commit any pending live text as English-only so history is preserved on restart
        if !lastPartialText.isEmpty {
            transcriptOverlay?.commitEntry(english: lastPartialText, chinese: "")
        } else {
            transcriptOverlay?.clearPending()
        }
        stopRecognition()
        lastPartialText = ""
        lastEnglishSentForTranslation = ""

        let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        guard recognizer?.isAvailable == true else {
            logError("MeetingCaptureEngine", "SFSpeechRecognizer unavailable")
            return
        }
        speechRecognizer = recognizer

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        // Don't force on-device — let the framework decide; falls back to server if model unavailable

        requestLock.lock()
        _recognitionRequest = request
        requestLock.unlock()

        recognitionTask = recognizer?.recognitionTask(with: request) { [weak self] result, error in
            guard let self = self else { return }
            if let result = result {
                let text = result.bestTranscription.formattedString
                DispatchQueue.main.async { self.handleRecognitionResult(text) }
            }
            if let error = error {
                logError("MeetingCaptureEngine", "Recognition error: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    guard self.appState?.meetingSubtitleEnabled == true else { return }
                    self.startRecognition()
                }
            }
        }

        restartTimer = Timer.scheduledTimer(withTimeInterval: Self.sessionDuration, repeats: false) { [weak self] _ in
            guard self?.appState?.meetingSubtitleEnabled == true else { return }
            logDebug("MeetingCaptureEngine", "Session timeout — restarting")
            self?.startRecognition()
        }

        logInfo("MeetingCaptureEngine", "Recognition started (en-US)")
    }

    private func stopRecognition() {
        requestLock.lock()
        _recognitionRequest?.endAudio()
        _recognitionRequest = nil
        requestLock.unlock()
        recognitionTask?.cancel()
        recognitionTask = nil
        speechRecognizer = nil
    }

    // MARK: - Result handling (main thread)

    private func handleRecognitionResult(_ text: String) {
        guard text != lastPartialText, !text.isEmpty else { return }
        lastPartialText = text

        // Show full session transcript in the live (pending) slot
        transcriptOverlay?.updateLiveEnglish(text)

        guard appState?.hasPythonBackend == true else { return }

        translationTimer?.invalidate()
        translationTimer = Timer.scheduledTimer(withTimeInterval: Self.translationDebounce, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            // Capture full display text and translation chunk at debounce fire time
            let displayText = text
            let chunk = String(text.suffix(Self.maxTranslationChars))
            guard chunk != self.lastEnglishSentForTranslation else { return }
            self.lastEnglishSentForTranslation = chunk

            self.translationGeneration += 1
            let gen = self.translationGeneration
            logDebug("MeetingCaptureEngine", "Translating segment (\(chunk.count) chars, gen=\(gen))")

            WhisperBridge.shared.translate(text: chunk) { [weak self] result in
                guard let self = self else { return }
                DispatchQueue.main.async {
                    guard gen == self.translationGeneration else {
                        logDebug("MeetingCaptureEngine", "Translation gen \(gen) stale, discarding")
                        return
                    }
                    switch result {
                    case .success(let chinese) where !chinese.isEmpty:
                        logInfo("MeetingCaptureEngine", "Translation done: '\(chinese.prefix(40))'")
                        self.transcriptOverlay?.commitEntry(english: displayText, chinese: chinese)
                        self.lastPartialText = ""  // prevent startRecognition from double-committing
                        self.startRecognition()
                    case .success:
                        logWarn("MeetingCaptureEngine", "Translation returned empty")
                    case .failure(let error):
                        logError("MeetingCaptureEngine", "Translation failed: \(error.localizedDescription)")
                    }
                }
            }
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
        requestLock.lock()
        let req = _recognitionRequest
        requestLock.unlock()
        req?.appendAudioSampleBuffer(sampleBuffer)
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
