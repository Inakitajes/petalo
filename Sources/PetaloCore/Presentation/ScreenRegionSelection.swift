import CoreGraphics
import Foundation

/// A rectangle expressed as fractions of its single source display. The Y
/// origin is AppKit display-space (bottom leading); a capture adapter converts
/// it to its API's source-coordinate convention at the final boundary.
public struct NormalizedScreenRegion: Equatable, Sendable {
    public let displayID: UInt32
    public let x: CGFloat
    public let y: CGFloat
    public let width: CGFloat
    public let height: CGFloat

    public init(displayID: UInt32, x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) {
        self.displayID = displayID
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    /// Normalizes untrusted values into the unit square and then trims the
    /// trailing edges to that square. A caller can use `hasArea` to reject a
    /// degenerate result without ever passing an out-of-display rectangle to a
    /// platform capture API.
    public func clampedToDisplay() -> NormalizedScreenRegion {
        let x = Self.clamp(x)
        let y = Self.clamp(y)
        return NormalizedScreenRegion(
            displayID: displayID,
            x: x,
            y: y,
            width: min(Self.clamp(width), 1 - x),
            height: min(Self.clamp(height), 1 - y)
        )
    }

    public var hasArea: Bool {
        x.isFinite && y.isFinite && width.isFinite && height.isFinite
            && x >= 0 && y >= 0 && width > 0 && height > 0
            && x + width <= 1 && y + height <= 1
    }

    private static func clamp(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }
}

/// Validates untrusted pointer geometry at the display boundary. A selection
/// must start inside the overlay's display, while its end point is clamped so
/// a drag cannot generate a cross-display capture rectangle.
public enum ScreenRegionSelection {
    public static func normalizedRectangle(
        start: DisplayPoint,
        end: DisplayPoint,
        on display: DisplaySnapshot
    ) -> NormalizedScreenRegion? {
        guard display.frame.minX.isFinite,
              display.frame.minY.isFinite,
              display.frame.width.isFinite,
              display.frame.height.isFinite,
              display.frame.width > 0,
              display.frame.height > 0,
              start.x.isFinite,
              start.y.isFinite,
              end.x.isFinite,
              end.y.isFinite,
              display.frame.contains(start) else {
            return nil
        }

        let maxX = display.frame.minX + display.frame.width
        let maxY = display.frame.minY + display.frame.height
        guard maxX.isFinite, maxY.isFinite else { return nil }
        let endX = min(max(end.x, display.frame.minX), maxX)
        let endY = min(max(end.y, display.frame.minY), maxY)
        let minimumX = min(start.x, endX)
        let maximumX = max(start.x, endX)
        let minimumY = min(start.y, endY)
        let maximumY = max(start.y, endY)
        guard maximumX > minimumX, maximumY > minimumY else { return nil }

        return NormalizedScreenRegion(
            displayID: display.id,
            x: (minimumX - display.frame.minX) / display.frame.width,
            y: (minimumY - display.frame.minY) / display.frame.height,
            width: (maximumX - minimumX) / display.frame.width,
            height: (maximumY - minimumY) / display.frame.height
        )
    }

    /// View-space rounded rectangle describing the live drag, with the corner
    /// radius clamped to half the shorter side so a tiny selection never
    /// carries an oversized radius. Returns nil for degenerate (zero-area) or
    /// non-finite drags, matching `normalizedRectangle`'s contract — the
    /// overlay uses the nil case to dismiss the glass lens without touching a
    /// shape API. This is pure geometry: it never reads display coordinates,
    /// so the overlay can call it with raw pointer/view points.
    public static func roundedSelectionRect(
        start: CGPoint,
        end: CGPoint,
        cornerRadius requestedCornerRadius: CGFloat
    ) -> RoundedSelectionRect? {
        guard start.x.isFinite, start.y.isFinite,
              end.x.isFinite, end.y.isFinite else { return nil }
        let minimumX = min(start.x, end.x)
        let minimumY = min(start.y, end.y)
        let maximumX = max(start.x, end.x)
        let maximumY = max(start.y, end.y)
        guard maximumX > minimumX, maximumY > minimumY else { return nil }
        let rect = CGRect(
            x: minimumX,
            y: minimumY,
            width: maximumX - minimumX,
            height: maximumY - minimumY
        )
        let clampedRadius = min(
            max(requestedCornerRadius, 0),
            rect.width / 2,
            rect.height / 2
        )
        return RoundedSelectionRect(rect: rect, cornerRadius: clampedRadius)
    }

    /// Scales a rounded selection about its own center, re-clamping the radius
    /// to half the shorter side of the result. Used by the release pulse so
    /// the glass lens, the dim cutout, the hairline and the ripple's clip all
    /// squash in lockstep — and, because the center is invariant, so the pulse
    /// can never drift the rendered rectangle off the region the user actually
    /// outlined. Degenerate or non-finite scales are a no-op rather than a
    /// collapsed rectangle.
    public static func scaled(
        _ rounded: RoundedSelectionRect,
        by scale: CGSize
    ) -> RoundedSelectionRect {
        guard scale.width.isFinite, scale.height.isFinite,
              scale.width > 0, scale.height > 0,
              rounded.rect.width > 0, rounded.rect.height > 0 else { return rounded }
        let width = rounded.rect.width * scale.width
        let height = rounded.rect.height * scale.height
        let rect = CGRect(
            x: rounded.rect.midX - width / 2,
            y: rounded.rect.midY - height / 2,
            width: width,
            height: height
        )
        let radius = min(
            max(rounded.cornerRadius * min(scale.width, scale.height), 0),
            width / 2,
            height / 2
        )
        return RoundedSelectionRect(rect: rect, cornerRadius: radius)
    }

    /// Mirrors a point from AppKit's bottom-left view space into the top-left
    /// space SwiftUI draws in — which is also the space a `layerEffect` shader
    /// receives its `position` in. The overlay tracks the drag bottom-left but
    /// hands the release location to the ripple shader, so it converts here.
    public static func flippedVertically(
        _ point: CGPoint,
        inHeight height: CGFloat
    ) -> CGPoint {
        guard height.isFinite, point.y.isFinite else { return point }
        return CGPoint(x: point.x, y: height - point.y)
    }
}

/// View-space rounded rectangle for the live drag selection. The overlay's
/// liquid-glass lens, its dim mask cutout, and its border stroke all read from
/// the same clamped values so the three stay in lockstep as the drag grows.
public struct RoundedSelectionRect: Equatable, Sendable {
    public let rect: CGRect
    public let cornerRadius: CGFloat

    public init(rect: CGRect, cornerRadius: CGFloat) {
        self.rect = rect
        self.cornerRadius = cornerRadius
    }
}

/// Inner + outer refraction tuning after proportional scaling. The lens view
/// rebuilds its glass filter with these values whenever the drag's quantized
/// ratio crosses a step.
public struct ScaledRefraction: Equatable, Sendable {
    public let innerAmount: Double
    public let innerHeight: Double
    public let outerAmount: Double
    public let outerHeight: Double

    public init(
        innerAmount: Double,
        innerHeight: Double,
        outerAmount: Double,
        outerHeight: Double
    ) {
        self.innerAmount = innerAmount
        self.innerHeight = innerHeight
        self.outerAmount = outerAmount
        self.outerHeight = outerHeight
    }

    public static let zero = ScaledRefraction(
        innerAmount: 0, innerHeight: 0, outerAmount: 0, outerHeight: 0
    )
}

/// Pure refraction scaling: a small lens refracts less than a large one, so
/// the drag's edge lensing diminishes with its size. The ratio is the
/// selection's smaller dimension over `referenceSize`, clamped to [0, 1] —
/// selections past the reference keep the maximum refraction, never more.
public enum GlassRefractionScale {
    public static func scale(
        minDimension: CGFloat,
        referenceSize: CGFloat,
        maxInnerAmount: Double,
        maxInnerHeight: Double,
        maxOuterAmount: Double,
        maxOuterHeight: Double
    ) -> ScaledRefraction {
        guard referenceSize > 0, minDimension > 0 else { return .zero }
        let ratio = min(Double(minDimension / referenceSize), 1.0)
        return ScaledRefraction(
            innerAmount: maxInnerAmount * ratio,
            innerHeight: maxInnerHeight * ratio,
            outerAmount: maxOuterAmount * ratio,
            outerHeight: maxOuterHeight * ratio
        )
    }
}
