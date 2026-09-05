import AppKit
import CoreGraphics
import ScreenCaptureKit

import PetaloCore

/// ScreenCaptureKit boundary. It receives only a previously validated
/// normalized rectangle and creates a PNG in memory; no capture is written to
/// a temporary file or logged.
/// A finished capture: the in-memory PNG that travels to the destination, plus
/// the source `CGImage` it was encoded from.
///
/// The image is handed back so the release ripple can run the Metal shader on
/// the actual captured pixels — decoding the PNG again would mean a full
/// decode on the main thread at the exact moment the animation has to start.
/// It never leaves the process: same in-memory-only contract as the payload.
struct CapturedRegion {
    let payload: AssistantImagePayload
    let image: CGImage
}

@MainActor
final class ScreenRegionCaptureProvider {
    enum CaptureError: Error {
        case displayUnavailable
        case invalidRegion
        case imageEncodingFailed
    }

    func requestPermissionIfNeeded() -> Bool {
        guard !CGPreflightScreenCaptureAccess() else { return true }
        _ = CGRequestScreenCaptureAccess()
        return false
    }

    func capture(
        region: NormalizedScreenRegion,
        excluding petaloWindows: [NSWindow]
    ) async throws -> CapturedRegion {
        let region = region.clampedToDisplay()
        guard region.hasArea else { throw CaptureError.invalidRegion }
        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        let displayID = CGDirectDisplayID(region.displayID)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw CaptureError.displayUnavailable
        }

        let petaloWindowIDs = Set(petaloWindows.map { CGWindowID($0.windowNumber) })
        let excludedWindows = content.windows.filter { petaloWindowIDs.contains($0.windowID) }
        let filter = SCContentFilter(display: display, excludingWindows: excludedWindows)
        let pixelWidth = max(1, Int(CGDisplayPixelsWide(displayID)))
        let pixelHeight = max(1, Int(CGDisplayPixelsHigh(displayID)))
        let sourceRect = Self.sourceRect(
            for: region,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight
        )
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = sourceRect
        configuration.width = max(1, Int(sourceRect.width.rounded()))
        configuration.height = max(1, Int(sourceRect.height.rounded()))
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        )
        guard let png = NSBitmapImageRep(cgImage: image).representation(
            using: .png,
            properties: [:]
        ) else {
            throw CaptureError.imageEncodingFailed
        }
        return CapturedRegion(
            payload: AssistantImagePayload(data: png, mimeType: "image/png"),
            image: image
        )
    }

    private static func sourceRect(
        for region: NormalizedScreenRegion,
        pixelWidth: Int,
        pixelHeight: Int
    ) -> CGRect {
        // ScreenCaptureKit source rectangles have a top-leading origin while
        // AppKit's display frame used by the selector has a bottom-leading one.
        let x = CGFloat(pixelWidth) * clamp(region.x)
        let width = CGFloat(pixelWidth) * clamp(region.width)
        let height = CGFloat(pixelHeight) * clamp(region.height)
        let y = CGFloat(pixelHeight) * clamp(1 - region.y - region.height)
        return CGRect(
            x: min(max(x, 0), CGFloat(pixelWidth - 1)),
            y: min(max(y, 0), CGFloat(pixelHeight - 1)),
            width: min(max(width, 1), CGFloat(pixelWidth)),
            height: min(max(height, 1), CGFloat(pixelHeight))
        )
    }

    private static func clamp(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }
}
