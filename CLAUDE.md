# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

TypelessMLX is a macOS menu-bar app (Apple Silicon, macOS 14+) for private, offline voice dictation, real-time bilingual subtitles, word lookup, sentence translation, and OCR. All inference runs on-device via MLX.

## Build Commands

```bash
# Debug build
swift build

# Build + install to /Applications + launch (most common during dev)
./build-app.sh --install

# Release: app bundle + DMG + model zip archives
./build-app.sh --release --allow-adhoc
SIGN_IDENTITY="Apple Development: You (TEAMID)" ./build-app.sh --release --install
```

## Tests

Standalone executable targets (not XCTest):

```bash
swift run TypelessMLXAudioTapFormatTests
swift run TypelessMLXAudioInputAvailabilityTests
```

## Architecture

Split into a Swift frontend and a long-running Python backend subprocess.

### Swift Layer

**Core singletons:**
- `AppState` — all `@AppStorage` settings, `@Published` status/history, available model list, `resolvedModelPath` / `resolvedTextModelPath`
- `WhisperBridge` — owns the Python subprocess; JSON-RPC over stdin/stdout pipes; idle-kills after 15 min; `makeEnv()` sets `HF_ENDPOINT=https://hf-mirror.com` by default
- `HotkeyManager` — Carbon hotkeys (id 1=main, 2=translate, 3=OCR) + NSEvent modifier monitors; drives the full record→transcribe→paste flow
- `ModelManager` — HF cache size tracking; `init()` computes sizes **synchronously** so SettingsView shows correct state immediately; async `refreshAllStatuses()` for post-download updates

**Feature managers (each a singleton set up at launch):**
- `LookupManager` — ⌃⌥D hotkey; calls `WhisperBridge.lookup(text:textModel:)`
- `TranslateManager` — ⌃⌥T hotkey; calls `WhisperBridge.translate(text:textModel:)`
- `OCRManager` — ⌃⌥O hotkey; SCShareableContent permission check → `ScreenshotOverlay` screen selection → `VNRecognizeTextRequest` → `OCRResultOverlay`
- `MeetingCaptureEngine` — SCStream system audio → 0.5s PCM chunks → Python `subtitle_stream` action; feeds both `SubtitleBar` (real-time) and `TranscriptOverlay` (quality transcript); `subtitleModelPath` is **hardcoded to Qwen3-ASR-0.6B** regardless of selected model

**Display overlays:**
- `SubtitleBar` — bottom-center floating window; max 2 lines (English + Chinese); new sentence overwrites old; auto-hides after 6s silence
- `TranscriptOverlay` — top-right accumulating transcript; only updated at VAD commit (not on eager partial sentences)
- `RecordingOverlay` — audio-reactive bars during hotkey recording
- `LookupOverlay` / `TranslateOverlay` / `OCRResultOverlay` — result popovers near cursor

**Other:**
- `AudioRecorder` — AVAudioEngine → WAV via `AudioTapFileWriter`
- `SpeechStreamer` — SFSpeechRecognizer for live preview and "macOS built-in" ASR backend
- `TextRefiner` — `LanguageModelSession` post-processing, strictly `#available(macOS 26, *)`; **not warmed up at launch** to avoid TCC permission prompts
- `TextPaster` — NSPasteboard + CGEvent Cmd+V; restores prior clipboard after 2s

### Python Layer (`backend/transcribe_server.py`)

Single-threaded JSON-RPC server over stdin/stdout. Actions:

| action | description |
|--------|-------------|
| `transcribe` | Whisper or Qwen3-ASR transcription from WAV file |
| `subtitle_stream` | Streaming subtitle: accumulate PCM chunks, eager per-sentence translate, VAD commit |
| `translate` | Bidirectional EN↔ZH translation via Qwen2.5-1.5B; accepts optional `text_model` for lazy model swap |
| `lookup` | Dictionary entry via LLM; accepts optional `text_model` |
| `translate_subtitle` | Legacy subtitle translate action |
| `ping` / `pong` | Health check |

**Subtitle pipeline internals:**
- `_subtitle_buffer`: list of float32 numpy arrays, capped at 15s
- `_subtitle_committed_prefix`: eagerly translated prefix for current utterance
- `_subtitle_utterance_sentences`: accumulates all eager sentences for commit-time transcript write
- At VAD commit: punc_restore + split + translate the **full stable ASR text** for clean transcript output
- `_SUBTITLE_STABLE_THRESHOLD = 2`: two identical ASR results → commit

**Key Python components:**
- `punc_restore()` — sherpa-onnx CT-Punc (`model.int8.onnx`), auto-downloads to `~/.cache/sherpa-onnx/`
- `_load_text_model()` — lazy load/reload with **full rollback on failure** (preserves previous model if new load fails)
- `_is_silence_hallucination()` — filters ASR output that verbatim echoes a system prompt (Qwen3-ASR on silence)
- `_get_completed_sentences()` — splits on `[。！？!?]+` or `\.(?=\s)` (NOT `$` — avoids false positives from Qwen3-ASR terminal period)

### Data Flows

**Voice dictation:**
```
Right Option held → AudioRecorder (WAV to temp)
  → macOS model: SpeechStreamer.transcribe()
  → else: WhisperBridge → Python transcribe action
  → optional TextRefiner (macOS 26+ only)
  → TextPaster (Cmd+V)
  → AppState.addToHistory()
```

**Real-time subtitle:**
```
SCStream PCM (16kHz mono) → 0.5s chunks → Python subtitle_stream
  → Qwen3-ASR 0.6B (built-in VAD) → eager sentence detection
  → CT-Punc → translate → SubtitleBar (partial/committed)
  → At VAD commit: full text → CT-Punc + split + translate → TranscriptOverlay
```

## Runtime Paths

| Path | Contents |
|---|---|
| `~/.local/share/typelessmlx/venv/` | Python venv (Python 3.12, uv-managed) |
| `~/.cache/huggingface/hub/` | HF model weights (Qwen3-ASR, Qwen2.5, Whisper) |
| `~/.cache/sherpa-onnx/` | CT-Punc ONNX model (auto-downloaded on first subtitle use) |
| `~/.local/share/typelessmlx/history.json` | Transcription history |
| `~/Library/Logs/TypelessMLX/typelessmlx.log` | App log (auto-truncated at 5 MB) |

## Key Constraints

- App is `LSUIElement=true` (menu-bar only, no Dock icon); not sandboxed (only `com.apple.security.device.audio-input` entitlement)
- `WhisperBridge` starts Python lazily on first request, not at app launch
- `TextRefiner` **must not** be warmed up at startup — `LanguageModelSession()` default init triggers TCC prompts for Photos/Desktop/Documents/Downloads
- `subtitleModelPath` in `MeetingCaptureEngine` is hardcoded to `mlx-community/Qwen3-ASR-0.6B-8bit` — subtitle speed must not follow the user's ASR model selection
- `HF_ENDPOINT` defaults to `https://hf-mirror.com` in `makeEnv()` — required for downloads in restricted networks; user can override via shell env
- `_SENT_END` regex uses `\.(?=\s)` not `\.(?=\s|$)` — Qwen3-ASR always terminates output with a bare period; matching `$` caused every partial to be treated as a complete sentence
