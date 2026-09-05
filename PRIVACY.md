# Privacy

Petalo is local-only. It has no networking code, telemetry, analytics, advertising, crash reporting, accounts, API keys, or cloud storage.

## Data read

- connected-display geometry and safe-area information required to position the notch or pill;
- the pointer location when pointer-based display selection is enabled;
- when focused-window selection is enabled, the frontmost application's process ID and normal on-screen window bounds. Petalo does not read window names, images, or contents.
- after the user invokes **Ask about selected text**, the frontmost application's focused Accessibility element and its selected text. Petalo requests Accessibility only for that action. Petalo first tries to read the selection through macOS Accessibility (no clipboard disturbance). Some applications do not expose their selection through Accessibility (for example ChatGPT's Electron input or Raycast); for those, Petalo falls back to simulating Cmd+C so the frontmost app copies its own selection to the system clipboard, reads the string, and restores the prior clipboard contents. The fallback lasts only the few milliseconds of the capture, requires the same Accessibility trust already requested, and restores the prior clipboard only when the pasteboard change count proves Petalo still owns the temporary copy — otherwise it discards the snapshot without modifying the clipboard;
- after the user invokes **Ask about screen region**, a user-dragged rectangle on one display and the corresponding ScreenCaptureKit pixels. Petalo requests Screen Recording only for that action and excludes Petalo's own windows from the capture;
- whether the native ChatGPT application can be opened by its bundle identifier. Petalo does not inspect ChatGPT's windows, conversations, or controls.

Focused-window geometry is cached in memory briefly and is never persisted. When macOS withholds focused-window geometry, Petalo falls back to the pointer, then the last selected display, then the first connected display.

Selected text, captured PNG bytes, prompt instructions, source-app labels, and the workflow payload exist only in memory from capture through cancellation, delivery, or failure. They are never written to logs, preferences, or files. A captured image is encoded directly to in-memory PNG data; Petalo creates no screenshot or prompt temporary file.

ChatGPT has no supported inbound compose API. Petalo therefore delivers the prepared prompt by copying it to the system clipboard, opening ChatGPT, and simulating Cmd+V followed by Return using synthetic keyboard events (CGEvent). For image payloads the image is pasted first, then the instruction text, then Return. Petalo does not inspect or target a specific ChatGPT window or conversation; it sends synthetic events to whichever view ChatGPT presents after activation. Petalo retains the prior clipboard snapshot only in memory for up to two minutes. It restores that snapshot only if the pasteboard change count proves the clipboard still contains Petalo's own temporary data; otherwise it discards the snapshot without modifying the clipboard.

## Data stored

Petalo stores ordinary UI preferences, display settings, and two global-shortcut bindings in macOS user defaults. It keeps a private application lock under the user's Application Support directory to prevent duplicate panels. It does not store sessions, process histories, terminal identifiers, prompts, selected text, captures, clipboard snapshots, source files, credentials, or integration configuration.

## Development permission note

Screen Recording and Accessibility authorization are tied to macOS's view of the local app identity. The `build-app.sh` script signs the `.build/Petalo.app` bundle with the first available Developer ID Application certificate so that Privacy & Security (TCC) recognises the rebuilt app as the same one instead of creating a new orphaned entry each time. If no Developer ID certificate is found, it falls back to ad-hoc signing, which can require re-authorization after rebuilding. Petalo does not request either permission merely to place its panels.
