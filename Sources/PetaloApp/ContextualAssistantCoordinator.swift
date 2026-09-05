import AppKit
import ApplicationServices

import PetaloCore

/// AppKit boundary around the framework-neutral workflow. It captures source
/// context first, then morphs the existing notch/pill surface into the prompt
/// only after the context is safely represented by the in-memory state
/// machine. The same surface also serves hover-initiated (no-context) prompts,
/// which submit directly from the idle state.
@MainActor
final class ContextualAssistantCoordinator {
    private struct InvocationContext {
        let display: AssistantInvocationDisplay
        let displaySnapshot: DisplaySnapshot
        let screen: NSScreen
    }

    private var workflow = ContextualAssistantWorkflow()
    private let textProvider = AccessibilitySelectedTextProvider()
    private weak var notchPanelController: NotchPanelController?
    private let regionOverlay = RegionSelectionOverlayController()
    private let screenCaptureProvider = ScreenRegionCaptureProvider()
    private let destination: AssistantDestination
    private var deliveryTask: Task<Void, Never>?

    init(notchPanelController: NotchPanelController, destination: AssistantDestination? = nil) {
        self.notchPanelController = notchPanelController
        self.destination = destination ?? ChatGPTDesktopDestination()
    }

    func invoke(_ action: AssistantShortcutAction) {
        switch action {
        case .selectedText:
            invokeSelectedText()
        case .screenRegion:
            invokeScreenRegion()
        case .directPrompt:
            invokeDirectPrompt()
        }
    }

    func invokeSelectedText() {
        guard let context = invocationContext() else {
            presentFailure(.selectedTextUnavailable, message: "Petalo could not determine the display for this action.")
            return
        }
        // A new capture supersedes any in-flight delivery: cancel the old
        // delivery Task and abandon the delivering state so the state machine
        // is free to accept the new capture. Without this, the old delivery's
        // keystrokes would continue firing into ChatGPT while the new capture
        // proceeds, causing the old payload to race the new one.
        deliveryTask?.cancel()
        workflow.abandonDelivery()
        workflow.beginSelectedTextCapture(on: context.display)
        guard textProvider.requestPermissionIfNeeded() else {
            fail(.accessibilityDenied)
            return
        }
        guard let sourceApplication = NSWorkspace.shared.frontmostApplication,
              sourceApplication.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            fail(.selectedTextUnavailable)
            return
        }
        do {
            let text = try textProvider.selectedText(from: sourceApplication)
            workflow.captureSelectedText(text, sourceApplication: sourceApplication.localizedName)
            presentPromptIfReady(on: context.screen)
        } catch {
            fail(.selectedTextUnavailable)
        }
    }

    func cancel() {
        deliveryTask?.cancel()
        notchPanelController?.dismissPrompt()
        regionOverlay.hide()
        workflow.cancel()
    }

    func invokeScreenRegion() {
        guard let context = invocationContext() else {
            presentFailure(.invalidRegionSelection, message: "Petalo could not determine the display for this action.")
            return
        }
        // Same supersession guard as invokeSelectedText: a new region capture
        // cancels any in-flight delivery so old keystrokes don't race.
        deliveryTask?.cancel()
        workflow.abandonDelivery()
        workflow.beginRegionSelection(on: context.display)
        guard screenCaptureProvider.requestPermissionIfNeeded() else {
            fail(.screenRecordingDenied)
            return
        }
        regionOverlay.show(
            on: context.screen,
            display: context.displaySnapshot,
            onSelection: { [weak self] region in
                self?.capture(region: region, on: context.screen)
            },
            onCancel: { [weak self] in self?.cancel() }
        )
    }

    /// Opens the prompt surface with no captured context — the direct-prompt
    /// shortcut. The workflow stays in `.idle` (no capture, no draft); the user
    /// types and submits from idle via `beginDirectDelivery`, exactly like the
    /// hover/click path. Any in-flight delivery or open draft is superseded:
    /// the delivery task is cancelled and the workflow is reset to idle.
    func invokeDirectPrompt() {
        guard let context = invocationContext() else {
            presentFailure(.deliveryFailed, message: "Petalo could not determine the display for this action.")
            return
        }
        deliveryTask?.cancel()
        regionOverlay.hide()
        workflow.cancel()
        notchPanelController?.presentDirectPrompt(on: context.screen)
    }

    /// Submits the prompt. This is the single entry point for both the shortcut
    /// path (workflow is `.prompting` with a captured draft) and the hover path
    /// (workflow is `.idle` with no context). The surface is dismissed
    /// immediately; delivery proceeds in the background.
    func submit(instruction: String) {
        let payload: AssistantPayload
        do {
            switch workflow.state {
            case .prompting:
                payload = try workflow.beginDelivery(instruction: instruction)
            case .idle:
                payload = try workflow.beginDirectDelivery(instruction: instruction)
            default:
                notchPanelController?.dismissPrompt()
                return
            }
        } catch let failure as AssistantWorkflowFailure {
            notchPanelController?.dismissPrompt()
            presentFailure(failure)
            return
        } catch {
            notchPanelController?.dismissPrompt()
            presentFailure(.deliveryFailed)
            return
        }
        notchPanelController?.dismissPrompt()
        deliveryTask = Task { [weak self] in
            guard let self else { return }
            let result = await destination.deliver(payload)
            // If the delivery was cancelled by a newer invocation, skip
            // completeDelivery so the state machine is not clobbered — the
            // new invocation already called abandonDelivery and moved on.
            if Task.isCancelled { return }
            workflow.completeDelivery(result)
            switch result {
            case let .failed(failure):
                presentFailure(failure)
            case .completed:
                break
            case .manualCompletionRequired:
                break
            }
        }
    }

    private func presentPromptIfReady(on screen: NSScreen) {
        guard let draft = workflow.promptDraft else { return }
        notchPanelController?.presentPrompt(draft: draft, on: screen)
    }

    private func fail(_ failure: AssistantWorkflowFailure) {
        notchPanelController?.dismissPrompt()
        regionOverlay.hide()
        workflow.captureFailed(failure)
        presentFailure(failure)
    }

    private func presentFailure(_ failure: AssistantWorkflowFailure, message: String? = nil) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Petalo couldn't start the contextual assistant"
        alert.informativeText = message ?? Self.message(for: failure)
        if let privacyPane = Self.privacyPane(for: failure) {
            alert.addButton(withTitle: "Open Privacy & Security")
            alert.addButton(withTitle: "OK")
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(privacyPane)
            }
        } else {
            alert.addButton(withTitle: "OK")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
        workflow.dismissFailure()
    }

    private func capture(region: NormalizedScreenRegion, on screen: NSScreen) {
        // Snapshot Petalo's windows — including the still-on-screen region
        // selection overlay — BEFORE ordering the overlay out. ScreenCaptureKit
        // can only exclude a window while it remains on screen: it must appear
        // in the shareable content's window list, which is sampled inside
        // `capture`. The overlay's Liquid Glass lens (`CABackdropLayer` with
        // `windowServerAware` + the private `glassBackground` filter) refracts
        // the screen content behind its clear panel. If the overlay were
        // ordered out before capture it could no longer be excluded, and the
        // glass refraction — a crystal/frosted wash over the real content —
        // would bleed into the captured region whenever the window server's
        // composition had not yet recomposed without the panel (order-out is
        // synchronous in AppKit but not in the compositor ScreenCaptureKit
        // samples). Keeping the overlay on screen during capture lets
        // `capture` exclude it, so the captured region is the crisp screen
        // content with no glass lens layered on top. The overlay is torn down
        // right after the in-memory capture resolves.
        let petaloWindows = NSApp.windows
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let captured = try await screenCaptureProvider.capture(
                    region: region,
                    excluding: petaloWindows
                )
                // The state machine advances as soon as the image is in hand;
                // only the *presentation* waits. The captured frame goes back
                // to the overlay, which drops the live glass lens, puts the
                // frame in its place and runs the release ripple over it —
                // the drag area's own content sloshing like water — before
                // tearing down. The wait is not cosmetic: the overlay sits at
                // `.screenSaver` and the prompt panel at `.statusBar`, so a
                // prompt opened before the teardown would appear behind the
                // dimming scrim. A cancel during the ripple drops this
                // completion, so no stale prompt follows.
                workflow.captureRegion(captured.payload)
                regionOverlay.playCaptureRipple(image: captured.image) { [weak self] in
                    self?.presentPromptIfReady(on: screen)
                }
            } catch {
                fail(.captureFailed)
            }
        }
    }

    private func invocationContext() -> InvocationContext? {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let screen,
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        let display = AssistantInvocationDisplay(id: number.uint32Value)
        return InvocationContext(
            display: display,
            displaySnapshot: DisplaySnapshot(
                id: display.id,
                frame: DisplayFrame(
                    minX: screen.frame.minX,
                    minY: screen.frame.minY,
                    width: screen.frame.width,
                    height: screen.frame.height
                )
            ),
            screen: screen
        )
    }

    private static func message(for failure: AssistantWorkflowFailure) -> String {
        switch failure {
        case .accessibilityDenied:
            "Allow Petalo in Accessibility to read the focused control's selected text. Petalo asks only after you invoke this action."
        case .selectedTextUnavailable:
            "The active app did not expose selected text through macOS Accessibility. Select text in a supported native control and try again."
        case .screenRecordingDenied:
            "Allow Petalo in Screen Recording to capture a screen region after you invoke that action."
        case .invalidRegionSelection:
            "Start and finish the selection on the same display."
        case .captureFailed:
            "Petalo could not capture that region. Try again without moving the selection to another display."
        case .emptyInstruction:
            "Enter an instruction before sending the content to ChatGPT."
        case .destinationUnavailable:
            "ChatGPT for macOS was not found. Install or open the ChatGPT desktop app, then try again."
        case .deliveryFailed:
            "Petalo could not paste the prompt into ChatGPT. Your prompt and captured context have been cleared."
        }
    }

    private static func privacyPane(for failure: AssistantWorkflowFailure) -> URL? {
        let anchor: String
        switch failure {
        case .accessibilityDenied:
            anchor = "Privacy_Accessibility"
        case .screenRecordingDenied:
            anchor = "Privacy_ScreenCapture"
        default:
            return nil
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")
    }
}
