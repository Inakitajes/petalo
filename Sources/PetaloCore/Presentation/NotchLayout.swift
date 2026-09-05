import Foundation

/// Geometry for Petalo's reusable native-notch and external-display surfaces.
/// It deliberately has no product, session, or process concepts.
public struct NotchLayout: Equatable, Sendable {
    public enum Presentation: Equatable, Sendable {
        case notch
        case pill
    }

    public enum CompactControlContent: Equatable, Sendable {
        case none
        case brandLabel
    }

    public let presentation: Presentation
    public let width: CGFloat
    public let height: CGFloat
    public let topGap: CGFloat
    public let expandedHeight: CGFloat
    public let originX: CGFloat
    public let originY: CGFloat
    public let notchWidth: CGFloat
    private let notchLeadingX: CGFloat?

    public var cornerStyle: HangingNotchCornerStyle {
        presentation == .pill ? .bubble : .hangingNotch
    }

    /// Rounded-corner radius for the surface's bottom edges. The pill uses a
    /// larger radius than the hardware notch so the expanded card reads as a
    /// softer floating bubble, matching the prompt panel's profile.
    public var effectiveBottomCornerRadius: CGFloat {
        presentation == .pill ? 28 : HangingNotchMetrics.bottomCornerRadius
    }

    /// Collapsed native notch content is empty: the leading corner no longer
    /// draws the petal mark. The bar stays full-width so the glass still masks
    /// the hardware cutout; only the glyph is gone.
    public var compactControlContent: CompactControlContent {
        presentation == .pill ? .brandLabel : .none
    }

    /// Whether the collapsed compact control draws the petal glyph. The mark
    /// has been retired from the compact bar on both presentations: the
    /// hardware notch is pure glass and the external pill keeps only the
    /// "Petalo" wordmark.
    public var compactControlShowsPetalMark: Bool {
        false
    }

    /// Compact controls occupy the space beside the hardware cutout using the
    /// same idle wings that the pre-refactor presentation used.
    public var compactLeadingWingWidth: CGFloat {
        switch presentation {
        case .notch: Self.hardwareNotchLeadingWingWidth
        case .pill: Self.pillCompactWidth / 2
        }
    }

    public var compactTrailingWingWidth: CGFloat {
        switch presentation {
        case .notch: Self.hardwareNotchTrailingWingWidth
        case .pill: Self.pillCompactWidth / 2
        }
    }

    public var compactBarWidth: CGFloat {
        switch presentation {
        case .notch: compactLeadingWingWidth + notchWidth + compactTrailingWingWidth
        case .pill: Self.pillCompactWidth
        }
    }

    public var compactBarLeadingOffset: CGFloat {
        switch presentation {
        case .notch:
            return (notchLeadingX ?? originX) - compactLeadingWingWidth - originX
        case .pill:
            return (width - compactBarWidth) / 2
        }
    }

    /// Extra vertical breathing room for an external-display bubble.
    public var expandedHeaderTopPadding: CGFloat {
        presentation == .pill ? Self.pillExpandedHeaderTopPadding : 0
    }

    /// The external-display surface floats below the menu-bar edge once open.
    public var expandedTopGap: CGFloat {
        presentation == .pill ? Self.pillExpandedTopGap : 0
    }

    public var expandedContentSideInset: CGFloat {
        presentation == .notch ? HangingNotchMetrics.topShoulderRadius : 0
    }

    /// Widths for the expanded header around a hardware camera housing.
    public func expandedHeaderWingWidths() -> (left: CGFloat, right: CGFloat) {
        switch presentation {
        case .notch:
            let left = max(0, (notchLeadingX ?? originX) - originX)
            return (left, max(0, width - left - notchWidth))
        case .pill:
            return (width / 2, width / 2)
        }
    }

    public static let expandedPanelWidth: CGFloat = 480
    public static let expandedContentWidth: CGFloat = 464
    public static let expandedCurveGutter: CGFloat = 8
    /// Space held for generic controls/content, not a list of sessions.
    public static let expandedCanvasMaximumHeight: CGFloat = 144
    public static let expandedBottomPadding: CGFloat = 8
    /// Original idle hardware-notch wings: enough room for the compact control
    /// on the left and the small finished shoulder on the right.
    public static let hardwareNotchLeadingWingWidth: CGFloat = 48
    public static let hardwareNotchTrailingWingWidth: CGFloat = 28
    /// Intrinsic width of the collapsed pill's brand label as rendered
    /// (`Text("Petalo")` at 12pt semibold rounded, no petal glyph), measured
    /// with `NSHostingController.sizeThatFits`.
    public static let pillCompactContentWidth: CGFloat = 37
    /// Breathing room between the capsule's rounded ends and that label. The
    /// collapsed width is derived from it rather than hardcoded, so this is
    /// the single knob for how tightly the pill hugs its content.
    public static let pillCompactHorizontalPadding: CGFloat = 16
    public static let pillCompactWidth: CGFloat = pillCompactContentWidth
        + 2 * pillCompactHorizontalPadding
    public static let pillBottomInset: CGFloat = 4
    public static let pillTopGap: CGFloat = 4
    public static let pillExpandedTopGap: CGFloat = 20
    public static let pillExpandedHeaderTopPadding: CGFloat = 14
    public static let fallbackMenuBarHeight: CGFloat = 24

    public static func contentWidth(forExpandedPanelWidth panelWidth: CGFloat) -> CGFloat {
        guard panelWidth.isFinite else { return 1 }
        return min(expandedContentWidth, max(1, panelWidth - 2 * expandedCurveGutter))
    }

    public init(
        screenMinX: CGFloat,
        screenWidth: CGFloat,
        screenMaxY: CGFloat,
        safeAreaTop: CGFloat,
        leftNotchEdgeX: CGFloat?,
        rightNotchEdgeX: CGFloat?,
        menuBarHeight: CGFloat = 0
    ) {
        let usableScreenWidth = max(1, screenWidth.isFinite ? screenWidth : 1)
        let centerX = screenMinX + usableScreenWidth / 2
        let expandedWidth = min(Self.expandedPanelWidth, usableScreenWidth)
        if safeAreaTop.isFinite, safeAreaTop > 0,
           let leftNotchEdgeX, let rightNotchEdgeX,
           leftNotchEdgeX.isFinite, rightNotchEdgeX.isFinite,
           rightNotchEdgeX > leftNotchEdgeX {
            presentation = .notch
            notchLeadingX = leftNotchEdgeX
            topGap = 0
            height = safeAreaTop
            // Keep the pre-refactor minimum housing width: macOS can report a
            // narrower auxiliary gap on some notched displays, but the native
            // presentation was tuned around at least this camera band.
            notchWidth = max(rightNotchEdgeX - leftNotchEdgeX, 168)
            width = expandedWidth
            let notchCenterX = (leftNotchEdgeX + rightNotchEdgeX) / 2
            originX = min(
                max(notchCenterX - width / 2, screenMinX),
                screenMinX + usableScreenWidth - width
            )
            originY = screenMaxY - height
        } else {
            presentation = .pill
            notchLeadingX = nil
            let menuBar = menuBarHeight > 0 ? menuBarHeight : Self.fallbackMenuBarHeight
            topGap = Self.pillTopGap
            height = max(1, menuBar - Self.pillTopGap - Self.pillBottomInset)
            notchWidth = 0
            width = expandedWidth
            originX = centerX - width / 2
            originY = screenMaxY - height
        }
        expandedHeight = height + Self.expandedCanvasMaximumHeight + Self.expandedBottomPadding
            + (presentation == .pill ? Self.pillExpandedTopGap + Self.pillExpandedHeaderTopPadding : 0)
    }
}
