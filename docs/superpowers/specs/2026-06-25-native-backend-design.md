# Native Backend Design

**Date:** 2026-06-25  
**Goal:** Replace the Python backend (663 MB venv) with native Swift/Rust components. No Python process at runtime. Existing model weights reused as-is.

---

## 1. Architecture

Four new Swift components replace `WhisperBridge` + `transcribe_server.py`:

| Component | Technology | Responsibility |
|-----------|-----------|----------------|
| `ASRService` | Rust `asr-server` subprocess (HTTP) | Qwen3-ASR transcription + subtitle ASR |
| `WhisperService` | WhisperKit (Swift Package) | Whisper transcription |
| `LLMService` | mlx-swift MLXLLM (Swift Package) | Translation + word lookup |
| `PuncService` | sherpa-onnx Swift binding | CT-Punc punctuation restoration |

**Swift Package dependencies to add:**
```
https://github.com/argmaxinc/WhisperKit
https://github.com/ml-explore/mlx-swift-examples  (MLXLLM, MLXLMCommon)
https://github.com/k2-fsa/sherpa-onnx             (Swift binding)
```

**Files retired:**
- `backend/` directory (entire Python backend)
- `TypelessMLX/Sources/WhisperBridge.swift`
- `TypelessMLX/Sources/SetupWindowController.swift`

**Files unchanged:** `AudioRecorder`, `TextPaster`, `HotkeyManager`, `SpeechStreamer`, `OCRManager`, all overlays, `SubtitleBar`, `TranscriptOverlay`.

---

## 2. ASRService

Manages the `asr-server` Rust binary bundled at `Contents/Resources/bin/asr-server`.

**Lifecycle:**
- Lazy start on first transcription request (same pattern as current Python process)
- Persistent: model stays loaded between requests
- Terminated on app quit; idle-kill after 15 min optional

**Startup:**
```swift
// asr-server --model mlx-community/Qwen3-ASR-0.6B-8bit --port 18080
```
Port chosen at random; `ASRService` retains it for subsequent calls.

**Transcription API:**
```swift
func transcribe(url: URL, language: String?) async throws -> String
// POST multipart/form-data to http://localhost:{port}/v1/audio/transcriptions
// Compatible with OpenAI audio transcription API
```

**Subtitle stream usage:**
`MeetingCaptureEngine` already manages the PCM buffer in Swift. Each timer tick writes the full accumulated buffer to a temp WAV and calls `ASRService.transcribe()`. Same semantics as current Python `_transcribe_qwen3_subtitle()`.

**Model path:** `AppState.resolvedModelPath` for the selected Qwen3-ASR model. Passed as `--model` flag to `asr-server`. Uses `~/.cache/huggingface/hub/` — same cache as before.

---

## 3. WhisperService

```swift
class WhisperService {
    func transcribe(url: URL, language: String?) async throws -> String
}
```

- Wraps `WhisperKit`; lazy-loads model on first call
- Model ID from `AppState.resolvedModelPath` (e.g. `openai/whisper-large-v3`)
- WhisperKit loads from HF cache directly; no format conversion needed

---

## 4. LLMService

```swift
class LLMService {
    func translate(_ text: String) async throws -> String   // auto-detects EN↔ZH
    func lookup(_ word: String) async throws -> String
}
```

- Wraps `MLXLLM` from `mlx-swift-examples`
- Lazy-loads `mlx-community/Qwen2.5-1.5B-Instruct-4bit` (path from `AppState.resolvedTextModelPath`)
- Prompts ported verbatim from Python:
  - Translate EN→ZH: `将以下英文翻译成简体中文，只输出中文译文：\n「{text}」`
  - Translate ZH→EN: system prompt + `「{text}」`
  - Lookup: existing dictionary-format prompt
- Direction detection: CJK ratio > 30% → ZH→EN (same as Python)
- CJK-presence validation on output (same as Python)

---

## 5. PuncService

```swift
class PuncService {
    func restore(_ text: String) -> String   // synchronous, fast
}
```

- Wraps sherpa-onnx Swift `OfflinePunctuation` API
- Model path: `~/.cache/sherpa-onnx/sherpa-onnx-punct-ct-transformer-zh-en-vocab272727-2024-04-12-int8/model.int8.onnx`
- Auto-downloads model on first use (same URL as current Python implementation)
- Loaded once, kept in memory

---

## 6. Subtitle Streaming Pipeline

All logic currently in `handle_subtitle_stream()` (Python) moves to `MeetingCaptureEngine` (Swift).

**State added to `MeetingCaptureEngine`:**
```swift
private var subtitlePrevText: String = ""
private var subtitleStableCount: Int = 0
private var subtitleCommittedPrefix: String = ""
private var subtitleUtteranceSentences: [(en: String, zh: String)] = []
```

**New call sequence per timer tick:**
```
sendNextChunk()
  → write full pcmBuffer to temp WAV
  → ASRService.transcribe(wav)           // HTTP, async
  → stability check (stableCount logic)
  → _getCompletedSentences(rawText)      // Swift port of Python helper
  → PuncService.restore(sentence)        // sync
  → LLMService.translate(sentence)       // async
  → SubtitleBar.commitSentence / TranscriptOverlay.commitEntry
```

**Sentence splitting regex (Swift port of Python `_SENT_END`):**
```swift
let sentEndPattern = /([。！？!?]+|\.(?=\s))/
```

`_is_silence_hallucination()` also ported as a Swift helper — filters ASR output that echoes the system prompt.

---

## 7. HotkeyManager Routing

```swift
// Qwen3-ASR model selected
let text = try await ASRService.shared.transcribe(url: audioURL, language: language)

// Whisper model selected  
let text = try await WhisperService.shared.transcribe(url: audioURL, language: language)

// macOS built-in (unchanged)
let text = try await SpeechStreamer.shared.transcribe(url: audioURL)
```

---

## 8. AppState Changes

- Remove `hasPythonBackend: Bool` published property
- Remove `resolvedSubtitleModelPath` (subtitle always uses `resolvedModelPath` via `ASRService`)
- `updatePermissionState()` checks only mic + accessibility (no Python check)
- `SetupWindowController` and its venv installation flow removed entirely

---

## 9. Build Changes (`build-app.sh`)

**Remove:**
- Python venv bundling (`cp -RL venv` step, ~663 MB)
- `libpython3.12.dylib` copy step

**Add:**
```bash
# Build asr-server
cd vendor/qwen3_asr_rs
cargo build --release --features mlx
cp target/release/asr-server "$APP_BUNDLE/Contents/Resources/bin/"
```

`qwen3_asr_rs` vendored as a git submodule at `vendor/qwen3_asr_rs`.

**Result:** DMG drops from ~290 MB to ~15 MB (excluding model weights).

---

## 10. Migration Boundary

| Keep unchanged | Remove / replace |
|----------------|-----------------|
| All overlay UI classes | `WhisperBridge.swift` |
| `AudioRecorder` | `SetupWindowController.swift` |
| `TextPaster`, `TextRefiner` | `backend/` directory |
| `HotkeyManager` (routing logic only changes) | Python venv in build |
| `ModelManager` (HF cache paths unchanged) | `hasPythonBackend` in AppState |
| All model weight files in `~/.cache/` | — |

---

## 11. Implementation Order

1. Add Swift Package dependencies; verify they build
2. Implement `PuncService` (simplest — no async, no process)
3. Implement `LLMService` (port prompts from Python)
4. Implement `ASRService` (process management, HTTP client)
5. Implement `WhisperService` (thin WhisperKit wrapper)
6. Refactor `HotkeyManager` to use new services
7. Refactor `LookupManager` + `TranslateManager`
8. Refactor `MeetingCaptureEngine` subtitle pipeline
9. Remove `WhisperBridge`, `SetupWindowController`, `AppState.hasPythonBackend`
10. Update `build-app.sh` (add asr-server build, remove Python venv)
11. Update `AppState.updatePermissionState()`
