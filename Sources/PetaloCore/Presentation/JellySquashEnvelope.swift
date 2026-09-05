import Foundation

/// Pure envelope for the expand-time jelly squash & stretch. Extracted from
/// the SwiftUI `JellySquashEffect` so the math is testable without a window
/// and the resting-scale contract is guarded by a behavioral test.
///
/// The envelope is a damped sinusoid **windowed** by `sin(π·phase/duration)`,
/// so it is exactly zero at `phase = 0` and `phase = duration`. Without the
/// window the damped sinusoid is nonzero at the end, and SwiftUI's
/// `keyframeAnimator` leaves the value at the final keyframe after the
/// animation — which shrinks the resting notch by ~1.3% permanently (the
/// "no cubre el 100% de la altura del notch" regression). The window forces
/// the scale back to identity when the animator settles.
public enum JellySquashEnvelope {
    public static let amplitude: Double = 0.1345
    public static let angular: Double = 3 * .pi
    public static let decay: Double = 4.83
    /// How much of the height displacement the width counter-applies. 0.6
    /// keeps the scale product (volume) near 1 across the oscillation.
    public static let widthCoupling: Double = 0.6

    /// Scale offset `(dx, dy)` to add to the identity scale `(1, 1)` at
    /// `phase` (raw time in `[0, duration]`). Returns `(0, 0)` at both
    /// endpoints and outside the window, so the resting scale is identity.
    /// `dy` is the height stretch; `dx` counter-oscillates it (narrow when
    /// tall) for the volume-preserving squash & stretch read.
    public static func scaleOffset(
        phase: Double,
        duration: Double
    ) -> (dx: Double, dy: Double) {
        guard duration > 0, phase > 0, phase < duration else { return (0, 0) }
        let window = sin(.pi * phase / duration)
        let envelope = amplitude * sin(angular * phase) * exp(-decay * phase) * window
        return (dx: -widthCoupling * envelope, dy: envelope)
    }
}
