import Foundation
import SwiftUI

import PetaloCore

/// Water-drop ripple riding on the expand spring, done entirely with public
/// API: a `layerEffect` Metal shader (`Ripple.metal`) displaces the SwiftUI
/// layer radially with a damped traveling wave and brightens its crests.
/// Driven by `keyframeAnimator` so the shader clock advances only while the
/// wave is alive; outside that window `isEnabled` keeps the effect free.
///
/// Apply it to SwiftUI-rendered content only. The glass backdrop is
/// composited by the window server: rasterizing it through a shader (or a
/// CATransition) renders it blank for the duration of the animation.
/// The packaged app keeps the prebuilt library in the main bundle's signed
/// Resources directory; unbundled `swift run` builds use SwiftPM's module
/// resource bundle instead.
enum RippleShaderResources {
    static var bundle: Bundle {
        if Bundle.main.url(forResource: "default", withExtension: "metallib") != nil {
            return Bundle.main
        }
        return .module
    }
}

struct ExpansionRippleEffect: ViewModifier {
    /// Bump to fire one ripple; the animator triggers on change.
    let trigger: Int

    private nonisolated static let duration: TimeInterval = 0.9

    func body(content: Content) -> some View {
        content.keyframeAnimator(
            initialValue: 0,
            trigger: trigger
        ) { view, elapsedTime in
            view.modifier(RippleShaderModifier(elapsedTime: elapsedTime))
        } keyframes: { _ in
            MoveKeyframe(0)
            LinearKeyframe(Self.duration, duration: Self.duration)
        }
    }
}

private struct RippleShaderModifier: ViewModifier {
    var elapsedTime: TimeInterval

    /// Hand-tuned for the notch surface: one subtle pulse, not a train of
    /// rings — the decay eats the sine before its second cycle, so a single
    /// wavefront crosses the surface and dies with the expand spring.
    /// `nonisolated` because the shader closure inside `visualEffect` is
    /// Sendable and off the main actor.
    private nonisolated static let amplitude: Double = 8
    private nonisolated static let frequency: Double = 6
    private nonisolated static let decay: Double = 5
    private nonisolated static let speed: Double = 1_300
    /// Crest highlight strength. The notch scrim is a dark low-alpha wash, so
    /// the glint leans bright (0.4) to read through it. The region capture
    /// shares this shader but runs over an opaque frame and uses a much lower
    /// value — see `ReleaseRippleShader.crest`.
    private nonisolated static let crest: Double = 0.4
    private nonisolated static let duration: TimeInterval = 0.9

    func body(content: Content) -> some View {
        let elapsedTime = elapsedTime
        content.visualEffect { view, proxy in
            view.layerEffect(
                ShaderLibrary.bundle(RippleShaderResources.bundle).expansionRipple(
                    // The wave sets out from the bar band's center — the
                    // camera housing or the collapsed capsule — regardless
                    // of how far the card has grown.
                    .float2(CGPoint(x: proxy.size.width / 2, y: 0)),
                    .float(elapsedTime),
                    .float(Self.amplitude),
                    .float(Self.frequency),
                    .float(Self.decay),
                    .float(Self.speed),
                    .float(Self.crest)
                ),
                maxSampleOffset: CGSize(width: Self.amplitude, height: Self.amplitude),
                isEnabled: elapsedTime > 0 && elapsedTime < Self.duration
            )
        }
    }
}

/// The same `expansionRipple` shader, run over the frame the screen-region
/// capture just produced.
///
/// Deliberately the same treatment `ExpansionRippleEffect` gives the notch —
/// an opaque, detailed surface sloshing like water — and for the same reason
/// it is *not* run on the drag area's live glass: that lens is a
/// `CABackdropLayer` composited by the window server, and a `layerEffect`
/// would render it blank, exactly as documented at the top of this file. The
/// overlay's other candidate surface, the dimming scrim, is a flat 28% wash
/// with a single thin outline: the shader has nothing there to displace, so it
/// reads as either nothing at all or a dented rectangle. The captured frame is
/// the one surface here with the substance this shader was built for, and it
/// happens to be a pixel-exact stand-in for the lens it replaces.
///
/// Unlike `ExpansionRippleEffect` this takes its clock directly rather than
/// through a `keyframeAnimator`: the overlay already drives the dim dissolve,
/// the hairline flash and the elastic pulse off a single timer, and the shader
/// has to stay on that same tick or the wave would drift out of step with the
/// frame it is bending. Tuning lives in `ReleaseRippleShader` (PetaloCore) so
/// the "the wave is spent before the overlay is torn down" invariant is a
/// tested contract rather than a hand-checked number.
struct RegionReleaseRippleModifier: ViewModifier {
    /// Seconds since the release. Zero (or past the ripple) disables the
    /// effect outright, so the drag itself costs nothing.
    var elapsedTime: TimeInterval
    /// Release location in the captured frame's own top-left coordinate space
    /// — the space `layerEffect` hands the shader as `position`.
    var origin: CGPoint
    /// Full-strength amplitude for *this* selection: the wave throws a small
    /// drag proportionally, not by the same number of points as a large one.
    /// The silhouette derives the identical value from the same rectangle.
    var amplitude: Double
    /// Propagation speed for *this* selection's diagonal. Scales the
    /// wavefront's reach and the spatial wavelength together, so the same
    /// number of crests crosses any selection in the same fraction of the
    /// ripple's life.
    var speed: Double

    func body(content: Content) -> some View {
        let elapsedTime = elapsedTime
        let origin = origin
        let amplitude = amplitude
        let speed = speed
        return content.visualEffect { view, _ in
            view.layerEffect(
                ShaderLibrary.bundle(RippleShaderResources.bundle).expansionRipple(
                    .float2(origin),
                    .float(elapsedTime),
                    // Windowed, so the shader's own per-pixel wave lands at
                    // exactly zero on the frame the panel is ordered out —
                    // and so the pixels bend by precisely the number
                    // `RippleOutline` bends the silhouette by. The window is a
                    // function of `phase` alone, which is why it can ride in
                    // on the amplitude instead of needing a new uniform.
                    .float(ReleaseRippleShader.windowedAmplitude(
                        phase: elapsedTime,
                        amplitude: amplitude
                    )),
                    .float(ReleaseRippleShader.frequency),
                    .float(ReleaseRippleShader.decay),
                    .float(speed),
                    .float(ReleaseRippleShader.crest)
                ),
                maxSampleOffset: CGSize(width: amplitude, height: amplitude),
                isEnabled: elapsedTime > 0 && elapsedTime < ReleaseRippleEnvelope.duration
            )
        }
    }
}

/// Volume-conserving squash & stretch layered over the expand spring: as the
/// bubble springs open or collapses it bounces **horizontally** — narrowing
/// then settling — the elastic "rebote" read the user wants on the width axis
/// (where there is wing margin to absorb the overshoot). The vertical
/// component is deliberately suppressed: the scaleEffect applies only `dx`,
/// never `dy`, so the height never compresses past the physical notch during
/// collapse (the "se ve el Notch" glitch). A layer transform (like the
/// heartbeat above), so the window-server-composited glass backdrop follows
/// it; unlike the radial ripple it is not confined to the scrim.
///
/// Reuses `rippleTrigger` (incremented on every `isExpanded` change and gated
/// on `!reduceMotion` in `NotchWidgetView`), so the squash plays on both
/// expand and collapse and never under Reduce Motion. A single phase value is
/// animated 0→duration (raw time); the damped, windowed sinusoid lives in
/// `JellySquashEnvelope` (PetaloCore, tested). The window forces the envelope
/// to zero at both endpoints, so when SwiftUI's `keyframeAnimator` settles on
/// the final keyframe the scale is identity — the resting notch keeps its
/// true dimensions (no persistent shrink).
struct JellySquashEffect: ViewModifier {
    let trigger: Int

    private nonisolated static let duration: TimeInterval = 0.42

    func body(content: Content) -> some View {
        content.keyframeAnimator(
            initialValue: 0,
            trigger: trigger
        ) { view, phase in
            view.modifier(JellyScaleModifier(phase: phase, duration: Self.duration))
        } keyframes: { _ in
            MoveKeyframe(0)
            LinearKeyframe(Self.duration, duration: Self.duration)
        }
    }
}

private struct JellyScaleModifier: ViewModifier {
    /// Animation phase as raw time in `[0, duration]`. Zero at rest; the
    /// keyframe animator ramps it linearly to `duration` over the effect.
    var phase: Double
    var duration: Double

    func body(content: Content) -> some View {
        let offset = JellySquashEnvelope.scaleOffset(phase: phase, duration: duration)
        // Horizontal-only: the width bounces (dx) but the height is locked at
        // 1.0 (no dy). This is the fix for the "se ve el Notch" glitch — the
        // vertical compression from dy would push the virtual notch behind
        // the hardware cutout during collapse. The horizontal bounce is safe
        // because there is wing margin on both sides. The envelope's dy is
        // computed (and still tested) but discarded here.
        content.scaleEffect(
            CGSize(width: 1 + offset.dx, height: 1),
            anchor: .top
        )
    }
}
