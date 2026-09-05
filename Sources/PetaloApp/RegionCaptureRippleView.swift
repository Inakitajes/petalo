import AppKit
import CoreGraphics
import SwiftUI

import PetaloCore

/// The frame the region capture just produced, with the release ripple running
/// over it — the *same* `expansionRipple` shader the notch expansion uses.
///
/// This is the one piece of the overlay that has to be SwiftUI, because
/// `layerEffect` exists nowhere else. It is deliberately scoped as tightly as
/// possible: it covers only the selection rectangle, and it is installed only
/// **after** the mouse has been released. An earlier attempt hosted the whole
/// dimming scrim in SwiftUI for the duration of the drag, and the full-screen
/// `NSHostingView` swallowed the `mouseDown` that starts the drag — the click
/// never reached the overlay at all. Nothing SwiftUI-hosted may exist while the
/// overlay is still taking mouse input.
///
/// The image fills the *inner* rectangle: this view is inflated by
/// `RippleOutline.margin` on every side so the wave has somewhere to push the
/// edge into. Without that margin the view's own bounds clip the silhouette
/// back to a rigid rectangle and the border can only ever be eaten inward,
/// which is exactly the half of the effect that was missing. Only the shader's
/// origin needs converting, since `layerEffect` reads `position` top-left while
/// the overlay tracks the drag bottom-left.
struct RegionCaptureRipple: View {
    let capture: CGImage
    /// Size of the selection itself, without the margin. How hard the wave
    /// throws the surface is proportional to this, so the margin, the clip and
    /// the shader's uniform are all derived from it rather than from a constant
    /// that could disagree with the rectangle actually on screen.
    let contentSize: CGSize
    let cornerRadius: CGFloat
    /// Release location in this view's own top-left space — including the
    /// margin, so it is offset from the image's own corner.
    let rippleOrigin: CGPoint
    let elapsed: TimeInterval
    /// Dissolves with the overlay's dim so the frozen frame is gone — not
    /// yanked — when the panel is ordered out.
    let opacity: Double

    private var contentRect: CGRect { CGRect(origin: .zero, size: contentSize) }

    var body: some View {
        let margin = RippleOutline.margin(for: contentRect)
        let amplitude = Double(RippleOutline.amplitude(for: contentRect))
        let speed = Double(RippleOutline.speed(for: contentRect))
        Image(decorative: capture, scale: 1)
            .resizable()
            .interpolation(.high)
            .padding(margin)
            // Shader first, clip second. The shader drags pixels out into the
            // margin; the clip then admits them exactly as far as the same wave
            // says the edge has travelled. Clipping first (as this did before
            // the border wobbled) pins the silhouette to a rigid rounded rect
            // and throws that displacement away.
            .modifier(RegionReleaseRippleModifier(
                elapsedTime: elapsed,
                origin: rippleOrigin,
                amplitude: amplitude,
                speed: speed
            ))
            .clipShape(RippledSelectionShape(
                margin: margin,
                cornerRadius: cornerRadius,
                rippleOrigin: rippleOrigin,
                elapsed: elapsed
            ))
            .opacity(opacity)
            .allowsHitTesting(false)
    }
}

/// The captured frame's silhouette under the release wave — `RippleOutline`
/// turned into a `Path`.
///
/// It is the same closed polyline the overlay strokes as its hairline and
/// punches out of its dimming scrim, so the three cannot disagree: one wave,
/// one outline, three surfaces reading from it.
///
/// Takes the margin off the rect SwiftUI hands it rather than being told the
/// content rect, so the inset can only ever be the padding applied above it.
struct RippledSelectionShape: Shape {
    var margin: CGFloat
    var cornerRadius: CGFloat
    var rippleOrigin: CGPoint
    var elapsed: TimeInterval

    func path(in rect: CGRect) -> Path {
        let content = rect.insetBy(dx: margin, dy: margin)
        guard content.width > 0, content.height > 0 else { return Path(rect) }
        guard let points = RippleOutline.deformedBoundary(
            RoundedSelectionRect(rect: content, cornerRadius: cornerRadius),
            origin: rippleOrigin,
            phase: elapsed
        ), points.count > 2 else {
            return Path(roundedRect: content, cornerRadius: cornerRadius, style: .circular)
        }
        var path = Path()
        path.addLines(points)
        path.closeSubpath()
        return path
    }
}

/// Hosts `RegionCaptureRipple` inside the AppKit overlay.
///
/// Refuses hit testing outright. By the time this view exists the drag is over,
/// so this is belt-and-braces rather than load-bearing — but the bug it guards
/// against (a hosted view quietly eating the overlay's mouse events) cost a
/// working screenshot flow once already.
final class RegionCaptureRippleHostingView: NSHostingView<RegionCaptureRipple> {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
