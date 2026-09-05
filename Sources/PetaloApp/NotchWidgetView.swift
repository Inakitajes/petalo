import AppKit
import Combine
import SwiftUI

import PetaloCore

struct NotchPointerSnapshot: Equatable {
    let isInside: Bool
    let revision: UInt
}

/// The AppKit hosting view owns one fixed tracking area. SwiftUI observes the
/// normalized containment state rather than recreating tracking areas while
/// the surface expands and collapses.
@MainActor
final class NotchPointerTracker: ObservableObject {
    @Published private(set) var snapshot = NotchPointerSnapshot(isInside: false, revision: 0)
    let hoverExpansionRequests = PassthroughSubject<DisplayPoint, Never>()
    private var reducer = PointerSampleReducer()

    @discardableResult
    func update(isInside: Bool, location: DisplayPoint) -> DisplayPoint {
        let reduction = reducer.reduce(isInside: isInside, location: location)
        if let containment = reduction.containmentChange {
            snapshot = NotchPointerSnapshot(
                isInside: containment.isInside,
                revision: containment.revision
            )
        }
        return reduction.location
    }

    func requestHoverExpansion(at location: DisplayPoint) {
        hoverExpansionRequests.send(location)
    }
}

/// Observable prompt state shared between the panel controller and the widget.
/// Mutating it does **not** recreate the widget (unlike swapping `rootView`),
/// so SwiftUI's `@State` — including `isExpanded` — survives. This is what
/// prevents the compact bar from flickering back into view when a shortcut
/// attaches a draft.
@MainActor
final class NotchPromptModel: ObservableObject {
    /// The prompt surface geometry for the current display and content mode.
    /// Always set (text mode by default); switched to image mode when an image
    /// draft is attached.
    @Published var surfaceLayout: PromptSurfaceLayout
    /// The captured context attached to the prompt. `nil` means the prompt was
    /// opened by hovering (no selection) — the user just types and sends.
    @Published var draft: AssistantPromptDraft?
    /// Bumped by the controller to request the widget to collapse (cancel or
    /// submit). The widget observes this and sets `isExpanded = false`.
    @Published var collapseRequest = 0
    /// Bumped by the controller to request the widget to expand without a
    /// captured draft — the direct-prompt shortcut path. The widget observes
    /// this and calls `openSurface()` (same as a click, never auto-collapses).
    @Published var expandRequest = 0

    init(surfaceLayout: PromptSurfaceLayout) {
        self.surfaceLayout = surfaceLayout
    }
}

/// Notch UI shell. The expanded surface is **always** the contextual prompt —
/// the old idle "Contextual assistant" placeholder is gone. Hovering or
/// clicking the compact bar opens a no-context prompt (type and send); a
/// shortcut attaches a captured draft to the same surface and auto-expands it.
struct NotchWidgetView: View {
    @AppStorage("glassFrostRadiusNotch") private var notchFrostRadius = NotchGlassStyle.defaultFrostRadius
    @AppStorage("glassTintOpacityNotch") private var notchTintOpacity = NotchGlassStyle.defaultTintOpacity
    @AppStorage("glassFrostRadiusPill") private var pillFrostRadius = NotchGlassStyle.defaultFrostRadius
    @AppStorage("glassTintOpacityPill") private var pillTintOpacity = NotchGlassStyle.defaultTintOpacity
    @Environment(\.openSettings) private var openSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let layout: NotchLayout
    @ObservedObject var promptModel: NotchPromptModel
    @ObservedObject var pointerTracker: NotchPointerTracker
    let onSubmit: (String) -> Void
    let onCancel: () -> Void
    let requestPointerRefresh: () -> Void
    let onInteractiveRegionChange: (HangingNotchInteractionRegion) -> Void
    let onMenuVisibilityChange: (Bool) -> Void

    @State private var isExpanded = false
    @State private var rippleTrigger = 0
    @State private var collapseWorkItem: DispatchWorkItem?
    @State private var hoverExpandWorkItem: DispatchWorkItem?
    @State private var isHoveringPanel = false
    @State private var outsideClickMonitor: Any?
    /// True while the prompt content is playing its exit animation (send
    /// button zooms out, then the editor/context block fades). Set
    /// immediately on dismiss; the panel stays fully open (`isExpanded`
    /// still true) for `PromptContentMetrics.contentExitDuration` so the
    /// button shrinks/fades **in place** — neither riding the panel's
    /// leading-offset slide nor being clipped by the collapsing height.
    /// `isExpanded` flips false (and the panel collapses) only once the
    /// content is already invisible, so the dismissal reads as a clean
    /// zoom-out → content fade → panel collapse instead of a sideways
    /// slide. Passed to `PromptContent` as its `isExiting` signal.
    @State private var contentExiting = false
    /// Pending panel collapse, scheduled `contentExitDuration` after the
    /// content exit begins so the panel only collapses once the content has
    /// faded out. Cancelled if the surface re-expands (shortcut attaches a
    /// new draft, or the pointer re-enters a hover prompt) so a quick
    /// toggle reuses the open panel.
    @State private var contentExitWorkItem: DispatchWorkItem?
    /// True when the expansion was triggered by the hover timer (not a click
    /// or shortcut). Hover-initiated prompts auto-collapse when the pointer
    /// leaves; click/shortcut-initiated prompts stay open until explicitly
    /// dismissed.
    @State private var isHoverInitiated = false
    /// Drives the scale pulse on the compact bar while the hover timer
    /// is running. A gentle scale (1.0 → 1.05) applied to the whole
    /// notch/pill — content, glass scrim, and glass backdrop alike — so
    /// it reads as a heartbeat hint. Anchored to `.top` so the bar stays
    /// pinned to the screen edge and grows downward.
    @State private var bounceScale: CGFloat = 1
    /// Jelly wobble phase in `[0, 1]`, animated linearly on expand. The
    /// scrim silhouette and the live glass mask both read it so the contour
    /// recoils in lockstep. Reset to 0 (rigid) shortly after the animation
    /// completes; at rest the wobbled path equals the rigid silhouette, so
    /// steady state is free. Gated by Reduce Motion: the wobble never starts
    /// and `wobbleAmplitude` is forced to 0 when motion is reduced.
    @State private var wobblePhase: CGFloat = 0
    @State private var wobbleResetWorkItem: DispatchWorkItem?

    /// Wobble first-crest height (points) and run time. Tuned to read as a
    /// gentle jelly follow-through layered on the expand spring — two
    /// damped recoils of the bottom edge over ~0.6 s.
    private static let wobbleAmplitude: CGFloat = 5
    private static let wobbleDuration: TimeInterval = 0.6

    private var surface: PromptSurfaceLayout { promptModel.surfaceLayout }

    /// Width of the visible bubble when expanded (480, clamped to the panel).
    private var contentWidth: CGFloat { surface.contentWidth }

    private var effectiveBottomCornerRadius: CGFloat {
        // The notch opens into a natural bubble: when expanded it adopts the
        // larger, softer radius (matching the external pill) so the open card
        // reads as a round bubble hanging from the screen edge. The compact bar
        // keeps the tight notch radius so the collapsed silhouette still hugs
        // the hardware cutout. `HangingNotchShape` carries this on its
        // `animatableData`, so SwiftUI interpolates the radius with the same
        // spring that drives the height change. The pill is already a bubble in
        // both states, so both radii are identical and this is a no-op there.
        isExpanded ? surface.expandedBottomCornerRadius : surface.bottomCornerRadius
    }

    /// Concave top shoulder radius for the hanging-notch silhouette. When
    /// expanded the notch's shoulders grow to match the expanded bottom radius
    /// so the open card's curves are symmetric — a natural bubble profile edge
    /// to edge. The compact bar keeps the tight shoulder radius so the
    /// collapsed silhouette still hugs the hardware cutout. The pill's bubble
    /// path ignores this entirely, so the expanded value (zero) is a no-op.
    private var effectiveTopShoulderRadius: CGFloat {
        isExpanded ? surface.expandedTopShoulderRadius : HangingNotchMetrics.topShoulderRadius
    }

    /// Side inset for expanded content so it clears the concave shoulder curve.
    /// Grows with the expanded top shoulder radius so the wider curve never
    /// clips text. Zero on a pill (straight sides, no shoulder).
    private var expandedContentSideInset: CGFloat {
        isExpanded ? surface.expandedTopShoulderRadius : 0
    }

    /// Extra space above the header when expanded. On a pill the bar sits at
    /// `topGap` (4pt) from the panel top — too tight for the header text. The
    /// pill's expanded top gap adds breathing room. Zero on a notch (the safe
    /// area already provides the gap).
    private var headerTopPadding: CGFloat {
        isExpanded ? max(0, surface.contentTopOffset - layout.topGap - layout.height) : 0
    }

    /// Spring driving the expand/collapse geometry. Critically damped
    /// (dampingFraction >= 1.0) so the height **never overshoots** — during
    /// collapse the virtual notch shrinks toward the physical hardware cutout
    /// height, and an underdamped spring would dip below it, exposing the
    /// hardware notch through the transparent overlay (the "se ve el Notch"
    /// glitch). The horizontal "rebote" the user feels comes from the
    /// `JellySquashEffect` scaleEffect layered on top (a layer transform, not
    /// a frame change), which fires on both expand and collapse. Under Reduce
    /// Motion the calm, near-critically-damped spring is used and the squash
    /// trigger never increments, so both honor the accessibility preference.
    private var expandSpring: Animation {
        reduceMotion
            ? .spring(
                response: NotchExpandSpringSpec.reduceMotion.response,
                dampingFraction: NotchExpandSpringSpec.reduceMotion.dampingFraction
            )
            : .spring(
                response: NotchExpandSpringSpec.vertical.response,
                dampingFraction: NotchExpandSpringSpec.vertical.dampingFraction
            )
    }

    var body: some View {
        let compactFrame = DisplayFrame(
            minX: layout.compactBarLeadingOffset,
            minY: layout.topGap,
            width: layout.compactBarWidth,
            height: layout.height
        )

        ZStack(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 0) {
                // Breathing room above the header on external displays so
                // "Ask ChatGPT" and the gear button are not glued to the top
                // edge. Zero on notched displays (the safe area is the gap).
                Color.clear
                    .frame(height: headerTopPadding)

                ZStack(alignment: .topLeading) {
                    Button(action: openSurface) {
                        compactBar
                            .contentShape(silhouette)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Open Petalo")
                    .frame(width: layout.compactBarWidth, height: layout.height)
                    .opacity(isExpanded ? 0 : 1)
                    .allowsHitTesting(!isExpanded)

                    promptHeader
                        .frame(width: contentWidth, height: layout.height)
                        .opacity(isExpanded ? 1 : 0)
                        .allowsHitTesting(isExpanded)
                }
                .frame(height: layout.height)

                if isExpanded {
                    PromptContent(
                        draft: promptModel.draft,
                        isExiting: contentExiting,
                        onSubmit: onSubmit,
                        onCancel: onCancel,
                        onTextEditorHeightChange: { measuredHeight in
                            promptModel.surfaceLayout = promptModel.surfaceLayout
                                .withTextEditorHeight(measuredHeight)
                        }
                    )
                    .frame(width: max(1, contentWidth - 2 * expandedContentSideInset))
                    .frame(width: contentWidth, alignment: .center)
                    // No panel-level `.transition`: the content stays mounted
                    // (and `isExpanded` stays true) for the whole exit, so the
                    // button zooms out and the editor/chip fade in place
                    // before the panel collapses. Unmounting when `isExpanded`
                    // finally flips false is invisible — the content has
                    // already faded to opacity 0 by then.
                }
            }
            .frame(
                width: isExpanded ? contentWidth : layout.compactBarWidth,
                height: isExpanded ? surface.panelHeight - layout.topGap : nil,
                alignment: .topLeading
            )
            .background(
                NotchGlassScrim(
                    silhouette: silhouette,
                    barBandHeight: layout.height,
                    presentation: layout.presentation,
                    tintOpacity: layout.presentation == .pill ? pillTintOpacity : notchTintOpacity,
                    wobblePhase: wobblePhase,
                    wobbleAmplitude: wobbleAmplitude
                )
                .modifier(ExpansionRippleEffect(trigger: rippleTrigger))
            )
            .background(
                NotchGlassBackdrop(
                    presentation: layout.presentation,
                    frostRadius: layout.presentation == .pill ? pillFrostRadius : notchFrostRadius,
                    bottomCornerRadius: effectiveBottomCornerRadius,
                    topShoulderRadius: effectiveTopShoulderRadius,
                    wobblePhase: wobblePhase,
                    wobbleAmplitude: wobbleAmplitude
                )
            )
            // Pulse the entire notch/pill — content + glass scrim + glass
            // backdrop — as one heartbeat, not just the compact-bar content.
            // Anchored to `.top` so the bar stays pinned to the screen edge
            // (notch sits at y = 0) and grows downward, avoiding any clipping
            // above the panel.
            .scaleEffect(bounceScale, anchor: .top)
            // Jelly squash & stretch layered over the critically-damped expand
            // spring: the bubble bounces **horizontally** only (the scaleEffect
            // applies dx, not dy) so the vertical height never compresses past
            // the physical notch — the "rebote" reads as elastic width wobble
            // without the glitch of the virtual notch hiding behind the
            // hardware cutout. A layer transform (like the heartbeat above),
            // so the live glass backdrop follows it; unlike the radial ripple
            // it is not confined to the scrim. Fires on both expand and
            // collapse (the trigger increments on every isExpanded change),
            // gated by Reduce Motion (the trigger never increments then).
            .modifier(JellySquashEffect(trigger: rippleTrigger))
            .contentShape(silhouette)
            .contextMenu {
                SettingsLink {
                    Label("Petalo Settings", systemImage: "gearshape")
                }
                Divider()
                Button { NSApp.terminate(nil) } label: {
                    Label("Quit Petalo", systemImage: "power")
                }
            }
            .offset(
                x: isExpanded ? 0 : layout.compactBarLeadingOffset,
                y: layout.topGap
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(expandSpring, value: isExpanded)
        .onChange(of: promptModel.draft) { _, newDraft in
            // A shortcut attached a captured context: auto-expand immediately
            // (no hover/click required) so the bubble opens the moment the
            // selection is ready. Shortcut expansions never auto-collapse.
            if newDraft != nil {
                stopBouncing()
                hoverExpandWorkItem?.cancel()
                hoverExpandWorkItem = nil
                cancelPendingCollapse()
                cancelContentExit()
                isHoverInitiated = false
                contentExiting = false
                isExpanded = true
            }
        }
        .onChange(of: promptModel.collapseRequest) { _, _ in
            stopBouncing()
            isHoverInitiated = false
            // Begin the content exit (button zoom-out, then content fade)
            // and delay the panel collapse until it has played, so the
            // button shrinks/fades in place instead of riding the panel's
            // leading-offset slide or being clipped by the collapsing
            // height.
            beginContentExit()
        }
        .onChange(of: promptModel.expandRequest) { _, _ in
            // The direct-prompt shortcut asked the widget to open with no
            // captured context. This mirrors a click on the compact bar —
            // the surface opens, the text field receives focus, and the
            // prompt never auto-collapses (it is an editable input).
            openSurface()
        }
        .onChange(of: promptModel.surfaceLayout) { _, _ in
            publishInteractiveRegion(compactFrame: compactFrame)
        }
        .onChange(of: pointerTracker.snapshot) { _, snapshot in
            handlePointerContainmentChange(snapshot)
        }
        .onReceive(pointerTracker.hoverExpansionRequests) { location in
            guard HoverInteraction.shouldScheduleExpansion(
                pointer: location,
                compactFrame: compactFrame,
                panelOriginX: layout.originX,
                panelTopY: layout.originY + layout.height,
                isExpanded: isExpanded,
                cornerStyle: layout.cornerStyle,
                topShoulderRadius: effectiveTopShoulderRadius,
                bottomCornerRadius: effectiveBottomCornerRadius
            ) else { return }
            scheduleExpansion()
        }
        .onAppear {
            publishInteractiveRegion(compactFrame: compactFrame)
            requestPointerRefresh()
            onMenuVisibilityChange(isExpanded)
        }
        .onChange(of: isExpanded) { _, isVisible in
            // Fire the horizontal jelly bounce on BOTH expand and collapse —
            // the squash scaleEffect is horizontal-only (no vertical dy), so
            // it is always safe regardless of direction. The wobble (a
            // one-sided vertical contour recoil) stays expand-only because it
            // shrinks the silhouette; on collapse that would push the virtual
            // notch behind the hardware cutout.
            if !reduceMotion {
                rippleTrigger += 1
            }
            if isVisible, !reduceMotion {
                startWobble()
            }
            if isVisible {
                // Reset any lingering text-editor growth from a previous
                // session so the bubble starts from its compact base. This
                // is a no-op when the layout is already at base (the common
                // case), and it preserves the content-mode (text vs image)
                // set by the controller — only the dynamic height delta is
                // cleared.
                promptModel.surfaceLayout = promptModel.surfaceLayout
                    .withTextEditorHeight(0)
                // A re-expand (shortcut draft attached, or pointer re-entry
                // on a hover prompt) cancels any in-flight content exit and
                // clears the exit flag so `PromptContent` replays its entry
                // cascade.
                cancelContentExit()
                contentExiting = false
            }
            publishInteractiveRegion(compactFrame: compactFrame)
            updateOutsideClickMonitor(isVisible: isVisible)
            onMenuVisibilityChange(isVisible)
        }
        .onChange(of: compactFrame) { _, _ in
            publishInteractiveRegion(compactFrame: compactFrame)
            requestPointerRefresh()
        }
        .onDisappear {
            updateOutsideClickMonitor(isVisible: false)
            onMenuVisibilityChange(false)
        }
    }

    private var compactBar: some View {
        Group {
            switch layout.compactControlContent {
            case .none:
                // No glyph: the bar is pure glass over the hardware cutout.
                // It still spans the full compact silhouette so it masks the
                // notch and remains hover/click-expandable.
                Color.clear
                    .frame(width: layout.compactBarWidth, height: layout.height)
            case .brandLabel:
                Text("Petalo")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.88))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var silhouette: HangingNotchShape {
        HangingNotchShape(
            style: layout.cornerStyle,
            topShoulderRadius: effectiveTopShoulderRadius,
            bottomCornerRadius: effectiveBottomCornerRadius
        )
    }

    /// The prompt header shown in the bar area when expanded: the context
    /// title on the left, and the action button on the right. On a notched
    /// display the title and button sit in the wings around the camera
    /// cutout; on a pill they span the bar directly.
    private var promptHeader: some View {
        let wings = layout.expandedHeaderWingWidths()
        return HStack(spacing: 0) {
            Text(headerTitle)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.78))
                .padding(.leading, 20 + expandedContentSideInset)
                .frame(width: wings.left, height: layout.height, alignment: .leading)
                .lineLimit(1)

            if layout.presentation == .notch {
                Color.clear.frame(width: layout.notchWidth, height: layout.height)
            }

            HStack {
                Spacer(minLength: 0)
                Button(action: headerButtonAction) {
                    Image(systemName: headerButtonIcon)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.58))
                        .frame(width: 28, height: 28)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(headerButtonLabel)
            }
            .padding(.trailing, 20 + expandedContentSideInset)
            .frame(
                width: layout.presentation == .notch ? wings.right : contentWidth - wings.left,
                height: layout.height
            )
        }
    }

    private var headerTitle: String {
        // The header stays "Ask ChatGPT" for every prompt that takes text input
        // — including a selected-text draft — so the title never gets clipped
        // to "Selected te…" by the narrow notch wings. A selected-text draft
        // shows its context as a preview chip below the header (see
        // `PromptContent`) instead of in the title, mirroring how an image
        // draft shows its capture below. Only the image draft keeps a distinct
        // "Screen region" label, which is short enough to fit the wings.
        if case .capturedImage = promptModel.draft?.context { return "Screen region" }
        return "Ask ChatGPT"
    }

    /// Gear (settings) in hover mode (no draft to cancel); X (cancel) when a
    /// shortcut attached a draft.
    private var headerButtonIcon: String {
        promptModel.draft == nil ? "gearshape" : "xmark"
    }

    private var headerButtonLabel: String {
        promptModel.draft == nil ? "Petalo settings" : "Cancel contextual prompt"
    }

    private func headerButtonAction() {
        if promptModel.draft == nil {
            showSettings()
        } else {
            onCancel()
        }
    }

    private func showSettings() {
        NSApp.activate(ignoringOtherApps: true)
        openSettings()
        onCancel()
    }

    private func openSurface() {
        stopBouncing()
        hoverExpandWorkItem?.cancel()
        hoverExpandWorkItem = nil
        cancelPendingCollapse()
        cancelContentExit()
        isHoverInitiated = false
        contentExiting = false
        isExpanded = true
    }

    /// Schedules a hover expansion after a 2-second delay. While waiting, the
    /// compact bar plays a gentle bounce animation to hint that it is about to
    /// open. If the pointer leaves before the timer fires, the bounce stops
    /// and the expansion is cancelled.
    private func scheduleExpansion() {
        guard !isExpanded, hoverExpandWorkItem == nil else { return }
        startBouncing()
        let workItem = DispatchWorkItem {
            stopBouncing()
            cancelContentExit()
            contentExiting = false
            isHoverInitiated = true
            isExpanded = true
            hoverExpandWorkItem = nil
        }
        hoverExpandWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: workItem)
    }

    // MARK: - Bounce

    /// Starts a gentle scale pulse on the entire notch/pill — glass and
    /// content together — so the user knows the surface is about to open.
    /// A slow heartbeat: the bar grows ~5% then settles back, repeating
    /// until the timer fires or the pointer leaves.
    private func startBouncing() {
        guard !reduceMotion else { return }
        withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
            bounceScale = 1.05
        }
    }

    /// Stops the pulse and returns the entire notch/pill to its resting size.
    private func stopBouncing() {
        withAnimation(.easeOut(duration: 0.2)) {
            bounceScale = 1
        }
    }

    // MARK: - Wobble

    /// Wobble amplitude for the current motion preference: the tuned crest
    /// height, or zero under Reduce Motion so the contour stays rigid (the
    /// wobble never starts and `wobbledPath` collapses to the rigid path).
    private var wobbleAmplitude: CGFloat {
        reduceMotion ? 0 : Self.wobbleAmplitude
    }

    /// Plays the jelly contour wobble layered on the expand spring: the
    /// silhouette's bottom edge recoils upward with a damped two-bump
    /// envelope while the scrim and the live glass mask recoil in lockstep.
    /// Driven by a single linear animation of `wobblePhase` 0→1 — the damped
    /// shape lives in `HangingNotchGeometry.wobbledPath`, so the linear ramp
    /// produces the non-linear jelly feel. `wobblePhase` is already 0 at rest
    /// (the post-animation reset returns it there), so the animation always
    /// runs the full 0→1 sweep. The reset to 0 a beat later is a rigid→rigid
    /// jump (both endpoints render the rigid silhouette), so it is invisible
    /// whether or not it lands inside an animation transaction.
    private func startWobble() {
        guard !reduceMotion else { return }
        wobbleResetWorkItem?.cancel()
        withAnimation(.linear(duration: Self.wobbleDuration)) {
            wobblePhase = 1
        }
        let reset = DispatchWorkItem { wobblePhase = 0 }
        wobbleResetWorkItem = reset
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.wobbleDuration + 0.05,
            execute: reset
        )
    }

    private func publishInteractiveRegion(compactFrame: DisplayFrame) {
        // The bubble occupies from `topGap` (the compact bar's top) down to
        // the panel bottom, so its height is `panelHeight - topGap`. Clicks
        // inside this region are accepted; the transparent strip above the
        // bar (notch) and any panel margin pass through.
        let bubbleHeight = max(0, surface.panelHeight - layout.topGap)
        let frame = HoverInteraction.interactiveFrame(
            compactFrame: compactFrame,
            expandedPanelWidth: contentWidth,
            expandedMaximumHeight: surface.panelHeight,
            measuredContentHeight: bubbleHeight,
            isExpanded: isExpanded,
            expandedTopInset: layout.topGap
        )
        onInteractiveRegionChange(HangingNotchInteractionRegion(
            frame: frame,
            cornerStyle: layout.cornerStyle,
            topShoulderRadius: effectiveTopShoulderRadius,
            bottomCornerRadius: effectiveBottomCornerRadius
        ))
    }

    private func handlePointerContainmentChange(_ snapshot: NotchPointerSnapshot) {
        isHoveringPanel = snapshot.isInside
        if snapshot.isInside {
            cancelPendingCollapse()
            // Pointer came back during a hover-initiated exit: cancel the
            // pending collapse and revert the content exit so the prompt
            // re-appears (the button zooms back in, the editor fades back).
            if contentExiting {
                cancelContentExit()
                contentExiting = false
            }
        } else {
            // Pointer left: cancel any pending hover-expand + bounce.
            hoverExpandWorkItem?.cancel()
            hoverExpandWorkItem = nil
            stopBouncing()
            // Only hover-initiated prompts auto-collapse. Click and shortcut
            // expansions stay open until explicitly dismissed.
            if isHoverInitiated {
                scheduleCollapseOnHoverExit()
            }
        }
    }

    private func scheduleCollapseOnHoverExit() {
        cancelPendingCollapse()
        guard HoverInteraction.shouldCollapse(isExpanded: isExpanded, isHoveringPanel: isHoveringPanel) else {
            return
        }
        let workItem = DispatchWorkItem {
            guard HoverInteraction.shouldCollapse(isExpanded: isExpanded, isHoveringPanel: isHoveringPanel) else {
                return
            }
            collapseWorkItem = nil
            isHoverInitiated = false
            // Hover prompts have no draft, so there is no chip to preserve;
            // still play the content exit before the panel collapses so the
            // send button zooms out and the editor fades in place.
            beginContentExit()
        }
        collapseWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: workItem)
    }

    private func cancelPendingCollapse() {
        collapseWorkItem?.cancel()
        collapseWorkItem = nil
    }

    /// Begins the content exit and schedules the panel collapse for
    /// `contentExitDuration` later. The send button zooms out (shrinks +
    /// fades in place, slot held by its `Spacer`) and the editor/context
    /// block fades out just behind it; only once that has played does
    /// `isExpanded` flip false so the panel collapses around content that
    /// is already invisible. This is what makes the dismissal read as a
    /// mirror of the entry cascade rather than the button sliding off the
    /// trailing edge with the panel's leading-offset animation.
    private func beginContentExit() {
        contentExitWorkItem?.cancel()
        contentExiting = true
        let collapse = DispatchWorkItem {
            contentExitWorkItem = nil
            // If a re-expand cancelled the exit (clearing `contentExiting`),
            // leave the panel open. The work item is also cancelled on
            // re-expand, so this guard is a backstop.
            guard contentExiting else { return }
            isExpanded = false
            contentExiting = false
        }
        contentExitWorkItem = collapse
        DispatchQueue.main.asyncAfter(
            deadline: .now() + PromptContentMetrics.contentExitDuration,
            execute: collapse
        )
    }

    /// Cancels a pending content-exit collapse — used when the surface
    /// re-expands (shortcut attaches a new draft, or the pointer re-enters a
    /// hover prompt) so a quick toggle reuses the open panel and replays the
    /// entry cascade instead of collapsing.
    private func cancelContentExit() {
        contentExitWorkItem?.cancel()
        contentExitWorkItem = nil
    }

    /// An outside click cancels the prompt (and any attached draft) via the
    /// coordinator, which clears the workflow and requests a collapse. A
    /// no-context (hover) prompt is cancelled the same way — the workflow
    /// cancel is a safe no-op from idle.
    private func updateOutsideClickMonitor(isVisible: Bool) {
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
        guard isVisible else { return }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { _ in
            onCancel()
        }
    }
}

struct HangingNotchShape: Shape {
    var style: HangingNotchCornerStyle = .hangingNotch
    var topShoulderRadius: CGFloat
    var bottomCornerRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topShoulderRadius, bottomCornerRadius) }
        set {
            topShoulderRadius = newValue.first
            bottomCornerRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        Path(HangingNotchGeometry.path(
            in: rect,
            style: style,
            topShoulderRadius: topShoulderRadius,
            bottomCornerRadius: bottomCornerRadius
        ))
    }
}

/// Silhouette whose bottom edge recoils upward with a damped two-bump jelly
/// envelope, delegating to `HangingNotchGeometry.wobbledPath`. Built per
/// frame by `NotchGlassScrim` as `wobblePhase` animates 0→1; at rest (phase 0
/// or 1, or amplitude 0) it is identical to `HangingNotchShape`, so the scrim
/// is free until the wobble plays. The wobble is render-only — hit testing
/// keeps using the rigid `HangingNotchInteractionRegion`, so the tappable
/// silhouette never jiggles.
struct WobblingHangingNotchShape: Shape {
    var style: HangingNotchCornerStyle
    var topShoulderRadius: CGFloat
    var bottomCornerRadius: CGFloat
    var wobblePhase: CGFloat
    var wobbleAmplitude: CGFloat

    func path(in rect: CGRect) -> Path {
        Path(HangingNotchGeometry.wobbledPath(
            in: rect,
            style: style,
            topShoulderRadius: topShoulderRadius,
            bottomCornerRadius: bottomCornerRadius,
            phase: wobblePhase,
            amplitude: wobbleAmplitude
        ))
    }
}
