import AppKit

import PetaloCore

/// A temporary, key-capable single-display overlay. It is intentionally not a
/// notch panel: it exists only while choosing a region and disappears before
/// ScreenCaptureKit begins the in-memory capture.
@MainActor
final class RegionSelectionOverlayController {
    private var panel: KeyCapablePanel?
    /// Safety net for `playCaptureRipple(image:completion:)`: if the tick ever
    /// stalls, the completion would never run and the prompt would never open.
    private var teardownFallback: Task<Void, Never>?

    func show(
        on screen: NSScreen,
        display: DisplaySnapshot,
        onSelection: @escaping (NormalizedScreenRegion) -> Void,
        onCancel: @escaping () -> Void
    ) {
        hide()
        let panel = KeyCapablePanel(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.onCancel = onCancel
        let view = RegionSelectionView(
            display: display,
            onSelection: onSelection,
            onCancel: onCancel
        )
        panel.contentView = view
        panel.setFrame(screen.frame, display: true)
        self.panel = panel
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    /// Immediate teardown, for cancel and failure paths: any release ripple is
    /// abandoned and its pending completion dropped rather than fired — a
    /// cancelled selection must not open a prompt. Dropping `contentView`
    /// moves the view out of its window, which is where `RegionSelectionView`
    /// releases that completion.
    func hide() {
        teardownFallback?.cancel()
        teardownFallback = nil
        panel?.orderOut(nil)
        panel?.contentView = nil
        panel = nil
    }

    /// Runs the release ripple over the frame that was just captured, then
    /// tears the overlay down and calls `completion`.
    ///
    /// The drag area stops being a live glass lens here and becomes the capture
    /// itself, which is what the Metal shader sloshes: the lens is a
    /// window-server backdrop that renders blank through a shader, and the
    /// captured frame is a pixel-exact stand-in for it.
    ///
    /// Holding the prompt back until the wave finishes is not cosmetic: this
    /// overlay sits at `.screenSaver` while the prompt panel sits at
    /// `.statusBar`, so a prompt opened before the teardown would appear behind
    /// the dimming scrim.
    func playCaptureRipple(image: CGImage, completion: @escaping () -> Void) {
        guard let view = panel?.contentView as? RegionSelectionView else {
            hide()
            completion()
            return
        }
        var hasFired = false
        let finish = { [weak self] in
            guard !hasFired else { return }
            hasFired = true
            self?.hide()
            completion()
        }
        view.playCaptureRipple(image: image, completion: finish)
        // Reduce Motion (and a torn-down view) complete synchronously, leaving
        // nothing to guard.
        guard !hasFired else { return }
        teardownFallback = Task { @MainActor in
            let grace = ReleaseRippleEnvelope.duration + 0.15
            try? await Task.sleep(nanoseconds: UInt64(grace * 1_000_000_000))
            guard !Task.isCancelled else { return }
            finish()
        }
    }
}

private final class RegionSelectionView: NSView {
    private let display: DisplaySnapshot
    private let onSelection: (NormalizedScreenRegion) -> Void
    private let onCancel: () -> Void
    /// Rigid start corner — the anchor of the drag. Never moves after
    /// `mouseDown`. The captured region is built from this and the rigid
    /// release point, so capture accuracy is never affected by the spring.
    private var startPoint: NSPoint?
    /// Rigid current corner — the actual cursor position, updated on every
    /// drag event. The spring chases this; `mouseUp` captures from it.
    private var currentPoint: NSPoint?
    /// Spring-driven corner — the *rendered* trailing corner. Lags
    /// `currentPoint` with a damped 2D spring (`DragSpring.jelly`) so the
    /// drag rectangle reads as an elastic rubber-band with a wobble as the
    /// cursor pauses. The glass lens, dim cutout, and stroke all read from
    /// this (via `selectionRoundedRect`), so the three stay in lockstep.
    /// Under Reduce Motion this is kept equal to `currentPoint` (rigid).
    private var renderedPoint: NSPoint?
    /// Spring velocity for `renderedPoint`. Zeroed on `mouseDown`; integrated
    /// per tick by `springTimer`.
    private var renderedVelocity = CGVector(dx: 0, dy: 0)
    /// Per-frame driver for the spring. A short-interval `Timer` in `.common`
    /// mode so it fires between drag events; stopped when the spring settles
    /// and restarted on the next drag. Never created under Reduce Motion.
    private var springTimer: Timer?
    private var lastTickTime: CFTimeInterval = 0
    private var hintLayer: CATextLayer?

    /// Rigid release point — where the cursor let go. The wave sets out from
    /// here, so it reads as coming from the click rather than from the middle
    /// of the selection.
    private var releasePoint: NSPoint?

    // Two clocks, one timer. The shutter feedback fires the instant the mouse
    // comes up, but the wave cannot start until the captured frame lands a
    // moment later — so the elastic pulse and the hairline flash run off
    // `releasePhase` while the shader and the dim dissolve run off
    // `ripplePhase`. Both advance from the same tick, so everything drawn in
    // one frame is the same instant.
    private var releaseTime: CFTimeInterval?
    private var releasePhase: TimeInterval?
    private var rippleTime: CFTimeInterval?
    private var ripplePhase: TimeInterval?
    private var releaseTimer: Timer?
    /// The hosted capture, created only once the frame lands. Nothing
    /// SwiftUI-hosted exists before this point: a full-screen `NSHostingView`
    /// present during the drag swallows `mouseDown` outright.
    private var captureRipple: RegionCaptureRippleHostingView?
    private var captureImage: CGImage?
    /// Run once when the wave ends so the overlay is torn down and the prompt
    /// opens. Dropped without firing if the view leaves its window first.
    private var rippleCompletion: (() -> Void)?
    /// Elastic pop of the selection on release — the longest release-only
    /// animation, so with no captured frame yet nothing needs redrawing past
    /// this point.
    private static let releasePulseDuration: TimeInterval = 0.30

    /// The drag area renders as a Liquid Glass lens: clear glass that refracts
    /// the screen content behind the overlay, with rounded corners. Tuning is
    /// far gentler than the notch's — zero frost, no white face wash, and only
    /// a whisper of border refraction — so a large selection reads as nearly
    /// flat, crystal-clear glass. The inner refraction sits well below the
    /// system `.clear` baseline (-60 over 20pt) so the edge lensing barely
    /// bends content inward and the selected region stays legible.
    private let regionCornerRadius: CGFloat = 28
    private let glassView: RoundedGlassView

    init(
        display: DisplaySnapshot,
        onSelection: @escaping (NormalizedScreenRegion) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.display = display
        self.onSelection = onSelection
        self.onCancel = onCancel
        self.glassView = RoundedGlassView(
            frostRadius: 0,
            cornerRadius: 28,
            maxInnerAmount: -50,
            maxInnerHeight: 12,
            maxOuterAmount: -10,
            maxOuterHeight: 5,
            refractionReferenceSize: 280
        )
        super.init(frame: .zero)
        wantsLayer = true
        setAccessibilityLabel("Screen region selection")
        setAccessibilityHelp("Drag to select the area to capture. Press Esc to cancel.")
        addSubview(glassView)
        glassView.isHidden = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("not used")
    }

    override var isFlipped: Bool { false }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, hintLayer == nil else { return }
        let hint = CATextLayer()
        hint.string = "Drag to select a screen region"
        hint.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        hint.fontSize = 13
        hint.foregroundColor = NSColor.white.withAlphaComponent(0.78).cgColor
        hint.alignmentMode = .center
        hint.contentsScale = window?.screen?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        layer?.addSublayer(hint)
        hintLayer = hint
        needsLayout = true
    }

    override func layout() {
        super.layout()
        if let hintLayer {
            hintLayer.preferredFrameSize()
            let size = hintLayer.preferredFrameSize()
            hintLayer.frame = CGRect(
                x: (bounds.width - size.width) / 2,
                y: (bounds.height - size.height) / 2,
                width: size.width,
                height: size.height
            )
            hintLayer.isHidden = startPoint != nil
        }
        // Position the glass lens over the live drag and keep its corner
        // radius in lockstep with the rounded selection geometry so the
        // refraction always follows the visible rounded rectangle.
        let rounded = renderedSelectionRect
        // The lens is live only until the captured frame lands; from then on
        // the capture stands in for it, and it is the capture that ripples.
        if let rounded, captureImage == nil {
            glassView.frame = rounded.rect
            glassView.apply(cornerRadius: rounded.cornerRadius)
            glassView.isHidden = false
        } else {
            glassView.isHidden = true
        }
        if let rounded, let captureRipple, let captureImage, let phase = ripplePhase {
            // Inflated by the wave's reach on every side: the frame itself
            // still lands on `rounded.rect` (the hosted view pads it back), but
            // the extra room is what lets the wobbling edge bulge outward
            // instead of being clipped flat by the host's bounds.
            let margin = RippleOutline.margin(for: rounded.rect)
            let host = rounded.rect.insetBy(dx: -margin, dy: -margin)
            captureRipple.frame = host
            // The shader reads `position` top-left within this view, and the
            // rect moves with the elastic pulse, so the origin is re-derived
            // every frame rather than computed once.
            let local = CGPoint(
                x: (releasePoint?.x ?? rounded.rect.midX) - host.minX,
                y: (releasePoint?.y ?? rounded.rect.midY) - host.minY
            )
            captureRipple.rootView = RegionCaptureRipple(
                capture: captureImage,
                contentSize: rounded.rect.size,
                cornerRadius: rounded.cornerRadius,
                rippleOrigin: ScreenRegionSelection.flippedVertically(
                    local,
                    inHeight: host.height
                ),
                elapsed: phase,
                opacity: dimFade
            )
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = clamped(convert(event.locationInWindow, from: nil))
        startPoint = point
        currentPoint = point
        // Start the spring at rest on the cursor: the rubber-band only appears
        // once the cursor moves away, so the first pixel of drag is already
        // taut rather than snapping from an offset.
        renderedPoint = point
        renderedVelocity = CGVector(dx: 0, dy: 0)
        stopSpringTimer()
        hintLayer?.isHidden = true
        needsDisplay = true
        needsLayout = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard startPoint != nil else { return }
        currentPoint = clamped(convert(event.locationInWindow, from: nil))
        if reduceMotion {
            // Rigid render: the rectangle follows the cursor exactly, no lag
            // or wobble. The spring is not consulted and the timer stays off.
            renderedPoint = currentPoint
            needsDisplay = true
            needsLayout = true
        } else {
            startSpringTimer()
        }
    }

    override func mouseUp(with event: NSEvent) {
        stopSpringTimer()
        // Snap the render to the rigid release point so the last visible frame
        // (before the overlay is torn down) matches what will actually be
        // captured — no wobble lingering on the release frame.
        if let currentPoint {
            renderedPoint = currentPoint
            renderedVelocity = CGVector(dx: 0, dy: 0)
            needsDisplay = true
            needsLayout = true
        }
        guard let startPoint, let window else {
            onCancel()
            return
        }
        // Capture uses the RIGID start and release points — never the spring
        // point — so the captured region is exactly what the cursor outlined.
        let endPoint = clamped(convert(event.locationInWindow, from: nil))
        let start = window.convertPoint(toScreen: startPoint)
        let end = window.convertPoint(toScreen: endPoint)
        guard let region = ScreenRegionSelection.normalizedRectangle(
            start: DisplayPoint(x: start.x, y: start.y),
            end: DisplayPoint(x: end.x, y: end.y),
            on: display
        ) else {
            onCancel()
            return
        }
        releasePoint = endPoint
        // The flash and the elastic pop fire now, so the release has an
        // immediate acknowledgement; the wave waits for the captured frame it
        // runs on. Neither is visible to the capture — both are drawn inside
        // this panel, which `capture` already excludes — and neither delays it.
        startReleaseFeedback()
        onSelection(region)
    }

    override func cancelOperation(_ sender: Any?) {
        stopSpringTimer()
        onCancel()
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        // On release the dim dissolves so the overlay lifts off the screen
        // instead of being yanked. It is exactly zero on the wave's last frame,
        // which is the frame still on screen when the panel is ordered out.
        let dim = dimFade
        NSColor.black.withAlphaComponent(0.28 * CGFloat(dim)).setFill()
        // Dim the area OUTSIDE the rounded selection so attention stays on the
        // drag. The inside is left unfilled (even-odd), so the glass lens above
        // refracts the actual screen rather than a flat tint.
        if let rounded = renderedSelectionRect {
            // Once the wave is running, the hole and the hairline follow the
            // deformed outline instead of the rigid rectangle — the same
            // polyline the captured frame is clipped to, so the border wobbles
            // with the pixels rather than pinning them inside a fixed shape.
            // During the drag there is no wave and this is nil, leaving the
            // exact rounded-rect geometry (and its cost) untouched.
            let wobble = rippleOutlinePath(for: rounded)
            context.addPath(CGPath(rect: bounds, transform: nil))
            context.addPath(wobble ?? CGPath(
                roundedRect: rounded.rect,
                cornerWidth: rounded.cornerRadius,
                cornerHeight: rounded.cornerRadius,
                transform: nil
            ))
            context.fillPath(using: .evenOdd)
            // A subtle white hairline on the rounded rect gives the glass edge
            // a crisp boundary to lens against, matching the previous marker.
            // No flare on release: the elastic pop (JellySquashEnvelope) is
            // already the release acknowledgement, and a brightening border
            // read as a white flash rather than a shutter click. The hairline
            // holds its steady drag alpha and just fades out with the dim.
            let lineWidth: CGFloat = 1
            let strokeColor = NSColor.white
                .withAlphaComponent(0.50 * CGFloat(dim))
            strokeColor.setStroke()
            if let wobble {
                // Stroked centered on the outline rather than inset like the
                // rigid path below: it has to sit exactly where the captured
                // frame's clipped edge is, and that edge is this polyline.
                context.addPath(wobble)
                context.setStrokeColor(strokeColor.cgColor)
                context.setLineWidth(lineWidth)
                context.setLineJoin(.round)
                context.strokePath()
            } else {
                let inset = lineWidth / 2
                let strokeRadius = max(rounded.cornerRadius - inset, 0)
                let stroke = NSBezierPath(
                    roundedRect: rounded.rect.insetBy(dx: inset, dy: inset),
                    xRadius: strokeRadius,
                    yRadius: strokeRadius
                )
                stroke.lineWidth = lineWidth
                stroke.stroke()
            }
        } else {
            context.fill(bounds)
        }
        context.restoreGState()
    }

    /// The *rendered* rounded rectangle: built from the fixed start corner and
    /// the spring-driven `renderedPoint`, so the visible drag rectangle (glass
    /// lens, dim cutout, hairline stroke) trails the cursor with the jelly
    /// rubber-band + wobble. The captured region is built separately from the
    /// rigid cursor points in `mouseUp`, so capture accuracy is unaffected.
    private var selectionRoundedRect: RoundedSelectionRect? {
        guard let startPoint, let renderedPoint else { return nil }
        return ScreenRegionSelection.roundedSelectionRect(
            start: startPoint,
            end: renderedPoint,
            cornerRadius: regionCornerRadius
        )
    }

    private func clamped(_ point: NSPoint) -> NSPoint {
        NSPoint(
            x: min(max(point.x, bounds.minX), bounds.maxX),
            y: min(max(point.y, bounds.minY), bounds.maxY)
        )
    }

    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// The rounded rectangle actually painted this frame: `selectionRoundedRect`
    /// with the release pulse applied. A centered scale, so the rectangle
    /// bounces without drifting off the outlined region, and the lens, cutout,
    /// hairline and hosted capture all read from here so they squash together.
    ///
    /// Reuses `JellySquashEnvelope` — already covered by a test pinning it to
    /// identity at both endpoints. Both axes apply here; the notch suppresses
    /// the vertical one only because it would compress past the hardware
    /// cutout, which does not apply to a free-floating selection.
    private var renderedSelectionRect: RoundedSelectionRect? {
        guard let rounded = selectionRoundedRect else { return nil }
        guard let phase = releasePhase else { return rounded }
        let offset = JellySquashEnvelope.scaleOffset(
            phase: phase,
            duration: Self.releasePulseDuration
        )
        return ScreenRegionSelection.scaled(
            rounded,
            by: CGSize(width: 1 + offset.dx, height: 1 + offset.dy)
        )
    }

    /// The selection's outline bent by the release wave, or nil while there is
    /// no wave to bend it — during the whole drag, and on any degenerate
    /// geometry `RippleOutline` refuses. Callers fall back to the rigid rounded
    /// rectangle, which is what the drag drew before any of this existed.
    ///
    /// Built from `releasePoint` (the rigid corner where the cursor let go, not
    /// the sprung one) so the wave sets out from the click, and from the
    /// *rendered* rect so the wobble rides on top of the elastic pop rather
    /// than fighting it.
    private func rippleOutlinePath(for rounded: RoundedSelectionRect) -> CGPath? {
        guard let phase = ripplePhase,
              let release = releasePoint,
              let points = RippleOutline.deformedBoundary(
                  rounded,
                  origin: release,
                  phase: phase
              ),
              points.count > 2 else { return nil }
        let path = CGMutablePath()
        path.addLines(between: points)
        path.closeSubpath()
        return path
    }

    /// Strength of the scrim and the hosted capture this frame: 1 during the
    /// drag, dissolving to 0 across the back half of the release ripple.
    private var dimFade: Double {
        ripplePhase.map(ReleaseRippleEnvelope.dimFade) ?? 1
    }

    // MARK: - Release ripple

    /// Installs the frame that was just captured over the drag area and starts
    /// the wave across it, running `completion` when the wave finishes. This is
    /// all that stands between the capture resolving and the prompt opening, so
    /// it must always call `completion` exactly once.
    ///
    /// Under Reduce Motion nothing animates and the completion runs straight
    /// away, so the prompt opens with the latency it had before any of this.
    func playCaptureRipple(image: CGImage, completion: @escaping () -> Void) {
        guard !reduceMotion, window != nil, selectionRoundedRect != nil else {
            completion()
            return
        }
        captureImage = image
        rippleCompletion = completion
        rippleTime = CACurrentMediaTime()
        ripplePhase = 0
        // Created here and nowhere earlier: a hosted view present during the
        // drag eats the mouse events the drag is made of.
        let host = RegionCaptureRippleHostingView(
            rootView: RegionCaptureRipple(
                capture: image,
                contentSize: .zero,
                cornerRadius: 0,
                rippleOrigin: .zero,
                elapsed: 0,
                opacity: 1
            )
        )
        addSubview(host)
        captureRipple = host
        startReleaseTimer()
        needsDisplay = true
        needsLayout = true
    }

    /// The shutter feedback that fires immediately on mouse-up: the hairline
    /// flash and the elastic pop. The wave itself waits for
    /// `playCaptureRipple`. Same driver shape as the drag spring — a
    /// `.common`-mode timer — so both behave alike under a busy run loop.
    private func startReleaseFeedback() {
        guard !reduceMotion else { return }
        releaseTime = CACurrentMediaTime()
        releasePhase = 0
        startReleaseTimer()
        needsDisplay = true
        needsLayout = true
    }

    private func startReleaseTimer() {
        guard releaseTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 90.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tickRelease() }
        }
        RunLoop.main.add(timer, forMode: .common)
        releaseTimer = timer
    }

    private func stopReleaseTimer() {
        releaseTimer?.invalidate()
        releaseTimer = nil
    }

    private func tickRelease() {
        let now = CACurrentMediaTime()
        if let releaseTime {
            releasePhase = min(now - releaseTime, Self.releasePulseDuration)
        }
        guard let rippleTime else {
            // Only the release feedback is running. Once the pulse is spent
            // there is nothing to redraw until the capture lands, so idle out
            // rather than spin behind a slow capture.
            if (releasePhase ?? 0) >= Self.releasePulseDuration {
                stopReleaseTimer()
            }
            needsDisplay = true
            needsLayout = true
            return
        }
        let elapsed = now - rippleTime
        guard elapsed < ReleaseRippleEnvelope.duration else {
            finishCaptureRipple()
            return
        }
        ripplePhase = elapsed
        needsDisplay = true
        needsLayout = true
    }

    /// Ends the wave and releases the overlay to be torn down. Both phases are
    /// pinned to their endpoints rather than cleared, because every envelope is
    /// exactly at rest there: clearing them would snap the dim back to full
    /// strength on the very last frame before the panel disappears.
    private func finishCaptureRipple() {
        stopReleaseTimer()
        releasePhase = Self.releasePulseDuration
        ripplePhase = ReleaseRippleEnvelope.duration
        needsDisplay = true
        needsLayout = true
        let completion = rippleCompletion
        rippleCompletion = nil
        completion?()
    }

    // MARK: - Spring driver

    /// Starts the per-frame spring timer if it is not already running. The
    /// timer integrates `renderedPoint` toward `currentPoint` and flags a
    /// redraw each frame; it stops itself once the spring settles so a paused
    /// cursor does not burn cycles. Created in `.common` mode so it fires
    /// during the mouse-tracking run loop.
    private func startSpringTimer() {
        guard springTimer == nil else { return }
        lastTickTime = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 90.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.tickSpring()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        springTimer = timer
    }

    private func stopSpringTimer() {
        springTimer?.invalidate()
        springTimer = nil
    }

    /// One spring integration step toward the rigid cursor point. Flags a
    /// redraw only when the rendered point actually moves (so a settled
    /// spring against a still cursor is free), and stops the timer once the
    /// spring is at rest — restarted by the next `mouseDragged`.
    private func tickSpring() {
        guard let target = currentPoint, var rendered = renderedPoint else {
            stopSpringTimer()
            return
        }
        let now = CACurrentMediaTime()
        // Clamp dt so a stalled run loop (e.g. reentry, display sleep) cannot
        // make one giant step that explodes the spring.
        let dt = min(max(now - lastTickTime, 0), 1.0 / 30.0)
        lastTickTime = now
        let next = DragSpring.jelly.step(
            position: rendered,
            velocity: renderedVelocity,
            toward: target,
            dt: dt
        )
        rendered = next.position
        renderedVelocity = next.velocity
        let moved = hypot(rendered.x - (renderedPoint?.x ?? rendered.x),
                          rendered.y - (renderedPoint?.y ?? rendered.y)) > 0.1
        renderedPoint = rendered
        if moved {
            needsLayout = true
            needsDisplay = true
        }
        let speed = hypot(renderedVelocity.dx, renderedVelocity.dy)
        let error = hypot(target.x - rendered.x, target.y - rendered.y)
        if error < 0.3, speed < 2 {
            renderedVelocity = CGVector(dx: 0, dy: 0)
            stopSpringTimer()
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        // If the overlay is being torn down mid-drag (e.g. cancel without
        // mouseUp), stop the timer so it does not outlive the view.
        if newWindow == nil {
            stopSpringTimer()
            stopReleaseTimer()
            rippleTime = nil
            // Dropped without running: it opens the prompt, and a cancelled
            // selection must not open one.
            rippleCompletion = nil
        }
    }
}
