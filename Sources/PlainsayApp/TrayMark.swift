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

    /// - Parameter height: point size to render at; width follows the
    ///   source's aspect ratio. 16pt matches a standard menu bar glyph.
    static func image(height: CGFloat = 16) -> NSImage {
        let scale = height / viewBox.height
        let size = NSSize(width: viewBox.width * scale, height: height)

        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.setFill()
            for (x, y, w, h) in bars {
                // SVG y grows downward; AppKit's flipped:false context grows
                // upward, so flip around the viewBox height to match.
                let barRect = NSRect(
                    x: x * scale,
                    y: (viewBox.height - y - h) * scale,
                    width: w * scale,
                    height: h * scale
                )
                NSBezierPath(roundedRect: barRect, xRadius: barRect.width / 2, yRadius: barRect.width / 2)
                    .fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}

/// SwiftUI wrapper for the menu bar label.
struct TrayMarkView: View {
    var height: CGFloat = 16

    var body: some View {
        Image(nsImage: TrayMark.image(height: height))
    }
}
