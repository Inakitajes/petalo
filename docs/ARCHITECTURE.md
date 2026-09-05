# Architecture

Petalo is a local, layered macOS contextual assistant.

## Components

- `PetaloApp` owns the SwiftUI lifecycle, AppKit panel lifecycle, settings, glass rendering, display synchronization, Carbon global-hotkey registration, Accessibility and ScreenCaptureKit adapters, and the ChatGPT handoff.
- `PetaloCore` provides framework-neutral display selection, layout, notch geometry, hover interaction, pointer reduction, synchronization policy, glass style math, shortcut validation, normalized-region validation, typed assistant payloads, and the assistant workflow state machine.
- `ContextualAssistantCoordinator` owns the app-layer workflow: it captures selected text or a region before it morphs the existing notch/pill surface into the prompt, drives destination delivery, and clears private state for cancellation, success, and failure.
- `AssistantDestination` is the provider boundary. `ChatGPTDesktopDestination` delivers the prepared prompt by copying it to the clipboard, opening ChatGPT, and simulating paste and Return via synthetic keyboard events.

## Presentation

`NotchLayout` derives a presentation from the selected `NSScreen`. A display with a valid camera safe area and auxiliary top areas receives the physical hanging-notch shape. A display without one receives a centered pill entirely inside the menu-bar strip. Both presentations share the same expansion transition, glass layers, transparent-corner hit testing, and hover lifecycle.

`ScreenSelection` is independent of AppKit and resolves the display from the pointer by default. Focused-window mode receives only normal on-screen window geometry from `ExternalFocusedWindowProvider`; unavailable geometry falls back to the pointer, the previous display, and then the first connected display. All-displays mode creates an independent panel for every connected display.

## Interaction

`NotchHostingView` passes clicks through transparent portions of the panel. `NotchPointerTracker`, `PointerSampleReducer`, and `PointerMovementGate` prevent synthetic hover events caused by panel relocation from expanding Petalo without a deliberate pointer movement.

The expanded surface is **always** the contextual prompt — the old idle "Contextual assistant" placeholder is gone. Three paths reach the same surface and coexist:
- **Hover**: hovering or clicking the compact bar expands a no-context prompt. The user types and sends to ChatGPT with no selection; the workflow submits directly from idle via `beginDirectDelivery` (an `AssistantContext.none` payload).
- **Shortcut (capture)**: a global hotkey captures selected text or a screen region, attaches it as a draft, and auto-expands the same surface. The user types an instruction and sends; the workflow submits from `.prompting` via `beginDelivery`.
- **Shortcut (direct)**: a global hotkey (`⌘⇧A`) opens the surface with no captured context — identical to the hover path but triggered from a keyboard shortcut. The workflow stays in `.idle`; the user types and sends via `beginDirectDelivery`.

The surface state is shared through a `NotchPromptModel` (`@ObservableObject`) rather than by recreating the SwiftUI view, so attaching a draft does not reset `isExpanded` (which previously caused the compact bar to flicker back into view). The panel always hangs from the top of the screen and is sized to the `PromptSurfaceLayout` (480pt-wide bubble), so the compact bar stays in the menu bar / notch in both states and only the height grows. On a notched display the prompt stays attached to the top edge with the hanging-notch silhouette; on an external display it floats below the menu bar as a rounded bubble (480pt wide, 38pt corner radius). `NotchPanel` is key only while the prompt is active (`allowsKeyMode`); in every other state it stays non-key to preserve its transparent-corner click-through contract. An open prompt does not auto-collapse on hover-exit (it is an editable input); it closes on Esc, the cancel button, an outside click, or submit. Panel synchronization is paused while the prompt is active so the surface is not torn down mid-input.

`RegionSelectionOverlayController` creates one temporary crosshair overlay on the display where the action began. `ScreenRegionSelection` rejects an off-display start and clamps the drag endpoint; its normalized region is sanitized again at the ScreenCaptureKit boundary. `ScreenRegionCaptureProvider` converts AppKit's bottom-leading normalized coordinates to capture pixels, excludes every visible Petalo window by window ID, and encodes the result as in-memory PNG data.

## Delivery and permissions

`AccessibilitySelectedTextProvider` requests Accessibility only when selected-text mode is invoked. It first reads the focused element's selected text through macOS Accessibility (no clipboard disturbance). Apps that do not expose `kAXSelectedTextAttribute` (ChatGPT's Electron input, Raycast, custom text views) fall back to a clipboard-copy strategy: Petalo simulates Cmd+C so the frontmost app copies its own selection, reads the string, and restores the prior clipboard. The restore is gated by the pasteboard change count — mirroring the paste flow's `TemporaryClipboard` — so a user or app clipboard change in the capture window is never clobbered. `ScreenRegionCaptureProvider` requests Screen Recording only when region mode is invoked. Permission and unsupported-app failures lead to actionable alerts without opening a prompt.

No documented ChatGPT desktop compose contract exists. `ChatGPTDesktopDestination` checks the `com.openai.chat` application URL, opens the app, and delivers the prompt by simulating `Cmd+V` and `Return` via synthetic keyboard events (CGEvent). For image payloads the image is pasted first, then the instruction text, then `Return`. The destination does not enumerate target windows, choose a conversation, or inspect ChatGPT's UI; it sends events to whichever view ChatGPT presents after activation. `ManualCompletionPlan.combinedPromptText(for:)` builds the text that Petalo pastes. The clipboard restorer retains its snapshot only in memory and restores it only when its recorded pasteboard change count still proves ownership.

## Local state

The only non-preference filesystem state is an advisory duplicate-instance lock under the user's Application Support directory. Petalo does not maintain a domain state store or inspect sessions, terminal data, source files, or integration configuration. Prompts, selected text, capture data, and clipboard snapshots are memory-only and released when the workflow ends (except Petalo's temporary clipboard data while waiting for the synthetic paste, which is restored or discarded within two minutes).
