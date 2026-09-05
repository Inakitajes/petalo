import CoreGraphics
import Foundation

/// A 2D spring used to give a drag rectangle elastic follow-through: the
/// rendered corner trails the cursor with lag (the "physics"/rubber-band),
/// and an underdamped spring overshoots and oscillates as the cursor pauses
/// (the "wobble"). One model gives both behaviors, and because it is a real
/// spring — not a canned envelope — it reacts correctly to any cursor motion
/// (fast, slow, direction changes). The captured region always uses the rigid
/// cursor points; this spring only drives the *render*, so capture accuracy
/// is never affected (the same render-wobbles / capture-stays-rigid contract
/// the notch wobble uses).
///
/// Semi-implicit (symplectic) Euler integration, frame-rate independent via
/// the caller-supplied `dt`. Tuned for the screen-region drag: a ~17 rad/s
/// natural frequency with a ~0.52 damping ratio, so the trailing corner
/// settles in ~0.4 s with a couple of visible wobbles — a clear jelly read
/// without being seasick during fast drags.
public struct DragSpring: Sendable {
    public let stiffness: CGFloat
    public let damping: CGFloat

    public init(stiffness: CGFloat, damping: CGFloat) {
        self.stiffness = stiffness
        self.damping = damping
    }

    /// The drag's jelly spring. `stiffness` 300 → ω ≈ 17.3 rad/s (~2.75 Hz
    /// wobble); `damping` 18 → ζ ≈ 0.52 (underdamped, ~2 visible overshoots).
    public static let jelly = DragSpring(stiffness: 300, damping: 18)

    /// One integration step toward `target`. Returns the new position and
    /// velocity. With zero stiffness and zero velocity this is a no-op (the
    /// position is unchanged), so a rigid mode that never carries velocity
    /// stays pinned — used by the overlay's Reduce-Motion path as a guard.
    public func step(
        position: CGPoint,
        velocity: CGVector,
        toward target: CGPoint,
        dt: TimeInterval
    ) -> (position: CGPoint, velocity: CGVector) {
        guard dt > 0 else { return (position, velocity) }
        // ax = -k(x - target) - c·v  →  k(target - x) - c·v
        let ax = stiffness * (target.x - position.x) - damping * velocity.dx
        let ay = stiffness * (target.y - position.y) - damping * velocity.dy
        let newVelocity = CGVector(
            dx: velocity.dx + ax * CGFloat(dt),
            dy: velocity.dy + ay * CGFloat(dt)
        )
        let newPosition = CGPoint(
            x: position.x + newVelocity.dx * CGFloat(dt),
            y: position.y + newVelocity.dy * CGFloat(dt)
        )
        return (newPosition, newVelocity)
    }
}
