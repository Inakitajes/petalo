# Agent Guide

## Petalo

Petalo is a native macOS 14+ Swift package with a notch/external-display UI app and a dependency-free behavioral test runner.

## Commands

```bash
swift build
swift run petalo-tests
./scripts/build-app.sh
```

Run all three before proposing a pull request. The generated app bundle is `.build/Petalo.app` and must never be committed.

## Engineering rules

- Add a failing behavioral test before changing runtime behavior.
- Keep the package local-only; do not add networking, telemetry, accounts, process scanning, or terminal automation without explicit product approval and privacy documentation.
- Keep source under `Sources/` and behavioral tests under `Tests/PetaloCoreTests/`.
- Preserve the physical-notch and external-display pill presentations, including click-through in transparent corners and display-selection fallbacks.
- Treat display and window geometry as untrusted input. Do not request Accessibility or Screen Recording permissions solely for placement.
