# Native Backend Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the 663 MB Python backend with four native Swift/Rust components: ASRService, WhisperService, LLMService, PuncService.

**Architecture:** `qwen3_asr_rs` asr-server runs as a local HTTP subprocess for Qwen3-ASR. WhisperKit handles Whisper models. mlx-swift MLXLLM handles translation/lookup. sherpa-onnx Swift handles CT-Punc. All subtitle streaming logic moves from Python into `MeetingCaptureEngine`.

**Tech Stack:** Swift, Rust (qwen3_asr_rs), WhisperKit, mlx-swift MLXLLM, sherpa-onnx Swift binding, URLSession (HTTP to asr-server)

**Spec:** `docs/superpowers/specs/2026-06-25-native-backend-design.md`

---

## File Map

| Action | File | Purpose |
|--------|------|---------|
| Create | `TypelessMLX/Sources/ASRService.swift` | Manages asr-server process + HTTP transcription |
| Create | `TypelessMLX/Sources/WhisperService.swift` | WhisperKit wrapper |
| Create | `TypelessMLX/Sources/LLMService.swift` | MLXLLM translation + lookup |
| Create | `TypelessMLX/Sources/PuncService.swift` | sherpa-onnx CT-Punc |
| Modify | `Package.swift` | Add 3 new package dependencies |
| Modify | `TypelessMLX/Sources/HotkeyManager.swift` | Route to ASRService / WhisperService |
| Modify | `TypelessMLX/Sources/LookupManager.swift` | Use LLMService |
| Modify | `TypelessMLX/Sources/TranslateManager.swift` | Use LLMService |
| Modify | `TypelessMLX/Sources/MeetingCaptureEngine.swift` | Full subtitle pipeline in Swift |
| Modify | `TypelessMLX/Sources/AppState.swift` | Remove hasPythonBackend |
| Modify | `TypelessMLX/Sources/TypelessMLXApp.swift` | Remove Python startup logic |
| Modify | `build-app.sh` | Remove venv bundling, add asr-server build |
| Delete | `TypelessMLX/Sources/WhisperBridge.swift` | Replaced by ASRService + WhisperService |
| Delete | `TypelessMLX/Sources/SetupWindowController.swift` | Python setup flow no longer needed |
| Add submodule | `vendor/qwen3_asr_rs` | Rust source for asr-server |

---

## Prerequisites

Before starting, verify:
- `cargo` is installed: `cargo --version` → `cargo 1.x`
- `rustup target list --installed` includes `aarch64-apple-darwin`
- Xcode Command Line Tools installed

---

## Task 1: Add Swift Package Dependencies

**Files:**
- Modify: `Package.swift`

- [ ] **Step 1: Add package dependencies to Package.swift**

Replace the entire `Package.swift` with:

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TypelessMLX",
    platforms: [
        .macOS(.v13)
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit", from: "0.9.0"),
        .package(url: "https://github.com/ml-explore/mlx-swift-examples", branch: "main"),
        .package(url: "https://github.com/k2-fsa/sherpa-onnx", from: "1.10.0"),
    ],
    targets: [
        .target(
            name: "TypelessMLXAudioTapSupport",
            path: "TypelessMLX/AudioSupport",
            linkerSettings: [
                .linkedFramework("AVFoundation")
            ]
        ),
        .target(
            name: "TypelessMLXAudioInputSupport",
            path: "TypelessMLX/AudioInputSupport"
        ),
        .executableTarget(
            name: "TypelessMLX",
            dependencies: [
                "TypelessMLXAudioTapSupport",
                "TypelessMLXAudioInputSupport",
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "MLXLLM", package: "mlx-swift-examples"),
                .product(name: "MLXLMCommon", package: "mlx-swift-examples"),
                .product(name: "SherpaOnnx", package: "sherpa-onnx"),
            ],
            path: "TypelessMLX/Sources",
            linkerSettings: [
                .linkedFramework("Cocoa"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Carbon"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("UserNotifications"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("Speech"),
                .unsafeFlags(["-Xlinker", "-weak_framework", "-Xlinker", "FoundationModels"])
            ]
        ),
        .executableTarget(
            name: "TypelessMLXAudioTapFormatTests",
            dependencies: ["TypelessMLXAudioTapSupport"],
            path: "TypelessMLX/Tests/AudioTapFormat"
        ),
        .executableTarget(
            name: "TypelessMLXAudioInputAvailabilityTests",
            dependencies: ["TypelessMLXAudioInputSupport"],
            path: "TypelessMLX/Tests/AudioInputAvailability"
        )
    ]
)
```

- [ ] **Step 2: Resolve packages and verify build**

```bash
swift package resolve
swift build 2>&1 | tail -5
```

Expected: `Build complete!` (or package resolution errors to fix — check exact product names against each package's Package.swift if needed)

- [ ] **Step 3: Commit**

```bash
git add Package.swift Package.resolved
git commit -m "Add WhisperKit, MLXLLM, sherpa-onnx Swift package dependencies"
```

---

## Task 2: Vendor qwen3_asr_rs and Build asr-server

**Files:**
- Add: `vendor/qwen3_asr_rs/` (git submodule)

- [ ] **Step 1: Add git submodule**

```bash
git submodule add https://github.com/second-state/qwen3_asr_rs vendor/qwen3_asr_rs
```

- [ ] **Step 2: Build asr-server with MLX backend**

```bash
cd vendor/qwen3_asr_rs
cargo build --release --features mlx
ls -lh target/release/asr-server
```

Expected: `asr-server` binary ~10–30 MB

- [ ] **Step 3: Test asr-server starts**

```bash
./target/release/asr-server --model mlx-community/Qwen3-ASR-0.6B-8bit --port 18080 &
sleep 3
curl -s http://localhost:18080/health
kill %1
```

Expected: `{"status":"ok"}` or similar health response

- [ ] **Step 4: Commit**

```bash
cd ../..
git add vendor/qwen3_asr_rs .gitmodules
git commit -m "Add qwen3_asr_rs as git submodule; build asr-server binary"
```

---

## Task 3: PuncService

**Files:**
- Create: `TypelessMLX/Sources/PuncService.swift`

- [ ] **Step 1: Create PuncService.swift**

```swift
import Foundation
import SherpaOnnx

/// Wraps sherpa-onnx offline CT-Punc for synchronous punctuation restoration.
class PuncService {
    static let shared = PuncService()

    private var punc: SherpaOnnxOfflinePunctuationWrapper?
    private let modelDir: String = {
        let name = "sherpa-onnx-punct-ct-transformer-zh-en-vocab272727-2024-04-12-int8"
        return (NSHomeDirectory() as NSString)
            .appendingPathComponent(".cache/sherpa-onnx/\(name)")
    }()

    private init() {}

    /// Add punctuation to raw ASR text. Returns input unchanged on failure.
    func restore(_ text: String) -> String {
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return text }
        if punc == nil { punc = loadModel() }
        guard let p = punc else { return text }
        return p.addPunct(text: text)
    }

    private func loadModel() -> SherpaOnnxOfflinePunctuationWrapper? {
        let onnx = (modelDir as NSString).appendingPathComponent("model.int8.onnx")
        guard FileManager.default.fileExists(atPath: onnx) else {
            logWarn("PuncService", "CT-Punc model not found at \(onnx)")
            return nil
        }
        let modelConfig = sherpaOnnxOfflinePunctuationModelConfig(ctTransformer: onnx)
        let config = sherpaOnnxOfflinePunctuationConfig(model: modelConfig, numThreads: 2)
        return SherpaOnnxOfflinePunctuationWrapper(config: config)
    }
}
```

- [ ] **Step 2: Verify build**

```bash
swift build 2>&1 | grep -E "error:|Build complete"
```

Expected: `Build complete!`

- [ ] **Step 3: Manual smoke test**

Add temporarily to `TypelessMLXApp.applicationDidFinishLaunching`:
```swift
let result = PuncService.shared.restore("今天天气很好我们去公园走走吧")
print("PuncService test:", result)
```
Run app, check log for: `今天天气很好，我们去公园走走吧。`
Remove the test line after verifying.

- [ ] **Step 4: Commit**

```bash
git add TypelessMLX/Sources/PuncService.swift
git commit -m "Add PuncService: sherpa-onnx CT-Punc wrapper"
```

---

## Task 4: LLMService

**Files:**
- Create: `TypelessMLX/Sources/LLMService.swift`

- [ ] **Step 1: Create LLMService.swift**

```swift
import Foundation
import MLXLLM
import MLXLMCommon

/// Wraps mlx-swift MLXLLM for translation and word lookup.
@MainActor
class LLMService: ObservableObject {
    static let shared = LLMService()

    private var container: ModelContainer?
    private var loadedModelPath: String?
    @Published var isReady = false

    private init() {}

    // MARK: - Public API

    func translate(_ text: String) async throws -> String {
        let container = try await ensureModel()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let cjkCount = trimmed.unicodeScalars.filter { $0.value >= 0x4E00 && $0.value <= 0x9FFF }.count
        let isChinese = Double(cjkCount) / Double(max(trimmed.count, 1)) > 0.3

        let prompt: String
        if isChinese {
            prompt = try buildPrompt(container: container, messages: [
                ["role": "system", "content": "You are a translator. Translate the Chinese text to natural, fluent English. Output only the translation, no explanations."],
                ["role": "user", "content": "「\(trimmed)」"]
            ])
        } else {
            prompt = try buildPrompt(container: container, messages: [
                ["role": "user", "content": "将以下英文翻译成简体中文，只输出中文译文，不要输出英文：\n「\(trimmed)」"]
            ])
        }

        let result = try await generate(container: container, prompt: prompt, maxTokens: 400)
        logInfo("LLMService", "translate result: \(result.prefix(80))")

        // Validate output direction
        let resultCJK = result.unicodeScalars.filter { $0.value >= 0x4E00 && $0.value <= 0x9FFF }.count
        let resultIsChinese = Double(resultCJK) / Double(max(result.count, 1)) > 0.3
        if isChinese && resultIsChinese { return "" }  // ZH→EN but got Chinese back
        if !isChinese && !resultIsChinese { return "" } // EN→ZH but got English back
        return result
    }

    func lookup(_ word: String) async throws -> String {
        let container = try await ensureModel()
        let prompt = try buildPrompt(container: container, messages: [
            ["role": "user", "content": """
                你是英汉词典，只输出2行，不多不少。格式：
                第1行: [词性] [中文核心含义，不超过8字]
                第2行: 例: [英文短句] → [中文]

                单词：「\(word.trimmingCharacters(in: .whitespacesAndNewlines))」
                """]
        ])
        let result = try await generate(container: container, prompt: prompt, maxTokens: 80)
        logInfo("LLMService", "lookup result: \(result.prefix(80))")
        return result
    }

    // MARK: - Model Management

    func preload() async {
        _ = try? await ensureModel()
    }

    private func ensureModel() async throws -> ModelContainer {
        let modelPath = await MainActor.run { AppState.shared.resolvedTextModelPath }
        if let c = container, loadedModelPath == modelPath { return c }

        logInfo("LLMService", "Loading text model: \(modelPath)")
        let config = ModelConfiguration(id: modelPath)
        let c = try await LLMModelFactory.shared.loadContainer(configuration: config)
        container = c
        loadedModelPath = modelPath
        isReady = true
        logInfo("LLMService", "Text model ready")
        return c
    }

    private func buildPrompt(container: ModelContainer, messages: [[String: String]]) throws -> String {
        try container.perform { _, tokenizer in
            try tokenizer.applyChatTemplate(messages: messages)
        }
    }

    private func generate(container: ModelContainer, prompt: String, maxTokens: Int) async throws -> String {
        var output = ""
        let stream = try await container.perform { model, tokenizer in
            let input = try tokenizer.encode(text: prompt)
            return model.generate(input: .tokens(MLXArray(input)), parameters: .init(maxTokens: maxTokens))
        }
        for await token in stream {
            output += token
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
```

> **Note:** Verify the exact `ModelContainer` API against mlx-swift-examples. The `perform` pattern and `generate` stream API may differ slightly — check `LLMEval` example in the package.

- [ ] **Step 2: Verify build**

```bash
swift build 2>&1 | grep -E "error:|Build complete"
```

- [ ] **Step 3: Manual smoke test**

In `applicationDidFinishLaunching`:
```swift
Task {
    let result = try? await LLMService.shared.translate("Hello world")
    print("LLMService test:", result ?? "nil")
}
```
Expected log: `LLMService test: 你好，世界。`
Remove after verifying.

- [ ] **Step 4: Commit**

```bash
git add TypelessMLX/Sources/LLMService.swift
git commit -m "Add LLMService: MLXLLM wrapper for translation and lookup"
```

---

## Task 5: ASRService

**Files:**
- Create: `TypelessMLX/Sources/ASRService.swift`

- [ ] **Step 1: Create ASRService.swift**

```swift
import Foundation

/// Manages the qwen3_asr_rs asr-server subprocess and transcribes audio via HTTP.
class ASRService {
    static let shared = ASRService()

    private var process: Process?
    private var port: Int = 0
    private var currentModelPath: String = ""
    private let lock = NSLock()
    private static let startupTimeout: TimeInterval = 30

    private init() {}

    // MARK: - Public API

    func transcribe(url: URL, language: String? = nil) async throws -> String {
        try await ensureRunning()
        return try await sendRequest(audioURL: url, language: language)
    }

    func stop() {
        lock.lock()
        let proc = process
        process = nil
        port = 0
        currentModelPath = ""
        lock.unlock()
        proc?.terminate()
        logInfo("ASRService", "asr-server stopped")
    }

    // MARK: - Process Management

    private func ensureRunning() async throws {
        let modelPath = AppState.shared.resolvedModelPath

        lock.lock()
        let alreadyRunning = process?.isRunning == true && currentModelPath == modelPath
        lock.unlock()

        if alreadyRunning { return }

        stop()
        try await startServer(modelPath: modelPath)
    }

    private func startServer(modelPath: String) async throws {
        let binary = serverBinaryPath()
        guard FileManager.default.fileExists(atPath: binary) else {
            throw ASRError.binaryNotFound(binary)
        }

        let p = Int.random(in: 18000...19000)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binary)
        proc.arguments = ["--model", modelPath, "--port", "\(p)"]
        proc.environment = makeEnv()
        proc.standardOutput = FileHandle.nullDevice

        let errPipe = Pipe()
        proc.standardError = errPipe
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            if let text = String(data: handle.availableData, encoding: .utf8), !text.isEmpty {
                logDebug("asr-server", text.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }

        try proc.run()
        logInfo("ASRService", "Starting asr-server on port \(p), model: \(modelPath)")

        // Wait for server to be ready
        let deadline = Date().addingTimeInterval(Self.startupTimeout)
        while Date() < deadline {
            if let _ = try? await healthCheck(port: p) { break }
            try await Task.sleep(nanoseconds: 500_000_000)
        }

        guard proc.isRunning else { throw ASRError.startupFailed }

        lock.lock()
        self.process = proc
        self.port = p
        self.currentModelPath = modelPath
        lock.unlock()
        logInfo("ASRService", "asr-server ready on port \(p)")
    }

    private func healthCheck(port: Int) async throws -> Bool {
        let url = URL(string: "http://localhost:\(port)/health")!
        let (_, response) = try await URLSession.shared.data(from: url)
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    // MARK: - HTTP Transcription

    private func sendRequest(audioURL: URL, language: String?) async throws -> String {
        lock.lock()
        let p = port
        lock.unlock()

        var request = URLRequest(url: URL(string: "http://localhost:\(p)/v1/audio/transcriptions")!)
        request.httpMethod = "POST"
        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        // model field
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\nqwen3-asr\r\n".data(using: .utf8)!)
        // language field
        if let lang = language, !lang.isEmpty, lang != "auto" {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"language\"\r\n\r\n\(lang)\r\n".data(using: .utf8)!)
        }
        // file field
        let audioData = try Data(contentsOf: audioURL)
        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(audioData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body
        request.timeoutInterval = 120

        let (data, _) = try await URLSession.shared.data(for: request)
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["text"] as? String else {
            throw ASRError.invalidResponse
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Helpers

    private func serverBinaryPath() -> String {
        if let bundled = Bundle.main.path(forResource: "asr-server", ofType: nil, inDirectory: "bin") {
            return bundled
        }
        // Development fallback
        let projectRoot = URL(fileURLWithPath: #file)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return projectRoot.appendingPathComponent("vendor/qwen3_asr_rs/target/release/asr-server").path
    }

    private func makeEnv() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["HF_HOME"] = NSHomeDirectory() + "/.cache/huggingface"
        if env["HF_ENDPOINT"] == nil { env["HF_ENDPOINT"] = "https://hf-mirror.com" }
        return env
    }

    enum ASRError: LocalizedError {
        case binaryNotFound(String)
        case startupFailed
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .binaryNotFound(let p): return "asr-server binary not found at \(p)"
            case .startupFailed: return "asr-server failed to start"
            case .invalidResponse: return "Invalid response from asr-server"
            }
        }
    }
}
```

- [ ] **Step 2: Verify build**

```bash
swift build 2>&1 | grep -E "error:|Build complete"
```

- [ ] **Step 3: Manual smoke test**

```swift
// In applicationDidFinishLaunching:
Task {
    do {
        let text = try await ASRService.shared.transcribe(url: someWAVURL)
        print("ASRService test:", text)
    } catch {
        print("ASRService error:", error)
    }
}
```

- [ ] **Step 4: Commit**

```bash
git add TypelessMLX/Sources/ASRService.swift
git commit -m "Add ASRService: qwen3_asr_rs subprocess manager with HTTP transcription"
```

---

## Task 6: WhisperService

**Files:**
- Create: `TypelessMLX/Sources/WhisperService.swift`

- [ ] **Step 1: Create WhisperService.swift**

```swift
import Foundation
import WhisperKit

/// Wraps WhisperKit for Whisper model transcription.
class WhisperService {
    static let shared = WhisperService()

    private var pipeline: WhisperKit?
    private var loadedModelPath: String?

    private init() {}

    func transcribe(url: URL, language: String?) async throws -> String {
        let modelPath = AppState.shared.resolvedModelPath
        if pipeline == nil || loadedModelPath != modelPath {
            logInfo("WhisperService", "Loading model: \(modelPath)")
            pipeline = try await WhisperKit(model: modelPath)
            loadedModelPath = modelPath
            logInfo("WhisperService", "Whisper model ready")
        }

        var options = DecodingOptions()
        if let lang = language, !lang.isEmpty, lang != "auto" {
            options.language = lang
        }

        let results = try await pipeline!.transcribe(audioPath: url.path, decodeOptions: options)
        return results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
```

- [ ] **Step 2: Verify build**

```bash
swift build 2>&1 | grep -E "error:|Build complete"
```

- [ ] **Step 3: Commit**

```bash
git add TypelessMLX/Sources/WhisperService.swift
git commit -m "Add WhisperService: WhisperKit wrapper"
```

---

## Task 7: AppState — Remove hasPythonBackend

**Files:**
- Modify: `TypelessMLX/Sources/AppState.swift`

- [ ] **Step 1: Remove hasPythonBackend and update updatePermissionState**

In `AppState.swift`:

1. Delete line: `@Published var hasPythonBackend: Bool = false`

2. Replace `updatePermissionState()`:
```swift
func updatePermissionState() {
    if hasMicPermission && hasAccessibilityPermission {
        permissionState = .ready
    } else {
        permissionState = .missingPermissions
    }
    logInfo("AppState", "Permission state: \(permissionState.rawValue) [mic=\(hasMicPermission) ax=\(hasAccessibilityPermission)]")
}
```

- [ ] **Step 2: Verify build (will have errors — fix in next step)**

```bash
swift build 2>&1 | grep "error:"
```

Note all references to `hasPythonBackend` and fix them one by one.

- [ ] **Step 3: Fix all hasPythonBackend references**

Search and remove/replace:
```bash
grep -rn "hasPythonBackend" TypelessMLX/Sources/
```

For each occurrence:
- `TypelessMLXApp.swift`: remove the `AppState.shared.hasPythonBackend = success` line and the Python startup check block
- `HotkeyManager.swift`: remove the `if modelType != "macos", !appState.hasPythonBackend` guard; services start lazily
- `MeetingCaptureEngine.swift`: remove `guard appState?.hasPythonBackend == true` guards

- [ ] **Step 4: Verify clean build**

```bash
swift build 2>&1 | grep -E "error:|Build complete"
```

Expected: `Build complete!`

- [ ] **Step 5: Commit**

```bash
git add TypelessMLX/Sources/AppState.swift TypelessMLX/Sources/TypelessMLXApp.swift \
        TypelessMLX/Sources/HotkeyManager.swift TypelessMLX/Sources/MeetingCaptureEngine.swift
git commit -m "Remove hasPythonBackend from AppState and all callers"
```

---

## Task 8: HotkeyManager — Route to Native Services

**Files:**
- Modify: `TypelessMLX/Sources/HotkeyManager.swift`

- [ ] **Step 1: Replace WhisperBridge.transcribe call in transcription flow**

Find the block around line 375–381 in `HotkeyManager.swift`:
```swift
// OLD — remove this block:
let model = appState.resolvedModelPath
logInfo("HotkeyManager", "Sending to WhisperBridge. ...")
WhisperBridge.shared.transcribe(audioURL: audioURL, model: model, language: language, completion: handleResult)
```

Replace with:
```swift
let modelType = appState.selectedModel.modelType
logInfo("HotkeyManager", "Transcribing with \(modelType) model")

Task { [weak self] in
    do {
        let text: String
        switch modelType {
        case "qwen3":
            text = try await ASRService.shared.transcribe(url: audioURL, language: language)
        case "whisper":
            text = try await WhisperService.shared.transcribe(url: audioURL, language: language)
        default:
            return  // macOS model handled above via SpeechStreamer
        }
        await MainActor.run { handleResult(.success(text)) }
    } catch {
        await MainActor.run { handleResult(.failure(error)) }
    }
}
```

- [ ] **Step 2: Remove WhisperBridge.shared.start call**

Find and remove the block that calls `WhisperBridge.shared.start { ... }` (around line 225). Services start lazily now.

- [ ] **Step 3: Verify build**

```bash
swift build 2>&1 | grep -E "error:|Build complete"
```

- [ ] **Step 4: Commit**

```bash
git add TypelessMLX/Sources/HotkeyManager.swift
git commit -m "HotkeyManager: route to ASRService/WhisperService instead of WhisperBridge"
```

---

## Task 9: LookupManager + TranslateManager

**Files:**
- Modify: `TypelessMLX/Sources/LookupManager.swift`
- Modify: `TypelessMLX/Sources/TranslateManager.swift`

- [ ] **Step 1: Update LookupManager**

Find `WhisperBridge.shared.lookup(text: word, ...)` call and replace:
```swift
// OLD: WhisperBridge.shared.lookup(text: word, textModel: ...) { ... }

Task { [weak self] in
    guard let self = self else { return }
    do {
        let entry = try await LLMService.shared.lookup(word)
        logInfo("LookupManager", "lookup result: \(entry.prefix(60))")
        await MainActor.run {
            if entry.isEmpty {
                self.overlay?.setContent("无结果")
            } else {
                self.overlay?.setContent(entry)
            }
        }
    } catch {
        logError("LookupManager", "lookup failed: \(error)")
        await MainActor.run { self.overlay?.setContent("查询失败") }
    }
}
```

- [ ] **Step 2: Update TranslateManager**

Find `WhisperBridge.shared.translate(text: trimmed, ...)` call and replace:
```swift
// OLD: WhisperBridge.shared.translate(text: trimmed, textModel: ...) { ... }

Task { [weak self] in
    guard let self = self else { return }
    do {
        let translation = try await LLMService.shared.translate(trimmed)
        logInfo("TranslateManager", "translation: \(translation.prefix(60))")
        await MainActor.run {
            if translation.isEmpty {
                self.overlay?.setContent("无结果")
            } else {
                self.overlay?.setContent(translation)
            }
        }
    } catch {
        logError("TranslateManager", "translate failed: \(error)")
        await MainActor.run { self.overlay?.setContent("翻译失败") }
    }
}
```

- [ ] **Step 3: Verify build**

```bash
swift build 2>&1 | grep -E "error:|Build complete"
```

- [ ] **Step 4: Commit**

```bash
git add TypelessMLX/Sources/LookupManager.swift TypelessMLX/Sources/TranslateManager.swift
git commit -m "LookupManager + TranslateManager: use LLMService instead of WhisperBridge"
```

---

## Task 10: MeetingCaptureEngine — Full Subtitle Pipeline in Swift

**Files:**
- Modify: `TypelessMLX/Sources/MeetingCaptureEngine.swift`

This is the largest task. Port all subtitle streaming logic from Python to Swift.

- [ ] **Step 1: Add subtitle state properties**

In `MeetingCaptureEngine`, add these private properties alongside existing ones:
```swift
// Subtitle streaming state (mirroring Python session state)
private var subtitlePrevText: String = ""
private var subtitleStableCount: Int = 0
private var subtitleCommittedPrefix: String = ""
private var subtitleUtteranceSentences: [(en: String, zh: String)] = []
private static let subtitleStableThreshold = 2
private static let subtitleMaxSamples = 15 * 16000
```

- [ ] **Step 2: Add sentence-splitting and hallucination-filter helpers**

Add these private methods to `MeetingCaptureEngine`:
```swift
/// Split punctuated text into (completeSentences, incompleteTail).
/// Mirrors Python _get_completed_sentences().
private func getCompletedSentences(_ text: String) -> ([String], String) {
    // Matches Chinese/English sentence-ending punctuation.
    // Uses \.(?=\s) — NOT \.(?=\s|$) to avoid false positives from
    // Qwen3-ASR's terminal period on every output.
    let pattern = /([。！？!?]+|\.(?=\s))/
    var sentences: [String] = []
    var remaining = text

    while let match = remaining.firstMatch(of: pattern) {
        let sentence = (String(remaining[..<match.range.upperBound])).trimmingCharacters(in: .whitespaces)
        if !sentence.isEmpty { sentences.append(sentence) }
        remaining = String(remaining[match.range.upperBound...]).trimmingCharacters(in: .whitespaces)
    }
    return (sentences, remaining)
}

/// Return true if ASR echoed back its own system prompt (silence/noise).
private func isSilenceHallucination(_ text: String) -> Bool {
    let known = [
        "请以简体中文输出语音识别结果，加上适当标点符号，不要使用繁体中文。",
        "请输出语音识别结果，保持原始语言，不要添加解释。"
    ]
    let t = text.trimmingCharacters(in: .whitespaces)
    return known.contains { t == $0 || t.hasPrefix($0) || $0.hasPrefix(t) }
}
```

- [ ] **Step 3: Rewrite sendNextChunk to use ASRService**

Replace the `sendNextChunk()` method body. The WAV writing stays the same; only the callback changes:

```swift
private func sendNextChunk() {
    guard !subtitleInFlight else { return }

    pcmLock.lock()
    guard pcmBuffer.count >= Self.minChunkSamples else {
        pcmLock.unlock(); return
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
        defer {
            try? FileManager.default.removeItem(at: url)
            DispatchQueue.main.async { self.subtitleInFlight = false }
        }
        do {
            let text = try await ASRService.shared.transcribe(url: url)
            await MainActor.run { self.processSubtitleASRResult(text) }
        } catch {
            logError("MeetingCaptureEngine", "Subtitle ASR error: \(error)")
        }
    }
}
```

- [ ] **Step 4: Add processSubtitleASRResult — the core subtitle pipeline**

Add this method (called on main thread):
```swift
/// Core subtitle pipeline: stability check → eager sentences → punc → translate.
/// Mirrors handle_subtitle_stream() in Python.
@MainActor
private func processSubtitleASRResult(_ rawText: String) {
    let text = isSilenceHallucination(rawText) ? "" : rawText
    logDebug("MeetingCaptureEngine", "Subtitle ASR: \(text.prefix(60))")

    // Find new complete sentences in the suffix after committed prefix
    let suffix: String
    if text.hasPrefix(subtitleCommittedPrefix) {
        suffix = String(text.dropFirst(subtitleCommittedPrefix.count))
    } else {
        subtitleCommittedPrefix = ""
        suffix = text
    }

    let (newSentences, tail) = getCompletedSentences(suffix)

    // Eager-translate newly completed sentences
    for raw in newSentences {
        let clean = PuncService.shared.restore(raw)
        subtitleCommittedPrefix += raw
        subtitleUtteranceSentences.append((en: clean, zh: ""))
        let idx = subtitleUtteranceSentences.count - 1
        SubtitleBar.shared.updateLive(clean)
        Task { [weak self, clean, idx] in
            guard let self = self else { return }
            if let zh = try? await LLMService.shared.translate(clean) {
                await MainActor.run {
                    self.subtitleUtteranceSentences[idx].zh = zh
                    SubtitleBar.shared.commitSentence(english: clean, chinese: zh)
                }
            }
        }
    }

    // VAD stability check
    let totalSamples = pcmBuffer.count  // approximate
    let forceCommit = totalSamples >= Self.subtitleMaxSamples
    if text == subtitlePrevText {
        subtitleStableCount += 1
    } else {
        subtitleStableCount = 0
        subtitlePrevText = text
    }
    let commit = (subtitleStableCount >= Self.subtitleStableThreshold && !text.isEmpty) || forceCommit

    if commit {
        // Translate + commit tail to transcript
        let tailClean = PuncService.shared.restore(tail)
        let allSentences = subtitleUtteranceSentences
        subtitlePrevText = ""
        subtitleStableCount = 0
        subtitleCommittedPrefix = ""
        subtitleUtteranceSentences = []

        for pair in allSentences {
            transcriptOverlay?.commitEntry(english: pair.en, chinese: pair.zh)
        }
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
```

- [ ] **Step 5: Update startSubtitleStreaming — remove WhisperBridge reset**

In `startSubtitleStreaming()`, remove the block:
```swift
// Remove this:
if appState?.hasPythonBackend == true {
    WhisperBridge.shared.streamSubtitle(audioURL: nil, ..., reset: true) { _ in }
}
```

Also reset new state:
```swift
subtitlePrevText = ""
subtitleStableCount = 0
subtitleCommittedPrefix = ""
subtitleUtteranceSentences = []
```

- [ ] **Step 6: Remove SubtitleChunk and handleSubtitleChunk**

Delete `handleSubtitleChunk(_:)` method and all `WhisperBridge.SubtitleChunk` references from `MeetingCaptureEngine.swift`.

- [ ] **Step 7: Verify build**

```bash
swift build 2>&1 | grep -E "error:|Build complete"
```

- [ ] **Step 8: Commit**

```bash
git add TypelessMLX/Sources/MeetingCaptureEngine.swift
git commit -m "MeetingCaptureEngine: port full subtitle pipeline to Swift using ASRService + PuncService + LLMService"
```

---

## Task 11: Delete WhisperBridge and SetupWindowController

**Files:**
- Delete: `TypelessMLX/Sources/WhisperBridge.swift`
- Delete: `TypelessMLX/Sources/SetupWindowController.swift`

- [ ] **Step 1: Remove SetupWindowController**

Delete `SetupWindowController.swift`. Then find all references to it:
```bash
grep -rn "SetupWindowController\|showSetup\|SetupView\|SetupViewModel" TypelessMLX/Sources/
```

Remove calls in `TypelessMLXApp.swift` (typically `SetupWindowController.shared.show(...)` in the `checkBackendAndSetup` function). That whole `checkBackendAndSetup()` function can be removed or simplified to just starting `ASRService` lazily.

- [ ] **Step 2: Remove WhisperBridge**

Delete `WhisperBridge.swift`. Verify no remaining references:
```bash
grep -rn "WhisperBridge" TypelessMLX/Sources/
```

Fix any remaining references.

- [ ] **Step 3: Clean up TypelessMLXApp.swift**

Remove:
- `checkBackendAndSetup()` method (or reduce to a no-op)
- Any Python-related startup logic
- `WhisperBridge.isVenvReady()` calls

- [ ] **Step 4: Verify build**

```bash
swift build 2>&1 | grep -E "error:|Build complete"
```

Expected: `Build complete!`

- [ ] **Step 5: Commit**

```bash
git rm TypelessMLX/Sources/WhisperBridge.swift
git rm TypelessMLX/Sources/SetupWindowController.swift
git add TypelessMLX/Sources/TypelessMLXApp.swift
git commit -m "Delete WhisperBridge and SetupWindowController; remove Python startup logic"
```

---

## Task 12: Update build-app.sh

**Files:**
- Modify: `build-app.sh`

- [ ] **Step 1: Remove Python venv bundling, add asr-server build**

In `build-app.sh`, in the release block, replace the venv bundling section:
```bash
# REMOVE these lines:
VENV_SRC="$HOME/.local/share/typelessmlx/venv"
if [ -d "$VENV_SRC" ]; then
    echo "  📦 Bundling Python venv..."
    cp -RL "$VENV_SRC" "$APP_BUNDLE/Contents/Resources/venv"
    LIBPYTHON=$(find ...)
    ...
fi
```

Add asr-server build instead:
```bash
echo "  🦀 Building asr-server..."
ASR_RS_DIR="$PROJECT_DIR/vendor/qwen3_asr_rs"
if [ -d "$ASR_RS_DIR" ]; then
    (cd "$ASR_RS_DIR" && cargo build --release --features mlx 2>&1)
    mkdir -p "$APP_BUNDLE/Contents/Resources/bin"
    cp "$ASR_RS_DIR/target/release/asr-server" "$APP_BUNDLE/Contents/Resources/bin/"
    echo "  ✅ asr-server bundled ($(du -sh "$APP_BUNDLE/Contents/Resources/bin/asr-server" | awk '{print $1}'))"
else
    echo "  ❌ vendor/qwen3_asr_rs not found — run: git submodule update --init"
    exit 1
fi
```

- [ ] **Step 2: Remove Python-related backend copy if still present**

```bash
grep -n "backend\|requirements\|transcribe_server" build-app.sh
```

Remove any lines copying Python backend files to the bundle.

- [ ] **Step 3: Update DMG size estimate in comments if any**

- [ ] **Step 4: Test release build**

```bash
./build-app.sh --release --allow-adhoc --no-models 2>&1 | grep -E "✅|❌|Build complete|DMG"
```

Expected: no venv bundling, asr-server appears, DMG ~15 MB

- [ ] **Step 5: Commit**

```bash
git add build-app.sh
git commit -m "build-app.sh: remove Python venv bundling, add asr-server compilation"
```

---

## Task 13: Integration Test

- [ ] **Step 1: Install and launch app**

```bash
./build-app.sh --install
```

- [ ] **Step 2: Verify Qwen3-ASR transcription**

1. Select Qwen3-ASR 0.6B in Settings
2. Hold Right Option, say something in Chinese
3. Check log: `tail -20 ~/Library/Logs/TypelessMLX/typelessmlx.log`
4. Expected: transcription appears and is pasted

- [ ] **Step 3: Verify translation**

1. Select any text
2. Press ⌃⌥T
3. Expected: translation overlay appears with Chinese/English

- [ ] **Step 4: Verify subtitle streaming**

1. Enable meeting subtitle
2. Play audio from a video
3. Expected: SubtitleBar shows English + Chinese at screen bottom

- [ ] **Step 5: Verify Whisper (if model downloaded)**

1. Select Whisper Large v3 in Settings
2. Hold Right Option, speak
3. Expected: transcription via WhisperKit

- [ ] **Step 6: Commit any fixes found during integration**

```bash
git add -A
git commit -m "Integration fixes from end-to-end testing"
```

---

## Summary

After all tasks complete:
- Python backend: **gone**
- App bundle size: ~15 MB (was ~290 MB)
- All model weights: unchanged, same `~/.cache/huggingface/hub/` paths
- CT-Punc model: unchanged, same `~/.cache/sherpa-onnx/` path
- User experience: identical
