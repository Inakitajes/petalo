import Foundation

/// Pure scale contract for the "Send to ChatGPT" button's entry/exit zoom.
/// Extracted from the SwiftUI `PromptContent` so the symmetry between entry
/// and exit is guarded by a behavioral test: the dismissal must be the exact
/// inverse of the appearance — the button scales back down to `hiddenScale`
/// and fades out **in place**, rather than sliding off the trailing edge as
/// the panel collapses.
///
/// On a notched display the expanded panel (480pt wide, leading at the
/// panel origin) collapses to the compact bar centered under the camera
/// housing — a leading-offset shift of ~86pt. While the panel's
/// `.animation(value: isExpanded)` drives that offset, any content still
/// mounted inside the panel rides the slide. So the button cannot rely on
/// the panel-level removal to look right; it must exit on its *own*
/// conditional so SwiftUI detaches it from the parent layout for the
/// transition. The SwiftUI view therefore drives both directions from a
/// single Boolean (`sendButtonAppeared`) plus an asymmetric `.transition`:
///
/// - insertion (entry): grows from `hiddenScale` to `restingScale` + fades in;
/// - removal  (exit):   shrinks from `restingScale` to `hiddenScale` + fades out.
///
/// Because the removal is the button's own conditional flip, SwiftUI renders
/// the exit as a detached snapshot at the button's last frame — the
/// collapsing panel's offset no longer carries it sideways, and the dismissal
/// reads as a shrink-and-fade that mirrors the entry zoom-in.
public enum PromptButtonZoom {
    /// Scale at the hidden endpoint — the button's starting scale on entry
    /// and its ending scale on exit. Symmetric so the exit reads as the
    /// exact inverse of the entry zoom-in.
    public static let hiddenScale: CGFloat = 0.85
    /// Scale at the resting (fully appeared) endpoint.
    public static let restingScale: CGFloat = 1.0

    /// Entry zooms the button from `hiddenScale` up to `restingScale`.
    public static var entryScaleRange: (from: CGFloat, to: CGFloat) {
        (hiddenScale, restingScale)
    }

    /// Exit zooms the button from `restingScale` back down to `hiddenScale`
    /// — the exact inverse of entry, so the dismissal mirrors the appearance
    /// instead of sliding off.
    public static var exitScaleRange: (from: CGFloat, to: CGFloat) {
        (restingScale, hiddenScale)
    }
}
