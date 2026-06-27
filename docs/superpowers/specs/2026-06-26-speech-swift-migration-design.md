# Speech-Swift Migration Design

**Date:** 2026-06-26  
**Branch:** native-backend  
**Goal:** Replace the Rust `asr-server` subprocess and custom stability-count VAD with native Swift equivalents from [soniqo/speech-swift](https://github.com/soniqo/speech-swift).

---

## Context

The current ASR stack has two layers of indirection:

1. **Voice dictation** (`HotkeyManager` → `ASRService`) launches a Rust subprocess (`qwen3_asr_rs/asr-server`), waits for health-check on a random port, then POSTs a multipart WAV file over HTTP.
2. **Subtitle streaming** (`MeetingCaptureEngine`) runs a 0.5 s timer, writes WAV chunks to disk, sends them to the same Rust server, and applies a custom stability-count VAD in Swift.

speech-swift provides `Qwen3ASRModel` (in-process MLX inference) and `StreamingVADProcessor` (Silero VAD, 32 ms chunks) that replace both layers entirely.

**Not affected:** `LLMService` (translate/lookup via `mlx-swift-lm`), `PuncService` (sherpa-onnx CT-Punc), `WhisperService` (WhisperKit), `SpeechStreamer` (macOS built-in), `HotkeyManager`, `SubtitleBar`, `TranscriptOverlay`.

---

## Dependency Changes (`Package.swift`)

- **Add** `speech-swift` from `https://github.com/soniqo/speech-swift`  
- **Products used:** `Qwen3ASR`, `SpeechVAD`  
- **Platform** bump: `.macOS(.v14)` → `.macOS(.v15)` (speech-swift requirement)  
- **Keep:** `mlx-swift-lm`, `sherpa-onnx-spm`, `WhisperKit`

---

## Component 1: `ASRService.swift` (full rewrite)

**Public API — unchanged:**
```swift
func transcribe(url: URL, language: String? = nil) async throws -> String
func stop()
```

**Internals — before → after:**

| Before | After |
|--------|-------|
| `Process` + random port | `Qwen3ASRModel` in-process |
| Health-poll loop (30 s timeout) | Lazy `loadModel()` task (same pattern as `WhisperService`) |
| Multipart HTTP POST | `model.transcribe(audio:language:)` |
| Model path → `--model-dir` CLI arg | Model path → `Qwen3ASRModel.fromPretrained(modelId:)` |

Model loading: lazy on first `transcribe()` call, reloads if `AppState.resolvedModelPath` changes.  
Model path resolution: same `resolveModelPath()` logic as current `ASRService` (HF cache snapshot lookup).

The `Qwen3ASRModel` instance is held in `ASRService` and exposed as `ASRService.shared.model` so `MeetingCaptureEngine` can share it without a second load.

---

## Component 2: `MeetingCaptureEngine.swift` (subtitle streaming rewrite)

### State removed
- `chunkTimer: Timer`
- `subtitleInFlight: Bool`, `chunkSeq: Int`
- `subtitlePrevText`, `subtitleStableCount`, `subtitleCommittedPrefix`, `subtitleUtteranceSentences`
- `writeWAV()` helper
- `lastPartialText`

### State added
- `vadProcessor: StreamingVADProcessor?`
- `rollingBuffer: [Float]` — rolling 30 s cap (same max as current `subtitleMaxSamples`)
- `speechStartSample: Int?` — absolute sample index when speech started
- `samplesConsumed: Int` — total samples fed to VAD processor (for index math after buffer trim)
- `inFlightASR: Bool` — prevents overlapping ASR calls on the same segment

### New flow

**Audio ingestion** (from `SCStreamOutput` callback, unchanged):
```
extractPCM() → appendSubtitlePCM()
```

**`appendSubtitlePCM(_ samples: [Float])`** (replaces `sendNextChunk()` + timer):
1. Append to `rollingBuffer`; trim front if > 30 s, updating `samplesConsumed` offset.
2. Feed `samples` to `vadProcessor.process(samples:)`.
3. For each `VADEvent`:
   - `.speechStarted(time:)` → `speechStartSample = Int(time * 16000)`
   - `.speechEnded(segment:)` → extract speech audio from `rollingBuffer`, fire ASR task

**`processSpeechSegment(_ audio: [Float])`** (async Task):
1. `let text = try await ASRService.shared.transcribe(audio: audio)` — new overload that takes `[Float]` directly (avoids WAV round-trip).  
   Falls back to existing URL overload if needed.
2. `let clean = PuncService.shared.restore(text)` — unchanged.
3. `SubtitleBar.shared.updateLive(clean)` — immediate display.
4. Async translate: `LLMService.shared.translate(clean)` → `SubtitleBar.shared.commitSentence(english:chinese:)`.
5. `transcriptOverlay?.commitEntry(english:chinese:)`.

### What stays
- `SCStream` setup, `startStream()`, `stopStream()` — unchanged.
- `PuncService` punctuation restoration — unchanged.
- `LLMService` translation — unchanged.
- `SubtitleBar` / `TranscriptOverlay` display calls — unchanged.
- `isSilenceHallucination()` filter — unchanged.

---

## Component 3: `ASRService` model sharing

Add a second `transcribe` overload that takes `[Float]` directly (no WAV file):

```swift
func transcribe(audio: [Float], language: String? = nil) async throws -> String
```

`MeetingCaptureEngine` uses this overload; `HotkeyManager` continues to use `transcribe(url:language:)` unchanged.

---

## Build Script (`build-app.sh`)

Remove the release-only block:
```bash
# DELETE:
echo "  🦀 Building asr-server (Rust + MLX)..."
...
cp "$ASR_RS_DIR/target/release/asr-server" ...
```

The `vendor/qwen3_asr_rs` submodule can be deinited and removed.

---

## Error Handling

- Model load failure in `ASRService`: same error propagation as current (`throw` up to caller → shown as overlay error in `HotkeyManager`).
- VAD processor: `StreamingVADProcessor` is synchronous and non-throwing; no new error paths.
- ASR on short segments (< ~0.5 s): pass through; Qwen3-ASR handles short audio gracefully.

---

## Testing Approach

No automated tests exist for this path. Manual verification:
1. Voice dictation hotkey (Right Option) transcribes correctly.
2. Subtitle mode: speech boundary detection fires on real speech, not on silence/noise.
3. `isSilenceHallucination` filter still suppresses Qwen3-ASR system-prompt echoes.
4. PuncService punctuation applied before display.
5. Chinese translation appears in SubtitleBar.
6. `build-app.sh --install` succeeds with no Rust toolchain present.
