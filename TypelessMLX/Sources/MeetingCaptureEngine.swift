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
    private var subtitleOverlay: SubtitleOverlay?

    // SCStream
    private let streamLock = NSLock()
    private var activeStream: SCStream?

    // Speech recognition (main-thread owned, requestLock guards cross-thread access)
    private let requestLock = NSLock()
    private var _recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var speechRecognizer: SFSpeechRecognizer?

    // Session state — main thread only
    private var restartTimer: Timer?
    private var translationTimer: Timer?
    private var translationGeneration: Int = 0
    private var lastPartialText: String = ""
    private var sessionLastEnglish: String = ""
    private var sessionLastChinese: String = ""

    private static let sessionDuration: TimeInterval = 50.0
    private static let translationDebounce: TimeInterval = 2.0
    private static let maxDisplayChars: Int = 150
    private static let maxTranslationChars: Int = 300

    private override init() { super.init() }

    // MARK: - Lifecycle

    func setup(appState: AppState) {
        self.appState = appState
        self.subtitleOverlay = SubtitleOverlay()
        appState.meetingSubtitleEnabled = false
        logInfo("MeetingCaptureEngine", "Setup complete")
    }

    func stop() {
        stopAll()
        subtitleOverlay?.hide()
    }

    func setEnabled(_ enabled: Bool) {
        if enabled {
            checkPermissionsAndStart()
        } else {
            stopAll()
            subtitleOverlay?.hide()
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
        // Push last session's text to history row before resetting
        if !sessionLastEnglish.isEmpty {
            subtitleOverlay?.advanceToHistory(english: sessionLastEnglish, chinese: sessionLastChinese)
        }

        stopRecognition()
        lastPartialText = ""
        sessionLastEnglish = ""
        sessionLastChinese = ""

        let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        guard recognizer?.isAvailable == true else {
            logError("MeetingCaptureEngine", "SFSpeechRecognizer unavailable")
            return
        }
        speechRecognizer = recognizer

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true

        requestLock.lock()
        _recognitionRequest = request
        requestLock.unlock()

        recognitionTask = recognizer?.recognitionTask(with: request) { [weak self] result, error in
            guard let self = self else { return }
            if let result = result {
                let text = result.bestTranscription.formattedString
                DispatchQueue.main.async { self.handleRecognitionResult(text, isFinal: result.isFinal) }
            }
            if error != nil {
                DispatchQueue.main.async {
                    guard self.appState?.meetingSubtitleEnabled == true else { return }
                    logDebug("MeetingCaptureEngine", "Recognition error — restarting")
                    self.startRecognition()
                }
            }
        }

        restartTimer?.invalidate()
        restartTimer = Timer.scheduledTimer(withTimeInterval: Self.sessionDuration, repeats: false) { [weak self] _ in
            guard self?.appState?.meetingSubtitleEnabled == true else { return }
            logDebug("MeetingCaptureEngine", "Session timeout — restarting")
            self?.startRecognition()
        }

        logInfo("MeetingCaptureEngine", "Recognition started (en-US, on-device)")
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

    private func handleRecognitionResult(_ text: String, isFinal: Bool) {
        guard text != lastPartialText, !text.isEmpty else { return }
        lastPartialText = text
        sessionLastEnglish = String(text.suffix(Self.maxDisplayChars))

        subtitleOverlay?.updatePartialEnglish(sessionLastEnglish)
        scheduleTranslation(text, immediate: isFinal)
    }

    private func scheduleTranslation(_ fullText: String, immediate: Bool) {
        guard appState?.hasPythonBackend == true else { return }

        translationTimer?.invalidate()
        let delay: TimeInterval = immediate ? 0 : Self.translationDebounce

        translationTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            self.translationGeneration += 1
            let gen = self.translationGeneration
            let chunk = String(fullText.suffix(Self.maxTranslationChars))

            WhisperBridge.shared.translate(text: chunk) { [weak self] result in
                guard let self = self else { return }
                if case .success(let chinese) = result, !chinese.isEmpty {
                    DispatchQueue.main.async {
                        guard gen == self.translationGeneration else { return }
                        self.sessionLastChinese = chinese
                        self.subtitleOverlay?.updateChineseTranslation(chinese)
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
