import CoreGraphics

/// Visual metrics shared by rendering and hit testing. Every display uses the
/// same compact-notch profile; expansion preserves those curves and inserts a
/// straight side between them instead of stretching them into an S shape.
public enum HangingNotchMetrics {
    public static let topShoulderRadius: CGFloat = 14
    public static let bottomCornerRadius: CGFloat = 20
}

/// How the silhouette meets the top of its rectangle. A hardware notch reads
/// as part of the screen edge, so its top corners flare outward into concave
/// shoulders; a notchless display carries a detached floating surface whose
/// top corners round inward like any other bubble.
public enum HangingNotchCornerStyle: Equatable, Sendable {
    case hangingNotch
    case bubble
}

/// Shared path geometry for the top-attached notch/drop silhouette. The top
/// edge flares into the screen edge before curving inward to the body, which
/// creates the concave shoulders that a rounded rectangle cannot express.
public enum HangingNotchGeometry {
    public static func path(
        in rect: CGRect,
        style: HangingNotchCornerStyle = .hangingNotch,
        topShoulderRadius requestedTopRadius: CGFloat,
        bottomCornerRadius requestedBottomRadius: CGFloat
    ) -> CGPath {
        let path = CGMutablePath()
        guard rect.width.isFinite,
              rect.height.isFinite,
              rect.width > 0,
              rect.height > 0 else {
            return path
        }

        if style == .bubble {
            // The bubble rounds every corner with the notch profile's lower
            // radius; the shoulder radius plays no part because nothing
            // attaches to a screen edge. Short rectangles clamp the radius to
            // the half-height, so the collapsed bar comes out a true capsule
            // and grows into the rounded card through the expand spring.
            let radius = min(
                sanitizedRadius(requestedBottomRadius),
                rect.width / 2,
                rect.height / 2
            )
            path.addPath(CGPath(
                roundedRect: rect,
                cornerWidth: radius,
                cornerHeight: radius,
                transform: nil
            ))
            return path
        }

        let constrainedTopRadius = min(
            sanitizedRadius(requestedTopRadius),
            rect.width / 2
        )
        let constrainedBottomRadius = min(
            sanitizedRadius(requestedBottomRadius),
            max(0, (rect.width - 2 * constrainedTopRadius) / 2)
        )
        // Preserve the pre-refactor transition: when the surface is shorter
        // than both preferred radii, shrink them proportionally. The shoulder
        // and lower corner remain matching circular arcs instead of snapping
        // to the external-display capsule profile.
        let totalRadius = constrainedTopRadius + constrainedBottomRadius
        let scale = totalRadius > 0 ? min(1, rect.height / totalRadius) : 1
        let topRadius = constrainedTopRadius * scale
        let bottomRadius = constrainedBottomRadius * scale
        let leftBodyX = rect.minX + topRadius
        let rightBodyX = rect.maxX - topRadius
        let upperSideY = rect.minY + topRadius
        let lowerSideY = rect.maxY - bottomRadius
        let circleControlOffset: (CGFloat) -> CGFloat = { $0 * 0.552_284_75 }

        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        // The cubic control offset is the standard quarter-circle constant.
        // It leaves a clean vertical side between the shallow shoulder and
        // the generous lower corner at every expanded height.
        let topControl = circleControlOffset(topRadius)
        path.addCurve(
            to: CGPoint(x: leftBodyX, y: upperSideY),
            control1: CGPoint(x: rect.minX + topControl, y: rect.minY),
            control2: CGPoint(x: leftBodyX, y: upperSideY - topControl)
        )
        path.addLine(to: CGPoint(x: leftBodyX, y: lowerSideY))
        let bottomControl = circleControlOffset(bottomRadius)
        path.addCurve(
            to: CGPoint(x: leftBodyX + bottomRadius, y: rect.maxY),
            control1: CGPoint(x: leftBodyX, y: lowerSideY + bottomControl),
            control2: CGPoint(x: leftBodyX + bottomRadius - bottomControl, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rightBodyX - bottomRadius, y: rect.maxY))
        path.addCurve(
            to: CGPoint(x: rightBodyX, y: lowerSideY),
            control1: CGPoint(x: rightBodyX - bottomRadius + bottomControl, y: rect.maxY),
            control2: CGPoint(x: rightBodyX, y: lowerSideY + bottomControl)
        )
        path.addLine(to: CGPoint(x: rightBodyX, y: upperSideY))
        path.addCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control1: CGPoint(x: rightBodyX, y: upperSideY - topControl),
            control2: CGPoint(x: rect.maxX - topControl, y: rect.minY)
        )
        path.closeSubpath()
        return path
    }

    /// Silhouette with a damped jelly recoil on its bottom edge: the path is
    /// built in a rect whose height is shrunk by a one-sided, damped,
    /// two-bump envelope of `phase`, so the bottom edge pulls *upward* (into
    /// the bubble) and relaxes — never extending past the resting bounds, so
    /// it clips nowhere. At `phase` 0 and 1 the recoil is exactly zero, so the
    /// result equals `path(in:...)` and the resting silhouette is untouched.
    /// `amplitude` is the first crest's height in points; the second crest is
    /// roughly a third of that.
    ///
    /// This is a *render-only* deformation. Hit testing still uses the rigid
    /// `path`/`contains` above so the tappable silhouette never jiggles.
    public static func wobbledPath(
        in rect: CGRect,
        style: HangingNotchCornerStyle = .hangingNotch,
        topShoulderRadius: CGFloat,
        bottomCornerRadius: CGFloat,
        phase: CGFloat,
        amplitude: CGFloat
    ) -> CGPath {
        let recoil = wobbleRecoil(phase: phase, amplitude: amplitude)
        guard recoil > 0 else {
            return path(
                in: rect,
                style: style,
                topShoulderRadius: topShoulderRadius,
                bottomCornerRadius: bottomCornerRadius
            )
        }
        let wobbled = CGRect(
            x: rect.minX,
            y: rect.minY,
            width: rect.width,
            height: max(1, rect.height - recoil)
        )
        return path(
            in: wobbled,
            style: style,
            topShoulderRadius: topShoulderRadius,
            bottomCornerRadius: bottomCornerRadius
        )
    }

    /// One-sided (≥0), damped, two-bump envelope. Zero at the endpoints so the
    /// wobble starts and ends at the rigid silhouette. `amplitude` is scaled
    /// by the envelope normalized to its first crest, so `amplitude` reads as
    /// the first crest's height in points.
    private static func wobbleRecoil(phase: CGFloat, amplitude: CGFloat) -> CGFloat {
        guard amplitude > 0, phase > 0, phase < 1 else { return 0 }
        let window = sin(.pi * phase)                  // 0 → 1 → 0 over the run
        let oscillation = (1 - cos(4 * .pi * phase)) / 2  // crests at 0.25 and 0.75
        let decay = exp(-2.5 * phase)
        let envelope = window * oscillation * decay
        // envelope(0.25) ≈ 0.37748; normalize so the first crest ≈ amplitude.
        return amplitude * (envelope / 0.377_481)
    }

    public static func contains(
        _ point: DisplayPoint,
        width: CGFloat,
        height: CGFloat,
        style: HangingNotchCornerStyle = .hangingNotch,
        topShoulderRadius: CGFloat,
        bottomCornerRadius: CGFloat
    ) -> Bool {
        guard point.x.isFinite, point.y.isFinite else { return false }
        return path(
            in: CGRect(x: 0, y: 0, width: width, height: height),
            style: style,
            topShoulderRadius: topShoulderRadius,
            bottomCornerRadius: bottomCornerRadius
        ).contains(CGPoint(x: point.x, y: point.y))
    }

    private static func sanitizedRadius(_ radius: CGFloat) -> CGFloat {
        radius.isFinite ? max(0, radius) : 0
    }
}

/// Top-leading panel-local event region matching the rendered hanging notch.
/// AppKit and SwiftUI share this model so transparent shoulders and rounded
/// corner pockets pass clicks through instead of behaving like a rectangle.
public struct HangingNotchInteractionRegion: Equatable, Sendable {
    public static let empty = HangingNotchInteractionRegion(
        frame: DisplayFrame(minX: 0, minY: 0, width: 0, height: 0),
        topShoulderRadius: 0,
        bottomCornerRadius: 0
    )

    public let frame: DisplayFrame
    public let cornerStyle: HangingNotchCornerStyle
    public let topShoulderRadius: CGFloat
    public let bottomCornerRadius: CGFloat

    public init(
        frame: DisplayFrame,
        cornerStyle: HangingNotchCornerStyle = .hangingNotch,
        topShoulderRadius: CGFloat,
        bottomCornerRadius: CGFloat
    ) {
        self.frame = frame
        self.cornerStyle = cornerStyle
        self.topShoulderRadius = topShoulderRadius
        self.bottomCornerRadius = bottomCornerRadius
    }

    public func contains(_ panelLocalPoint: DisplayPoint) -> Bool {
        HangingNotchGeometry.contains(
            DisplayPoint(
                x: panelLocalPoint.x - frame.minX,
                y: panelLocalPoint.y - frame.minY
            ),
            width: frame.width,
            height: frame.height,
            style: cornerStyle,
            topShoulderRadius: topShoulderRadius,
            bottomCornerRadius: bottomCornerRadius
        )
    }
}
