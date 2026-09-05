import Foundation

/// Reconciles SwiftUI hover exits with the panel's actual interactive shape.
public enum HoverInteraction {
    public static func shouldCollapse(isExpanded: Bool, isHoveringPanel: Bool) -> Bool {
        isExpanded && !isHoveringPanel
    }

    /// Resolves the AppKit event gate independently from SwiftUI's animated
    /// geometry. On expansion, the whole reusable canvas becomes clickable.
    public static func interactiveFrame(
        compactFrame: DisplayFrame,
        expandedPanelWidth: CGFloat,
        expandedMaximumHeight: CGFloat,
        measuredContentHeight: CGFloat,
        isExpanded: Bool,
        expandedTopInset: CGFloat? = nil
    ) -> DisplayFrame {
        guard isExpanded else { return compactFrame }
        let maximumHeight = max(compactFrame.height, expandedMaximumHeight)
        let hasMeasurement = measuredContentHeight.isFinite && measuredContentHeight > compactFrame.height
        let height = hasMeasurement ? min(measuredContentHeight, maximumHeight) : maximumHeight
        return DisplayFrame(
            minX: 0,
            minY: expandedTopInset ?? compactFrame.minY,
            width: max(0, expandedPanelWidth),
            height: max(0, height)
        )
    }

    public static func shouldScheduleExpansion(
        pointer: DisplayPoint,
        compactFrame: DisplayFrame,
        panelOriginX: CGFloat,
        panelTopY: CGFloat,
        isExpanded: Bool,
        cornerStyle: HangingNotchCornerStyle = .hangingNotch,
        topShoulderRadius: CGFloat = 0,
        bottomCornerRadius: CGFloat = 0
    ) -> Bool {
        guard !isExpanded else { return false }
        let localX = pointer.x - panelOriginX - compactFrame.minX
        let localY = panelTopY - compactFrame.minY - pointer.y
        return HangingNotchGeometry.contains(
            DisplayPoint(x: localX, y: localY),
            width: compactFrame.width,
            height: compactFrame.height,
            style: cornerStyle,
            topShoulderRadius: topShoulderRadius,
            bottomCornerRadius: bottomCornerRadius
        )
    }
}
