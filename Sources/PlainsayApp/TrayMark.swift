import AppKit
import SwiftUI

/// The menu bar's own mark: five rounded bars, imported from the "Plainsay
/// macOS ikony aplikacji" Claude Design project (`assets/tray-icon.svg`) —
/// the same waveform-bar motif as `assets/logo.svg`, frozen for a 24×22 grid.
///
/// Drawn programmatically rather than shipped as an image asset: a
/// `NSImage.isTemplate` glyph is what makes AppKit tint it automatically for
/// light/dark menu bars and for the selection-highlight invert, the same
/// contract `Image(systemName:)` already relies on — a plain colored View in
/// the status item's label would lose that.
enum TrayMark {
    /// (x, y, width, height) in the source SVG's 24×22 viewBox.
    private static let bars: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
        (2, 7.5, 2, 7),
        (6.5, 5, 2, 12),
        (11, 2.5, 2, 17),
        (15.5, 5.5, 2, 11),
        (20, 8, 2, 6),
    ]
    private static let viewBox = CGSize(width: 24, height: 22)

    /// Built once per size and kept.
    ///
    /// `TrayMarkView.body` runs whenever SwiftUI re-renders the menu bar
    /// label, which is often; minting a fresh `NSImage` each time was both
    /// wasteful and one more thing happening inside `updateButton` while it
    /// was trying to rasterise the last one.
    @MainActor private static var cache: [CGFloat: NSImage] = [:]

    /// - Parameter height: point size to render at; width follows the
    ///   source's aspect ratio. 16pt matches a standard menu bar glyph.
    @MainActor static func image(height: CGFloat = 16) -> NSImage? {
        if let cached = cache[height] { return cached }
        guard let drawn = draw(height: height) else { return nil }
        cache[height] = drawn
        return drawn
    }

    /// Rasterised eagerly, into a representation that exists before anyone
    /// asks for it.
    ///
    /// This used to be `NSImage(size:flipped:drawingHandler:)`, which draws
    /// *lazily*: the image carries no bitmap until something rasterises it.
    /// SwiftUI's menu-bar label does that inside `MenuBarExtraController
    /// .updateButton`, and on macOS 26.6.2 that path traps — the app shows its
    /// icon for a moment and quits, reported from the field and reproduced on
    /// no machine here. Handing over an image that is already a bitmap takes
    /// that conversion out of the equation entirely.
    private static func draw(height: CGFloat) -> NSImage? {
        let scale = height / viewBox.height
        let size = NSSize(width: viewBox.width * scale, height: height)
        guard size.width > 0, size.height > 0 else { return nil }

        // Backing scale of the widest display, so the glyph stays crisp on
        // Retina without assuming which screen the menu bar is on.
        let backing = NSScreen.screens.map(\.backingScaleFactor).max() ?? 2
        let pixelsWide = Int((size.width * backing).rounded())
        let pixelsHigh = Int((size.height * backing).rounded())
        guard pixelsWide > 0, pixelsHigh > 0,
              let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: pixelsWide, pixelsHigh: pixelsHigh,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
              )
        else { return nil }
        rep.size = size

        guard let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        NSColor.black.setFill()
        for (x, y, w, h) in bars {
            // SVG y grows downward; the context grows upward, so flip around
            // the viewBox height to match.
            let barRect = NSRect(
                x: x * scale,
                y: (viewBox.height - y - h) * scale,
                width: w * scale,
                height: h * scale
            )
            NSBezierPath(roundedRect: barRect, xRadius: barRect.width / 2, yRadius: barRect.width / 2)
                .fill()
        }
        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: size)
        image.addRepresentation(rep)
        image.isTemplate = true
        return image
    }
}

/// SwiftUI wrapper for the menu bar label.
struct TrayMarkView: View {
    var height: CGFloat = 16

    var body: some View {
        // Falls back to the stock glyph rather than to nothing. The mark is
        // decoration; the menu bar item is how the app is reached at all. A
        // cosmetic touch must never be able to take the app down with it —
        // which is exactly what happened here.
        if let mark = TrayMark.image(height: height) {
            Image(nsImage: mark)
        } else {
            Image(systemName: "waveform")
                .symbolRenderingMode(.hierarchical)
        }
    }
}
