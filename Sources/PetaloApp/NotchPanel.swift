import AppKit
import Combine
import SwiftUI

import PetaloCore

final class NotchPanel: NSPanel {
    /// Toggled on only while the surface hosts the prompt, so the hosted
    /// `NSTextView` can take focus for typing and dictation. In every other
    /// state the panel stays non-key to preserve its transparent-corner
    /// click-through contract.
    var allowsKeyMode = false
    /// Esc handler active while the panel is key in prompt mode.
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { allowsKeyMode }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}

/// Hosting view that only accepts events inside the visible notch silhouette.
/// The panel always spans the prompt surface height — resizing the window
/// while SwiftUI animates the shape caused a visible glitch — so pass-through
/// for the transparent strip below the notch is handled here.
final class NotchHostingView<Content: View>: NSHostingView<Content> {
    var interactiveRegion = HangingNotchInteractionRegion.empty {
        didSet { refreshPointerLocation() }
    }
    var onPointerUpdate: ((Bool, DisplayPoint) -> Void)?
    private var pointerTrackingArea: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = superview.map { convert(point, from: $0) } ?? point
        let localX = local.x - bounds.minX
        let distanceFromTop = isFlipped
            ? local.y - bounds.minY
            : bounds.maxY - local.y
        guard interactiveRegion.contains(
            DisplayPoint(x: localX, y: distanceFromTop)
        ) else {
            return nil
        }
        return super.hitTest(point)
    }

    override func updateTrackingAreas() {
        if let pointerTrackingArea {
            removeTrackingArea(pointerTrackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        pointerTrackingArea = area
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        report(event: event)
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        report(event: event)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        let location = globalLocation(for: event)
        onPointerUpdate?(false, location)
    }

    func refreshPointerLocation() {
        guard let window else { return }
        let global = NSEvent.mouseLocation
        let inWindow = window.convertPoint(fromScreen: NSPoint(x: global.x, y: global.y))
        let local = convert(inWindow, from: nil)
        report(localPoint: local, globalLocation: DisplayPoint(x: global.x, y: global.y))
    }

    private func report(event: NSEvent) {
        let local = convert(event.locationInWindow, from: nil)
        report(localPoint: local, globalLocation: globalLocation(for: event))
    }

    private func report(localPoint: NSPoint, globalLocation: DisplayPoint) {
        let topLeadingY = isFlipped
            ? localPoint.y - bounds.minY
            : bounds.maxY - localPoint.y
        let isInside = interactiveRegion.contains(
            DisplayPoint(x: localPoint.x - bounds.minX, y: topLeadingY)
        )
        onPointerUpdate?(isInside, globalLocation)
    }

    private func globalLocation(for event: NSEvent) -> DisplayPoint {
        guard let window else {
            let location = NSEvent.mouseLocation
            return DisplayPoint(x: location.x, y: location.y)
        }
        let point = window.convertPoint(toScreen: event.locationInWindow)
        return DisplayPoint(x: point.x, y: point.y)
    }
}

/// One independent SwiftUI/AppKit surface for a display. Each surface owns
/// hover and prompt state via a shared `NotchPromptModel`, which lets the
/// widget react to an attached draft without recreating its view (and thus
/// without resetting `isExpanded`).
@MainActor
private final class NotchDisplayPanel {
    private let panel: NotchPanel
    private let displayID: UInt32
    private var layout: NotchLayout
    private let promptModel: NotchPromptModel
    private var hostingView: NotchHostingView<NotchWidgetView>?
    private var pointerGate = PointerMovementGate()
    private let pointerTracker = NotchPointerTracker()
    private var hoverExpansionIntentSent = false
    private let onSubmit: (String) -> Void
    private let onCancel: () -> Void
    private let onExpandedChange: (UInt32, Bool) -> Void
    /// Reacts to `surfaceLayout` changes (including dynamic text-editor growth)
    /// so the NSPanel's frame stays in sync with the SwiftUI content. The
    /// subscription fires synchronously when the `@Published` property is
    /// set — before SwiftUI re-renders — so the panel is already at the new
    /// height when the animation begins, avoiding a brief clip of the growing
    /// content.
    private var layoutCancellable: AnyCancellable?
    /// Pending draft clear after the content exit has played, cancelled if a
    /// new prompt is presented before it fires (a quick re-present wins).
    private var finalizeDismissWorkItem: DispatchWorkItem?

    private(set) var menuIsVisible = false

    init(
        displayID: UInt32,
        layout: NotchLayout,
        onSubmit: @escaping (String) -> Void,
        onCancel: @escaping () -> Void,
        onExpandedChange: @escaping (UInt32, Bool) -> Void
    ) {
        self.displayID = displayID
        self.layout = layout
        self.onSubmit = onSubmit
        self.onCancel = onCancel
        self.onExpandedChange = onExpandedChange
        let surface = Self.surfaceLayout(for: layout, contentMode: .text)
        self.promptModel = NotchPromptModel(surfaceLayout: surface)
        panel = NotchPanel(
            contentRect: NSRect(x: 0, y: 0, width: layout.width, height: surface.panelHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        // Create the hosting view exactly once. From here on the widget
        // observes the prompt model — attaching a draft or resizing never
        // recreates the view, so `@State` (including `isExpanded`) survives.
        let hostingView = NotchHostingView(rootView: makeRootView())
        hostingView.onPointerUpdate = { [weak self] isInside, location in
            self?.handlePointerUpdate(isInside: isInside, location: location)
        }
        self.hostingView = hostingView
        panel.contentView = hostingView
        // Keep the NSPanel's frame in sync with the prompt surface as the user
        // types — the widget grows `panelHeight` dynamically and the panel
        // must follow so the taller text is not clipped. `dropFirst` skips the
        // initial value (the explicit `resizePanel()` below handles that).
        layoutCancellable = promptModel.$surfaceLayout
            .dropFirst()
            .sink { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.resizePanel()
                }
            }
        resizePanel()
    }

    func show() {
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }

    func update(layout: NotchLayout) {
        guard layout != self.layout else { return }
        self.layout = layout
        // Keep the text-mode surface ready for a hover-initiated prompt.
        promptModel.surfaceLayout = Self.surfaceLayout(for: layout, contentMode: .text)
        // The rootView captures `layout` (a value type), so a real screen
        // change is the one case that must recreate it. This is rare and never
        // happens during a prompt, so it does not reset `isExpanded` mid-input.
        if let hostingView {
            hostingView.rootView = makeRootView()
        }
        resizePanel()
    }

    func lockHoverExpansion(at point: DisplayPoint) {
        pointerGate.lock(at: point)
        hoverExpansionIntentSent = false
    }

    /// Attaches a captured draft (shortcut path) and auto-expands. The surface
    /// layout switches to image mode when the draft carries an image so the
    /// panel grows to fit the preview. The panel becomes key so the text
    /// editor receives focus immediately — the user explicitly invoked this.
    /// The rootView is **not** recreated here: the widget observes the model
    /// and reacts to the new draft without resetting `isExpanded`.
    func presentPrompt(draft: AssistantPromptDraft) {
        let contentMode: PromptSurfaceLayout.ContentMode = {
            switch draft.context {
            case .capturedImage: return .image
            case .selectedText: return .selectedText
            case .none: return .text
            }
        }()
        // A new prompt wins over any in-flight dismissal: cancel the pending
        // draft clear so the new draft isn't wiped the instant it's attached.
        finalizeDismissWorkItem?.cancel()
        finalizeDismissWorkItem = nil
        promptModel.surfaceLayout = Self.surfaceLayout(for: layout, contentMode: contentMode)
        resizePanel()
        promptModel.draft = draft
        panel.allowsKeyMode = true
        panel.onCancel = onCancel
        panel.orderFrontRegardless()
        panel.makeKeyAndOrderFront(nil)
    }

    /// Opens the prompt surface with no captured draft — the direct-prompt
    /// shortcut path. Clears any previous draft so an old context chip or
    /// image preview is removed, switches the surface to text mode, and bumps
    /// `expandRequest` so the widget expands (mirroring a click on the compact
    /// bar). The panel becomes key so the text editor receives focus
    /// immediately — the user explicitly invoked this. The rootView is **not**
    /// recreated: the widget observes the model and reacts without resetting
    /// `isExpanded`.
    func presentDirectPrompt() {
        finalizeDismissWorkItem?.cancel()
        finalizeDismissWorkItem = nil
        promptModel.draft = nil
        promptModel.surfaceLayout = Self.surfaceLayout(for: layout, contentMode: .text)
        resizePanel()
        promptModel.expandRequest += 1
        panel.allowsKeyMode = true
        panel.onCancel = onCancel
        panel.orderFrontRegardless()
        panel.makeKeyAndOrderFront(nil)
    }

    /// Begins the prompt dismissal: tells the widget to play its content
    /// exit (send button zooms out, then editor/context block fades) and
    /// schedules the draft clear for `contentExitDuration` later. The draft
    /// is kept until the content has faded so the context chip doesn't pop
    /// out before the exit animation finishes, and the surface stays at the
    /// draft's content-mode height so the panel doesn't jump while the
    /// content is still exiting. Called for both submit and cancel, on the
    /// shortcut and outside-click paths. (Hover-initiated prompts have no
    /// draft and collapse directly from the widget, so they don't pass
    /// through here.)
    func dismissPrompt() {
        // Stop typing immediately so the editor doesn't keep accepting input
        // while it fades out.
        panel.makeFirstResponder(nil)
        // Signal the widget to begin the content exit; the panel stays open
        // (isExpanded still true) while the button zooms out and the content
        // fades in place.
        promptModel.collapseRequest += 1
        // Clear the draft once the content has faded — invisible then, so the
        // chip doesn't vanish mid-fade. Cancelled if a new prompt is attached
        // before the delay elapses (quick re-present).
        finalizeDismissWorkItem?.cancel()
        let finalize = DispatchWorkItem { [weak self] in
            self?.finalizeDismiss()
        }
        finalizeDismissWorkItem = finalize
        DispatchQueue.main.asyncAfter(
            deadline: .now() + PromptContentMetrics.contentExitDuration,
            execute: finalize
        )
    }

    private func finalizeDismiss() {
        finalizeDismissWorkItem = nil
        promptModel.draft = nil
        panel.allowsKeyMode = false
        panel.onCancel = nil
    }

    /// Called by the controller when the widget's `isExpanded` flips. Enables
    /// key mode on expand and actively makes the panel key so the text field's
    /// cursor is blinking and ready to type — on click, hover, and shortcut
    /// paths alike. On collapse, key mode is disabled to restore the
    /// transparent-corner click-through contract.
    func setExpanded(_ isVisible: Bool) {
        if isVisible {
            panel.allowsKeyMode = true
            panel.onCancel = onCancel
            if PromptKeyPolicy.shouldMakeKey(isExpanded: isVisible) {
                panel.orderFrontRegardless()
                panel.makeKeyAndOrderFront(nil)
            }
        } else {
            panel.allowsKeyMode = false
            panel.onCancel = nil
            // Reset the surface to the compact text-mode layout once the panel
            // has collapsed, so the next hover-initiated (no-context) prompt
            // isn't left at the taller selected-text/image height from the
            // just-dismissed draft. Done here (not during the content exit) so
            // the panel doesn't jump height while the content is still
            // fading out: at this point `isExpanded` is false, so SwiftUI's
            // frame height no longer reads `surface.panelHeight` and the reset
            // is invisible.
            promptModel.surfaceLayout = Self.surfaceLayout(for: layout, contentMode: .text)
            resizePanel()
        }
        onExpandedChange(displayID, isVisible)
    }

    /// Resizes/repositions the panel to the maximum possible expanded height.
    /// The panel is transparent and borderless, so the space below the visible
    /// bubble is invisible — only the SwiftUI-drawn glass/content is visible.
    /// Hit-testing is handled by the `interactiveRegion` (based on
    /// `surface.panelHeight`), not the panel bounds, so clicks in the
    /// transparent area pass through.
    ///
    /// By sizing the panel to the maximum once (on init / layout / content-mode
    /// change) instead of on every text-growth tick, the panel's frame never
    /// changes during the SwiftUI height animation — eliminating the bounce
    /// at the notch's top edge (where the panel is glued to the screen) and the
    /// bottom clipping on external displays.
    private func resizePanel() {
        let surface = promptModel.surfaceLayout
        let maxGrowth = max(
            0,
            PromptSurfaceLayout.maxTextEditorHeight - PromptSurfaceLayout.baseTextEditorHeight
        )
        let panelHeight = surface.basePanelHeight + maxGrowth
        panel.setFrame(
            NSRect(
                x: layout.originX,
                y: layout.originY + layout.height - panelHeight,
                width: layout.width,
                height: panelHeight
            ),
            display: true
        )
    }

    private func handlePointerUpdate(isInside: Bool, location: DisplayPoint) {
        let location = pointerTracker.update(isInside: isInside, location: location)
        guard isInside else {
            hoverExpansionIntentSent = false
            return
        }
        guard !hoverExpansionIntentSent,
              pointerGate.update(pointerLocation: location) else { return }
        hoverExpansionIntentSent = true
        pointerTracker.requestHoverExpansion(at: location)
    }

    private func makeRootView() -> NotchWidgetView {
        NotchWidgetView(
            layout: layout,
            promptModel: promptModel,
            pointerTracker: pointerTracker,
            onSubmit: onSubmit,
            onCancel: onCancel,
            requestPointerRefresh: { [weak self] in
                self?.hostingView?.refreshPointerLocation()
            },
            onInteractiveRegionChange: { [weak self] region in
                self?.hostingView?.interactiveRegion = region
            },
            onMenuVisibilityChange: { [weak self] isVisible in
                guard let self else { return }
                menuIsVisible = isVisible
                setExpanded(isVisible)
            }
        )
    }

    private static func surfaceLayout(
        for layout: NotchLayout,
        contentMode: PromptSurfaceLayout.ContentMode
    ) -> PromptSurfaceLayout {
        PromptSurfaceLayout.layout(
            presentation: layout.presentation,
            barHeight: layout.height,
            panelWidth: layout.width,
            topGap: layout.topGap,
            contentMode: contentMode
        )
    }
}

@MainActor
final class NotchPanelController {
    private let focusedWindowProvider = ExternalFocusedWindowProvider()
    private var displayPanels: [UInt32: NotchDisplayPanel] = [:]
    private var selectedDisplayID: UInt32?
    /// The display currently showing the expanded prompt (hover or shortcut).
    /// Panel synchronization is paused while this is set so the prompt is not
    /// torn down by a workspace or pointer change mid-input.
    private var activePromptDisplayID: UInt32?
    private var selectionMode: ScreenSelectionMode
    private var displaySnapshots: [DisplaySnapshot] = []
    private var pointerDisplayChanges = PointerDisplayChangeReducer(initialDisplayID: nil)
    private var synchronizationPolicy = PanelSynchronizationPolicy()
    private var panelsAreVisible = false
    private var hasPendingSelectedDisplay = false
    private var screenObserver: NSObjectProtocol?
    private var activationObserver: NSObjectProtocol?
    private var spaceObserver: NSObjectProtocol?
    private var defaultsObserver: NSObjectProtocol?
    private var localPointerMonitor: Any?
    private var globalPointerMonitor: Any?
    private var focusedWindowFallbackTimer: Timer?

    /// Routes the prompt's submit/cancel to the assistant coordinator. Set
    /// once by the app delegate.
    var submitHandler: ((String) -> Void)?
    var cancelHandler: (() -> Void)?

    init() {
        selectionMode = Self.configuredSelectionMode
        synchronizePanels()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.focusedWindowProvider.invalidate()
                self?.synchronizePanels()
            }
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                DispatchQueue.main.async {
                    self?.handleWorkspaceContextChange()
                }
            }
        }
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleWorkspaceContextChange()
            }
        }
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: UserDefaults.standard,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleDefaultsChange()
            }
        }
        transitionSynchronizationResources(to: selectionMode)
    }

    deinit {
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
        if let spaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver)
        }
        if let defaultsObserver {
            NotificationCenter.default.removeObserver(defaultsObserver)
        }
        if let localPointerMonitor {
            NSEvent.removeMonitor(localPointerMonitor)
        }
        if let globalPointerMonitor {
            NSEvent.removeMonitor(globalPointerMonitor)
        }
        focusedWindowFallbackTimer?.invalidate()
    }

    func show() {
        panelsAreVisible = true
        displayPanels.values.forEach { $0.show() }
    }

    /// Attaches a captured draft to the prompt surface on the given display
    /// and auto-expands it. This is the shortcut path: the selection is
    /// already captured by the coordinator; here we just reveal it on the
    /// unified surface.
    func presentPrompt(draft: AssistantPromptDraft, on screen: NSScreen) {
        guard let displayID = Self.displayID(for: screen) else { return }
        activePromptDisplayID = displayID
        let displayPanel: NotchDisplayPanel
        if let existing = displayPanels[displayID] {
            displayPanel = existing
        } else {
            let layout = Self.layout(for: screen)
            displayPanel = makeDisplayPanel(displayID: displayID, layout: layout)
            displayPanels[displayID] = displayPanel
            if panelsAreVisible { displayPanel.show() }
        }
        displayPanel.presentPrompt(draft: draft)
    }

    /// Opens a no-context prompt on the given display — the direct-prompt
    /// shortcut path. No draft is captured; the user types and sends from
    /// the idle workflow state via `beginDirectDelivery`.
    func presentDirectPrompt(on screen: NSScreen) {
        guard let displayID = Self.displayID(for: screen) else { return }
        activePromptDisplayID = displayID
        let displayPanel: NotchDisplayPanel
        if let existing = displayPanels[displayID] {
            displayPanel = existing
        } else {
            let layout = Self.layout(for: screen)
            displayPanel = makeDisplayPanel(displayID: displayID, layout: layout)
            displayPanels[displayID] = displayPanel
            if panelsAreVisible { displayPanel.show() }
        }
        displayPanel.presentDirectPrompt()
    }

    /// Collapses the prompt surface (submit or cancel, shortcut or hover).
    func dismissPrompt() {
        guard let displayID = activePromptDisplayID else { return }
        activePromptDisplayID = nil
        displayPanels[displayID]?.dismissPrompt()
    }

    // MARK: - Display panel creation

    private func makeDisplayPanel(displayID: UInt32, layout: NotchLayout) -> NotchDisplayPanel {
        NotchDisplayPanel(
            displayID: displayID,
            layout: layout,
            onSubmit: { [weak self] instruction in
                self?.submitHandler?(instruction)
            },
            onCancel: { [weak self] in
                self?.cancelHandler?()
            },
            onExpandedChange: { [weak self] displayID, isVisible in
                self?.handleExpandedChange(displayID: displayID, isVisible: isVisible)
            }
        )
    }

    private func handleExpandedChange(displayID: UInt32, isVisible: Bool) {
        if isVisible {
            activePromptDisplayID = displayID
        } else if activePromptDisplayID == displayID {
            activePromptDisplayID = nil
        }
    }

    // MARK: - Synchronization

    private func synchronizePanels() {
        // A prompt surface is key and resized to the prompt frame; letting
        // synchronization tear it down or swap displays mid-prompt would
        // abort the user's text input. Workspace and pointer events resume
        // synchronization once the prompt collapses.
        guard activePromptDisplayID == nil else { return }
        let screens = NSScreen.screens
        let screensByID = screens.reduce(into: [UInt32: NSScreen]()) { result, screen in
            guard let displayID = Self.displayID(for: screen) else { return }
            result[displayID] = screen
        }
        let displays = screens.compactMap { screen -> DisplaySnapshot? in
            guard let displayID = Self.displayID(for: screen) else { return nil }
            return DisplaySnapshot(
                id: displayID,
                frame: DisplayFrame(
                    minX: screen.frame.minX,
                    minY: screen.frame.minY,
                    width: screen.frame.width,
                    height: screen.frame.height
                )
            )
        }
        displaySnapshots = displays
        let mouseLocation = NSEvent.mouseLocation
        let pointerLocation = DisplayPoint(x: mouseLocation.x, y: mouseLocation.y)
        _ = pointerDisplayChanges.update(
            displayID: Self.displayID(containing: pointerLocation, displays: displays)
        )
        let pointerIsOnDisplay = displays.contains { $0.frame.contains(pointerLocation) }
        let needsFocusedWindow = selectionMode == .focusedWindow
            || (selectionMode == .pointer && !pointerIsOnDisplay)
        let focusedDisplayID: UInt32?
        if needsFocusedWindow {
            let quartzDisplays = displays.map(Self.quartzDisplaySnapshot)
            focusedDisplayID = focusedWindowProvider
                .focusedWindowFrame(on: quartzDisplays)
                .flatMap {
                    ScreenSelection.displayID(containingMostOf: $0, displays: quartzDisplays)
                }
        } else {
            focusedDisplayID = nil
        }
        let desiredIDs = ScreenSelection.selectDisplayIDs(
            mode: selectionMode,
            pointerLocation: pointerLocation,
            focusedDisplayID: focusedDisplayID,
            lastSelectedDisplayID: selectedDisplayID,
            displays: displays
        )
        let desiredIDSet = Set(desiredIDs)

        if selectionMode != .allDisplays,
           let desiredID = desiredIDs.first,
           let currentID = selectedDisplayID,
           currentID != desiredID,
           displayPanels[currentID]?.menuIsVisible == true {
            hasPendingSelectedDisplay = true
            return
        }

        let previousSelectedDisplayID = selectedDisplayID
        selectedDisplayID = selectionMode == .allDisplays ? nil : desiredIDs.first
        hasPendingSelectedDisplay = false

        for displayID in desiredIDs {
            guard let screen = screensByID[displayID] else { continue }
            let layout = Self.layout(for: screen)
            if let displayPanel = displayPanels[displayID] {
                displayPanel.update(layout: layout)
            } else {
                let displayPanel = makeDisplayPanel(displayID: displayID, layout: layout)
                displayPanels[displayID] = displayPanel
                if panelsAreVisible {
                    displayPanel.show()
                }
                if selectionMode != .allDisplays,
                   let previousSelectedDisplayID,
                   previousSelectedDisplayID != displayID {
                    let mouse = NSEvent.mouseLocation
                    displayPanel.lockHoverExpansion(at: DisplayPoint(x: mouse.x, y: mouse.y))
                }
            }
        }

        let removedDisplayIDs = displayPanels.keys.filter { !desiredIDSet.contains($0) }
        for displayID in removedDisplayIDs {
            displayPanels[displayID]?.hide()
            displayPanels.removeValue(forKey: displayID)
        }
    }

    private func handleDefaultsChange() {
        let mode = Self.configuredSelectionMode
        guard mode != selectionMode else { return }
        selectionMode = mode
        focusedWindowProvider.invalidate()
        transitionSynchronizationResources(to: mode)
        synchronizePanels()
    }

    private func handleWorkspaceContextChange() {
        switch selectionMode {
        case .focusedWindow:
            break
        case .pointer:
            let pointer = NSEvent.mouseLocation
            guard Self.displayID(
                containing: DisplayPoint(x: pointer.x, y: pointer.y),
                displays: displaySnapshots
            ) == nil else { return }
        case .allDisplays:
            return
        }
        focusedWindowProvider.invalidate()
        synchronizePanels()
    }

    private func transitionSynchronizationResources(to mode: ScreenSelectionMode) {
        let transition = synchronizationPolicy.transition(to: mode)
        for resource in transition.removed {
            switch resource {
            case .pointerEventMonitor:
                removePointerEventMonitors()
            case .focusedWindowFallbackTimer:
                stopFocusedWindowFallbackTimer()
            }
        }
        for resource in transition.installed {
            switch resource {
            case .pointerEventMonitor:
                installPointerEventMonitors()
            case .focusedWindowFallbackTimer:
                startFocusedWindowFallbackTimer()
            }
        }
    }

    private func installPointerEventMonitors() {
        guard localPointerMonitor == nil, globalPointerMonitor == nil else { return }
        let mask: NSEvent.EventTypeMask = [
            .mouseMoved,
            .leftMouseDragged,
            .rightMouseDragged,
            .otherMouseDragged,
        ]
        localPointerMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            MainActor.assumeIsolated {
                self?.handlePointerMovement()
            }
            return event
        }
        globalPointerMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handlePointerMovement()
            }
        }
    }

    private func removePointerEventMonitors() {
        if let localPointerMonitor {
            NSEvent.removeMonitor(localPointerMonitor)
            self.localPointerMonitor = nil
        }
        if let globalPointerMonitor {
            NSEvent.removeMonitor(globalPointerMonitor)
            self.globalPointerMonitor = nil
        }
    }

    private func handlePointerMovement() {
        let location = NSEvent.mouseLocation
        let displayID = Self.displayID(
            containing: DisplayPoint(x: location.x, y: location.y),
            displays: displaySnapshots
        )
        guard pointerDisplayChanges.update(displayID: displayID) else { return }
        synchronizePanels()
    }

    private func startFocusedWindowFallbackTimer() {
        guard focusedWindowFallbackTimer == nil else { return }
        let interval = PanelSynchronizationPolicy.focusedWindowFallbackInterval
        let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.focusedWindowProvider.invalidate()
                self?.synchronizePanels()
            }
        }
        timer.tolerance = interval * 0.25
        focusedWindowFallbackTimer = timer
    }

    private func stopFocusedWindowFallbackTimer() {
        focusedWindowFallbackTimer?.invalidate()
        focusedWindowFallbackTimer = nil
    }

    private func handleMenuVisibilityChange() {
        guard hasPendingSelectedDisplay,
              !displayPanels.values.contains(where: \.menuIsVisible) else { return }
        synchronizePanels()
    }

    private static func layout(for screen: NSScreen?) -> NotchLayout {
        let menuBarHeight = screen.map { $0.frame.maxY - $0.visibleFrame.maxY } ?? 0
        return NotchLayout(
            screenMinX: screen?.frame.minX ?? 0,
            screenWidth: screen?.frame.width ?? 1_512,
            screenMaxY: screen?.frame.maxY ?? 982,
            safeAreaTop: screen?.safeAreaInsets.top ?? 0,
            leftNotchEdgeX: screen?.auxiliaryTopLeftArea?.maxX,
            rightNotchEdgeX: screen?.auxiliaryTopRightArea?.minX,
            menuBarHeight: menuBarHeight
        )
    }

    private static func displayID(for screen: NSScreen?) -> UInt32? {
        (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
            .map { $0.uint32Value }
    }

    private static func displayID(
        containing point: DisplayPoint,
        displays: [DisplaySnapshot]
    ) -> UInt32? {
        displays.first { $0.frame.contains(point) }?.id
    }

    private static var configuredSelectionMode: ScreenSelectionMode {
        ScreenSelectionMode(
            rawValue: UserDefaults.standard.string(forKey: "screenSelectionMode") ?? ""
        ) ?? .pointer
    }

    private static func quartzDisplaySnapshot(_ display: DisplaySnapshot) -> DisplaySnapshot {
        let bounds = CGDisplayBounds(CGDirectDisplayID(display.id))
        return DisplaySnapshot(
            id: display.id,
            frame: DisplayFrame(
                minX: bounds.minX,
                minY: bounds.minY,
                width: bounds.width,
                height: bounds.height
            )
        )
    }
}
