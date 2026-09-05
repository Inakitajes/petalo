import SwiftUI

/// Petalo's brand mark: three slender petals fanning open from a shared base
/// point, mirroring the glyph inside `assets/icon.svg`. Each petal is a lens —
/// pointed at both ends — so the gaps between them survive as negative space
/// even when the whole mark is drawn as a single monochrome fill at 11pt.
///
/// The petals are laid out in a local canvas whose base sits at the origin and
/// whose tips point up, giving bounds of x ±118.2 by y −172…0. The path is then
/// scaled uniformly to fit `rect` and centered, so callers are free to pass any
/// frame without distorting the mark.
struct PetalMarkShape: Shape {
    /// Local-canvas bounds of the composed bloom, used to fit it into `rect`.
    private static let canvas = CGSize(width: 236.4, height: 172)

    func path(in rect: CGRect) -> Path {
        // A petal with its base at (0, 0) and tip at (0, -length). `width` is
        // the half-width at the petal's widest point.
        func petal(width: CGFloat, length: CGFloat) -> Path {
            var petal = Path()
            petal.move(to: CGPoint(x: 0, y: -length))
            petal.addCurve(
                to: .zero,
                control1: CGPoint(x: width * 0.68, y: -length * 0.8),
                control2: CGPoint(x: width, y: -length * 0.4)
            )
            petal.addCurve(
                to: CGPoint(x: 0, y: -length),
                control1: CGPoint(x: -width, y: -length * 0.4),
                control2: CGPoint(x: -width * 0.68, y: -length * 0.8)
            )
            petal.closeSubpath()
            return petal
        }

        let side = petal(width: 38, length: 150)
        let center = petal(width: 38, length: 172)

        // Fit the canvas into `rect` uniformly, then center the result.
        let scale = min(rect.width / Self.canvas.width, rect.height / Self.canvas.height)
        let size = CGSize(width: Self.canvas.width * scale, height: Self.canvas.height * scale)
        // The canvas origin is the bloom's base: horizontally centered, at the
        // bottom edge of the fitted box.
        let fit = CGAffineTransform(
            translationX: rect.midX,
            y: rect.midY + size.height / 2
        ).scaledBy(x: scale, y: scale)

        var path = Path()
        path.addPath(side, transform: CGAffineTransform(rotationAngle: -52 * .pi / 180).concatenating(fit))
        path.addPath(side, transform: CGAffineTransform(rotationAngle: 52 * .pi / 180).concatenating(fit))
        path.addPath(center, transform: fit)
        return path
    }
}
