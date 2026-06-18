import Foundation
import Speech
import AVFoundation

/// Serves two purposes:
/// 1. **Live preview**: streams partial SFSpeechRecognizer results to RecordingOverlay
///    during any recording session (Breeze / Qwen3 / macOS model).
/// 2. **Standalone model**: final transcription when user picks "macOS 内置" ASR.
class SpeechStreamer {
    static let shared = SpeechStreamer()

    private var recognizer: SFSpeechRecognizer?
    private var streamRequest: SFSpeechAudioBufferRecognitionRequest?
    private var streamTask: SFSpeechRecognitionTask?
    private let lock = NSLock()

    /// Called on the main thread with the latest partial / final text.
    var liveTextHandler: ((String) -> Void)?

    private(set) var isAuthorized = false

    private init() {}

    // MARK: - Authorization

    static func requestAuthorization(completion: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async { completion(status == .authorized) }
        }
    }

    // MARK: - Live streaming (overlay preview)

    func startStreaming(language: String?) {
        lock.lock()
        cancelStreamingLocked()
        lock.unlock()

        let locale = Self.locale(for: language)
        guard let rec = SFSpeechRecognizer(locale: locale), rec.isAvailable else {
            logWarn("SpeechStreamer", "Not available for \(locale.identifier)")
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true

        lock.lock()
        recognizer = rec
        streamRequest = request
        lock.unlock()

        let task = rec.recognitionTask(with: request) { [weak self] result, _ in
            guard let self = self, let result = result else { return }
            let text = result.bestTranscription.formattedString
            DispatchQueue.main.async { self.liveTextHandler?(text) }
        }

        lock.lock()
        streamTask = task
        lock.unlock()

        logInfo("SpeechStreamer", "Live streaming started (\(locale.identifier))")
    }

    /// Forward each AVAudioPCMBuffer from the recording tap.
    func appendBuffer(_ buffer: AVAudioPCMBuffer) {
        lock.lock()
        let req = streamRequest
        lock.unlock()
        req?.append(buffer)
    }

    /// Signal end-of-audio so SFSpeechRecognizer can flush its final result.
    func stopStreaming() {
        lock.lock()
        let req = streamRequest
        lock.unlock()
        req?.endAudio()
        logInfo("SpeechStreamer", "Streaming ended (flushing)")
    }

    /// Cancel without waiting for a final result (e.g. recording too short).
    func cancelStreaming() {
        lock.lock()
        cancelStreamingLocked()
        lock.unlock()
        DispatchQueue.main.async { self.liveTextHandler?("") }
    }

    private func cancelStreamingLocked() {
        streamTask?.cancel()
        streamTask = nil
        streamRequest = nil
        recognizer = nil
    }

    // MARK: - Standalone macOS ASR (final result)

    func transcribe(audioURL: URL, language: String?,
                    completion: @escaping (Result<String, Error>) -> Void) {
        let locale = Self.locale(for: language)
        guard let rec = SFSpeechRecognizer(locale: locale), rec.isAvailable else {
            let err = NSError(domain: "SpeechStreamer", code: -1,
                              userInfo: [NSLocalizedDescriptionKey: "macOS 语音识别不可用（\(locale.identifier)）"])
            completion(.failure(err))
            return
        }

        let request = SFSpeechURLRecognitionRequest(url: audioURL)
        request.shouldReportPartialResults = false

        rec.recognitionTask(with: request) { result, error in
            if let result = result, result.isFinal {
                let text = result.bestTranscription.formattedString
                if AppState.shared.enableTextRefinement, #available(macOS 26, *) {
                    Task {
                        let refined = await TextRefiner.shared.refine(text)
                        DispatchQueue.main.async { completion(.success(refined)) }
                    }
                } else {
                    DispatchQueue.main.async { completion(.success(text)) }
                }
            } else if let error = error {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    // MARK: - Helpers

    static func locale(for language: String?) -> Locale {
        switch language {
        case "zh": return Locale(identifier: "zh-CN")
        case "en": return Locale(identifier: "en-US")
        case "ja": return Locale(identifier: "ja-JP")
        case "ko": return Locale(identifier: "ko-KR")
        default:   return Locale(identifier: "zh-CN")
        }
    }
}
