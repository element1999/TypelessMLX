# Repository Guidelines

## Project Structure & Module Organization
- `TypelessMLX/Sources/`: main macOS app code, including SwiftUI/AppKit UI, hotkeys, overlays, OCR, translation, ASR, and transcription.
- `TypelessMLX/AudioSupport/` and `TypelessMLX/AudioInputSupport/`: helper targets used by the app and validation executables.
- `TypelessMLX/Tests/`: standalone Swift executable tests by feature (`AudioTapFormat`, `AudioInputAvailability`, `FillerCleaner`), not XCTest bundles.
- `TypelessMLX/Resources/`: bundled runtime resources such as Silero VAD assets and Whisper tokenizers.
- `scripts/`: model/resource download helpers used before packaging.
- `build-app.sh`: app bundling, install, signing, DMG, and release packaging script.
- `docs/`: implementation and manual-install notes.

## Build, Test, and Development Commands
- `swift build`: build all Swift package targets in debug mode.
- `./build-app.sh --install`: build the app bundle, install to `/Applications`, and launch for local testing.
- `./build-app.sh --release --allow-adhoc`: create release artifacts with ad-hoc signing fallback.
- `./scripts/download-whisper-tokenizers.sh`: fetch tokenizer resources before release packaging when needed.
- `swift run TypelessMLXAudioTapFormatTests`: validate audio tap file/format behavior.
- `swift run TypelessMLXAudioInputAvailabilityTests`: validate audio input availability logic.
- `swift run TypelessMLXFillerCleanerTests`: validate filler-cleaning text behavior.

## Coding Style & Naming Conventions
- Use 4-space Swift indentation and Apple naming: `UpperCamelCase` for types, `lowerCamelCase` for properties and methods.
- Keep naming consistent with existing roles: `*Manager`, `*Overlay`, `*Service`, `*Bridge`, and `*Engine`.
- Prefer focused files under `TypelessMLX/Sources/`; avoid broad refactors when changing one workflow.
- Preserve existing action names, settings keys, and user-facing shortcut labels when modifying app contracts.

## Testing Guidelines
- Add headless validation as executable targets under `TypelessMLX/Tests/<Feature>/main.swift` when behavior can be tested without launching the app.
- Run the relevant `swift run ...Tests` command for the area changed; run all three before PRs touching shared app behavior.
- For UI, overlay, audio permission, or packaging changes, include manual verification because executable tests do not fully cover these paths.

## Commit & Pull Request Guidelines
- Match recent history: short imperative subjects, optionally scoped, such as `subtitle: release screen capture on stop`.
- Keep commits focused by area; avoid mixing UI, audio engine, packaging, and resource updates without a clear reason.
- PRs should include what changed, why, tests run, manual verification, and screenshots/GIFs for visible UI or overlay changes.

## Security & Configuration Tips
- Do not commit local caches, virtual environments, logs, build output, downloaded model weights, or machine-specific signing settings.
- Treat paths such as `/Applications`, `~/.cache/huggingface`, and `~/.local/share/typelessmlx` as local runtime state.
