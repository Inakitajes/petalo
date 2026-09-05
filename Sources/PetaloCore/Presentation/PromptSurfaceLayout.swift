import CoreGraphics
import Foundation

/// Geometry for the unified prompt surface. The notch/pill bar *becomes* the
/// prompt when expanded: on a notched display it stays attached to the top
/// edge with the hanging-notch silhouette; on an external display it floats
/// just below the menu bar as a rounded bubble matching the standalone prompt
/// panel's width and corner radius.
///
/// The panel always hangs from the top of the screen so the compact bar stays
/// in the menu bar / notch in both states — only the height grows to fit the
/// prompt content. The prompt header (title + button) occupies the bar area
/// itself (the notch safe area or the pill bar), so that top-edge space is not
/// wasted. The content (editor + send) drops straight below the header.
public struct PromptSurfaceLayout: Equatable, Sendable {
    public enum ContentMode: Equatable, Sendable {
        case text
        case image
        case selectedText
    }

    public let presentation: NotchLayout.Presentation
    /// Width of the prompt content (the visible bubble), clamped to the panel.
    public let contentWidth: CGFloat
    /// Distance from the panel's top edge to where the prompt content begins.
    /// This is the bottom of the bar area (topGap + barHeight), so the header
    /// occupies the bar and the content drops straight below it with no extra
    /// gap.
    public let contentTopOffset: CGFloat
    /// Total panel height: the content offset plus the content plus bottom
    /// padding. The panel is positioned so its top is at the screen's top
    /// edge and it hangs downward by this height. This is the **effective**
    /// height — it includes any dynamic growth from the text editor's
    /// measured intrinsic height (see `withTextEditorHeight`).
    public let panelHeight: CGFloat
    /// The fixed panel height without any dynamic text-editor growth. Used as
    /// the origin for `withTextEditorHeight` so the adjustment always
    /// recomputes from the same base — never accumulating across repeated
    /// calls or stale after the editor shrinks back.
    public let basePanelHeight: CGFloat
    /// Breathing room below the content before the rounded bottom edge. The
    /// notch uses a tighter padding since it is attached to the top; the pill
    /// uses a bit more since it floats.
    public let bottomPadding: CGFloat
    /// Bottom corner radius: the notch's standard radius (attached) or the
    /// bubble's 38pt (external), matching the standalone prompt's profile.
    public let bottomCornerRadius: CGFloat
    /// Bottom corner radius for the expanded state. The notch adopts a larger,
    /// softer radius when expanded so the open card reads as a natural bubble
    /// hanging from the screen edge — matching the external pill — while the
    /// compact bar keeps the tight `bottomCornerRadius` so the collapsed
    /// silhouette still hugs the hardware cutout. The pill is already a bubble
    /// in both states, so its expanded radius matches its collapsed radius.
    public let expandedBottomCornerRadius: CGFloat
    /// Concave top shoulder radius for the expanded state. The notch's
    /// shoulders grow to match the expanded bottom radius so the open card's
    /// curves are symmetric — a natural bubble profile edge to edge. The
    /// compact bar keeps the tight `HangingNotchMetrics.topShoulderRadius` so
    /// the collapsed silhouette still hugs the hardware cutout. The pill is a
    /// detached bubble with no concave shoulders, so its value is zero (the
    /// bubble path ignores it entirely).
    public let expandedTopShoulderRadius: CGFloat

    public var cornerStyle: HangingNotchCornerStyle {
        presentation == .pill ? .bubble : .hangingNotch
    }

    // MARK: - Metrics

    /// Width of the prompt bubble, matching the standalone prompt panel.
    public static let bubbleWidth: CGFloat = 480
    /// Total height of the text prompt content (editor + send + padding).
    /// The title row lives in the header; the top padding matches the side
    /// padding (20pt) so the text cursor is equidistant from all edges.
    /// Tuned to the intrinsic content height so the Spacer between the editor
    /// and the send button is exactly 0 — the button sits right below the
    /// text with only the VStack spacing.
    public static let textContentHeight: CGFloat = 122
    /// Total height with a captured-image preview. Adds the image height
    /// (~92pt) plus spacing to the text content height.
    public static let imageContentHeight: CGFloat = 224
    /// Total height with a selected-text preview chip. Keeps the header as
    /// "Ask ChatGPT" and moves the context into a small chip below it
    /// (analogous to the image preview). Adds the chip height (~60pt) plus
    /// spacing to the text content height, so the surface is taller than the
    /// no-context text surface and shorter than the image surface.
    public static let selectedTextContentHeight: CGFloat = 192
    /// Breathing room below the content before the rounded bottom edge.
    public static let pillBottomPadding: CGFloat = 8
    /// Tighter bottom padding for the attached notch presentation.
    public static let notchBottomPadding: CGFloat = 4
    /// Corner radius for the external-display bubble, matching the standalone
    /// prompt's `cornerRadius` so the pill prompt reads identically to the old
    /// floating bubble.
    public static let bubbleBottomCornerRadius: CGFloat = 38
    /// Bottom corner radius the notch adopts once expanded, giving the open
    /// card a natural bubble profile that matches the external pill. The
    /// compact bar keeps `HangingNotchMetrics.bottomCornerRadius` so the
    /// collapsed silhouette still reads as the hardware notch.
    public static let expandedNotchBottomCornerRadius: CGFloat = 38
    /// Concave top shoulder radius the notch adopts once expanded, matching
    /// the expanded bottom radius so the open card's curves are symmetric.
    /// The compact bar keeps `HangingNotchMetrics.topShoulderRadius`.
    public static let expandedNotchTopShoulderRadius: CGFloat = 38

    /// The text editor's height in the base (fixed) layout. The panel grows
    /// only when the editor's measured intrinsic height exceeds this value;
    /// below it the internal spacer absorbs the slack so the bubble keeps its
    /// compact profile for short prompts. Set to the same value as the
    /// editor's minimum frame height so the panel starts growing as soon as
    /// the text wraps past two lines — keeping the send-button spacing
    /// constant rather than shrinking it as the editor grows.
    public static let baseTextEditorHeight: CGFloat = 28
    /// Upper bound on the text editor's intrinsic height so the panel never
    /// grows unbounded. At a 15pt system font this fits roughly 15 lines.
    public static let maxTextEditorHeight: CGFloat = 300

    // MARK: - Factory

    /// Derives the prompt surface geometry from the active `NotchLayout`.
    ///
    /// - Parameters:
    ///   - presentation: The notch vs pill decision (from `NotchLayout`).
    ///   - barHeight: `NotchLayout.height` — the compact bar's height
    ///     (safe-area height on a notched display; the menu-bar interior bar
    ///     height on an external display).
    ///   - panelWidth: `NotchLayout.width` — the panel's full width; the
    ///     prompt content is centered within it and clamped to `bubbleWidth`.
    ///   - contentMode: `.text` or `.image` (image is taller).
    public static func layout(
        presentation: NotchLayout.Presentation,
        barHeight: CGFloat,
        panelWidth: CGFloat,
        topGap: CGFloat,
        contentMode: ContentMode
    ) -> PromptSurfaceLayout {
        let contentHeight: CGFloat = {
            switch contentMode {
            case .image: Self.imageContentHeight
            case .selectedText: Self.selectedTextContentHeight
            case .text: Self.textContentHeight
            }
        }()
        let contentWidth = min(bubbleWidth, max(1, panelWidth))

        // The header occupies the bar area. On a notched display the bar is
        // the safe-area height (32pt), so the header already has room. On an
        // external display the pill bar is only ~16pt and sits 4pt from the
        // top — too cramped for the header text. The pill's expanded top gap
        // adds breathing room above the header so "Ask ChatGPT" and the gear
        // button are not glued to the screen's top edge.
        let expandedTopGap: CGFloat = presentation == .pill
            ? NotchLayout.pillExpandedTopGap
            : 0

        let contentTopOffset = topGap + expandedTopGap + barHeight

        let bottomPadding: CGFloat = presentation == .notch
            ? Self.notchBottomPadding
            : Self.pillBottomPadding

        let panelHeight = contentTopOffset + contentHeight + bottomPadding
        let bottomCornerRadius: CGFloat = presentation == .pill
            ? bubbleBottomCornerRadius
            : HangingNotchMetrics.bottomCornerRadius
        // The notch opens into a natural bubble: the expanded radius matches
        // the external pill, while the compact bar keeps the tight notch radius.
        // The pill is already a bubble, so both values are the same.
        let expandedBottomCornerRadius: CGFloat = presentation == .pill
            ? bubbleBottomCornerRadius
            : Self.expandedNotchBottomCornerRadius
        // The notch's concave shoulders grow to match the expanded bottom
        // radius for a symmetric bubble profile. The pill has no concave
        // shoulders (the bubble path ignores it), so it stays zero.
        let expandedTopShoulderRadius: CGFloat = presentation == .pill
            ? 0
            : Self.expandedNotchTopShoulderRadius

        return PromptSurfaceLayout(
            presentation: presentation,
            contentWidth: contentWidth,
            contentTopOffset: contentTopOffset,
            panelHeight: panelHeight,
            basePanelHeight: panelHeight,
            bottomPadding: bottomPadding,
            bottomCornerRadius: bottomCornerRadius,
            expandedBottomCornerRadius: expandedBottomCornerRadius,
            expandedTopShoulderRadius: expandedTopShoulderRadius
        )
    }

    /// Returns a copy with `panelHeight` adjusted so the bubble grows (or
    /// shrinks back) to fit the text editor's measured intrinsic height.
    ///
    /// The adjustment is always recomputed from `basePanelHeight`, never from
    /// the current `panelHeight`, so repeated calls don't accumulate and
    /// deleting text returns the panel to its compact base. When the measured
    /// height is at or below `baseTextEditorHeight` the panel stays at base —
    /// the internal spacer absorbs the slack. When it exceeds the base the
    /// panel grows by the delta, capped at `maxTextEditorHeight`.
    public func withTextEditorHeight(_ measuredHeight: CGFloat) -> PromptSurfaceLayout {
        let capped = min(measuredHeight, Self.maxTextEditorHeight)
        let extra = max(0, capped - Self.baseTextEditorHeight)
        return PromptSurfaceLayout(
            presentation: presentation,
            contentWidth: contentWidth,
            contentTopOffset: contentTopOffset,
            panelHeight: basePanelHeight + extra,
            basePanelHeight: basePanelHeight,
            bottomPadding: bottomPadding,
            bottomCornerRadius: bottomCornerRadius,
            expandedBottomCornerRadius: expandedBottomCornerRadius,
            expandedTopShoulderRadius: expandedTopShoulderRadius
        )
    }
}
