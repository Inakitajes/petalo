import Foundation

/// Spring specifications for the notch expand/collapse transition. The frame
/// spring is critically damped (dampingFraction >= 1.0) so the height **never
/// overshoots** — during collapse the virtual notch must not dip below the
/// physical hardware cutout, or the hardware notch becomes visible through the
/// transparent overlay (the "se ve el Notch" glitch). The horizontal "rebote"
/// the user feels does NOT come from the frame spring — it comes from the
/// `JellySquashEffect` scaleEffect (a horizontal-only layer transform) layered
/// on top, which fires on both expand and collapse. This separation is what
/// allows the bounce to be horizontal-only: the frame never overshoots on any
/// axis, and the scaleEffect only scales `dx` (never `dy`).
///
/// The reduce-motion spec keeps a single near-critically-damped spring
/// (minimal overshoot, honoring the accessibility preference); the squash
/// trigger never increments under Reduce Motion either.
public enum NotchExpandSpringSpec {
    /// Bouncy reference spring (dampingFraction < 1.0) — used by the
    /// `JellySquashEffect`'s amplitude tuning, not by the frame spring. The
    /// horizontal overshoot is safe because there is wing margin on both
    /// sides, and it is a layer transform (scaleEffect), not a frame change.
    public static let horizontal = SpringSpec(response: 0.38, dampingFraction: 0.74)

    /// Frame spring: critically damped, never overshoots. Used for both the
    /// width and the height of the expand/collapse frame. During collapse the
    /// virtual notch must not dip below the physical hardware cutout — the
    /// overlay is transparent, so the hardware notch would show through. The
    /// horizontal bounce comes from the `JellySquashEffect` scaleEffect, not
    /// from this spring.
    public static let vertical = SpringSpec(response: 0.38, dampingFraction: 1.0)

    /// Reduce-motion spring: near-critically-damped, minimal overshoot.
    /// Honors the accessibility preference. Used for the frame spring under
    /// Reduce Motion; the squash trigger never increments then.
    public static let reduceMotion = SpringSpec(response: 0.32, dampingFraction: 0.86)
}

/// Pure spring specification (response + damping fraction). Extracted so the
/// "does this overshoot?" contract is testable without a SwiftUI window.
public struct SpringSpec: Equatable, Sendable {
    public let response: Double
    public let dampingFraction: Double

    public init(response: Double, dampingFraction: Double) {
        self.response = response
        self.dampingFraction = dampingFraction
    }

    /// A spring with dampingFraction < 1.0 overshoots its target; >= 1.0 does
    /// not (critically damped or overdamped).
    public var overshoots: Bool {
        dampingFraction < 1.0
    }
}
