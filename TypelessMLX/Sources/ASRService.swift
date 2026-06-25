import Foundation

/// Manages the asr-server Rust binary as a long-running subprocess and exposes
/// HTTP-based transcription via POST /v1/audio/transcriptions (OpenAI-compatible).
///
/// Usage:
///   let text = try await ASRService.shared.transcribe(url: wavURL, language: "zh")
actor ASRService {
    static let shared = ASRService()

    private var process: Process?
    private var port: Int = 0
    private var currentModelPath: String = ""
    private let urlSession = URLSession(configuration: .ephemeral)

    private static let healthPollInterval: TimeInterval = 0.2
    private static let healthPollTimeout: TimeInterval = 30.0

    private init() {}

    // MARK: - Public API

    /// Transcribes the WAV file at `url`.
    /// Lazily starts the asr-server subprocess on first call; restarts it when
    /// the resolved model path changes.
    func transcribe(url: URL, language: String? = nil) async throws -> String {
        let modelPath = resolveModelPath(AppState.shared.resolvedModelPath)

        if process == nil || !isProcessRunning() || currentModelPath != modelPath {
            try await startServer(modelPath: modelPath)
        }

        return try await postAudio(url: url, language: language)
    }

    /// Terminates the asr-server subprocess.
    func stop() {
        process?.terminate()
        process = nil
        currentModelPath = ""
        port = 0
        logInfo("ASRService", "asr-server stopped")
    }

    // MARK: - Server Lifecycle

    private func startServer(modelPath: String) async throws {
        // Terminate any existing process before starting fresh
        if let existing = process {
            existing.terminate()
            process = nil
        }

        guard !modelPath.isEmpty else {
            throw NSError(domain: "ASRService", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Model path is empty"])
        }

        guard FileManager.default.fileExists(atPath: modelPath) else {
            throw NSError(domain: "ASRService", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "Model path not found: \(modelPath)"])
        }

        let binaryPath = resolveBinaryPath()
        guard FileManager.default.fileExists(atPath: binaryPath) else {
            throw NSError(domain: "ASRService", code: -3,
                          userInfo: [NSLocalizedDescriptionKey: "asr-server binary not found at: \(binaryPath)"])
        }

        let newPort = Int.random(in: 18000...19000)
        logInfo("ASRService", "Starting asr-server on port \(newPort), model: \(modelPath)")

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binaryPath)
        proc.arguments = ["--model-dir", modelPath, "--port", "\(newPort)"]

        // Redirect stdout/stderr to logger
        let stderrPipe = Pipe()
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = stderrPipe

        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty, let text = String(data: data, encoding: .utf8) {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { logDebug("asr-server", trimmed) }
            }
        }

        proc.terminationHandler = { [weak self] p in
            logWarn("ASRService", "asr-server terminated (exit: \(p.terminationStatus))")
            Task { await self?.handleTermination() }
        }

        do {
            try proc.run()
        } catch {
            throw NSError(domain: "ASRService", code: -4,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to launch asr-server: \(error.localizedDescription)"])
        }

        process = proc
        port = newPort
        currentModelPath = modelPath

        try await waitForHealth()
        logInfo("ASRService", "asr-server ready on port \(newPort)")
    }

    private func handleTermination() {
        process = nil
        currentModelPath = ""
    }

    private func isProcessRunning() -> Bool {
        return process?.isRunning == true
    }

    // MARK: - Health Check

    private func waitForHealth() async throws {
        guard let healthURL = URL(string: "http://localhost:\(port)/health") else { return }
        let deadline = Date().addingTimeInterval(Self.healthPollTimeout)
        while Date() < deadline {
            if let (_, response) = try? await urlSession.data(from: healthURL),
               (response as? HTTPURLResponse)?.statusCode == 200 {
                return
            }
            try await Task.sleep(nanoseconds: UInt64(Self.healthPollInterval * 1_000_000_000))
        }
        throw NSError(domain: "ASRService", code: -5,
                      userInfo: [NSLocalizedDescriptionKey:
                                    "asr-server did not become ready within \(Self.healthPollTimeout)s"])
    }

    // MARK: - HTTP Transcription

    private func postAudio(url: URL, language: String?) async throws -> String {
        guard let endpoint = URL(string: "http://localhost:\(port)/v1/audio/transcriptions") else {
            throw NSError(domain: "ASRService", code: -6,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid endpoint URL"])
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"

        let boundary = "TypelessMLXBoundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)",
                         forHTTPHeaderField: "Content-Type")

        let audioData = try Data(contentsOf: url)
        var body = Data()

        // Audio file field
        body.appendString("--\(boundary)\r\n")
        body.appendString("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n")
        body.appendString("Content-Type: audio/wav\r\n\r\n")
        body.append(audioData)
        body.appendString("\r\n")

        // Model field (required by OpenAI-compatible API)
        body.appendString("--\(boundary)\r\n")
        body.appendString("Content-Disposition: form-data; name=\"model\"\r\n\r\n")
        body.appendString("qwen3-asr\r\n")

        // Optional language field
        if let lang = language, !lang.isEmpty, lang != "auto" {
            body.appendString("--\(boundary)\r\n")
            body.appendString("Content-Disposition: form-data; name=\"language\"\r\n\r\n")
            body.appendString("\(lang)\r\n")
        }

        body.appendString("--\(boundary)--\r\n")
        request.httpBody = body

        let (responseData, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "ASRService", code: -7,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid HTTP response"])
        }
        guard httpResponse.statusCode == 200 else {
            let responseBody = String(data: responseData, encoding: .utf8) ?? "(no body)"
            throw NSError(domain: "ASRService", code: httpResponse.statusCode,
                          userInfo: [NSLocalizedDescriptionKey:
                                        "HTTP \(httpResponse.statusCode): \(responseBody)"])
        }

        guard let json = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let text = json["text"] as? String else {
            throw NSError(domain: "ASRService", code: -8,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to parse transcription response"])
        }

        logInfo("ASRService", "Transcription (\(text.count) chars): \(text.prefix(80))")
        return text
    }

    // MARK: - Path Resolution

    private func resolveBinaryPath() -> String {
        // Production: app bundle Contents/Resources/bin/asr-server
        if let resourcePath = Bundle.main.resourcePath {
            let bundledPath = (resourcePath as NSString).appendingPathComponent("bin/asr-server")
            if FileManager.default.fileExists(atPath: bundledPath) { return bundledPath }
        }
        // Dev fallback: vendor/qwen3_asr_rs/target/release/asr-server (relative to this source file)
        let projectRoot = URL(fileURLWithPath: #file)
            .deletingLastPathComponent() // Sources/
            .deletingLastPathComponent() // TypelessMLX/
            .deletingLastPathComponent() // project root
        return projectRoot.appendingPathComponent("vendor/qwen3_asr_rs/target/release/asr-server").path
    }

    private func resolveModelPath(_ modelPath: String) -> String {
        // If it's already an absolute path, use it directly
        if modelPath.hasPrefix("/") { return modelPath }
        // Convert HF repo ID (e.g. "mlx-community/Qwen3-ASR-0.6B-8bit") to local cache snapshot
        let sanitized = modelPath.replacingOccurrences(of: "/", with: "--")
        let cacheBase = (NSHomeDirectory() as NSString)
            .appendingPathComponent(".cache/huggingface/hub/models--\(sanitized)/snapshots")
        let snapshots = (try? FileManager.default.contentsOfDirectory(atPath: cacheBase)) ?? []
        if let snapshot = snapshots.first {
            return (cacheBase as NSString).appendingPathComponent(snapshot)
        }
        return modelPath  // fallback: return as-is, server will error with a clear message
    }
}

// MARK: - Data helper

private extension Data {
    mutating func appendString(_ string: String) {
        if let data = string.data(using: .utf8) { append(data) }
    }
}
