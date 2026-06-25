import Foundation

/// Translation and word lookup via a lightweight Python subprocess (translate_server.py).
/// Uses stdin/stdout JSON-RPC, same pattern as the old WhisperBridge but simpler.
class LLMService {
    static let shared = LLMService()

    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var isReady = false
    private var pendingRequests: [String: CheckedContinuation<String, Error>] = [:]
    private let lock = NSLock()
    private var readBuffer = ""
    private static let requestTimeout: TimeInterval = 60.0

    private init() {}

    // MARK: - Public API

    func translate(_ text: String) async throws -> String {
        try await ensureRunning()
        return try await sendRequest(action: "translate", text: text)
    }

    func lookup(_ word: String) async throws -> String {
        try await ensureRunning()
        return try await sendRequest(action: "lookup", text: word)
    }

    // MARK: - Process Management

    private func ensureRunning() async throws {
        lock.lock()
        let running = process?.isRunning == true && isReady
        lock.unlock()
        if running { return }
        try await start()
    }

    private func start() async throws {
        lock.lock()
        if process?.isRunning == true && isReady {
            lock.unlock(); return
        }
        lock.unlock()

        let python = pythonPath()
        let script = scriptPath()
        guard FileManager.default.fileExists(atPath: script) else {
            throw LLMError.scriptNotFound(script)
        }

        logInfo("LLMService", "Starting translate_server: \(script)")
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: python)
        proc.arguments = ["-u", script]
        proc.environment = makeEnv()

        let stdin = Pipe(); let stdout = Pipe(); let stderr = Pipe()
        proc.standardInput = stdin
        proc.standardOutput = stdout
        proc.standardError = stderr

        stderr.fileHandleForReading.readabilityHandler = { handle in
            if let text = String(data: handle.availableData, encoding: .utf8), !text.isEmpty {
                logDebug("LLMService", text.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }

        proc.terminationHandler = { [weak self] _ in
            logWarn("LLMService", "translate_server terminated")
            self?.lock.lock()
            self?.isReady = false
            self?.process = nil
            self?.lock.unlock()
        }

        try proc.run()

        lock.lock()
        self.process = proc
        self.stdinPipe = stdin
        self.stdoutPipe = stdout
        lock.unlock()

        // Wait for {"status":"ready"}
        let readyLine = await withCheckedContinuation { (cont: CheckedContinuation<String, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let line = stdout.fileHandleForReading.availableData
                let text = String(data: line, encoding: .utf8) ?? ""
                cont.resume(returning: text)
            }
        }
        guard readyLine.contains("ready") else { throw LLMError.startupFailed }

        lock.lock()
        isReady = true
        lock.unlock()

        // Start async read loop
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in self?.readLoop() }
        logInfo("LLMService", "translate_server ready")
    }

    // MARK: - JSON-RPC

    private func sendRequest(action: String, text: String) async throws -> String {
        let reqID = UUID().uuidString
        let payload = ["id": reqID, "action": action, "text": text]
        guard let line = (try? JSONSerialization.data(withJSONObject: payload))
                .flatMap({ String(data: $0, encoding: .utf8) }) else {
            throw LLMError.encodingFailed
        }

        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            pendingRequests[reqID] = continuation
            lock.unlock()

            guard let data = (line + "\n").data(using: .utf8) else {
                lock.lock(); pendingRequests.removeValue(forKey: reqID); lock.unlock()
                continuation.resume(throwing: LLMError.encodingFailed)
                return
            }

            stdinPipe?.fileHandleForWriting.write(data)

            // Timeout
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.requestTimeout) { [weak self] in
                guard let self else { return }
                self.lock.lock()
                let cont = self.pendingRequests.removeValue(forKey: reqID)
                self.lock.unlock()
                cont?.resume(throwing: LLMError.timeout)
            }
        }
    }

    private func readLoop() {
        guard let stdout = stdoutPipe else { return }
        while process?.isRunning == true {
            let data = stdout.fileHandleForReading.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { break }
            lock.lock()
            readBuffer += text
            lock.unlock()
            processBuffer()
        }
    }

    private func processBuffer() {
        lock.lock()
        let lines = readBuffer.components(separatedBy: "\n")
        readBuffer = lines.last ?? ""
        let complete = lines.dropLast()
        lock.unlock()

        for line in complete where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let data = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let reqID = json["id"] as? String else { continue }
            let result = (json["text"] as? String) ?? ""
            lock.lock()
            let cont = pendingRequests.removeValue(forKey: reqID)
            lock.unlock()
            cont?.resume(returning: result)
        }
    }

    // MARK: - Helpers

    private func pythonPath() -> String {
        let venv = NSHomeDirectory() + "/.local/share/typelessmlx/venv/bin/python"
        return FileManager.default.fileExists(atPath: venv) ? venv : "python3"
    }

    private func scriptPath() -> String {
        if let p = Bundle.main.path(forResource: "translate_server", ofType: "py", inDirectory: "backend") {
            return p
        }
        let root = URL(fileURLWithPath: #file)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return root.appendingPathComponent("backend/translate_server.py").path
    }

    private func makeEnv() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let venvBin = NSHomeDirectory() + "/.local/share/typelessmlx/venv/bin"
        env["PATH"] = ([venvBin, "/opt/homebrew/bin", "/usr/bin", "/bin"] + [(env["PATH"] ?? "")])
            .joined(separator: ":")
        env["HF_HOME"] = NSHomeDirectory() + "/.cache/huggingface"
        env["PYTHONUNBUFFERED"] = "1"
        if env["HF_ENDPOINT"] == nil { env["HF_ENDPOINT"] = "https://hf-mirror.com" }
        return env
    }

    enum LLMError: LocalizedError {
        case scriptNotFound(String), startupFailed, encodingFailed, timeout
        var errorDescription: String? {
            switch self {
            case .scriptNotFound(let p): return "translate_server.py not found at \(p)"
            case .startupFailed: return "translate_server failed to start"
            case .encodingFailed: return "JSON encoding error"
            case .timeout: return "translate_server request timed out"
            }
        }
    }
}
