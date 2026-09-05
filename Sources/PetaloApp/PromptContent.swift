import AppKit
import SwiftUI

import PetaloCore

/// The inner content of the contextual-assistant prompt: the image preview,
/// text editor, and send button. The title row and action button live in the
/// widget's header (the bar area) so they use the top-edge space rather than
/// wasting it. When `draft` is nil (hover-initiated, no selection) no image
/// preview is shown; the user just types and sends to ChatGPT with no pasted
/// context.
struct PromptContent: View {
    let draft: AssistantPromptDraft?
    /// True while the content is playing its exit. The parent keeps the panel
    /// fully open (`isExpanded` still true) for `contentExitDuration` after
    /// flipping this to true, so the send button can zoom out and the editor/
    /// context block can fade **in place** before the panel collapses — the
    /// dismissal reads as a mirror of the entry cascade instead of the button
    /// sliding off the trailing edge with the panel's leading-offset slide.
    let isExiting: Bool
    let onSubmit: (String) -> Void
    let onCancel: () -> Void
    /// Receives the text editor's measured intrinsic content height so the
    /// panel can grow to fit it. Called on every text change and once on
    /// initial appearance.
    let onTextEditorHeightChange: (CGFloat) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var instruction = ""
    /// The editor's current intrinsic height, clamped to `[44, max]`. Drives
    /// the editor's frame so all typed text stays visible instead of being
    /// clipped by a fixed cap.
    @State private var editorHeight: CGFloat = 44
    /// Whether the editor + context preview block is visible. Drives a plain
    /// `.opacity` modifier — the block stays mounted the whole time, so its
    /// layout slot is stable and the panel's leading-offset slide can't make
    /// it drift while it fades.
    @State private var contentVisible = false
    /// Whether the send button has zoomed into its final position. Drives a
    /// render-time `.scaleEffect` + `.opacity` (the button is always
    /// mounted; the trailing `Spacer` keeps reserving its full layout slot),
    /// so the button zooms in on expand and zooms back out on dismiss **in
    /// place** — never riding the trailing edge or drifting to a corner the
    /// way a conditional + `.transition` would. The zoom endpoints live in
    /// `PromptButtonZoom` so the entry/exit symmetry is guarded by a test.
    @State private var sendButtonAppeared = false
    /// Pending cascade task that zooms the button in after the expand spring
    /// settles. Cancelled on dismiss (and on a quick re-expand) so the button
    /// never zooms in after the surface has already begun to exit.
    @State private var cascadeTask: Task<Void, Never>?
    /// Pending content fade scheduled on exit so the send button leads the
    /// dismissal and the editor/context block follows a beat behind — the
    /// reverse of the entry cascade (content first, then button).
    @State private var contentFadeTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: PromptContentMetrics.innerSpacing) {
            Group {
                if case let .capturedImage(image) = draft?.context,
                   let preview = NSImage(data: image.data) {
                    Image(nsImage: preview)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 92)
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .modifier(LiquidGlassPreviewOverlay(cornerRadius: 20))
                        .frame(maxWidth: .infinity)
                }

                if case let .selectedText(text) = draft?.context {
                    SelectedTextPreviewChip(text: text)
                        .padding(.bottom, PromptContentMetrics.chipBottomGap)
                }

                PromptTextEditor(
                    text: $instruction,
                    onSubmit: { onSubmit(instruction) },
                    onCancel: onCancel,
                    onHeightChange: handleEditorHeightChange
                )
                .frame(height: editorHeight)

                Spacer(minLength: 0)
            }
            // The whole editor + context block fades as one. Kept mounted
            // (no `if`) so its layout slot is stable and the panel's
            // leading-offset slide can't carry it sideways while it fades.
            .opacity(contentVisible ? 1 : 0)

            HStack(spacing: 0) {
                Spacer(minLength: 0)
                Button(action: { onSubmit(instruction) }) {
                    Text("Send to ChatGPT")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(.black.opacity(0.88))
                        .padding(.horizontal, 20)
                        .padding(.vertical, 9)
                        .background(.white.opacity(0.9), in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Send to ChatGPT")
                // The button zooms in on entry and back out on dismiss — both
                // in place. `.scaleEffect` is a render-time transform, so the
                // `Spacer` keeps reserving the button's full layout slot and
                // the final position never shifts (no corner drift, no slide).
                .opacity(sendButtonAppeared ? 1 : 0)
                .scaleEffect(
                    sendButtonAppeared ? PromptButtonZoom.restingScale : PromptButtonZoom.hiddenScale,
                    anchor: .center
                )
            }
        }
        .padding(.horizontal, PromptContentMetrics.sidePadding)
        .padding(.top, effectiveTopPadding)
        .padding(.bottom, PromptContentMetrics.bottomPadding)
        .onAppear {
            // Fresh mount: the parent only mounts `PromptContent` while
            // `isExpanded`, so on first appearance the surface is open and we
            // begin the entry cascade. (A quick toggle reuses the still-
            // mounted view and is handled by `onChange` below.)
            startEntry()
        }
        .onChange(of: isExiting) { _, exiting in
            if exiting {
                startExit()
            } else {
                // Re-expand of a still-mounted view (collapsed less than
                // `contentExitDuration` ago): clear any text carried over
                // from the prior session so each prompt opens empty, then
                // replay the entry cascade.
                instruction = ""
                startEntry()
            }
        }
    }

    /// Plays the entry cascade: the editor + context preview block fades in
    /// immediately (riding the panel's expand), then the send button zooms
    /// up from `PromptButtonZoom.hiddenScale` to its resting size at its own
    /// center once the surface has nearly settled — so the two movements
    /// read as a deliberate cascade rather than overlapping. Under Reduce
    /// Motion both appear instantly.
    private func startEntry() {
        contentFadeTask?.cancel()
        contentFadeTask = nil
        cascadeTask?.cancel()
        guard !reduceMotion else {
            contentVisible = true
            sendButtonAppeared = true
            return
        }
        withAnimation(.spring(response: 0.38, dampingFraction: 0.74)) {
            contentVisible = true
        }
        let task = Task {
            // Wait for the expand spring (the horizontal spring in
            // `NotchWidgetView` — `.spring(response: 0.38, dampingFraction:
            // 0.74)`, or the calmer reduce-motion `.spring(response: 0.32,
            // dampingFraction: 0.86)`) to nearly settle before the button
            // begins its zoom-in. The vertical spring is critically damped
            // (dampingFraction 1.0) so it settles without overshoot; the
            // horizontal spring is bouncy and settles slightly later.
            try? await Task.sleep(
                nanoseconds: PromptContentMetrics.sendButtonCascadeDelayNs
            )
            if Task.isCancelled { return }
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                sendButtonAppeared = true
            }
        }
        cascadeTask = task
    }

    /// Plays the exit — the reverse of the entry cascade: the send button
    /// zooms back down to `PromptButtonZoom.hiddenScale` and fades out
    /// immediately, and the editor + context preview block follows a beat
    /// behind (`sendButtonContentFadeDelay`) fading out. Both stay mounted
    /// and move only via render-time `.opacity`/`.scaleEffect`, so neither
    /// drifts with the panel's leading-offset slide. The parent keeps the
    /// panel open for `contentExitDuration` so this whole sequence plays in
    /// place before the panel collapses.
    private func startExit() {
        cascadeTask?.cancel()
        cascadeTask = nil
        contentFadeTask?.cancel()
        guard !reduceMotion else {
            sendButtonAppeared = false
            contentVisible = false
            return
        }
        // The send button leads the dismissal: shrink + fade in place now.
        // A fixed-duration easeOut (not a spring) so it is deterministically
        // at opacity 0 before the parent collapses the panel — a spring would
        // still be settling when the panel slide begins, letting a faint
        // button ride the leading-offset drift.
        withAnimation(.easeOut(duration: 0.2)) {
            sendButtonAppeared = false
        }
        // The editor + context block follows a beat behind but overlaps the
        // button's zoom-out heavily (the reverse of the entry cascade, where
        // the content fades in first and the button zooms in just behind).
        // The two run nearly together so the dismissal reads as one snappy
        // movement instead of a slow sequence, and both finish inside the
        // parent's `contentExitDuration` window before the panel collapses.
        let fade = Task {
            try? await Task.sleep(
                nanoseconds: PromptContentMetrics.sendButtonContentFadeDelayNs
            )
            if Task.isCancelled { return }
            withAnimation(.easeOut(duration: 0.16)) {
                contentVisible = false
            }
        }
        contentFadeTask = fade
    }


    /// Top padding for the content VStack. Tighter when a selected-text chip
    /// is shown (chip sits closer to the header); standard otherwise.
    private var effectiveTopPadding: CGFloat {
        if case .selectedText = draft?.context {
            return PromptContentMetrics.chipTopPadding
        }
        return PromptContentMetrics.topPadding
    }

    /// Clamps the editor's measured intrinsic height to `[44, max]` and only
    /// propagates changes when the value meaningfully shifts (avoiding
    /// sub-pixel layout loops). 44pt matches the original single-prompt
    /// minimum; the upper bound prevents the bubble from outgrowing the
    /// screen. Both the editor's frame and the panel's height animate
    /// together inside a single `withAnimation` so they stay in sync.
    ///
    /// Uses `.smooth` — a non-overshooting animation. A spring with damping <
    /// 1 would briefly grow past the target, clipping against the panel's
    /// frame (which resizes instantly via `setFrame`) and causing a visible
    /// bounce at the notch's top edge where it is glued to the screen.
    private func handleEditorHeightChange(_ measuredHeight: CGFloat) {
        let clamped = max(
            PromptContentMetrics.minEditorHeight,
            min(measuredHeight, PromptSurfaceLayout.maxTextEditorHeight)
        )
        guard abs(clamped - editorHeight) > 0.5 else { return }
        withAnimation(.smooth(duration: 0.22)) {
            editorHeight = clamped
            onTextEditorHeightChange(clamped)
        }
    }
}

/// Visual constants for the prompt's inner content. The overall surface
/// dimensions (width, height, corner radius) live in `PromptSurfaceLayout`;
/// these are the fine-grained spacing values the content view owns.
enum PromptContentMetrics {
    static let sidePadding: CGFloat = 20
    /// Top padding matches the side padding so the text cursor sits at an
    /// equal distance from the header as from the left/right edges.
    static let topPadding: CGFloat = 20
    /// Tighter top padding when a selected-text context chip is shown, so the
    /// chip sits closer to the header instead of floating with a large gap
    /// above it. The space removed here is added below the chip via
    /// `chipBottomGap` so the editor cursor clears the chip.
    static let chipTopPadding: CGFloat = 12
    /// Extra gap below the selected-text chip (outside its background) before
    /// the VStack's inner spacing, so the editor cursor sits a little below
    /// the chip rather than directly under it. Rebalances the `chipTopPadding`
    /// reduction: what's removed from above the chip is added below it.
    static let chipBottomGap: CGFloat = 8
    static let bottomPadding: CGFloat = 20
    static let innerSpacing: CGFloat = 10
    /// Minimum height of the text editor — sized to roughly one line of text
    /// (15pt system font) plus a small buffer, so the prompt doesn't show
    /// two empty lines of height before the user starts typing.
    static let minEditorHeight: CGFloat = 28
    /// How long the send button waits before its zoom-in cascade, in
    /// nanoseconds (for `Task.sleep`). Tuned to the horizontal expand spring
    /// in `NotchWidgetView` (`NotchExpandSpringSpec.horizontal` —
    /// `.spring(response: 0.38, dampingFraction: 0.74)`, or the calmer
    /// `NotchExpandSpringSpec.reduceMotion` under Reduce Motion): the button
    /// begins scaling in as the surface is almost settled and finishes just
    /// after, so the two movements read as a cascade. The bouncier horizontal
    /// spring overshoots later than the calm reduce-motion one, so the delay
    /// is nudged up to keep the handoff from landing on the overshoot.
    static let sendButtonCascadeDelayNs: UInt64 = 280_000_000
    /// How long the send button waits after the exit begins before the
    /// editor + context block starts to fade. Kept small so the content
    /// overlaps the button's zoom-out heavily — the dismissal reads as one
    /// snappy movement rather than a slow sequence — while the button still
    /// leads perceptibly. Both finish inside `contentExitDuration`.
    static let sendButtonContentFadeDelayNs: UInt64 = 40_000_000
    /// How long the parent keeps the panel fully open after the exit
    /// begins, so the content exit (button zoom-out, then content fade)
    /// plays in place before the panel collapses. Sized so both the button's
    /// 0.2 s easeOut and the content's 0.16 s easeOut (starting 40 ms later)
    /// are at opacity 0 by the time `isExpanded` flips false, so the
    /// collapse is invisible. The button's zoom endpoints live in
    /// `PromptButtonZoom` (PetaloCore) so the entry/exit symmetry is
    /// guarded by a behavioral test.
    static let contentExitDuration: TimeInterval = 0.22
}

// MARK: - Selected-text preview chip

/// A small container shown above the editor when the prompt carries a
/// selected-text draft. It previews one or two lines of the pasted selection
/// with a clipboard glyph and a trailing ellipsis, so the user can see — and
/// reference — the added context before sending. This mirrors how an image
/// draft shows its capture above the editor.
///
/// The raw selection is normalized by `SelectedTextPreview.snippet(from:)`
/// (collapses whitespace/newlines into single spaces) so the chip never shows
/// ragged line breaks. SwiftUI's `lineLimit(2)` + `.truncationMode(.tail)`
/// adds the visible ellipsis; the chip's intrinsic height (one or two lines
/// plus padding) fits within the space reserved by
/// `PromptSurfaceLayout.selectedTextContentHeight`, and the content VStack's
/// trailing `Spacer` absorbs any slack for short selections.
private struct SelectedTextPreviewChip: View {
    let text: String

    var body: some View {
        // `HStack` defaults to vertical `.center` alignment, so the clipboard
        // glyph centers against a one- or two-line snippet instead of sitting
        // at the top edge.
        HStack(spacing: 8) {
            Image(systemName: "doc.on.clipboard.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
                .frame(width: 16, height: 16)
            Text(SelectedTextPreview.snippet(from: text))
                .font(.system(size: 13, design: .rounded))
                .foregroundStyle(.white.opacity(0.72))
                .lineLimit(2)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            .white.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Selected text context")
        .accessibilityValue(SelectedTextPreview.snippet(from: text))
    }
}

// MARK: - Text editor

struct PromptTextEditor: NSViewRepresentable {
    @Binding var text: String
    let onSubmit: () -> Void
    let onCancel: () -> Void
    /// Receives the editor's measured intrinsic content height whenever the
    /// text changes or the view first lays out.
    let onHeightChange: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onHeightChange: onHeightChange)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = PromptNSTextView()
        context.coordinator.textView = textView
        textView.delegate = context.coordinator
        textView.drawsBackground = false
        textView.textColor = .white
        textView.insertionPointColor = .white
        textView.font = .systemFont(ofSize: 15)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.textContainerInset = NSSize(width: 0, height: 0)
        textView.textContainer?.lineFragmentPadding = 0
        // Allow vertical resizing so the text view grows with its content.
        // When the content exceeds the scroll view's (capped) height the text
        // view keeps growing and the scroll view clips and scrolls it — so the
        // text never walks off the bottom.
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        // The text container width tracks the text view (which tracks the
        // scroll view's visible width) so wrapping matches the visible width.
        // The height is unlimited so `usedRect` reports the true content height.
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.textContainer?.size = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.onSubmit = onSubmit
        textView.onCancel = onCancel

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        // Prevent the clip view from adding automatic content insets that
        // would shift the text and create a small visible offset.
        scrollView.contentView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)

        DispatchQueue.main.async {
            textView.window?.makeFirstResponder(textView)
            context.coordinator.reportHeight()
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }
        if textView.string != text {
            textView.string = text
        }
        textView.onSubmit = onSubmit
        textView.onCancel = onCancel
        context.coordinator.onHeightChange = onHeightChange
        // Re-measure after programmatic text changes (e.g. binding updates
        // from outside the editor) so the frame stays in sync.
        DispatchQueue.main.async {
            context.coordinator.reportHeight()
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        private var text: Binding<String>
        var onHeightChange: (CGFloat) -> Void
        weak var textView: PromptNSTextView?

        init(text: Binding<String>, onHeightChange: @escaping (CGFloat) -> Void) {
            self.text = text
            self.onHeightChange = onHeightChange
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? PromptNSTextView else { return }
            text.wrappedValue = textView.string
            reportHeight()
        }

        /// Measures the editor's intrinsic content height, resizes the text
        /// view's frame to match it (so the text view can exceed the scroll
        /// view's capped height and scroll), and forwards the height so the
        /// parent can grow the frame and the panel.
        func reportHeight() {
            guard let textView else { return }
            let height = textView.measuredContentHeight
            // Set the text view's frame height to the actual content height
            // (uncapped). The scroll view's height is capped by SwiftUI's
            // `.frame(height: editorHeight)`, so when the content exceeds
            // that cap the text view is taller than the scroll view and the
            // scroll view clips and scrolls — the text never walks off.
            var size = textView.frame.size
            if abs(size.height - height) > 0.5 {
                size.height = height
                textView.setFrameSize(size)
            }
            onHeightChange(height)
        }
    }
}

final class PromptNSTextView: NSTextView {
    var onSubmit: (() -> Void)?
    var onCancel: (() -> Void)?

    /// The editor's intrinsic content height — the height needed to display
    /// all the text without scrolling. Computed from the layout manager's
    /// `usedRect`, which wraps to the text container's width (tracked to the
    /// view's bounds) with unlimited height, so it reflects the true number of
    /// lines regardless of the view's current frame.
    var measuredContentHeight: CGFloat {
        guard let layoutManager, let textContainer else { return 0 }
        layoutManager.ensureLayout(for: textContainer)
        let height = layoutManager.usedRect(for: textContainer).height
        let lineHeight = font?.boundingRectForFont.height ?? 0
        // `usedRect` can miss the last line's full descent by a fraction of a
        // point, which the text view renders as a clipped bottom edge. Rounding
        // up to the next whole point and adding a small buffer ensures every
        // line — including the descent of the last one — is fully visible.
        return max(ceil(height) + 3, lineHeight)
    }

    /// Requests first-responder status once the view is placed in a window.
    /// Combined with the panel being made key on expand (see
    /// `PromptKeyPolicy`), this ensures the cursor is blinking and ready to
    /// type the moment the surface opens — whether by click, hover, or
    /// shortcut. The async hop lets the window finish its key-state
    /// transition before we claim focus.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            window.makeFirstResponder(self)
        }
    }

    override func doCommand(by selector: Selector) {
        if selector == #selector(NSResponder.insertNewline(_:)) {
            if NSEvent.modifierFlags.contains(.shift) {
                super.doCommand(by: selector)
            } else {
                onSubmit?()
            }
            return
        }
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            onCancel?()
            return
        }
        super.doCommand(by: selector)
    }
}

// MARK: - Liquid glass preview overlay

/// Subtle Liquid Glass treatment for the screenshot preview: a bright edge
/// highlight that catches light at the glass border, a faint inner shadow
/// that gives the rounded edges glass depth, and a soft drop shadow so the
/// preview reads as a piece of glass floating over the notch's own glass
/// surface. No blur — the user needs to see what they captured. Kept
/// intentionally light so it does not compete with the notch's own glass.
struct LiquidGlassPreviewOverlay: ViewModifier {
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            // Soft drop shadow so the preview floats above the notch glass.
            .shadow(color: .black.opacity(0.28), radius: 6, x: 0, y: 3)
            .overlay {
                // Glass edge highlight: a thin gradient stroke (brighter at
                // top, dimmer at bottom) that mimics light catching the rim
                // of a glass panel.
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(
                        LinearGradient(
                            stops: [
                                .init(color: .white.opacity(0.35), location: 0),
                                .init(color: .white.opacity(0.12), location: 0.5),
                                .init(color: .white.opacity(0.22), location: 1),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
            }
            .overlay {
                // Inner shadow at the edges: a slightly inset, blurred dark
                // stroke masked to a thin border ring gives the rounded
                // edges a subtle concave depth — the "glass thickness" read.
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(.black.opacity(0.18), lineWidth: 2)
                    .blur(radius: 1.5)
                    .mask(
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .stroke(lineWidth: 3)
                    )
            }
            .overlay {
                // Faint specular wash at the top: a soft white gradient that
                // fades to transparent within the first ~40% of the height,
                // mimicking the way light grazes the top of a glass surface.
                GeometryReader { geo in
                    let height = geo.size.height
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(
                            LinearGradient(
                                stops: [
                                    .init(color: .white.opacity(0.10), location: 0),
                                    .init(color: .white.opacity(0.03), location: 0.3),
                                    .init(color: .clear, location: 0.5),
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(width: geo.size.width, height: height)
                        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                }
                .allowsHitTesting(false)
            }
    }
}
