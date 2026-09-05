import AppKit
import ApplicationServices
import CoreGraphics

/// Reads the frontmost application's selected text after an explicit global
/// action. It is never queried from settings or during normal panel updates.
///
/// Two strategies are tried in order, so the action works in apps that do not
/// expose their selection through macOS Accessibility (e.g. ChatGPT's Electron
/// input, Raycast, and other custom text views):
/// 1. **Accessibility (preferred).** Reads `kAXSelectedTextAttribute` on the
///    focused element. Does not disturb the clipboard and works in any app
///    with standard text controls (Chrome, Notes, Mail, Safari, …).
/// 2. **Clipboard copy fallback.** When Accessibility can't read the
///    selection, Petalo simulates Cmd+C so the frontmost app copies its own
///    selection to the clipboard, reads the string, and restores the prior
///    clipboard contents. This requires the same Accessibility trust the
///    primary path already needs (synthetic keyboard events are gated by it)
///    and only ever touches the clipboard for the few milliseconds of the
///    capture. The restore is gated by the pasteboard change count — exactly
///    like the paste flow's `TemporaryClipboard` — so a user or app clipboard
///    change in the capture window is never clobbered. See PRIVACY.md for the
///    data-lifetime contract.
@MainActor
final class AccessibilitySelectedTextProvider {
    enum CaptureError: Error {
        case noFrontmostApplication
        case unsupportedSelection
    }

    /// Maximum time to wait for the frontmost app to update the clipboard after
    /// a simulated Cmd+C before giving up. Apps normally copy within tens of
    /// milliseconds; this is a generous upper bound.
    private static let clipboardCopyTimeout: TimeInterval = 0.4

    func selectedText(from application: NSRunningApplication) throws -> String {
        // Primary path. `try?` swallows any Accessibility failure (unsupported
        // element, no selection, transient AX error) and falls through to the
        // clipboard strategy, which is robust to all of those except a genuine
        // "no selection" — in which case Cmd+C copies nothing and the fallback
        // fails safely too.
        if let text = try? readSelectedTextViaAccessibility(from: application) {
            return text
        }
        return try copySelectedTextViaClipboard()
    }

    func requestPermissionIfNeeded() -> Bool {
        guard !AXIsProcessTrusted() else { return true }
        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true,
        ] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        return false
    }

    // MARK: - Accessibility

    private func readSelectedTextViaAccessibility(from application: NSRunningApplication) throws -> String {
        let appElement = AXUIElementCreateApplication(application.processIdentifier)
        var focusedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        ) == .success,
        let focusedValue else {
            throw CaptureError.unsupportedSelection
        }

        guard CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else {
            throw CaptureError.unsupportedSelection
        }
        let focusedElement = unsafeBitCast(focusedValue, to: AXUIElement.self)
        var selectedValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            focusedElement,
            kAXSelectedTextAttribute as CFString,
            &selectedValue
        ) == .success,
        let text = selectedValue as? String,
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CaptureError.unsupportedSelection
        }
        return text
    }

    // MARK: - Clipboard copy fallback

    private func copySelectedTextViaClipboard() throws -> String {
        let pasteboard = NSPasteboard.general
        let beforeCount = pasteboard.changeCount
        // Snapshot the current contents (in memory only) so they can be
        // restored after Petalo reads the selection.
        let snapshot = Self.snapshotPasteboard(pasteboard)

        Self.simulateCopy()
        guard Self.waitForClipboardChange(
            pasteboard,
            changedFrom: beforeCount,
            timeout: Self.clipboardCopyTimeout
        ) else {
            // No copy happened (no selection, or the app ignores Cmd+C). The
            // clipboard is untouched, so there is nothing to restore.
            throw CaptureError.unsupportedSelection
        }

        // Record the change count right after the copy so the restore can
        // prove Petalo still owns this temporary clipboard data. If the user
        // or another app changes the clipboard before the restore, the change
        // count will differ and the snapshot is discarded without modifying
        // the clipboard.
        let postCopyCount = pasteboard.changeCount

        guard let text = pasteboard.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            Self.restoreSnapshotIfOwned(
                snapshot,
                onto: pasteboard,
                ownedChangeCount: postCopyCount
            )
            throw CaptureError.unsupportedSelection
        }

        Self.restoreSnapshotIfOwned(
            snapshot,
            onto: pasteboard,
            ownedChangeCount: postCopyCount
        )
        return text
    }

    /// Posts Cmd+C to the frontmost app so it copies its own selection to the
    /// clipboard. Requires the same Accessibility trust Petalo already requests
    /// for reading selected text (synthetic keyboard events to other apps are
    /// gated by it). The key codes mirror the paste flow in
    /// `ChatGPTDesktopDestination`.
    private static func simulateCopy() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyCode_C: CGKeyCode = 8
        let keyCode_cmd: CGKeyCode = 0x37

        let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode_cmd, keyDown: true)
        cmdDown?.flags = .maskCommand

        let cDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode_C, keyDown: true)
        cDown?.flags = .maskCommand

        let cUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode_C, keyDown: false)
        cUp?.flags = .maskCommand

        let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode_cmd, keyDown: false)

        cmdDown?.post(tap: .cghidEventTap)
        cDown?.post(tap: .cghidEventTap)
        cUp?.post(tap: .cghidEventTap)
        cmdUp?.post(tap: .cghidEventTap)
    }

    /// Polls the pasteboard's change count until it changes or `timeout`
    /// elapses. The frontmost app updates the clipboard on its own thread, so
    /// this only yields the main run loop while waiting — it never busy-spins.
    private static func waitForClipboardChange(
        _ pasteboard: NSPasteboard,
        changedFrom changeCount: Int,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while Date() < deadline {
            if pasteboard.changeCount != changeCount { return true }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.01))
        }
        return pasteboard.changeCount != changeCount
    }

    // MARK: - Pasteboard snapshot/restore

    /// Captures every item and type on the pasteboard into an in-memory
    /// snapshot. Mirrors the snapshot logic in the paste flow's
    /// `TemporaryClipboard`; kept local so this provider stays self-contained.
    private static func snapshotPasteboard(
        _ pasteboard: NSPasteboard
    ) -> [[NSPasteboard.PasteboardType: Data]] {
        pasteboard.pasteboardItems?.map { item in
            item.types.reduce(into: [NSPasteboard.PasteboardType: Data]()) { result, type in
                if let data = item.data(forType: type) {
                    result[type] = data
                }
            }
        } ?? []
    }

    /// Restores the snapshot only when the pasteboard's change count still
    /// equals `ownedChangeCount`, proving Petalo's temporary copy has not been
    /// replaced. If another process changed the clipboard in the capture
    /// window, the snapshot is discarded without modifying the clipboard.
    private static func restoreSnapshotIfOwned(
        _ snapshot: [[NSPasteboard.PasteboardType: Data]],
        onto pasteboard: NSPasteboard,
        ownedChangeCount: Int
    ) {
        guard pasteboard.changeCount == ownedChangeCount else { return }
        pasteboard.clearContents()
        let items = snapshot.map { dataByType -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in dataByType {
                item.setData(data, forType: type)
            }
            return item
        }
        if !items.isEmpty {
            _ = pasteboard.writeObjects(items)
        }
    }
}
