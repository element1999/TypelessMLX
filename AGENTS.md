# Repository Guidelines

## Project Structure & Module Organization
- `TypelessMLX/Sources/`: main macOS app code (SwiftUI/AppKit, hotkeys, overlays, transcription flow).
- `TypelessMLX/AudioSupport/` and `TypelessMLX/AudioInputSupport/`: audio helper targets used by the app and test executables.
- `TypelessMLX/Tests/AudioTapFormat/` and `TypelessMLX/Tests/AudioInputAvailability/`: standalone Swift executable test targets (not XCTest bundles).
- `backend/`: Python JSON-RPC transcription/translation server (`transcribe_server.py`) plus runtime deps.
- `build-app.sh`: primary packaging script for `.app`, DMG, signing, and optional model archives.
- `docs/`: design notes and implementation plans.

## Build, Test, and Development Commands
- `swift build`: debug build of Swift Package targets.
- `./build-app.sh --install`: common dev loop; builds app bundle, installs to `/Applications`, and launches.
- `./build-app.sh --release --allow-adhoc`: release packaging (DMG, optional model zips) with ad-hoc signing fallback.
- `swift run TypelessMLXAudioTapFormatTests`: run audio tap format validation executable.
- `swift run TypelessMLXAudioInputAvailabilityTests`: run audio input availability validation executable.

## Coding Style & Naming Conventions
- Swift uses 4-space indentation and idiomatic Apple naming: `UpperCamelCase` for types, `lowerCamelCase` for methods/properties.
- Keep manager/service naming consistent with existing code (`*Manager`, `*Overlay`, `*Bridge`, `*Engine`).
- Prefer focused, single-responsibility files in `TypelessMLX/Sources/`.
- Python in `backend/` should follow PEP 8 style and preserve existing JSON-RPC action naming.

## Testing Guidelines
- Add or update executable tests under `TypelessMLX/Tests/<Feature>/main.swift` for behavior that can be validated headlessly.
- Validate both Swift-side behavior and backend contract changes when editing `backend/transcribe_server.py`.
- Run the two `swift run ...Tests` commands before opening a PR; include command output summary in PR notes.

## Commit & Pull Request Guidelines
- Match existing commit style: short imperative subject, optionally scoped (example: `build-app.sh: add --no-models flag`).
- Keep commits focused; avoid mixing backend, packaging, and UI refactors without clear reason.
- PRs should include: what changed, why, manual verification steps, and screenshots/GIFs for UI/overlay changes.
- Link related issues/plans (`docs/superpowers/...`) when implementing tracked tasks.

## Security & Configuration Tips
- Do not commit local caches, venvs, or model weights.
- Treat signing identity and runtime paths (`~/.local/share/typelessmlx`, `~/.cache/huggingface`) as machine-specific.
