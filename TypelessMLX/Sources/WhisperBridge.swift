import Foundation
import AVFoundation

/// Manages the persistent Python mlx-whisper subprocess.
/// Communicates via newline-delimited JSON over stdin/stdout (JSON-RPC style).
class WhisperBridge {
    static let shared = WhisperBridge()

    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var isReady = false
    private var isStarting = false
    private var startCompletions: [(Bool) -> Void] = []
    private struct RequestContext {
        let completion: (Result<String, Error>) -> Void
        let startTime: Date
        let timeoutItem: DispatchWorkItem
        let label: String
    }
    private var pendingRequests: [String: RequestContext] = [:]
    private let lock = NSLock()
    private var readBuffer = ""
    private var pingTimer: Timer?
    private var idleTimer: Timer?

    private static let transcribeTimeout: TimeInterval = 600.0  // 10 min — allows first-run model download (~1GB)
    private static let warmupTimeout: TimeInterval = 10.0       // short window for warm-up transcription

    private init() {}

    // MARK: - Paths

    var pythonPath: String {
        let venvPython = NSHomeDirectory() + "/.local/share/typelessmlx/venv/bin/python"
        if FileManager.default.fileExists(atPath: venvPython) { return venvPython }
        // Homebrew fallbacks
        for path in ["/opt/homebrew/bin/python3.12", "/opt/homebrew/bin/python3", "/usr/bin/python3"] {
            if FileManager.default.fileExists(atPath: path) { return path }
        }
        return "python3"
    }

    var scriptPath: String {
        // In app bundle (Resources/backend/transcribe_server.py)
        if let path = Bundle.main.path(forResource: "transcribe_server", ofType: "py", inDirectory: "backend") {
            return path
        }
        // Development: relative to this source file
        let projectRoot = URL(fileURLWithPath: #file)
            .deletingLastPathComponent() // Sources/
            .deletingLastPathComponent() // TypelessMLX/
            .deletingLastPathComponent() // project root
        return projectRoot.appendingPathComponent("backend/transcribe_server.py").path
    }

    static func isVenvReady() -> Bool {
        let venvBin = NSHomeDirectory() + "/.local/share/typelessmlx/venv/bin"
        let python = venvBin + "/python"
        guard FileManager.default.fileExists(atPath: python) else { return false }
        // Verify that key packages are actually installed
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: python)
        proc.arguments = ["-c", "import mlx_whisper, mlx_audio, huggingface_hub"]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try? proc.run()
        proc.waitUntilExit()
        return proc.terminationStatus == 0
    }

    // MARK: - Lifecycle

    func start(completion: @escaping (Bool) -> Void) {
        lock.lock()
        if isReady {
            lock.unlock()
            DispatchQueue.main.async { completion(true) }
            return
        }
        startCompletions.append(completion)
        if isStarting {
            lock.unlock()
            return
        }
        isStarting = true
        lock.unlock()

        DispatchQueue.global(qos: .userInitiated).async {
            self.startProcess()
        }
    }

    private func finishStart(_ success: Bool) {
        lock.lock()
        isStarting = false
        let completions = startCompletions
        startCompletions.removeAll()
        lock.unlock()

        DispatchQueue.main.async {
            completions.forEach { $0(success) }
        }
    }

    private func startProcess() {
        stopProcess()

        let python = self.pythonPath
        let script = self.scriptPath

        guard FileManager.default.fileExists(atPath: script) else {
            logError("WhisperBridge", "Script not found: \(script)")
            finishStart(false)
            return
        }

        logInfo("WhisperBridge", "Starting Python: \(python)")
        logInfo("WhisperBridge", "Script: \(script)")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = ["-u", script]  // -u = unbuffered stdout
        process.environment = Self.makeEnv()

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        process.terminationHandler = { [weak self] terminated in
            logWarn("WhisperBridge", "Python process terminated (exit: \(process.terminationStatus))")
            self?.handleProcessTermination(terminated)
        }

        do {
            try process.run()
        } catch {
            logError("WhisperBridge", "Failed to start Python: \(error)")
            finishStart(false)
            return
        }

        lock.lock()
        self.process = process
        self.stdinPipe = stdinPipe
        self.stdoutPipe = stdoutPipe
        self.stderrPipe = stderrPipe
        lock.unlock()

        // Log Python stderr for debugging
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty, let text = String(data: data, encoding: .utf8) {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    logDebug("Python", trimmed)
                }
            }
        }

        // Wait for {"status": "ready"} (up to 60s for model load on first run)
        let startTime = Date()
        var readyReceived = false

        while Date().timeIntervalSince(startTime) < 60 {
            let data = stdoutPipe.fileHandleForReading.availableData
            if !data.isEmpty, let text = String(data: data, encoding: .utf8) {
                if text.contains("\"ready\"") || text.contains("ready") {
                    readyReceived = true
                    break
                }
            }
            Thread.sleep(forTimeInterval: 0.1)
        }

        guard readyReceived else {
            logError("WhisperBridge", "Python did not send ready signal within 60s")
            process.terminate()
            finishStart(false)
            return
        }

        lock.lock()
        self.isReady = true
        lock.unlock()

        // Start async read loop
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.readLoop()
        }

        warmUpBackend()

        // Schedule health ping
        DispatchQueue.main.async { [weak self] in
            self?.pingTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
                self?.sendPing()
            }
        }

        logInfo("WhisperBridge", "Python backend ready ✅")
        finishStart(true)
    }

    private func handleProcessTermination(_ terminated: Process) {
        lock.lock()
        // Ignore stale termination callbacks from an old process instance.
        guard self.process === terminated else {
            lock.unlock()
            logDebug("WhisperBridge", "Ignoring stale process termination callback")
            return
        }
        isReady = false
        process = nil
        let pending = pendingRequests
        pendingRequests.removeAll()
        lock.unlock()

        DispatchQueue.main.async {
            AppState.shared.hasPythonBackend = false
            AppState.shared.updatePermissionState()
        }

        let error = NSError(domain: "WhisperBridge", code: -1,
                            userInfo: [NSLocalizedDescriptionKey: "Python process terminated unexpectedly"])
        DispatchQueue.main.async {
            for (_, context) in pending {
                context.timeoutItem.cancel()
                context.completion(.failure(error))
            }
        }
    }

    func stopProcess() {
        DispatchQueue.main.async { [weak self] in
            self?.pingTimer?.invalidate()
            self?.pingTimer = nil
            self?.idleTimer?.invalidate()
            self?.idleTimer = nil
        }

        lock.lock()
        isReady = false
        let proc = process
        process = nil
        stdinPipe?.fileHandleForWriting.closeFile()
        stdinPipe = nil
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stdoutPipe = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe = nil
        lock.unlock()

        proc?.terminate()
        logInfo("WhisperBridge", "Python process stopped")
    }

    // MARK: - Reading

    private func readLoop() {
        lock.lock()
        let pipe = stdoutPipe
        lock.unlock()

        guard let pipe = pipe else { return }

        while true {
            let data = pipe.fileHandleForReading.availableData
            if data.isEmpty {
                lock.lock()
                let running = process?.isRunning == true
                lock.unlock()
                if !running { break }
                Thread.sleep(forTimeInterval: 0.01)
                continue
            }

            guard let text = String(data: data, encoding: .utf8) else { continue }

            lock.lock()
            readBuffer += text
            lock.unlock()

            processBuffer()
        }
        logWarn("WhisperBridge", "Read loop ended")
    }

    private func processBuffer() {
        lock.lock()
        var lines: [String] = []
        while let range = readBuffer.range(of: "\n") {
            let line = String(readBuffer[readBuffer.startIndex..<range.lowerBound])
            readBuffer.removeSubrange(readBuffer.startIndex...range.lowerBound)
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { lines.append(trimmed) }
        }
        lock.unlock()

        for line in lines { handleResponse(line) }
    }

    private func handleResponse(_ line: String) {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            logWarn("WhisperBridge", "Invalid JSON response: \(String(line.prefix(100)))")
            return
        }

        // Ignore pong responses
        if let status = json["status"] as? String, status == "pong" { return }

        guard let id = json["id"] as? String else { return }

        lock.lock()
        let context = pendingRequests.removeValue(forKey: id)
        lock.unlock()

        guard let context = context else { return }
        context.timeoutItem.cancel()
        let elapsed = Date().timeIntervalSince(context.startTime)
        logInfo("WhisperBridge", "\(context.label) latency: \(String(format: "%.2f", elapsed))s")

        // SubtitleStream response: pass raw JSON string to caller
        if json.keys.contains("committed") {
            guard let data = try? JSONSerialization.data(withJSONObject: json),
                  let encoded = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async { context.completion(.success(encoded)) }
            return
        }

        // Subtitle response: encode english\u{0001}chinese for caller to unpack
        if let _ = json["translated"] {
            let english = json["text"] as? String ?? ""
            let chinese = json["translated"] as? String ?? ""
            let encoded = "\(english)\u{0001}\(chinese)"
            DispatchQueue.main.async { context.completion(.success(encoded)) }
            return
        }

        if let errorMsg = json["error"] as? String, !errorMsg.isEmpty {
            let err = NSError(domain: "WhisperBridge", code: -2,
                              userInfo: [NSLocalizedDescriptionKey: errorMsg])
            DispatchQueue.main.async { context.completion(.failure(err)) }
        } else if let text = json["text"] as? String {
            logInfo("WhisperBridge", "Transcription (\(text.count) chars): \(text.prefix(80))")
            // Only skip TextRefiner if text already has commas (mid-sentence punctuation).
            // A trailing 。 from the Python fallback is NOT enough — commas are the key.
            let needsRefinement = !text.contains("，")
            if AppState.shared.enableTextRefinement, needsRefinement, #available(macOS 26, *) {
                Task {
                    let refined = await TextRefiner.shared.refine(text)
                    DispatchQueue.main.async { context.completion(.success(refined)) }
                }
            } else {
                DispatchQueue.main.async { context.completion(.success(text)) }
            }
        } else {
            let err = NSError(domain: "WhisperBridge", code: -3,
                              userInfo: [NSLocalizedDescriptionKey: "Invalid response from Python"])
            DispatchQueue.main.async { context.completion(.failure(err)) }
        }
    }

    // MARK: - Transcription

    func transcribeForSubtitle(audioURL: URL, model: String?,
                                completion: @escaping (Result<(english: String, chinese: String), Error>) -> Void) {
        lock.lock()
        guard isReady else {
            lock.unlock()
            let err = NSError(domain: "WhisperBridge", code: -3,
                              userInfo: [NSLocalizedDescriptionKey: "Python backend not ready"])
            completion(.failure(err))
            return
        }
        lock.unlock()

        resetIdleTimer()

        var request: [String: Any] = [
            "action": "subtitle",
            "audio_path": audioURL.path,
            "model_type": "whisper"
        ]
        if let model = model, !model.isEmpty { request["model"] = model }

        // Wrap tuple completion using \u{0001} delimiter internally
        let wrapped: (Result<String, Error>) -> Void = { result in
            switch result {
            case .success(let encoded):
                let parts = encoded.components(separatedBy: "\u{0001}")
                if parts.count == 2 {
                    completion(.success((english: parts[0], chinese: parts[1])))
                } else {
                    completion(.success((english: encoded, chinese: "")))
                }
            case .failure(let error):
                completion(.failure(error))
            }
        }

        queueRequest(payload: request, timeout: 180.0, label: "Subtitle", completion: wrapped)
    }

    func lookup(text: String, textModel: String? = nil,
                completion: @escaping (Result<String, Error>) -> Void) {
        lock.lock()
        guard isReady else {
            lock.unlock()
            let err = NSError(domain: "WhisperBridge", code: -3,
                              userInfo: [NSLocalizedDescriptionKey: "Python backend not ready"])
            completion(.failure(err))
            return
        }
        lock.unlock()

        resetIdleTimer()

        var request: [String: Any] = ["action": "lookup", "text": text]
        if let model = textModel { request["text_model"] = model }
        queueRequest(payload: request, timeout: 30.0, label: "Lookup", completion: completion)
    }

    func translate(text: String, textModel: String? = nil,
                   completion: @escaping (Result<String, Error>) -> Void) {
        lock.lock()
        guard isReady else {
            lock.unlock()
            let err = NSError(domain: "WhisperBridge", code: -3,
                              userInfo: [NSLocalizedDescriptionKey: "Python backend not ready"])
            completion(.failure(err))
            return
        }
        lock.unlock()

        resetIdleTimer()

        var request: [String: Any] = ["action": "translate", "text": text]
        if let model = textModel { request["text_model"] = model }
        queueRequest(payload: request, timeout: 30.0, label: "Translate", completion: completion)
    }

    struct SubtitleChunk {
        let text: String                            // live partial (incomplete tail)
        let committed: Bool
        let chinese: String                         // translation of committed tail
        let eagerSentences: [(en: String, zh: String)]    // new eager sentences this call
        let utteranceSentences: [(en: String, zh: String)] // all eager for utterance (on commit only)
    }

    func streamSubtitle(audioURL: URL?, modelPath: String, initialPrompt: String? = nil, reset: Bool = false,
                        completion: @escaping (Result<SubtitleChunk, Error>) -> Void) {
        lock.lock()
        guard isReady else {
            lock.unlock()
            let err = NSError(domain: "WhisperBridge", code: -3,
                              userInfo: [NSLocalizedDescriptionKey: "Python backend not ready"])
            completion(.failure(err))
            return
        }
        lock.unlock()

        resetIdleTimer()

        var request: [String: Any] = ["action": "subtitle_stream", "model_path": modelPath]
        if let prompt = initialPrompt, !prompt.isEmpty { request["initial_prompt"] = prompt }
        if reset {
            request["reset"] = true
        } else if let url = audioURL {
            request["audio_path"] = url.path
        } else {
            return
        }

        let wrapped: (Result<String, Error>) -> Void = { result in
            switch result {
            case .success(let jsonStr):
                guard let data = jsonStr.data(using: .utf8),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    completion(.success(SubtitleChunk(text: "", committed: false, chinese: "", eagerSentences: [], utteranceSentences: [])))
                    return
                }
                let text = json["text"] as? String ?? ""
                let committed = json["committed"] as? Bool ?? false
                let chinese = json["chinese"] as? String ?? ""
                var eager: [(en: String, zh: String)] = []
                if let arr = json["eager_sentences"] as? [[String: String]] {
                    eager = arr.compactMap { d in
                        guard let en = d["en"] else { return nil }
                        return (en: en, zh: d["zh"] ?? "")
                    }
                }
                var utterance: [(en: String, zh: String)] = []
                if let arr = json["utterance_sentences"] as? [[String: String]] {
                    utterance = arr.compactMap { d in
                        guard let en = d["en"] else { return nil }
                        return (en: en, zh: d["zh"] ?? "")
                    }
                }
                completion(.success(SubtitleChunk(text: text, committed: committed,
                                                  chinese: chinese, eagerSentences: eager,
                                                  utteranceSentences: utterance)))
            case .failure(let error):
                completion(.failure(error))
            }
        }
        queueRequest(payload: request, timeout: 30.0, label: "SubtitleStream", completion: wrapped)
    }

    func transcribe(audioURL: URL, model: String?, language: String?,
                    completion: @escaping (Result<String, Error>) -> Void) {
        lock.lock()
        guard isReady else {
            lock.unlock()
            let err = NSError(domain: "WhisperBridge", code: -3,
                              userInfo: [NSLocalizedDescriptionKey: "Python backend not ready. Please complete setup first."])
            completion(.failure(err))
            return
        }
        lock.unlock()

        resetIdleTimer()

        var request: [String: Any] = [
            "action": "transcribe",
            "audio_path": audioURL.path,
            "model_type": AppState.shared.selectedModel.modelType
        ]
        if let model = model, !model.isEmpty { request["model"] = model }
        if let lang = language, !lang.isEmpty, lang != "auto" { request["language"] = lang }
        let prompt = DictionaryService.shared.buildPrompt(basePrompt: AppState.shared.initialPrompt)
        if !prompt.isEmpty { request["initial_prompt"] = prompt }
        if AppState.shared.removeFillers { request["remove_fillers"] = true }

        queueRequest(payload: request, timeout: Self.transcribeTimeout, label: "Transcribe") { result in
            completion(result)
        }
    }

    private func queueRequest(payload: [String: Any], timeout: TimeInterval, label: String,
                              completion: @escaping (Result<String, Error>) -> Void) {
        lock.lock()
        guard isReady, let pipe = stdinPipe else {
            lock.unlock()
            let err = NSError(domain: "WhisperBridge", code: -3,
                              userInfo: [NSLocalizedDescriptionKey: "Python backend not ready"])
            DispatchQueue.main.async { completion(.failure(err)) }
            return
        }
        let id = payload["id"] as? String ?? UUID().uuidString
        var request = payload
        request["id"] = id

        let timeoutItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            self.lock.lock()
            let context = self.pendingRequests.removeValue(forKey: id)
            self.lock.unlock()
            guard let context = context else { return }
            logError("WhisperBridge", "\(label) timed out after \(timeout)s")
            let err = NSError(domain: "WhisperBridge", code: -4,
                              userInfo: [NSLocalizedDescriptionKey: "\(label) timed out"])
            DispatchQueue.main.async { context.completion(.failure(err)) }
        }

        let context = RequestContext(completion: completion, startTime: Date(), timeoutItem: timeoutItem, label: label)
        pendingRequests[id] = context
        lock.unlock()

        do {
            let jsonData = try JSONSerialization.data(withJSONObject: request)
            var line = jsonData
            line.append(contentsOf: "\n".data(using: .utf8)!)
            pipe.fileHandleForWriting.write(line)
        } catch {
            lock.lock()
            let context = pendingRequests.removeValue(forKey: id)
            lock.unlock()
            context?.timeoutItem.cancel()
            DispatchQueue.main.async { completion(.failure(error)) }
            return
        }

        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutItem)
    }

    // MARK: - Warm-up helpers

    private func warmUpBackend() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            guard let audioURL = self.createWarmupAudio() else {
                logWarn("WhisperBridge", "Warm-up audio unavailable")
                return
            }
            var request: [String: Any] = [
                "action": "transcribe",
                "audio_path": audioURL.path,
                "model_type": AppState.shared.selectedModel.modelType
            ]
            request["model"] = AppState.shared.resolvedModelPath

            self.queueRequest(payload: request, timeout: Self.warmupTimeout, label: "Warm-up") { result in
                switch result {
                case .success(let text):
                    logInfo("WhisperBridge", "Warm-up transcription produced \(text.count) chars")
                case .failure(let error):
                    logWarn("WhisperBridge", "Warm-up failed: \(error.localizedDescription)")
                }
                try? FileManager.default.removeItem(at: audioURL)
            }
        }
    }

    private func createWarmupAudio(duration: TimeInterval = 0.12, sampleRate: Double = 16000) -> URL? {
        let frameCount = AVAudioFrameCount(max(1, Int(sampleRate * duration)))
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            return nil
        }
        buffer.frameLength = frameCount
        if let channelData = buffer.floatChannelData?[0] {
            let count = Int(buffer.frameLength)
            for idx in 0..<count { channelData[idx] = 0 }
        }

        let warmupURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("typelessmlx_warmup.wav")
        try? FileManager.default.removeItem(at: warmupURL)

        do {
            let file = try AVAudioFile(forWriting: warmupURL, settings: format.settings)
            try file.write(from: buffer)
            return warmupURL
        } catch {
            logWarn("WhisperBridge", "Failed to write warm-up audio: \(error.localizedDescription)")
            try? FileManager.default.removeItem(at: warmupURL)
            return nil
        }
    }

    // MARK: - Idle Timer

    private func resetIdleTimer() {
        guard !AppState.shared.keepBackendAlive else { return }
        idleTimer?.invalidate()
        DispatchQueue.main.async { [weak self] in
            self?.idleTimer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: false) { [weak self] _ in
                logInfo("WhisperBridge", "Idle timeout — stopping Python process to save power")
                self?.stopProcess()
                DispatchQueue.main.async {
                    AppState.shared.hasPythonBackend = false
                }
            }
        }
    }

    // MARK: - Health Ping
    private func sendPing() {
        lock.lock()
        guard isReady, let pipe = stdinPipe else {
            lock.unlock()
            return
        }
        lock.unlock()

        let request: [String: Any] = ["action": "ping", "id": UUID().uuidString]
        do {
            let data = try JSONSerialization.data(withJSONObject: request)
            var line = data
            line.append(contentsOf: "\n".data(using: .utf8)!)
            pipe.fileHandleForWriting.write(line)
        } catch {}
    }

    // MARK: - Environment

    static func makeEnv() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let venvBin = NSHomeDirectory() + "/.local/share/typelessmlx/venv/bin"
        let paths = [venvBin, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
        env["PATH"] = (paths + [(env["PATH"] ?? "")]).joined(separator: ":")
        env["HF_HOME"] = NSHomeDirectory() + "/.cache/huggingface"
        env["PYTHONUNBUFFERED"] = "1"
        env["HF_HUB_OFFLINE"] = "0"  // override shell setting; downloads must be allowed
        // Use hf-mirror.com if no custom endpoint is set in the shell environment
        if env["HF_ENDPOINT"] == nil {
            env["HF_ENDPOINT"] = "https://hf-mirror.com"
        }
        // Corporate CA certificate — prefer the in-app setting, fall back to
        // NODE_EXTRA_CA_CERTS (only present when launched from a shell).
        let certPath = AppState.shared.customCACertPath.trimmingCharacters(in: .whitespaces)
        let cert = !certPath.isEmpty ? certPath : (env["NODE_EXTRA_CA_CERTS"] ?? "")
        if !cert.isEmpty {
            let expanded = (cert as NSString).expandingTildeInPath
            env["SSL_CERT_FILE"] = expanded       // Python ssl / urllib / requests
            env["REQUESTS_CA_BUNDLE"] = expanded  // huggingface_hub
            env["CURL_CA_BUNDLE"] = expanded      // curl
            env["UV_CERT"] = expanded             // uv (uses rustls, ignores SSL_CERT_FILE)
        }
        return env
    }
}
