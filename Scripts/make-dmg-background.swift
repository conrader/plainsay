#!/usr/bin/env swift
// Renders the DMG's Finder-window background: an arrow between where the app
// icon and the /Applications alias sit, on Plainsay's own palette (matching
// Sources/PlainsayApp/DesignSystem.swift) rather than a generic installer
// look. Run with an output directory; writes background.png (1x) and
// background@2x.png (2x) — Finder picks the @2x variant on Retina displays
// the same way it does for any other resource, no extra wiring needed.

import AppKit

guard CommandLine.arguments.count > 1 else {
    FileHandle.standardError.write("usage: make-dmg-background.swift <output-dir>\n".data(using: .utf8)!)
    exit(1)
}
let outputDir = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

// Plainsay's palette (Sources/PlainsayApp/DesignSystem.swift).
let bone = NSColor(red: 0.949, green: 0.937, blue: 0.914, alpha: 1)
let ink = NSColor(red: 0.078, green: 0.086, blue: 0.102, alpha: 1)
let slate = NSColor(red: 0.478, green: 0.506, blue: 0.580, alpha: 1)
let signal = NSColor(red: 0.435, green: 0.827, blue: 0.780, alpha: 1)

// Window content size, in points — must match the `bounds` the release
// script sets on the Finder window so the arrow lines up with where the
// icons actually get positioned.
let width: CGFloat = 660
let height: CGFloat = 400
let iconY: CGFloat = 195
let leftIconX: CGFloat = 180
let rightIconX: CGFloat = 480

func render(scale: CGFloat) -> NSBitmapImageRep {
    let pixelSize = NSSize(width: width * scale, height: height * scale)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(pixelSize.width),
        pixelsHigh: Int(pixelSize.height),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    rep.size = NSSize(width: width, height: height)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    // No manual scaleBy: NSGraphicsContext(bitmapImageRep:) already maps
    // `rep.size` (point space, always 660x400 here) onto the bitmap's actual
    // pixel dimensions on its own — every draw call below stays in that same
    // 660x400 point space regardless of `scale`.

    // Background fill.
    bone.setFill()
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

    // A soft top-to-bottom vignette toward ink, purely decorative — keeps a
    // flat fill from looking like a placeholder.
    let gradient = NSGradient(colors: [bone, bone.blended(withFraction: 0.04, of: ink)!])!
    gradient.draw(in: NSRect(x: 0, y: 0, width: width, height: height), angle: 90)

    // Arrow, centered between the two icon slots, at icon-center height.
    let arrowMidX = (leftIconX + rightIconX) / 2
    let arrowHalfWidth: CGFloat = 44
    let shaftY = height - iconY  // NSBitmapImageRep draws bottom-up; icon Y is Finder's top-down.
    let shaftThickness: CGFloat = 5
    let headLength: CGFloat = 22
    let headHalfHeight: CGFloat = 16

    let shaftStart = CGPoint(x: arrowMidX - arrowHalfWidth, y: shaftY)
    let shaftEnd = CGPoint(x: arrowMidX + arrowHalfWidth - headLength, y: shaftY)

    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: shaftStart.x, y: shaftStart.y - shaftThickness / 2))
    arrow.line(to: NSPoint(x: shaftEnd.x, y: shaftEnd.y - shaftThickness / 2))
    arrow.line(to: NSPoint(x: shaftEnd.x, y: shaftEnd.y - headHalfHeight))
    arrow.line(to: NSPoint(x: arrowMidX + arrowHalfWidth, y: shaftY))
    arrow.line(to: NSPoint(x: shaftEnd.x, y: shaftEnd.y + headHalfHeight))
    arrow.line(to: NSPoint(x: shaftEnd.x, y: shaftEnd.y + shaftThickness / 2))
    arrow.line(to: NSPoint(x: shaftStart.x, y: shaftStart.y + shaftThickness / 2))
    arrow.close()
    signal.setFill()
    arrow.fill()

    // Caption.
    let caption = "Drag to Applications to install"
    let style = NSMutableParagraphStyle()
    style.alignment = .center
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 13, weight: .medium),
        .foregroundColor: slate,
        .paragraphStyle: style,
    ]
    let captionRect = NSRect(x: 0, y: height - iconY - 92, width: width, height: 20)
    (caption as NSString).draw(in: captionRect, withAttributes: attrs)

    NSGraphicsContext.current?.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func write(_ rep: NSBitmapImageRep, to url: URL) throws {
    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "make-dmg-background", code: 1, userInfo: [NSLocalizedDescriptionKey: "PNG encode failed"])
    }
    try data.write(to: url)
}

try write(render(scale: 1), to: outputDir.appendingPathComponent("background.png"))
try write(render(scale: 2), to: outputDir.appendingPathComponent("background@2x.png"))
print("Wrote background.png and background@2x.png to \(outputDir.path)")
