import CoreGraphics
import Foundation

/// The release ripple's silhouette: the selection's rounded rectangle bent by
/// the *same* wave that `Ripple.metal` runs over the captured frame's pixels.
///
/// The shader alone cannot make the edge wobble. It is a `layerEffect`, so it
/// can only move pixels that exist; the overlay's border and its dim cutout are
/// separate AppKit geometry, and left rigid they pin the silhouette in place
/// while the interior sloshes — half the read of a water drop is the deforming
/// edge. This traces that edge explicitly, and deliberately from the shader's
/// own constants (`ReleaseRippleShader`) rather than from a second, rhyming
/// animation: the hairline, the scrim's hole and the frame's clip are all the
/// same wave, so the stroke can never drift off the pixels it outlines.
///
/// **Sign.** `layerEffect` is a *backward* map: the shader writes
/// `layer.sample(position + displacement · direction)`, which moves the content
/// by `−displacement · direction`. A boundary point therefore ends up at
/// `p − displacement(|p − o|) · direction`, and the outline uses that sign. Get
/// it backwards and the border bulges out on exactly the frames where the
/// pixels sink in.
public enum RippleOutline {
    /// The wave's amplitude for a selection of this size — the one number the
    /// silhouette, the shader's uniform and the hosting view's inflation all
    /// have to agree on. Derived from the rectangle rather than passed around,
    /// so they cannot drift apart.
    public static func amplitude(for rect: CGRect) -> CGFloat {
        guard rect.width.isFinite, rect.height.isFinite else { return 0 }
        return CGFloat(ReleaseRippleShader.amplitude(
            forMinDimension: Double(min(rect.width, rect.height))
        ))
    }

    /// How far outside its rectangle the outline can travel, so the hosting
    /// view can be inflated by exactly this much and give the bulge somewhere
    /// to be drawn. The amplitude bounds the displacement outright — a generous
    /// bound, since the sine is still near zero when the decay envelope peaks
    /// (the real excursion tops out around 76% of it), but the shader's
    /// `maxSampleOffset` reserves the same.
    public static func margin(for rect: CGRect) -> CGFloat { amplitude(for: rect) }

    /// The wave's propagation speed for a selection of this size — the one
    /// number the shader's `speed` uniform and the silhouette's internal
    /// `wave` call have to agree on. Scales with the diagonal so the
    /// wavefront crosses in the same fraction of the ripple on every
    /// selection; derived from the rectangle for the same reason `amplitude`
    /// is.
    public static func speed(for rect: CGRect) -> CGFloat {
        guard rect.width.isFinite, rect.height.isFinite else { return 0 }
        let diagonal = Double(hypot(rect.width, rect.height))
        return CGFloat(ReleaseRippleShader.speed(forDiagonal: diagonal))
    }

    /// Samples per quarter-circle corner. Fixed rather than proportional: the
    /// corner radius is small and constant, so 40 segments keeps the arc smooth
    /// on the largest selection and the smallest alike.
    private static let cornerSamples = 40
    /// Target spacing along the straight edges, in points, *before* the wave
    /// gets hold of it.
    ///
    /// Bending the outline also stretches it: neighbours end up as much as 2.2x
    /// this far apart, worst around the impact, where the taper and the radial
    /// direction both turn over quickly. 2 pt therefore buys ~4.3 pt chords at
    /// the worst moment of the worst frame, comfortably inside what reads as a
    /// curve. The factor is a property of the tuning — it grew with the
    /// amplitude and the spatial frequency, so it is worth re-measuring if
    /// either moves much.
    private static let edgeSpacing: CGFloat = 2
    /// Ceiling per edge, so a 5K-wide drag cannot turn one frame into thousands
    /// of points.
    private static let maxEdgeSamples = 512

    /// The visible outline of `rounded` at `phase`, as a closed polyline in
    /// whatever space the caller passes in — the field is radial, so this works
    /// unchanged in AppKit's bottom-left view space and in the top-left space
    /// SwiftUI (and the shader) draw in.
    ///
    /// Returns nil for degenerate or non-finite geometry, matching
    /// `ScreenRegionSelection`'s contract: the overlay uses the nil case to fall
    /// back to its rigid `CGPath` rather than stroking garbage. At `phase == 0`
    /// the result is the rounded rectangle itself, because the wave has not
    /// displaced anything yet.
    public static func deformedBoundary(
        _ rounded: RoundedSelectionRect,
        origin: CGPoint,
        phase: TimeInterval
    ) -> [CGPoint]? {
        let rect = rounded.rect
        guard phase.isFinite, phase >= 0,
              rect.origin.x.isFinite, rect.origin.y.isFinite,
              rect.width.isFinite, rect.height.isFinite,
              rect.width > 0, rect.height > 0,
              origin.x.isFinite, origin.y.isFinite else { return nil }
        let radius = min(max(rounded.cornerRadius, 0), rect.width / 2, rect.height / 2)
        let amplitude = Double(amplitude(for: rect))
        let speed = Double(speed(for: rect))
        return boundary(of: rect, radius: radius).map {
            displaced($0, origin: origin, phase: phase, amplitude: amplitude, speed: speed)
        }
    }

    /// A boundary sample: where it is, which way is out, and how tightly the
    /// outline curves there.
    private struct Sample {
        let point: CGPoint
        /// Outward unit normal. The wave pushes along this, never along the
        /// radius from the release — see the type's note on why.
        let normal: CGVector
        /// Radius of curvature, or nil on the straight runs. A convex arc can
        /// only be pushed inward by so much before it turns itself inside out.
        let curvature: CGFloat?
    }

    /// One boundary point moved by the wave, along its own outward normal.
    ///
    /// The magnitude still comes from the wave at that point's distance from
    /// the release, so the deformation is born at the cursor and travels
    /// outward — only the *direction* differs from the shader's.
    private static func displaced(
        _ sample: Sample,
        origin: CGPoint,
        phase: TimeInterval,
        amplitude: Double,
        speed: Double
    ) -> CGPoint {
        let distance = hypot(sample.point.x - origin.x, sample.point.y - origin.y)
        var amount = CGFloat(ReleaseRippleShader.wave(
            phase: phase,
            distance: Double(distance),
            amplitude: amplitude,
            speed: speed
        ))
        // A corner cannot be pushed inward past its own centre of curvature
        // without folding through itself. Straight runs have no such limit —
        // a graph over a line cannot self-intersect however hard it is bent.
        if let curvature = sample.curvature {
            amount = max(amount, -inwardCornerLimit * curvature)
        }
        return CGPoint(
            x: sample.point.x + amount * sample.normal.dx,
            y: sample.point.y + amount * sample.normal.dy
        )
    }

    /// How far into its own radius a corner may be pushed. Below 1 by a
    /// comfortable margin, so the arc stays convex rather than merely
    /// non-degenerate.
    private static let inwardCornerLimit: CGFloat = 0.7

    /// The undeformed rounded rectangle, sampled counter-clockwise from the
    /// start of the min-Y edge, each sample carrying its outward normal. Each
    /// of the eight runs emits its own start and leaves its end to the next
    /// one, so the polyline closes implicitly with no duplicated vertex.
    private static func boundary(of rect: CGRect, radius: CGFloat) -> [Sample] {
        var points: [Sample] = []
        points.reserveCapacity(4 * cornerSamples + 64)
        let insetWidth = rect.width - 2 * radius
        let insetHeight = rect.height - 2 * radius

        func addEdge(from start: CGPoint, to end: CGPoint, normal: CGVector) {
            let length = hypot(end.x - start.x, end.y - start.y)
            guard length > 0.001 else { return }
            let steps = min(max(Int(ceil(length / edgeSpacing)), 1), maxEdgeSamples)
            for step in 0..<steps {
                let t = CGFloat(step) / CGFloat(steps)
                points.append(Sample(
                    point: CGPoint(
                        x: start.x + (end.x - start.x) * t,
                        y: start.y + (end.y - start.y) * t
                    ),
                    normal: normal,
                    curvature: nil
                ))
            }
        }

        func addCorner(center: CGPoint, from startAngle: CGFloat) {
            guard radius > 0 else {
                points.append(Sample(
                    point: center,
                    normal: CGVector(dx: cos(startAngle), dy: sin(startAngle)),
                    curvature: nil
                ))
                return
            }
            for step in 0..<cornerSamples {
                let angle = startAngle + (.pi / 2) * CGFloat(step) / CGFloat(cornerSamples)
                // On an arc the outward normal *is* the radius from its centre.
                let normal = CGVector(dx: cos(angle), dy: sin(angle))
                points.append(Sample(
                    point: CGPoint(
                        x: center.x + radius * normal.dx,
                        y: center.y + radius * normal.dy
                    ),
                    normal: normal,
                    curvature: radius
                ))
            }
        }

        let left = rect.minX + radius
        let right = rect.maxX - radius
        let bottom = rect.minY + radius
        let top = rect.maxY - radius

        if insetWidth > 0.001 {
            addEdge(
                from: CGPoint(x: left, y: rect.minY),
                to: CGPoint(x: right, y: rect.minY),
                normal: CGVector(dx: 0, dy: -1)
            )
        }
        addCorner(center: CGPoint(x: right, y: bottom), from: -.pi / 2)
        if insetHeight > 0.001 {
            addEdge(
                from: CGPoint(x: rect.maxX, y: bottom),
                to: CGPoint(x: rect.maxX, y: top),
                normal: CGVector(dx: 1, dy: 0)
            )
        }
        addCorner(center: CGPoint(x: right, y: top), from: 0)
        if insetWidth > 0.001 {
            addEdge(
                from: CGPoint(x: right, y: rect.maxY),
                to: CGPoint(x: left, y: rect.maxY),
                normal: CGVector(dx: 0, dy: 1)
            )
        }
        addCorner(center: CGPoint(x: left, y: top), from: .pi / 2)
        if insetHeight > 0.001 {
            addEdge(
                from: CGPoint(x: rect.minX, y: top),
                to: CGPoint(x: rect.minX, y: bottom),
                normal: CGVector(dx: -1, dy: 0)
            )
        }
        addCorner(center: CGPoint(x: left, y: bottom), from: .pi)
        return points
    }
}
