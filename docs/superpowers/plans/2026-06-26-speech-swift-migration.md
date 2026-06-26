# Speech-Swift Migration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the Rust `asr-server` subprocess with `Qwen3ASRModel` from speech-swift (in-process), and replace the custom stability-count subtitle VAD with `StreamingVADProcessor` (Silero VAD).

**Architecture:** speech-swift is added as an SPM dependency; `ASRService.swift` becomes a thin wrapper around `Qwen3ASRModel`; `MeetingCaptureEngine` feeds SCStream PCM directly into a `StreamingVADProcessor` on a dedicated serial queue, firing an ASR task on each confirmed speech segment.

**Tech Stack:** speech-swift v0.0.21 (`Qwen3ASR` + `SpeechVAD` products), Swift 5.9, AVFoundation (WAV loading), existing `LLMService` / `PuncService` unchanged.

---

## File Map

| File | Action |
|------|--------|
| `Package.swift` | Modify — add speech-swift dep, bump platform to macOS 15 |
| `TypelessMLX/Sources/ASRService.swift` | Rewrite — swap Rust HTTP for `Qwen3ASRModel` |
| `TypelessMLX/Sources/MeetingCaptureEngine.swift` | Modify — replace timer/WAV/VAD with `StreamingVADProcessor` |
| `build-app.sh` | Modify — remove Rust build block |

---

## Task 1: Add speech-swift dependency to Package.swift

**Files:**
- Modify: `Package.swift`

- [ ] **Step 1: Open Package.swift and read current state**

Current platforms line:
```swift
platforms: [
    .macOS(.v14)
],
```

Current dependencies array (partial):
```swift
dependencies: [
    .package(url: "https://github.com/argmaxinc/WhisperKit", from: "1.0.0"),
    .package(url: "https://github.com/ml-explore/mlx-swift-lm", from: "2.31.3"),
    .package(url: "https://github.com/genericgroup/sherpa-onnx-spm", exact: "1.0.4"),
],
```

- [ ] **Step 2: Bump platform and add speech-swift**

Replace the platforms line:
```swift
platforms: [
    .macOS(.v15)
],
```

Add speech-swift to the dependencies array:
```swift
.package(url: "https://github.com/soniqo/speech-swift", from: "0.0.21"),
```

Add `Qwen3ASR` and `SpeechVAD` products to the TypelessMLX executableTarget's dependencies:
```swift
.product(name: "Qwen3ASR", package: "speech-swift"),
.product(name: "SpeechVAD", package: "speech-swift"),
```

Final `Package.swift` after changes:
```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TypelessMLX",
    platforms: [
        .macOS(.v15)
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit", from: "1.0.0"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", from: "2.31.3"),
        .package(url: "https://github.com/genericgroup/sherpa-onnx-spm", exact: "1.0.4"),
        .package(url: "https://github.com/soniqo/speech-swift", from: "0.0.21"),
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
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "CSherpaOnnx", package: "sherpa-onnx-spm"),
                .product(name: "Qwen3ASR", package: "speech-swift"),
                .product(name: "SpeechVAD", package: "speech-swift"),
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

- [ ] **Step 3: Resolve and build to confirm dependency downloads**

```bash
cd /Users/donhu/proj/TypelessMLX/.worktrees/native-backend
swift package resolve 2>&1 | tail -5
swift build 2>&1 | grep -E "error:|Build complete" | head -20
```

Expected: `Build complete!` (may take several minutes on first resolve).  
If there are errors about missing symbols or platform requirements, check the exact error and adjust `from:` version or platform as needed.

- [ ] **Step 4: Commit**

```bash
git add Package.swift Package.resolved
git commit -m "$(cat <<'EOF'
Add speech-swift 0.0.21, bump platform to macOS 15

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: Rewrite ASRService.swift

**Files:**
- Modify: `TypelessMLX/Sources/ASRService.swift`

- [ ] **Step 1: Replace ASRService.swift with new Qwen3ASRModel-based implementation**

Write the following content to `TypelessMLX/Sources/ASRService.swift`:

```swift
import AVFoundation
import Foundation
import Qwen3ASR

/// Manages Qwen3ASR on-device transcription.
///
/// - `transcribe(url:language:)` — for voice dictation (WAV file from AudioTapFileWriter)
/// - `transcribe(audio:language:)` — for subtitle streaming (raw [Float] from SCStream)
///
/// The `Qwen3ASRModel` instance is loaded lazily on first call and reloaded
/// if `AppState.resolvedModelPath` changes.
actor ASRService {
    static let shared = ASRService()

    private var model: Qwen3ASRModel?
    private var loadTask: Task<Qwen3ASRModel, Error>?
    private var currentModelPath: String = ""

    private init() {}

    // MARK: - Public API

    /// Transcribes the WAV file at `url`. For voice dictation via HotkeyManager.
    func transcribe(url: URL, language: String? = nil) async throws -> String {
        let (samples, sampleRate) = try loadAudio(from: url)
        return try await transcribe(audio: samples, sampleRate: sampleRate, language: language)
    }

    /// Transcribes raw PCM samples. For subtitle streaming via MeetingCaptureEngine.
    func transcribe(audio: [Float], sampleRate: Int = 16000, language: String? = nil) async throws -> String {
        let modelPath = resolveModelPath(await MainActor.run { AppState.shared.resolvedModelPath })
        let m = try await loadedModel(modelPath: modelPath)
        let lang = (language?.isEmpty == false && language != "auto") ? language : nil
        // transcribe() is synchronous and CPU/GPU intensive — run off the cooperative thread pool.
        return try await Task.detached(priority: .userInitiated) {
            m.transcribe(audio: audio, sampleRate: sampleRate, language: lang)
        }.value
    }

    /// Releases the loaded model.
    func stop() {
        model = nil
        loadTask?.cancel()
        loadTask = nil
        currentModelPath = ""
        logInfo("ASRService", "ASRService stopped")
    }

    // MARK: - Model Lifecycle

    private func loadedModel(modelPath: String) async throws -> Qwen3ASRModel {
        if let m = model, currentModelPath == modelPath { return m }
        if let t = loadTask, currentModelPath == modelPath { return try await t.value }

        loadTask?.cancel()
        currentModelPath = modelPath

        let t = Task<Qwen3ASRModel, Error> { [weak self] in
            guard let self else { throw CancellationError() }
            let m = try await self.buildModel(modelPath: modelPath)
            await self.storeModel(m, path: modelPath)
            return m
        }
        loadTask = t
        return try await t.value
    }

    private func storeModel(_ m: Qwen3ASRModel, path: String) {
        model = m
        loadTask = nil
        currentModelPath = path
        logInfo("ASRService", "Qwen3ASR model ready: \(path.split(separator: "/").last ?? Substring(path))")
    }

    private func buildModel(modelPath: String) async throws -> Qwen3ASRModel {
        logInfo("ASRService", "Loading Qwen3ASR model: \(modelPath)")
        // Absolute snapshot path (already on disk) — load offline.
        if modelPath.hasPrefix("/"), FileManager.default.fileExists(atPath: modelPath) {
            let cacheDir = URL(fileURLWithPath: modelPath)
            return try await Qwen3ASRModel.fromPretrained(
                modelId: modelPath,
                cacheDir: cacheDir,
                offlineMode: true
            ) { progress, status in
                logDebug("ASRService", "Load \(Int(progress * 100))% \(status)")
            }
        }
        // HF repo ID — download to speech-swift's own cache.
        let repoId = modelPath.isEmpty ? "mlx-community/Qwen3-ASR-0.6B-8bit" : modelPath
        return try await Qwen3ASRModel.fromPretrained(modelId: repoId) { progress, status in
            logDebug("ASRService", "Download \(Int(progress * 100))% \(status)")
        }
    }

    // MARK: - Helpers

    /// Loads a WAV file produced by AudioTapFileWriter into Float32 samples.
    /// Uses AVAudioFile so any format/sample-rate written by the tap works.
    private func loadAudio(from url: URL) throws -> (samples: [Float], sampleRate: Int) {
        let file = try AVAudioFile(forReading: url)
        let srcFormat = file.processingFormat
        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: srcFormat.sampleRate,
            channels: 1,
            interleaved: false
        )!

        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0 else { return ([], Int(srcFormat.sampleRate)) }

        if srcFormat.channelCount == 1 && srcFormat.commonFormat == .pcmFormatFloat32 {
            let buf = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: frameCount)!
            try file.read(into: buf)
            let count = Int(buf.frameLength)
            let ptr = buf.floatChannelData![0]
            return (Array(UnsafeBufferPointer(start: ptr, count: count)), Int(srcFormat.sampleRate))
        }

        // Convert format (stereo → mono, int16 → float32, etc.)
        let srcBuf = AVAudioPCMBuffer(pcmFormat: srcFormat, frameCapacity: frameCount)!
        try file.read(into: srcBuf)

        guard let converter = AVAudioConverter(from: srcFormat, to: targetFormat) else {
            throw NSError(domain: "ASRService", code: -10,
                          userInfo: [NSLocalizedDescriptionKey: "Cannot create audio converter"])
        }
        let outCount = AVAudioFrameCount(
            Double(srcBuf.frameLength) * targetFormat.sampleRate / srcFormat.sampleRate
        ) + 1
        let outBuf = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCount)!
        var convError: NSError?
        var didProvide = false
        converter.convert(to: outBuf, error: &convError) { _, outStatus in
            if didProvide { outStatus.pointee = .noDataNow; return nil }
            outStatus.pointee = .haveData
            didProvide = true
            return srcBuf
        }
        if let e = convError { throw e }

        let count = Int(outBuf.frameLength)
        let ptr = outBuf.floatChannelData![0]
        return (Array(UnsafeBufferPointer(start: ptr, count: count)), Int(targetFormat.sampleRate))
    }

    /// Resolves an HF repo ID (e.g. "mlx-community/Qwen3-ASR-0.6B-8bit") to the
    /// local HF cache snapshot path. Returns the input unchanged if it's already
    /// absolute or no snapshot is found (fromPretrained will download).
    private func resolveModelPath(_ modelPath: String) -> String {
        guard !modelPath.hasPrefix("/") else { return modelPath }
        let sanitized = modelPath.replacingOccurrences(of: "/", with: "--")
        let cacheBase = (NSHomeDirectory() as NSString)
            .appendingPathComponent(".cache/huggingface/hub/models--\(sanitized)/snapshots")
        let snapshots = (try? FileManager.default.contentsOfDirectory(atPath: cacheBase)) ?? []
        if let snapshot = snapshots.sorted().last {
            return (cacheBase as NSString).appendingPathComponent(snapshot)
        }
        return modelPath
    }
}
```

- [ ] **Step 2: Build and check for compile errors**

```bash
swift build 2>&1 | grep -E "error:|Build complete"
```

Expected: `Build complete!`

If you see "cannot find type 'Qwen3ASRModel'" → verify Task 1 added `Qwen3ASR` product to the target dependencies.  
If you see "actor-isolated property" → the `transcribe(audio:)` method uses `Task.detached` which is correct; verify the method signature.

- [ ] **Step 3: Commit**

```bash
git add TypelessMLX/Sources/ASRService.swift
git commit -m "$(cat <<'EOF'
Replace Rust asr-server subprocess with Qwen3ASRModel

ASRService now loads Qwen3ASR in-process via speech-swift.
Same public API; removes subprocess management, port allocation,
health polling, and multipart HTTP round-trip.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: Rewrite MeetingCaptureEngine subtitle pipeline

**Files:**
- Modify: `TypelessMLX/Sources/MeetingCaptureEngine.swift`

Replace the subtitle streaming section of `MeetingCaptureEngine`. The SCStream setup, permission checks, `stopAll()`, `extractPCM()`, and `isSilenceHallucination()` are mostly preserved; only the subtitle pipeline internals change.

- [ ] **Step 1: Replace the full file with the new implementation**

Write the following to `TypelessMLX/Sources/MeetingCaptureEngine.swift`:

```swift
import AVFoundation
import AppKit
import Foundation
import Qwen3ASR
import ScreenCaptureKit
import SpeechVAD

/// Captures all system audio via ScreenCaptureKit, detects speech boundaries with
/// Silero VAD, and runs Qwen3-ASR + translation on each confirmed speech segment.
class MeetingCaptureEngine: NSObject {
    static let shared = MeetingCaptureEngine()

    private weak var appState: AppState?
    private var transcriptOverlay: TranscriptOverlay?

    // SCStream
    private let streamLock = NSLock()
    private var activeStream: SCStream?

    // PCM accumulation (written from SCStream callback, drained on subtitleQueue)
    private let pcmLock = NSLock()
    private var pcmBuffer: [Float] = []
    private static let maxBufferSamples = 16000 * 10  // 10 s safety cap

    // Subtitle VAD — accessed only on subtitleQueue
    private let subtitleQueue = DispatchQueue(label: "me.typelessmlx.subtitle-vad",
                                              qos: .userInteractive)
    private var vadModel: SileroVADModel?
    private var vadProcessor: StreamingVADProcessor?
    private var rollingBuffer: [Float] = []
    private var rollingBufferStart: Int = 0   // cumulative samples removed from buffer front
    private var speechStartSample: Int? = nil  // rolling-buffer-relative index when speech started

    private static let maxRollingBufferSamples = 30 * 16000  // 30 s

    // Enable/stop guard — mirrors existing pattern
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
            guard let self else { return }
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
            guard let self else { return }
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
                self.startSubtitleStreaming(token: token)
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
        stopStream()
        pcmLock.lock()
        pcmBuffer.removeAll()
        pcmLock.unlock()
        subtitleQueue.async { [weak self] in
            guard let self else { return }
            // Flush any pending VAD speech segment before teardown
            if let vad = self.vadProcessor {
                let events = vad.flush()
                for event in events { self.handleVADEvent(event, token: 0) }  // token=0 → canProceed fails
            }
            self.vadProcessor = nil
            self.vadModel = nil
            self.rollingBuffer.removeAll()
            self.rollingBufferStart = 0
            self.speechStartSample = nil
        }
    }

    // MARK: - Subtitle Streaming

    private func startSubtitleStreaming(token: UInt64) {
        // Reset rolling buffer on subtitle queue
        subtitleQueue.async { [weak self] in
            guard let self else { return }
            self.rollingBuffer.removeAll()
            self.rollingBufferStart = 0
            self.speechStartSample = nil
        }

        // Load Silero VAD model asynchronously
        Task { [weak self] in
            guard let self else { return }
            do {
                let vad = try await SileroVADModel.fromPretrained()
                let processor = StreamingVADProcessor(model: vad)
                self.subtitleQueue.async {
                    guard self.canProceed(token: token) else { return }
                    self.vadModel = vad
                    self.vadProcessor = processor
                    logInfo("MeetingCaptureEngine", "Silero VAD ready")
                }
            } catch {
                logError("MeetingCaptureEngine", "Failed to load Silero VAD: \(error)")
            }
        }
    }

    // MARK: - PCM Ingestion (called from subtitleQueue)

    private func drainAndProcess(token: UInt64) {
        guard let vad = vadProcessor else { return }

        pcmLock.lock()
        guard !pcmBuffer.isEmpty else { pcmLock.unlock(); return }
        let chunk = pcmBuffer
        pcmBuffer.removeAll(keepingCapacity: true)
        pcmLock.unlock()

        // Append to rolling buffer
        rollingBuffer.append(contentsOf: chunk)
        if rollingBuffer.count > Self.maxRollingBufferSamples {
            let excess = rollingBuffer.count - Self.maxRollingBufferSamples
            rollingBuffer.removeFirst(excess)
            rollingBufferStart += excess
            if let s = speechStartSample { speechStartSample = s - excess }
        }

        // Feed through Silero VAD
        let events = vad.process(samples: chunk)
        for event in events { handleVADEvent(event, token: token) }
    }

    // MARK: - VAD Event Handling (subtitleQueue)

    private func handleVADEvent(_ event: VADEvent, token: UInt64) {
        switch event {
        case .speechStarted(let time):
            let absSample = Int(time * Float(SileroVADModel.sampleRate))
            speechStartSample = absSample - rollingBufferStart
            logDebug("MeetingCaptureEngine", "VAD speech start \(String(format: "%.2f", time))s")

        case .speechEnded(let segment):
            guard let startIdx = speechStartSample else { return }
            speechStartSample = nil

            let endAbs = Int(segment.endTime * Float(SileroVADModel.sampleRate))
            let startBuf = max(0, startIdx)
            let endBuf = min(endAbs - rollingBufferStart, rollingBuffer.count)
            guard startBuf < endBuf else { return }

            let audio = Array(rollingBuffer[startBuf..<endBuf])
            logDebug("MeetingCaptureEngine",
                     "VAD speech end \(String(format: "%.2f", segment.startTime))–\(String(format: "%.2f", segment.endTime))s, \(audio.count) samples")

            Task { [weak self, audio, token] in
                guard let self, self.canProceed(token: token) else { return }
                do {
                    let raw = try await ASRService.shared.transcribe(audio: audio)
                    guard self.canProceed(token: token) else { return }

                    let text = self.isSilenceHallucination(raw) ? "" : raw
                    guard !text.isEmpty else { return }

                    let clean = PuncService.shared.restore(text)
                    await MainActor.run { SubtitleBar.shared.updateLive(clean) }

                    let zh = (try? await LLMService.shared.translate(clean)) ?? ""
                    guard self.canProceed(token: token) else { return }

                    await MainActor.run {
                        SubtitleBar.shared.commitSentence(english: clean, chinese: zh)
                        self.transcriptOverlay?.commitEntry(english: clean, chinese: zh)
                    }
                } catch {
                    logError("MeetingCaptureEngine", "ASR error: \(error)")
                }
            }
        }
    }

    // MARK: - Silence Hallucination Filter

    /// Returns true if ASR output verbatim echoes a known system-prompt fragment
    /// (Qwen3-ASR hallucination on silence/noise).
    private func isSilenceHallucination(_ text: String) -> Bool {
        let known = [
            "请以简体中文输出语音识别结果，加上适当标点符号，不要使用繁体中文。",
            "请输出语音识别结果，保持原始语言，不要添加解释。"
        ]
        let t = text.trimmingCharacters(in: .whitespaces)
        return known.contains { t == $0 || t.hasPrefix($0) || $0.hasPrefix(t) }
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

        // Accumulate in pcmBuffer (same as before)
        pcmLock.lock()
        pcmBuffer.append(contentsOf: samples)
        if pcmBuffer.count > MeetingCaptureEngine.maxBufferSamples {
            pcmBuffer.removeFirst(pcmBuffer.count - MeetingCaptureEngine.maxBufferSamples)
        }
        pcmLock.unlock()

        // Capture token before dispatching
        enableStateLock.lock()
        let token = enableToken
        let enabled = subtitleEnabled
        enableStateLock.unlock()
        guard enabled else { return }

        subtitleQueue.async { [weak self] in self?.drainAndProcess(token: token) }
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
```

- [ ] **Step 2: Build**

```bash
swift build 2>&1 | grep -E "error:|Build complete"
```

Expected: `Build complete!`

Common errors:
- `'VADEvent' is not a member of 'SpeechVAD'` — verify `SpeechVAD` product is in Package.swift target dependencies (Task 1).
- `actor-isolated 'enableStateLock'` — the lock is accessed from `subtitleQueue.async`; it's an NSLock, not a Swift actor, so this is fine. If the compiler warns, it's a warning, not error.
- `Cannot find 'SileroVADModel' in scope` — same check as above.

- [ ] **Step 3: Commit**

```bash
git add TypelessMLX/Sources/MeetingCaptureEngine.swift
git commit -m "$(cat <<'EOF'
Replace subtitle VAD pipeline with Silero VAD + Qwen3ASR

Removes 0.5s timer, WAV file writing, HTTP round-trip, and custom
stability-count VAD. StreamingVADProcessor now drives speech segment
boundaries; each confirmed segment fires one ASRService.transcribe(audio:)
call in-process.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: Remove Rust build step from build-app.sh

**Files:**
- Modify: `build-app.sh`

- [ ] **Step 1: Find and delete the Rust build block**

The block to remove is in the release-only section. It looks like:

```bash
if [ "$MODE" = "release" ]; then
    echo "  🦀 Building asr-server (Rust + MLX)..."
    ASR_RS_DIR="$PROJECT_DIR/vendor/qwen3_asr_rs"
    if [ -d "$ASR_RS_DIR" ]; then
        (cd "$ASR_RS_DIR" && source "$HOME/.cargo/env" && cargo build --release --no-default-features --features mlx 2>&1 | tail -3)
        mkdir -p "$APP_BUNDLE/Contents/Resources/bin"
        cp "$ASR_RS_DIR/target/release/asr-server" "$APP_BUNDLE/Contents/Resources/bin/"
        chmod +x "$APP_BUNDLE/Contents/Resources/bin/asr-server"
        echo "  ✅ asr-server bundled ($(du -sh "$APP_BUNDLE/Contents/Resources/bin/asr-server" | awk '{print $1}'))"
    else
        echo "  ❌ vendor/qwen3_asr_rs not found"
        exit 1
    fi
fi
```

Delete this entire block. Also remove any reference to `bin/asr-server` in cleanup or install steps — search for it:

```bash
grep -n "asr-server\|qwen3_asr\|cargo\|rust\|🦀" build-app.sh
```

Delete every line found.

- [ ] **Step 2: Verify build script still functions**

```bash
bash -n build-app.sh && echo "syntax OK"
```

Expected: `syntax OK`

- [ ] **Step 3: Commit**

```bash
git add build-app.sh
git commit -m "$(cat <<'EOF'
Remove Rust asr-server build step from build-app.sh

No longer needed: ASRService now runs Qwen3ASR in-process via
speech-swift. Rust toolchain is no longer a build dependency.

Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Smoke test

**No files to modify — manual verification steps.**

- [ ] **Step 1: Debug build + install**

```bash
./build-app.sh --install
```

Expected: `Build complete` with no mention of `cargo` or `asr-server`. App launches in menu bar.

- [ ] **Step 2: Voice dictation**

Hold Right Option → speak a sentence → release. Expected: text pasted into focused app within ~2 s of model warmup (first use only).

If the app crashes on first transcription: check `~/Library/Logs/TypelessMLX/typelessmlx.log` for `ASRService` errors. Common cause: model not found → `AppState.resolvedModelPath` returns empty → `fromPretrained` tries to download. Make sure a model is selected in Settings.

- [ ] **Step 3: Subtitle mode**

Enable subtitle mode from menu bar. Play audio (system sound or video). Expected: subtitle appears in `SubtitleBar` within ~1–2 s of first speech detected (Silero VAD warmup on first chunk).

Check log for `VAD speech start` and `VAD speech end` lines to confirm VAD is firing.

- [ ] **Step 4: Confirm no Rust process**

While subtitle mode is active:
```bash
ps aux | grep asr-server
```

Expected: no `asr-server` process.

- [ ] **Step 5: Final commit if any fixups were needed**

```bash
git add -p  # stage only intentional changes
git commit -m "..."
```
