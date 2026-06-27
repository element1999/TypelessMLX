# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

TypelessMLX is a macOS menu-bar app (Apple Silicon, macOS 15+) for private, offline voice dictation, real-time subtitles, word lookup, sentence translation, and OCR. Runtime inference is native Swift using MLX, speech-swift, WhisperKit, and Apple frameworks. There is no Python or Rust sidecar at runtime.

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

The app is a single native Swift process. Do not reintroduce Python, Rust, or local HTTP/JSON-RPC sidecars for ASR.

**Core singletons:**
- `AppState` - all `@AppStorage` settings, status/history, available model list, and resolved model paths.
- `ASRService` - in-process Qwen3-ASR via `speech-swift` `Qwen3ASRModel`.
- `WhisperService` - Whisper transcription via WhisperKit.
- `LLMService` - lookup/translation text model loading via `mlx-swift-lm`.
- `ModelManager` - HuggingFace cache size tracking and Swift-native model downloads via `HuggingFace.HubClient`.
- `HotkeyManager` - Carbon hotkeys and the record -> transcribe -> paste flow.

**Feature managers:**
- `MeetingCaptureEngine` - ScreenCaptureKit system audio capture, `SpeechVAD` segmentation, Qwen3-ASR transcription, and translation overlay updates.
- `LookupManager` - lookup hotkey and result overlay.
- `TranslateManager` - sentence translation hotkey and overlay.
- `OCRManager` - screen selection and OCR using macOS Vision.

**Display overlays:**
- `SubtitleBar` - bottom-center floating subtitle window.
- `TranscriptOverlay` - accumulating transcript window.
- `RecordingOverlay` - audio-reactive bars during hotkey recording.
- `LookupOverlay` / `TranslateOverlay` / `OCRResultOverlay` - result popovers near cursor.

**Other:**
- `AudioRecorder` - AVAudioEngine -> WAV via `AudioTapFileWriter`.
- `SpeechStreamer` - SFSpeechRecognizer for live preview and macOS built-in ASR backend.
- `TextRefiner` - `LanguageModelSession` post-processing, strictly `#available(macOS 26, *)`; do not warm it up at launch.
- `TextPaster` - NSPasteboard + CGEvent Cmd+V; restores prior clipboard after 2s.

## Runtime Paths

| Path | Contents |
|---|---|
| `~/.cache/huggingface/hub/` | HF model weights (Qwen3-ASR, Qwen2.5, Whisper) |
| `~/.cache/sherpa-onnx/` | CT-Punc ONNX model if used by punctuation restoration |
| `~/.local/share/typelessmlx/history.json` | Transcription history |
| `~/Library/Logs/TypelessMLX/typelessmlx.log` | App log (auto-truncated at 5 MB) |

## Key Constraints

- App is `LSUIElement=true` (menu-bar only, no Dock icon); not sandboxed.
- MLX requires `mlx.metallib` in the app bundle; `build-app.sh` calls `scripts/build-mlx-metallib.sh` and copies it into `Contents/MacOS` and `Contents/Resources`.
- `TextRefiner` must not be warmed up at startup because `LanguageModelSession()` default init can trigger TCC prompts for Photos/Desktop/Documents/Downloads.
- Model downloads must stay Swift-native. `ModelManager` uses `HuggingFace.HubClient` and stores files in `~/.cache/huggingface/hub`.
- `HF_ENDPOINT` defaults to `https://hf-mirror.com` for Swift model downloads unless overridden in the process environment.
