import Foundation
import QuartzCore

import PetaloCore

/// Creates the private `glassBackground` `CAFilter` used by Petalo's liquid-glass
/// surfaces. The filter is built by runtime lookup on the private `CAFilter`
/// class, so this compiles on any SDK and returns `nil` wherever the private
/// machinery is missing — callers fall back to a visual-effect blur.
///
/// A freshly created filter starts from zeroed inputs, not the values a live
/// `NSGlassEffectView` carries, so the recovered system baseline
/// (`systemClearBaseline`) is seeded first, then the caller's tuning overrides,
/// then the frost radius. The baseline is reference data recovered from a live
/// `NSGlassEffectView` in `.clear` style (240×120, corner radius 20) via
/// keyed-archive inspection; it is not logic that changes.
enum PetaloGlassFilter {
    /// `inputSourceSublayerName` pairs the backdrop with the SDF source layer
    /// the glassBackground filter resolves refraction through. The lens
    /// geometry lives in that sublayer stack — without it the filter blurs but
    /// never refracts.
    static let sdfSourceSublayerName = "@0"

    /// Input values recovered from a live `NSGlassEffectView` in `.clear`
    /// style. Applied before the caller's overrides and the frost radius.
    static let systemClearBaseline: [String: Any] = [
        "inputSourceSublayerName": sdfSourceSublayerName,
        "inputClamp": 1,
        "inputClampPreserveHue": false,
        "inputMaxHeadroom": 9999,
        // Blur: radius with five distance/opacity bands.
        "inputBlurRadius": 10,
        "inputBlurOpacity0": 1, "inputBlurDistance0": 0,
        "inputBlurOpacity1": 1, "inputBlurDistance1": 0,
        "inputBlurOpacity2": 1, "inputBlurDistance2": 0,
        "inputBlurOpacity3": 1, "inputBlurDistance3": 0,
        "inputBlurOpacity4": 1, "inputBlurDistance4": 0,
        // Refraction (the lensing itself).
        "inputInnerRefractionAmount": -60,
        "inputInnerRefractionHeight": 20,
        "inputOuterRefractionAmount": 0,
        "inputOuterRefractionHeight": 0,
        "inputRefractionDistance0": -1,
        "inputRefractionDistance1": -0.5,
        "inputRefractionOpacity": 0,
        // Face wash.
        "inputFaceOpacity": 1,
        "inputFaceColorMatrixBlack": 0.05,
        "inputFaceColorMatrixWhite": 0.8,
        "inputFaceColorMatrixSaturation": 1,
        "inputFaceColorMatrixFillColor": CGColor(red: 1, green: 1, blue: 1, alpha: 0.05),
        // Edge light bleed.
        "inputBleedAmount": 0,
        "inputBleedOpacity": 0,
        "inputBleedHeight": 0,
        "inputBleedBlurRadius": 0,
        "inputBleedDistance0": 1,
        "inputBleedDistance1": 0,
        "inputBleedDarkenBlend": true,
        "inputBleedColorMatrixBlack": 0.75,
        "inputBleedColorMatrixWhite": 1,
        "inputBleedColorMatrixSaturation": 1.2,
        // Contact shadow (disabled by zero opacity in clear style).
        "inputShadowOpacity": 0,
        "inputShadowAmount": 75,
        "inputShadowHeight": 48,
        "inputShadowRadius": 0,
        "inputShadowBlurRadius": 0,
        "inputShadowOffset": NSValue(size: NSSize(width: 0, height: 8)),
        "inputShadowDistanceOffset": 0,
        "inputShadowVibrancyContribution": 0,
        "inputShadowColorMatrixBlack": 0,
        "inputShadowColorMatrixWhite": 1,
        "inputShadowColorMatrixSaturation": 1.2,
        "inputShadowColorMatrixFillColor": CGColor(red: 0, green: 0, blue: 0, alpha: 0.1),
        // SDR/tone-mapping bookkeeping.
        "inputSDRGradientDistance0": 0,
        "inputSDRGradientDistance1": 0,
        "inputSDRShadowOpacity": 0,
        "inputSDRHoldingToneEnabled": false,
        "inputSDRHoldingToneWhite": 1,
    ]

    /// Builds a private `glassBackground` filter seeded with the system
    /// baseline, then `overrides`, then the frost radius applied to
    /// `inputBlurRadius`. Returns `nil` where the private filter machinery is
    /// missing so the caller can fall back to a visual-effect blur.
    static func make(
        frostRadius: Double = NotchGlassStyle.defaultFrostRadius,
        overrides: [String: Double] = NotchGlassStyle.glassFilterOverrides
    ) -> NSObject? {
        guard let filterClass = NSClassFromString("CAFilter") as AnyObject?,
              filterClass.responds(to: NSSelectorFromString("filterWithType:")),
              let filter = filterClass
                  .perform(NSSelectorFromString("filterWithType:"), with: "glassBackground")?
                  .takeUnretainedValue() as? NSObject
        else { return nil }
        for (key, value) in systemClearBaseline {
            filter.setValue(value, forKey: key)
        }
        for (key, value) in overrides {
            filter.setValue(value, forKey: key)
        }
        filter.setValue(frostRadius, forKey: "inputBlurRadius")
        return filter
    }
}
