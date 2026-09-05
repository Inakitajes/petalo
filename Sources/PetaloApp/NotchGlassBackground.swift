import AppKit
import SwiftUI

import PetaloCore

/// Two-layer notch background replacing the flat black fill: a Liquid Glass
/// backdrop under a black scrim that stays fully opaque across the bar band —
/// so the camera cutout never shows — and fades toward translucent glass
/// going down, like the Siri orb. On a display without a camera housing the
/// pill has no cutout to hide, so the scrim collapses to a flat smoked tint
/// and the whole silhouette reads as tinted glass in both states. The two
/// layers are separate views (`NotchGlassBackdrop`, `NotchGlassScrim`) so
/// the scrim can ride through SwiftUI layer effects the window-server-fed
/// backdrop must stay out of.
///
/// The backdrop is a self-owned `CABackdropLayer` running the same private
/// `glassBackground` filter `NSGlassEffectView` uses internally. The official
/// wrappers are unusable here: SwiftUI's `glassEffect` samples within the
/// window (flat gray in this clear borderless panel), and `NSGlassEffectView`
/// continuously re-commits its filter values, clobbering any tuning. Owning
/// the layer and filter outright is the only arrangement where our blur,
/// transparency, and refraction values actually hold.
/// The live glass half of the background. It must stay outside any SwiftUI
/// layer effect: the backdrop is composited by the window server, so a
/// shader (or transition) that rasterizes its layer renders it blank.
struct NotchGlassBackdrop: View {
    let presentation: NotchLayout.Presentation
    /// User-tuned glass blur radius (Settings → Appearance → Frosted).
    var frostRadius: Double = NotchGlassStyle.defaultFrostRadius
    /// Corner radius for the SDF lens element and shape mask. Defaults to the
    /// notch's canonical radius; panels with a larger bubble profile pass a
    /// bigger value so refraction follows the visible silhouette.
    var bottomCornerRadius: CGFloat = HangingNotchMetrics.bottomCornerRadius
    /// Concave top shoulder radius for the hanging-notch silhouette. Defaults
    /// to the notch's canonical shoulder; the expanded notch passes a larger
    /// value so the glass mask and SDF lens match the softer bubble profile.
    var topShoulderRadius: CGFloat = HangingNotchMetrics.topShoulderRadius
    /// Jelly wobble phase in `[0, 1]`, shared with the scrim so the glass
    /// mask recoils in lockstep with the SwiftUI-drawn silhouette. See
    /// `NotchGlassScrim.wobblePhase`. Only the custom-glass path honors it;
    /// the visual-effect fallback keeps its rigid mask (acceptable degrade).
    var wobblePhase: CGFloat = 0
    var wobbleAmplitude: CGFloat = 0

    var body: some View {
        Group {
            if NotchCustomGlassView.isSupported {
                NotchCustomGlassBackdrop(
                    cornerStyle: cornerStyle,
                    frostRadius: frostRadius,
                    bottomCornerRadius: bottomCornerRadius,
                    topShoulderRadius: topShoulderRadius,
                    wobblePhase: wobblePhase,
                    wobbleAmplitude: wobbleAmplitude
                )
            } else {
                NotchVisualEffectBackdrop(
                    cornerStyle: cornerStyle,
                    bottomCornerRadius: bottomCornerRadius,
                    topShoulderRadius: topShoulderRadius
                )
            }
        }
        .allowsHitTesting(false)
    }

    private var cornerStyle: HangingNotchCornerStyle {
        presentation == .pill ? .bubble : .hangingNotch
    }
}

/// The SwiftUI-drawn half: the black scrim over the glass. Pure vector
/// content, so it can ride through layer effects like the expansion ripple.
struct NotchGlassScrim: View {
    let silhouette: HangingNotchShape
    /// Height of the strip that must stay pure black (`layout.height`).
    let barBandHeight: CGFloat
    /// Pill presentation swaps the camera scrim for the flat tint.
    let presentation: NotchLayout.Presentation
    /// User-tuned black wash opacity (Settings → Appearance → Tint). The
    /// notch's camera band stays pure black regardless — the tint only sets
    /// the floor its scrim dissolves down to.
    var tintOpacity: Double = NotchGlassStyle.defaultTintOpacity
    /// Warp applied to the dissolve's progress: above 1 pushes the
    /// transition downward so the dark band persists longer before fading.
    var dissolveBias: Double = NotchGlassStyle.scrimDissolveBias
    /// Offset of the dissolve's virtual start relative to the solid band.
    /// Zero starts the fade right at the band (more pure black at top);
    /// negative lifts it above the band for a softer start.
    var fadeStartFraction: Double = NotchGlassStyle.scrimFadeStartFraction
    /// Jelly wobble phase in `[0, 1]`. Driven by `NotchWidgetView` via a
    /// linear animation on expand; the silhouette's bottom edge recoils
    /// upward with a damped two-bump envelope (see
    /// `HangingNotchGeometry.wobbledPath`). Zero (rest) yields the rigid
    /// silhouette, so the scrim is free until the wobble plays.
    var wobblePhase: CGFloat = 0
    /// First-crest height of the recoil, in points. Zero disables the wobble.
    var wobbleAmplitude: CGFloat = 0

    var body: some View {
        GeometryReader { proxy in
            scrim(height: max(proxy.size.height, 1))
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder private func scrim(height: CGFloat) -> some View {
        // Both notch and pill now share the same elliptical black-to-tint
        // gradient. The pill previously used a flat fill, which left the
        // expanded card without the notch's characteristic dark-to-glass fade.
        fillShape.fill(scrimGradient(height: height))
    }

    /// The silhouette filled by the scrim: wobbling when a wobble is active,
    /// otherwise the rigid `HangingNotchShape` passed in. Built per frame as
    /// `wobblePhase` animates.
    private var fillShape: some Shape {
        WobblingHangingNotchShape(
            style: silhouette.style,
            topShoulderRadius: silhouette.topShoulderRadius,
            bottomCornerRadius: silhouette.bottomCornerRadius,
            wobblePhase: wobblePhase,
            wobbleAmplitude: wobbleAmplitude
        )
    }

    /// The scrim renders as an elliptical gradient whose center sits at
    /// `scrimCenterY` (unit space, negative = above the notch): the
    /// iso-opacity bands become arcs that dip lower mid-panel — the curved
    /// black cap of the Siri orb — instead of ruler-straight lines. Vertical
    /// stop positions map to radius fractions relative to that center; the
    /// clamp keeps the center inside the solid band so the mirrored region
    /// above it can never reach visible glass.
    private func scrimGradient(height: CGFloat) -> EllipticalGradient {
        // The pill has no camera cutout to hide, so its collapsed bar
        // collapses to a flat smoked tint (the user's tint) rather than the
        // flat black the notch uses to hide the hardware housing. Once
        // expanded the pill is taller than the solid band and the full
        // black-to-glass gradient runs as usual.
        let collapsedOpacity = presentation == .pill ? tintOpacity : 1.0
        let stops = NotchGlassStyle.scrimStops(
            height: height,
            solidBandHeight: barBandHeight + NotchGlassStyle.solidBandOverlap,
            bottomOpacity: tintOpacity,
            dissolveBias: dissolveBias,
            fadeStartFraction: fadeStartFraction,
            collapsedOpacity: collapsedOpacity
        )
        let centerY = NotchGlassStyle.scrimCenterY
        let reach = 1 - centerY
        return EllipticalGradient(
            stops: stops.map {
                Gradient.Stop(
                    color: .black.opacity($0.opacity),
                    location: ($0.location - centerY) / reach
                )
            },
            center: UnitPoint(x: 0.5, y: centerY),
            startRadiusFraction: 0,
            endRadiusFraction: reach
        )
    }
}

private struct NotchCustomGlassBackdrop: NSViewRepresentable {
    let cornerStyle: HangingNotchCornerStyle
    let frostRadius: Double
    let bottomCornerRadius: CGFloat
    let topShoulderRadius: CGFloat
    let wobblePhase: CGFloat
    let wobbleAmplitude: CGFloat

    func makeNSView(context: Context) -> NotchCustomGlassView {
        NotchCustomGlassView(
            cornerStyle: cornerStyle,
            frostRadius: frostRadius,
            bottomCornerRadius: bottomCornerRadius,
            topShoulderRadius: topShoulderRadius,
            wobbleAmplitude: wobbleAmplitude
        )
    }

    func updateNSView(_ view: NotchCustomGlassView, context: Context) {
        view.apply(frostRadius: frostRadius)
        view.apply(bottomCornerRadius: bottomCornerRadius)
        view.apply(topShoulderRadius: topShoulderRadius)
        // Per-frame wobble: re-derives only the cheap `CAShapeLayer` mask
        // path (not the SDF lens), so the live glass silhouette recoils in
        // lockstep with the SwiftUI scrim without the per-frame cost of a
        // full relayout. No-op when the phase is unchanged (rest).
        view.apply(wobblePhase: wobblePhase)
    }
}

/// Self-owned Liquid Glass, replicating the exact private layer recipe found
/// inside `NSGlassEffectView` (recovered via keyed-archive inspection):
///
///     CABackdropLayer (name "@0", windowServerAware, glassBackground filter)
///       └── CASDFLayer (name "@0", effect: CASDFOutputEffect(maximum: 1))
///             └── CALayer
///                   └── CASDFElementLayer (cornerRadius, continuous curve)
///
/// The `glassBackground` filter reads its lens geometry from the signed
/// distance field produced by the sublayer named by `inputSourceSublayerName`
/// ("@0") — without that SDF stack the filter blurs but never refracts. We
/// own every object, so unlike `NSGlassEffectView`, nothing re-commits values
/// over our tuning. Everything resolves via runtime lookup: this compiles on
/// any SDK, and `isSupported` reports false wherever the private machinery is
/// missing (then pre-26 systems fall back to the visual-effect blur).
final class NotchCustomGlassView: NSView {
    static let isSupported: Bool =
        PetaloGlassFilter.make() != nil
            && NSClassFromString("CASDFLayer") is CALayer.Type
            && NSClassFromString("CASDFElementLayer") is CALayer.Type
            && NSClassFromString("CASDFOutputEffect") is NSObject.Type

    private let cornerStyle: HangingNotchCornerStyle
    private var frostRadius: Double
    private var bottomCornerRadius: CGFloat
    private var topShoulderRadius: CGFloat
    /// Jelly wobble phase in `[0, 1]`. Driven per-frame by the representable
    /// while the wobble animation runs; `apply(wobblePhase:)` re-derives only
    /// the `CAShapeLayer` mask path so the live glass silhouette recoils in
    /// lockstep with the SwiftUI scrim. The SDF lens element is intentionally
    /// left rigid (see `layout()`) to avoid re-deriving the distance field
    /// every frame; the refraction mismatch at the bottom edge during the
    /// ~0.6 s recoil is imperceptible.
    private var wobblePhase: CGFloat = 0
    private let wobbleAmplitude: CGFloat
    private let shapeMask = CAShapeLayer()
    private var backdrop: CALayer?
    private var sdfLayer: CALayer?
    private var sdfContainer: CALayer?
    private var sdfElement: CALayer?

    init(
        cornerStyle: HangingNotchCornerStyle = .hangingNotch,
        frostRadius: Double = NotchGlassStyle.defaultFrostRadius,
        bottomCornerRadius: CGFloat = HangingNotchMetrics.bottomCornerRadius,
        topShoulderRadius: CGFloat = HangingNotchMetrics.topShoulderRadius,
        wobbleAmplitude: CGFloat = 0
    ) {
        self.cornerStyle = cornerStyle
        self.frostRadius = frostRadius
        self.bottomCornerRadius = bottomCornerRadius
        self.topShoulderRadius = topShoulderRadius
        self.wobbleAmplitude = wobbleAmplitude
        super.init(frame: .zero)
        wantsLayer = true
    }

    /// Live re-tune from the Settings slider. CAFilter inputs are copied
    /// when assigned into `filters`, so mutating the old instance is inert —
    /// a rebuilt filter swapped in atomically is the reliable path.
    func apply(frostRadius: Double) {
        guard frostRadius != self.frostRadius else { return }
        self.frostRadius = frostRadius
        guard let backdrop, let filter = PetaloGlassFilter.make(frostRadius: frostRadius) else {
            return
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backdrop.filters = [filter]
        CATransaction.commit()
    }

    /// Live re-shape from the expand/collapse transition: the notch swaps its
    /// bottom corner radius between the tight notch profile (collapsed) and
    /// the softer bubble profile (expanded). The mask path and the SDF lens
    /// element both read this value in `layout()`, so flagging a relayout is
    /// enough to push the new silhouette through.
    func apply(bottomCornerRadius: CGFloat) {
        guard bottomCornerRadius != self.bottomCornerRadius else { return }
        self.bottomCornerRadius = bottomCornerRadius
        needsLayout = true
    }

    /// Live re-shape for the concave top shoulder: the notch swaps its
    /// shoulder radius between the tight notch profile (collapsed) and the
    /// softer bubble profile (expanded). The mask path and the SDF lens
    /// element inset both read this value in `layout()`.
    func apply(topShoulderRadius: CGFloat) {
        guard topShoulderRadius != self.topShoulderRadius else { return }
        self.topShoulderRadius = topShoulderRadius
        needsLayout = true
    }

    /// Per-frame wobble push from the representable. Re-derives only the
    /// `CAShapeLayer` mask path (the alpha silhouette) directly — *not* via
    /// `needsLayout` — so the expensive SDF distance field stays untouched
    /// and only the cheap path assignment runs each frame. The SDF lens
    /// element keeps its rigid geometry; only the visible glass shape recoils.
    /// No-op when the phase is unchanged (rest), so steady state is free.
    func apply(wobblePhase: CGFloat) {
        guard wobblePhase != self.wobblePhase else { return }
        self.wobblePhase = wobblePhase
        rederiveMaskPath()
    }

    /// Recomputes the alpha mask from the current bounds + radii + wobble
    /// phase. Uses `wobbledPath`, which equals the rigid `path` at rest, so
    /// callers don't need to special-case the no-wobble state.
    private func rederiveMaskPath() {
        shapeMask.path = HangingNotchGeometry.wobbledPath(
            in: bounds,
            style: cornerStyle,
            topShoulderRadius: topShoulderRadius,
            bottomCornerRadius: bottomCornerRadius,
            phase: wobblePhase,
            amplitude: wobbleAmplitude
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("not used")
    }

    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        installBackdropIfNeeded()
    }

    /// The backdrop is hosted as a plain sublayer, never as the view's
    /// backing layer: AppKit stamps backing layers with a debug name
    /// ("CABackdropLayer: …View"), clobbering the "@0" name that pairs the
    /// backdrop with the SDF source the glassBackground filter resolves via
    /// `inputSourceSublayerName`.
    private func installBackdropIfNeeded() {
        guard backdrop == nil, let hostLayer = layer else { return }
        guard let backdropType = NSClassFromString("CABackdropLayer") as? CALayer.Type,
              let sdfType = NSClassFromString("CASDFLayer") as? CALayer.Type,
              let elementType = NSClassFromString("CASDFElementLayer") as? CALayer.Type,
              let effectType = NSClassFromString("CASDFOutputEffect") as? NSObject.Type,
              let filter = PetaloGlassFilter.make(frostRadius: frostRadius) else {
            NSLog("Petalo custom glass unavailable; backdrop not installed")
            return
        }

        let glass = backdropType.init()
        glass.name = PetaloGlassFilter.sdfSourceSublayerName
        glass.filters = [filter]
        // CALayer KVC tolerates arbitrary keys, so these are safe no-ops if
        // the private layer stops recognizing them.
        glass.setValue(true, forKey: "windowServerAware")
        glass.setValue(false, forKey: "allowsGroupBlending")
        glass.setValue(true, forKey: "allowsFilteredLuma")
        glass.setValue(0.5, forKey: "scale")
        glass.mask = shapeMask

        let sdf = sdfType.init()
        sdf.name = PetaloGlassFilter.sdfSourceSublayerName
        let effect = effectType.init()
        effect.setValue(1, forKey: "maximum")
        sdf.setValue(effect, forKey: "effect")

        let container = CALayer()
        let element = elementType.init()
        element.cornerRadius = bottomCornerRadius
        element.cornerCurve = .continuous
        element.setValue(true, forKey: "hitTestsAsFill")

        container.addSublayer(element)
        sdf.addSublayer(container)
        glass.addSublayer(sdf)
        hostLayer.addSublayer(glass)

        backdrop = glass
        sdfLayer = sdf
        sdfContainer = container
        sdfElement = element
        needsLayout = true
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backdrop?.frame = bounds
        shapeMask.frame = bounds
        // The alpha mask follows the wobble (recoils with the SwiftUI scrim),
        // so a real layout mid-wobble keeps the visible glass in sync. At rest
        // `wobbledPath` equals the rigid `path`.
        shapeMask.path = HangingNotchGeometry.wobbledPath(
            in: bounds,
            style: cornerStyle,
            topShoulderRadius: topShoulderRadius,
            bottomCornerRadius: bottomCornerRadius,
            phase: wobblePhase,
            amplitude: wobbleAmplitude
        )
        sdfLayer?.frame = bounds
        sdfContainer?.frame = bounds
        switch cornerStyle {
        case .hangingNotch:
            // The lens element is the silhouette's straight-sided body: inset
            // by the shoulder radius so its rounded bottom corners coincide
            // exactly with the silhouette's bottom arcs. Its rounded top
            // corners sit under the solid black band and are never visible.
            // Both the inset and the corner radius are re-applied here (not
            // just at init) so the expand/collapse radius swap reaches the
            // refraction lens.
            sdfElement?.frame = bounds.insetBy(
                dx: topShoulderRadius, dy: 0
            )
            sdfElement?.cornerRadius = bottomCornerRadius
        case .bubble:
            // The bubble's lens is the silhouette itself: full bounds with
            // the same clamped radius, so the refraction follows the capsule
            // ends while collapsed and the rounded card once expanded.
            sdfElement?.frame = bounds
            sdfElement?.cornerRadius = min(
                bottomCornerRadius,
                bounds.width / 2,
                bounds.height / 2
            )
        }
        CATransaction.commit()
    }
}

/// Fallback backdrop: behind-window blur shaped by the view's own mask image.
/// SwiftUI `.mask`/`.clipShape` cannot clip behind-window blur — the window
/// server composites it outside SwiftUI's render tree — so the mask must live
/// on the `NSVisualEffectView` itself.
private struct NotchVisualEffectBackdrop: NSViewRepresentable {
    let cornerStyle: HangingNotchCornerStyle
    let bottomCornerRadius: CGFloat
    let topShoulderRadius: CGFloat

    func makeNSView(context: Context) -> NSVisualEffectView {
        // Both silhouettes clamp or scale their corner radii with the live
        // height (the bubble clamps to half-height; the notch shrinks both
        // radii proportionally), so neither can use a single fixed mask.
        // Each subclass re-derives the mask from the current bounds + radius.
        let view: NSVisualEffectView = cornerStyle == .bubble
            ? BubbleMaskVisualEffectView(bottomCornerRadius: bottomCornerRadius)
            : HangingNotchMaskVisualEffectView(
                bottomCornerRadius: bottomCornerRadius,
                topShoulderRadius: topShoulderRadius
            )
        view.blendingMode = .behindWindow
        // fullScreenUI transmits far more backdrop color than hudWindow; the
        // scrim above supplies whatever darkening legibility still needs.
        view.material = .fullScreenUI
        // The panel never becomes key, so following window state would leave
        // the blur permanently inert.
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        // The notch swaps both its radii between the tight collapsed profile
        // and the softer expanded bubble; the pill's radii are constant.
        if let notchMask = view as? HangingNotchMaskVisualEffectView {
            notchMask.apply(bottomCornerRadius: bottomCornerRadius)
            notchMask.apply(topShoulderRadius: topShoulderRadius)
        }
    }
}

/// Behind-window blur masked to the bubble/capsule silhouette. The corner
/// radius clamps to the half-height, so the mask must be re-derived as the
/// expand spring changes the view's size; regeneration only happens while the
/// clamped radius is actually moving, and the image itself stays tiny.
private final class BubbleMaskVisualEffectView: NSVisualEffectView {
    private let bottomCornerRadius: CGFloat
    private var installedRadius: CGFloat = -1

    init(bottomCornerRadius: CGFloat = HangingNotchMetrics.bottomCornerRadius) {
        self.bottomCornerRadius = bottomCornerRadius
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("not used")
    }

    override func layout() {
        super.layout()
        let radius = min(
            bottomCornerRadius,
            bounds.width / 2,
            bounds.height / 2
        )
        guard radius > 0, radius != installedRadius else { return }
        installedRadius = radius
        maskImage = Self.bubbleMask(radius: radius)
    }

    /// Stretchable rounded-rect mask: all four arcs live inside the cap
    /// insets, so resizing stretches only the flat middle.
    private static func bubbleMask(radius: CGFloat) -> NSImage {
        let size = NSSize(width: radius * 2 + 4, height: radius * 2 + 4)
        let image = NSImage(size: size, flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.addPath(CGPath(
                roundedRect: rect,
                cornerWidth: radius,
                cornerHeight: radius,
                transform: nil
            ))
            context.setFillColor(.black)
            context.fillPath()
            return true
        }
        image.capInsets = NSEdgeInsets(
            top: radius, left: radius, bottom: radius, right: radius
        )
        image.resizingMode = .stretch
        return image
    }
}

/// Behind-window blur masked to the hanging-notch silhouette. The notch's
/// corner radii scale proportionally with the height (so the collapsed bar
/// keeps tight shoulders around the camera cutout while the expanded card
/// opens into a soft bubble), and the radius itself swaps between the collapsed
/// and expanded profiles mid-transition. A fixed mask cannot express either
/// motion, so the mask is re-derived from the current bounds + radius whenever
/// the proportional-scaled radius actually changes — the same pattern as the
/// bubble, and just as cheap (the image stays tiny; regeneration only runs
/// while the scaled radius is moving, a short range at the start of the spring).
private final class HangingNotchMaskVisualEffectView: NSVisualEffectView {
    private var bottomCornerRadius: CGFloat
    private var topShoulderRadius: CGFloat
    private var installedRadiusKey: (CGFloat, CGFloat) = (-1, -1)

    init(
        bottomCornerRadius: CGFloat = HangingNotchMetrics.bottomCornerRadius,
        topShoulderRadius: CGFloat = HangingNotchMetrics.topShoulderRadius
    ) {
        self.bottomCornerRadius = bottomCornerRadius
        self.topShoulderRadius = topShoulderRadius
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("not used")
    }

    /// Push the expanded/collapsed bottom radius swap from the representable.
    func apply(bottomCornerRadius: CGFloat) {
        guard bottomCornerRadius != self.bottomCornerRadius else { return }
        self.bottomCornerRadius = bottomCornerRadius
        installedRadiusKey = (-1, -1)
        needsLayout = true
    }

    /// Push the expanded/collapsed top shoulder swap from the representable.
    func apply(topShoulderRadius: CGFloat) {
        guard topShoulderRadius != self.topShoulderRadius else { return }
        self.topShoulderRadius = topShoulderRadius
        installedRadiusKey = (-1, -1)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        // Mirror the hanging-notch path's proportional scaling exactly: when
        // the bar is shorter than both preferred radii, the path shrinks them
        // together so the collapsed silhouette still hugs the hardware cutout.
        // The mask must follow, or the blur would clip to the wrong corner
        // size while the SwiftUI scrim animates through the expanded profile.
        let constrainedTop = min(
            topShoulderRadius, bounds.width / 2
        )
        let constrainedBottom = min(
            bottomCornerRadius,
            max(0, (bounds.width - 2 * constrainedTop) / 2)
        )
        let total = constrainedTop + constrainedBottom
        let scale = total > 0 ? min(1, bounds.height / total) : 1
        let topRadius = constrainedTop * scale
        let bottomRadius = constrainedBottom * scale
        let key = (topRadius, bottomRadius)
        guard bottomRadius > 0, key != installedRadiusKey else { return }
        installedRadiusKey = key
        maskImage = Self.hangingNotchMask(
            topRadius: topRadius, bottomRadius: bottomRadius
        )
    }

    /// Stretchable hanging-notch mask: the concave shoulders and rounded
    /// bottom arcs live inside the cap-inset margins, so resizing during the
    /// expand spring stretches only the flat sides.
    private static func hangingNotchMask(
        topRadius: CGFloat, bottomRadius: CGFloat
    ) -> NSImage {
        let side = topRadius + bottomRadius
        let size = NSSize(
            width: side * 2 + 4, height: topRadius + bottomRadius + 4
        )
        let image = NSImage(size: size, flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.addPath(HangingNotchGeometry.path(
                in: rect,
                topShoulderRadius: topRadius,
                bottomCornerRadius: bottomRadius
            ))
            context.setFillColor(.black)
            context.fillPath()
            return true
        }
        image.capInsets = NSEdgeInsets(
            top: topRadius, left: side, bottom: bottomRadius, right: side
        )
        image.resizingMode = .stretch
        return image
    }
}
