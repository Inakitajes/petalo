import AppKit
import QuartzCore

import PetaloCore

/// Self-owned Liquid Glass over a plain rounded-rect lens. Same private layer
/// recipe as `NotchCustomGlassView` — a `CABackdropLayer` running the private
/// `glassBackground` filter, with a `CASDFLayer`/`CASDFElementLayer` stack that
/// produces the signed distance field the filter refracts through — but with a
/// simple rounded-rect silhouette and gentler refraction tuned for a large
/// drag area instead of the notch's hardware-hugging profile.
///
/// `windowServerAware` makes the backdrop sample the actual screen content
/// behind the clear overlay panel (not the panel's own layer tree), so the
/// live drag reads as clear glass with refracted borders: the inside stays
/// transparent and the rounded edges lens whatever sits underneath.
///
/// Refraction scales with the selection's smaller dimension: a small drag
/// carries subtle edge lensing, a large one gets the full aberration. The
/// glass filter is rebuilt only when the ratio crosses a 5% step, so a drag
/// rebuilds it ~20 times total, not on every mouse sample.
final class RoundedGlassView: NSView {
    private let frostRadius: Double
    private let maxInnerAmount: Double
    private let maxInnerHeight: Double
    private let maxOuterAmount: Double
    private let maxOuterHeight: Double
    private let refractionReferenceSize: CGFloat
    private var cornerRadius: CGFloat
    private let shapeMask = CAShapeLayer()
    private var backdrop: CALayer?
    private var sdfLayer: CALayer?
    private var sdfContainer: CALayer?
    private var sdfElement: CALayer?
    /// Last refraction pushed into the filter, quantized to a 5% step so the
    /// filter rebuilds only when the ratio actually moves a step.
    private var appliedRefraction: ScaledRefraction?

    init(
        frostRadius: Double,
        cornerRadius: CGFloat,
        maxInnerAmount: Double,
        maxInnerHeight: Double,
        maxOuterAmount: Double,
        maxOuterHeight: Double,
        refractionReferenceSize: CGFloat
    ) {
        self.frostRadius = frostRadius
        self.cornerRadius = cornerRadius
        self.maxInnerAmount = maxInnerAmount
        self.maxInnerHeight = maxInnerHeight
        self.maxOuterAmount = maxOuterAmount
        self.maxOuterHeight = maxOuterHeight
        self.refractionReferenceSize = refractionReferenceSize
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("not used")
    }

    override var isFlipped: Bool { true }

    /// Pushes the live corner radius from the drag geometry. Cheap to call
    /// every mouse-drag event: a no-op when the clamped value hasn't moved.
    func apply(cornerRadius: CGFloat) {
        guard cornerRadius != self.cornerRadius else { return }
        self.cornerRadius = cornerRadius
        needsLayout = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        installBackdropIfNeeded()
    }

    /// The backdrop is hosted as a plain sublayer, never as the view's backing
    /// layer: AppKit stamps backing layers with a debug name ("CABackdropLayer:
    /// …View"), clobbering the "@0" name that pairs the backdrop with the SDF
    /// source the glassBackground filter resolves via
    /// `inputSourceSublayerName`.
    private func installBackdropIfNeeded() {
        guard backdrop == nil, let hostLayer = layer else { return }
        guard let backdropType = NSClassFromString("CABackdropLayer") as? CALayer.Type,
              let sdfType = NSClassFromString("CASDFLayer") as? CALayer.Type,
              let elementType = NSClassFromString("CASDFElementLayer") as? CALayer.Type,
              let effectType = NSClassFromString("CASDFOutputEffect") as? NSObject.Type,
              let filter = PetaloGlassFilter.make(
                  frostRadius: frostRadius,
                  overrides: refractionOverrides(for: .zero)
              )
        else {
            NSLog("Petalo region glass unavailable; backdrop not installed")
            return
        }

        let glass = backdropType.init()
        glass.name = PetaloGlassFilter.sdfSourceSublayerName
        glass.filters = [filter]
        // CALayer KVC tolerates arbitrary keys, so these are safe no-ops if the
        // private layer stops recognizing them.
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
        appliedRefraction = .zero
        needsLayout = true
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Clamp again here, exactly like the geometry helper does, so a
        // zero-size frame (briefly, before the first drag sample) cannot push
        // an oversized radius into the lens element.
        let clampedRadius = min(
            max(cornerRadius, 0),
            bounds.width / 2,
            bounds.height / 2
        )
        backdrop?.frame = bounds
        shapeMask.frame = bounds
        shapeMask.path = CGPath(
            roundedRect: bounds,
            cornerWidth: clampedRadius,
            cornerHeight: clampedRadius,
            transform: nil
        )
        sdfLayer?.frame = bounds
        sdfContainer?.frame = bounds
        sdfElement?.frame = bounds
        sdfElement?.cornerRadius = clampedRadius

        // Size-proportional refraction: the lensing scales with the smaller
        // dimension so a tiny drag carries subtle edges and a large one gets
        // the full aberration. Quantized to 5% steps so the filter rebuilds
        // ~20 times across a full drag, not on every mouse sample.
        let quantized = quantizedRefraction()
        if quantized != appliedRefraction, let backdrop,
           let filter = PetaloGlassFilter.make(
               frostRadius: frostRadius,
               overrides: refractionOverrides(for: quantized)
           ) {
            backdrop.filters = [filter]
            appliedRefraction = quantized
        }

        CATransaction.commit()
    }

    /// Computes the size-scaled refraction, then snaps its ratio to a 5%
    /// step so equal comparisons work and the filter rebuilds at most ~20
    /// times across a drag. The unquantized math is the same as
    /// `GlassRefractionScale.scale`; the quantization is a performance concern
    /// (not a behavioral contract), so it is allowed to diverge by a sub-step.
    private func quantizedRefraction() -> ScaledRefraction {
        guard refractionReferenceSize > 0,
              min(bounds.width, bounds.height) > 0 else {
            return .zero
        }
        let ratio = min(
            Double(min(bounds.width, bounds.height) / refractionReferenceSize),
            1.0
        )
        let quantizedRatio = (ratio * 20).rounded() / 20
        return ScaledRefraction(
            innerAmount: maxInnerAmount * quantizedRatio,
            innerHeight: maxInnerHeight * quantizedRatio,
            outerAmount: maxOuterAmount * quantizedRatio,
            outerHeight: maxOuterHeight * quantizedRatio
        )
    }

    private func refractionOverrides(for refraction: ScaledRefraction) -> [String: Double] {
        [
            "inputFaceOpacity": 0,
            "inputInnerRefractionAmount": refraction.innerAmount,
            "inputInnerRefractionHeight": refraction.innerHeight,
            "inputOuterRefractionAmount": refraction.outerAmount,
            "inputOuterRefractionHeight": refraction.outerHeight,
            // Zero out every blur band so the lens adds no diffusion at all —
            // the system baseline ships these at opacity 1, and even though a
            // zero-radius blur is a mathematical no-op, forcing the opacity to
            // 0 guarantees the lens reads as fully transparent, crystal-clear
            // glass with no residual wash.
            "inputBlurOpacity0": 0,
            "inputBlurOpacity1": 0,
            "inputBlurOpacity2": 0,
            "inputBlurOpacity3": 0,
            "inputBlurOpacity4": 0,
        ]
    }
}
