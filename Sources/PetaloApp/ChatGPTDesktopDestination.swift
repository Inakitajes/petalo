import AppKit
import CoreGraphics

import PetaloCore

/// Capability-gated desktop adapter. ChatGPT exposes no documented compose
/// API, so this adapter routes through synthetic keyboard events: it opens
/// ChatGPT, then walks the ordered `ChatGPTHandoffPlan` steps — new
/// conversation, clipboard write, paste, return — to deliver the prompt.
///
/// Every synthetic keystroke is preceded by a `verifyFrontmost` probe that
/// re-checks ChatGPT is still the focused app, retrying with geometric
/// backoff (`ChatGPTHandoffTiming`) if focus has drifted. This is the
/// resilience gate: it fixes the race where keystrokes fired before
/// ChatGPT's window was active, or after another app stole focus mid-handoff.
///
/// The clipboard write is the last step before each paste (no `await`
/// between them), so a clipboard manager that auto-restores the prior
/// clipboard contents after detecting a programmatic change cannot replace
/// the prompt before the paste reads it. The plan's ordering is guarded by
/// a behavioral test.
///
/// The clipboard's prior contents are held only in memory and restored
/// after the handoff completes (or after two minutes, whichever comes
/// first), but only if Petalo can prove its temporary clipboard data has not
/// been replaced. See PRIVACY.md for the data-lifetime contract.
@MainActor
final class ChatGPTDesktopDestination: AssistantDestination {
    private static let bundleIdentifier = "com.openai.chat"
    private let clipboard = TemporaryClipboard()
    private var applicationURL: URL?

    func deliver(_ payload: AssistantPayload) async -> AssistantDeliveryResult {
        guard let applicationURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: Self.bundleIdentifier
        ) else {
            return ChatGPTDeliveryPolicy.result(for: .unavailable)
        }
        self.applicationURL = applicationURL

        guard await openApplication() else {
            return .failed(.deliveryFailed)
        }

        let hasImage: Bool = {
            if case .capturedImage = payload.context { return true }
            return false
        }()

        let steps = hasImage
            ? ChatGPTHandoffPlan.imageThenTextSteps(for: payload)
            : ChatGPTHandoffPlan.textSteps(for: payload)

        guard await executeHandoff(steps) else {
            clipboard.restoreIfOwned()
            return .failed(.deliveryFailed)
        }

        clipboard.restoreIfOwned()
        return ChatGPTDeliveryPolicy.result(for: .autoPaste)
    }

    // MARK: - Handoff execution

    /// Walks the plan's ordered steps, aborting safely on cancellation or
    /// focus loss. `Task.isCancelled` is checked before every step so a
    /// superseding invocation stops the handoff as soon as the current step
    /// yields. The `writeClipboard` → `paste` pair has no `await` between
    /// them, so a clipboard manager cannot replace the prompt in that gap.
    private func executeHandoff(_ steps: [ChatGPTHandoffPlan.Step]) async -> Bool {
        for step in steps {
            guard !Task.isCancelled else { return false }
            switch step {
            case .verifyFrontmost:
                guard await verifyFrontmost(.recovery) else { return false }
            case .newConversation:
                Self.simulateNewConversation()
            case .waitNanoseconds(let nanoseconds):
                try? await Task.sleep(nanoseconds: nanoseconds)
            case .writeClipboard(let clipboardStep):
                guard clipboard.write(clipboardStep) else { return false }
            case .paste:
                Self.simulatePaste()
            case .sendReturn:
                Self.simulateReturn()
            }
        }
        return true
    }

    // MARK: - Application opening and focus verification

    /// Opens ChatGPT and waits until it is actually the frontmost app before
    /// returning. `NSWorkspace.openApplication` with `activates = true` returns
    /// as soon as the launch is dispatched, not when the window is focused, so
    /// a blind fixed sleep here was the source of the "keystrokes fire before
    /// the window is focused" race. The `.activation` schedule polls
    /// `frontmostApplication` with geometric backoff instead.
    private func openApplication() async -> Bool {
        guard let applicationURL = applicationURL ?? NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: Self.bundleIdentifier
        ) else {
            return false
        }
        do {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            _ = try await NSWorkspace.shared.openApplication(at: applicationURL, configuration: configuration)
        } catch {
            return false
        }
        return await verifyFrontmost(.activation)
    }

    /// Returns true when ChatGPT is the frontmost app, retrying with the given
    /// backoff schedule. This is the resilience gate: synthetic keyboard events
    /// are only useful when ChatGPT's window is actually focused, so every
    /// keystroke is preceded by a `verifyFrontmost` probe. Returns false when
    /// the schedule is exhausted or when the delivery Task has been cancelled
    /// by a newer invocation, signalling the caller to abort the handoff.
    private func verifyFrontmost(_ timing: ChatGPTHandoffTiming) async -> Bool {
        var attempt = 0
        while !isFrontmost {
            guard !Task.isCancelled else { return false }
            guard let delay = timing.delay(forAttempt: attempt) else {
                return false
            }
            try? await Task.sleep(nanoseconds: delay)
            attempt += 1
        }
        return !Task.isCancelled
    }

    private var isFrontmost: Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Self.bundleIdentifier
    }

    // MARK: - Synthetic keyboard events

    /// Posts Cmd+N to start a new conversation in ChatGPT before pasting, so
    /// the prompt does not append to an existing thread.
    private static func simulateNewConversation() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyCode_N: CGKeyCode = 45
        let keyCode_cmd: CGKeyCode = 0x37

        let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode_cmd, keyDown: true)
        cmdDown?.flags = .maskCommand

        let nDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode_N, keyDown: true)
        nDown?.flags = .maskCommand

        let nUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode_N, keyDown: false)
        nUp?.flags = .maskCommand

        let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode_cmd, keyDown: false)

        cmdDown?.post(tap: .cghidEventTap)
        nDown?.post(tap: .cghidEventTap)
        nUp?.post(tap: .cghidEventTap)
        cmdUp?.post(tap: .cghidEventTap)
    }

    /// Posts Cmd+V to paste the current clipboard contents into the frontmost
    /// app (ChatGPT). Requires the same Accessibility trust Petalo already
    /// requests for reading selected text.
    private static func simulatePaste() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyCode_V: CGKeyCode = 9
        let keyCode_cmd: CGKeyCode = 0x37

        let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode_cmd, keyDown: true)
        cmdDown?.flags = .maskCommand

        let vDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode_V, keyDown: true)
        vDown?.flags = .maskCommand

        let vUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode_V, keyDown: false)
        vUp?.flags = .maskCommand

        let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode_cmd, keyDown: false)

        cmdDown?.post(tap: .cghidEventTap)
        vDown?.post(tap: .cghidEventTap)
        vUp?.post(tap: .cghidEventTap)
        cmdUp?.post(tap: .cghidEventTap)
    }

    /// Posts Return to send the pasted message in the frontmost app.
    private static func simulateReturn() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyCode_return: CGKeyCode = 0x24

        let returnDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode_return, keyDown: true)
        let returnUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode_return, keyDown: false)

        returnDown?.post(tap: .cghidEventTap)
        returnUp?.post(tap: .cghidEventTap)
    }
}

/// Holds a clipboard snapshot only in memory. Restoration happens only when
/// the general pasteboard still has the change count Petalo recorded after its
/// own write, so user or another-app clipboard changes always win.
@MainActor
private final class TemporaryClipboard {
    private struct Snapshot {
        let items: [[NSPasteboard.PasteboardType: Data]]
    }

    private let pasteboard = NSPasteboard.general
    private var snapshot: Snapshot?
    private var ownedChangeCount: Int?
    private var restorationWorkItem: DispatchWorkItem?

    deinit {
        restorationWorkItem?.cancel()
    }

    func write(_ step: ManualCompletionStep) -> Bool {
        restoreIfOwned()
        snapshot = Snapshot(items: pasteboard.pasteboardItems?.map { item in
            item.types.reduce(into: [:]) { result, type in
                if let data = item.data(forType: type) {
                    result[type] = data
                }
            }
        } ?? [])

        let item = NSPasteboardItem()
        switch step {
        case let .copyPrompt(text):
            item.setString(text, forType: .string)
        case let .copyImage(image):
            let type: NSPasteboard.PasteboardType = image.mimeType == "image/tiff" ? .tiff : .png
            item.setData(image.data, forType: type)
        }
        pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else {
            restoreSnapshot()
            wipeSnapshot()
            return false
        }
        ownedChangeCount = pasteboard.changeCount
        scheduleRestoration()
        return true
    }

    func restoreIfOwned() {
        restorationWorkItem?.cancel()
        restorationWorkItem = nil
        defer { wipeSnapshot() }
        guard snapshot != nil, let ownedChangeCount,
              pasteboard.changeCount == ownedChangeCount else {
            return
        }
        restoreSnapshot()
    }

    private func restoreSnapshot() {
        guard let snapshot else { return }
        pasteboard.clearContents()
        let items = snapshot.items.map { dataByType -> NSPasteboardItem in
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

    private func scheduleRestoration() {
        let item = DispatchWorkItem { [weak self] in
            self?.restoreIfOwned()
        }
        restorationWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 120, execute: item)
    }

    private func wipeSnapshot() {
        snapshot = nil
        ownedChangeCount = nil
    }

}
