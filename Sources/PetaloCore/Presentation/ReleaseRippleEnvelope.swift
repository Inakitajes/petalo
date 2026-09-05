import CoreGraphics
import Foundation

/// Pure envelopes for the shutter feedback played when the drag is released.
/// Extracted from the overlay for the same reason as `DragSpring` and
/// `JellySquashEnvelope` — the math is testable without a window, and the
/// resting contract is guarded by a behavioral test.
///
/// The house rule from `JellySquashEnvelope` applies to every curve here:
/// **each envelope is exactly at rest on both endpoints.** The overlay panel
/// is ordered out the instant the ripple ends, so whatever the envelope
/// returns at `duration` is literally the last frame on screen.
public enum ReleaseRippleEnvelope {
    /// Total life of the wave, measured from the moment the captured frame
    /// lands (not from the release — the shader has nothing to run on until
    /// then). The overlay stays on screen for exactly this long afterwards, so
    /// this is the added latency budget before the prompt opens.
    ///
    /// Doubled from 0.45 s deliberately, and it is the expensive knob here: at
    /// half a second the wavefront had to cross the selection so fast that
    /// barely half a spatial cycle fitted across it, so the whole border swelled
    /// almost in unison instead of rippling. The extra 450 ms buys a slower
    /// front — two full crests travelling around the outline — and room for the
    /// elastic to swing back more than once before it has to land.
    public static let duration: TimeInterval = 0.9
    /// Window of the hairline flash, measured from the *release*. It is the
    /// shutter click — the immediate acknowledgement that fires before the
    /// capture has even resolved — so it is deliberately much shorter than
    /// the wave that follows it.
    public static let flashDuration: TimeInterval = 0.18
    /// Fraction of `duration` the outside scrim holds at full strength before
    /// it starts dissolving, so the wave crosses a still-dimmed screen and the
    /// dim only lifts once the ripple is on its way out.
    public static let dimHoldFraction: Double = 0.45

    /// Multiplier for the outside scrim: 1 through the hold, then a smoothstep
    /// down to exactly 0 at `duration`, so the overlay lifts instead of being
    /// yanked and the last frame carries no dim at all.
    public static func dimFade(phase: TimeInterval) -> Double {
        guard phase.isFinite, phase > 0 else { return 1 }
        guard phase < duration else { return 0 }
        let holdEnd = duration * dimHoldFraction
        guard phase > holdEnd else { return 1 }
        let t = (phase - holdEnd) / (duration - holdEnd)
        // Smoothstep, so the dim eases away instead of ramping linearly.
        return 1 - t * t * (3 - 2 * t)
    }

    /// Intensity of the hairline flash in `[0, 1]`: a single half-sine over
    /// `flashDuration`, zero at both ends of its window and zero everywhere
    /// after it.
    public static func hairlineFlash(phase: TimeInterval) -> Double {
        guard phase.isFinite, phase > 0, phase < flashDuration else { return 0 }
        return sin(.pi * phase / flashDuration)
    }
}

/// Tuning for the `expansionRipple` Metal shader when it runs over the frame
/// the region capture just produced — the *same* shader the notch expansion
/// uses, tuned for a completely different job.
///
/// The shape is a single expansion: the surface bulges out once as the
/// wavefront passes, settles back, and stops. `frequency` is low enough that
/// only one temporal cycle fits in the window (`frequency · duration ≈ 2π`),
/// so each point on the border oscillates once rather than vibrating — the
/// read is a water drop, not a jello shake. The counter-swing survives at
/// ~13% of the first throw, enough to keep the settle from looking like a
/// hard stop but not enough to read as a second wave.
///
/// **The window is what makes the low decay safe.** With this little damping
/// the wave is nowhere near dead at `duration`, and `duration` is the frame the
/// panel is ordered out on — a wave still swinging there snaps the frame
/// straight as it disappears. `window(phase:)` lands it at exactly zero
/// instead, the same trick `JellySquashEnvelope` uses to keep the notch from
/// resting on a squashed scale. It is a *tail*, not the symmetric window that
/// envelope uses, because this wave already starts at rest on its own
/// (`sin(frequency · 0) = 0`, for every point): a symmetric window would only
/// smother the first throw near the cursor while leaving the far edge — which
/// the wavefront reaches around the window's peak — swinging *harder* than the
/// impact itself, which is backwards for a wave born under the cursor.
///
/// The surface matters: the shader displaces pixels radially and brightens
/// the crests, so it needs opaque, detailed content to read. On the notch that
/// is the glass scrim; here it is the captured frame. Run over the region
/// overlay's flat 28% wash instead it is either invisible or, cranked up
/// enough to see, just bends the selection rectangle out of shape.
///
/// Lives here rather than beside the shader so the resting and one-expansion
/// invariants are tested contracts instead of hand-checked numbers.
public enum ReleaseRippleShader {
    /// Amplitude for a selection at or above `amplitudeReference`. Below that
    /// it scales down — see `amplitude(forMinDimension:)`.
    ///
    /// Tuned for a *subtle* gelatine read: the excursion tops out around 5% of
    /// the shorter side, enough to read as an elastic edge without the selection
    /// looking like it is being dragged around by the wave. Lower than this and
    /// the border wobble drops below the hairline's own width; higher and the
    /// throw reads as exaggerated, which was the previous 76 pt tuning.
    public static let maximumAmplitude: Double = 30
    /// Shorter side at which the wave reaches full strength. Deliberately the
    /// same idea (and the same order of magnitude) as the lens's
    /// `refractionReferenceSize`: a small selection bends less, in points, than
    /// a large one.
    public static let amplitudeReference: Double = 420
    public static let frequency: Double = 8
    public static let decay: Double = 2.5
    /// Propagation speed at the `speedReference` diagonal. Below and above that
    /// it scales proportionally — see `speed(forDiagonal:)`. Raised from 1300
    /// once the wave collapsed to a single expansion: with only one lobe to
    /// read, the front can cross faster without flashing, so the drop reads as
    /// a quick, snappy expansion rather than a slow swell.
    public static let baseSpeed: Double = 2_000
    /// The diagonal at which the wave travels at `baseSpeed`. The typical drag
    /// (640 × 420) has a 765 pt diagonal, so that is the calibration point:
    /// the wavefront crosses it in ~65% of the ripple's life, leaving room
    /// to swing before the overlay is torn down.
    public static let speedReference: Double = 765
    /// Strength of the crest highlight the shader brightens the wave's crests
    /// by. The notch — the only other surface sharing `expansionRipple` — runs
    /// over a dark low-alpha scrim and needs 0.4 for the glint to read through.
    /// The captured frame is opaque, detailed content: even a modest highlight
    /// blows the crests toward white, so this stays a whisper — barely enough
    /// to suggest the wave is bending light, not enough to read as a white
    /// radiation.
    public static let crest: Double = 0.06

    /// Amplitude for a selection whose shorter side is `minDimension`.
    ///
    /// Proportional below the reference and capped above it, which keeps the
    /// deformation at a constant *fraction* of small selections (about 5% of
    /// the shorter side) instead of a constant number of points. Without this
    /// the tuning that makes a 640 pt drag slosh convincingly folds a 150 pt one
    /// in half — the wave does not care how big the thing it is crossing is.
    public static func amplitude(forMinDimension minDimension: Double) -> Double {
        guard minDimension.isFinite, minDimension > 0 else { return 0 }
        return maximumAmplitude * min(1, minDimension / amplitudeReference)
    }

    /// Propagation speed for a selection whose corner-to-corner diagonal is
    /// `diagonal`.
    ///
    /// Linear and uncapped, because both things that need to scale with the
    /// selection size are functions of `speed` alone: the wavefront's reach
    /// (`speed · duration`) has to cross the diagonal, and the spatial
    /// wavelength (`2π · speed / frequency`) has to fit the same number of
    /// lobes on every selection. Scaling `speed` linearly with the diagonal
    /// makes both of those constant *fractions* of the shape — a 150 pt drag
    /// ripples with the same leisurely tempo and the same number of crests as
    /// a 2000 pt one. Without this, the wave either flashes across a small
    /// drag before the eye can follow it, or stalls short of a large drag's
    /// far edge and leaves half the border rigid.
    ///
    /// `frequency` is deliberately *not* scaled: it is the temporal rate at
    /// which each point oscillates, and keeping it constant means the wobble
    /// speed at any given point is the same regardless of selection size —
    /// only the spatial pattern stretches.
    public static func speed(forDiagonal diagonal: Double) -> Double {
        guard diagonal.isFinite, diagonal > 0, speedReference > 0 else { return 0 }
        return baseSpeed * diagonal / speedReference
    }

    /// Raised-cosine tail multiplying the whole wave: 1 while it is doing its
    /// work, easing to exactly 0 at `duration` — and with zero slope there, so
    /// the wave lands rather than being cut off.
    ///
    /// A single global factor of `phase`, deliberately: it can therefore be
    /// folded into the amplitude the shader is handed
    /// (`windowedAmplitude(phase:)`) instead of needing a new uniform and a
    /// recompiled metallib, and the pixels and the silhouette stay driven by
    /// one identical number.
    public static func window(phase: TimeInterval) -> Double {
        guard phase.isFinite, phase > 0, phase < ReleaseRippleEnvelope.duration else { return 0 }
        return 0.5 * (1 + cos(.pi * phase / ReleaseRippleEnvelope.duration))
    }

    /// What to hand the shader as its `amplitude` uniform, so its per-pixel
    /// `amplitude · sin(frequency·t) · exp(-decay·t)` comes out as the windowed
    /// wave `displacement(phase:distance:)` describes.
    ///
    /// The crest highlight is unaffected: the shader scales it by
    /// `rippleAmount / amplitude`, and the window cancels in that ratio.
    public static func windowedAmplitude(phase: TimeInterval, amplitude: Double) -> Double {
        guard amplitude.isFinite, amplitude > 0 else { return 0 }
        return amplitude * window(phase: phase)
    }

    /// The signed radial displacement the shader applies at `phase` to a point
    /// `distance` away from the release, in points — an exact mirror of
    /// `Ripple.metal`'s `amplitude * sin(frequency·t) * exp(-decay·t)` with
    /// `t = max(0, phase - distance/speed)`.
    ///
    /// This is the whole wave, sign included, so the silhouette can be bent by
    /// the same field that bends the pixels (`RippleOutline`). It is exactly
    /// zero before the wavefront arrives (`t = 0` ⇒ `sin 0`), which is what
    /// makes the deformation read as a ring travelling outward from the release
    /// rather than as a single global pulse.
    /// The travelling wave itself: how far the surface at `distance` from the
    /// release has been pushed at `phase`, with no regard for which way.
    ///
    /// This is what the *silhouette* rides (`RippleOutline`), because the
    /// silhouette moves along its own outward normal, where the radial field's
    /// singularity — and therefore `taper` — simply does not arise. Keeping the
    /// taper here would only smother the border exactly where the wave is born.
    public static func wave(
        phase: TimeInterval,
        distance: Double,
        amplitude: Double,
        speed: Double
    ) -> Double {
        guard phase.isFinite, distance.isFinite, distance >= 0, speed > 0 else { return 0 }
        let t = max(0, phase - distance / speed)
        return windowedAmplitude(phase: phase, amplitude: amplitude) * sin(frequency * t) * exp(-decay * t)
    }

    public static func displacement(
        phase: TimeInterval,
        distance: Double,
        amplitude: Double,
        speed: Double
    ) -> Double {
        let scale = windowedAmplitude(phase: phase, amplitude: amplitude)
        return wave(phase: phase, distance: distance, amplitude: amplitude, speed: speed)
            * taper(distance: distance, scale: scale)
    }

    /// Fades the wave out at the impact point, mirroring `Ripple.metal`.
    ///
    /// The field is radial, so it is singular at the origin: everything within
    /// a displacement's reach of the release is pulled *through* it, and the
    /// surface tears — a fold in the silhouette, a visible crease in the
    /// pixels. Tapering linearly over the current amplitude keeps
    /// `|displacement| <= distance` everywhere, which is exactly the condition
    /// for the warp to stay injective. It scales itself: as the window closes,
    /// so does the taper radius.
    ///
    /// At the old 14 pt amplitude this was invisible and the shader shipped
    /// without it. At an amplitude that can actually be seen, it is the
    /// difference between a water drop and a rip.
    private static func taper(distance: Double, scale: Double) -> Double {
        guard scale > 0 else { return 0 }
        return min(1, distance / scale)
    }

    /// Envelope of the radial displacement the shader applies at `phase` to a
    /// point `distance` away from the release, in points. Mirrors
    /// `Ripple.metal`'s `amplitude * sin(frequency·t) * exp(-decay·t)` with
    /// `t = max(0, phase - distance/speed)`, taking the decay envelope rather
    /// than the signed sine so this is the *bound* on the displacement.
    public static func displacementBound(
        phase: TimeInterval,
        distance: Double,
        amplitude: Double,
        speed: Double
    ) -> Double {
        guard phase.isFinite, distance.isFinite, distance >= 0, speed > 0 else { return 0 }
        let t = max(0, phase - distance / speed)
        let scale = windowedAmplitude(phase: phase, amplitude: amplitude)
        return scale * exp(-decay * t) * taper(distance: distance, scale: scale)
    }

    /// How far the wavefront has set out by `phase`. Anything past this has
    /// not started moving yet.
    public static func wavefrontReach(phase: TimeInterval, speed: Double) -> Double {
        guard phase.isFinite, phase > 0, speed > 0 else { return 0 }
        return speed * phase
    }
}
