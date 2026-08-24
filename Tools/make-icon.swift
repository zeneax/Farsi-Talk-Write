import AppKit
import Foundation

// Generates AppIcon.icns from code, so the icon is reproducible and reviewable
// rather than an opaque binary checked into the repo.
//
//   swiftc Tools/make-icon.swift -o /tmp/make-icon && /tmp/make-icon <out-dir>

let outputDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let iconsetURL = URL(fileURLWithPath: outputDir).appendingPathComponent("AppIcon.iconset")

try? FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

/// Draws the icon at a given pixel size.
func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()

    guard let context = NSGraphicsContext.current?.cgContext else {
        image.unlockFocus()
        return image
    }
    context.setShouldAntialias(true)
    context.interpolationQuality = .high

    // macOS app icons sit inside a rounded "squircle" with breathing room around it.
    let inset = size * 0.09
    let rect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let radius = rect.width * 0.225
    let squircle = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

    // Warm violet → indigo gradient. Distinct in a Dock full of blue utilities.
    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.54, green: 0.30, blue: 0.86, alpha: 1.0),
        NSColor(calibratedRed: 0.28, green: 0.20, blue: 0.62, alpha: 1.0),
    ])
    squircle.addClip()
    gradient?.draw(in: rect, angle: -90)

    // Soft highlight across the top so the face is not flat.
    let highlight = NSGradient(colors: [
        NSColor(white: 1.0, alpha: 0.22),
        NSColor(white: 1.0, alpha: 0.0),
    ])
    highlight?.draw(in: NSRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height / 2), angle: -90)

    NSGraphicsContext.current?.cgContext.resetClip()

    // Microphone glyph, drawn as paths so the icon does not depend on SF Symbols
    // being renderable at build time.
    let cx = rect.midX
    let capsuleWidth = rect.width * 0.20
    let capsuleHeight = rect.height * 0.34
    let capsuleY = rect.minY + rect.height * 0.44

    NSColor.white.setFill()

    let capsule = NSBezierPath(
        roundedRect: NSRect(
            x: cx - capsuleWidth / 2,
            y: capsuleY,
            width: capsuleWidth,
            height: capsuleHeight
        ),
        xRadius: capsuleWidth / 2,
        yRadius: capsuleWidth / 2
    )
    capsule.fill()

    // The cradle arc under the capsule.
    let cradleRadius = rect.width * 0.175
    let lineWidth = rect.width * 0.052
    let cradleCenterY = capsuleY + capsuleHeight * 0.16

    let cradle = NSBezierPath()
    cradle.appendArc(
        withCenter: NSPoint(x: cx, y: cradleCenterY),
        radius: cradleRadius,
        startAngle: 200,
        endAngle: 340,
        clockwise: false
    )
    cradle.lineWidth = lineWidth
    cradle.lineCapStyle = .round
    NSColor.white.setStroke()
    cradle.stroke()

    // Stem down to the base. Kept short so the Farsi glyph below has clear air
    // around it rather than colliding with the stem's rounded cap.
    let stemTop = cradleCenterY - cradleRadius
    let stemBottom = rect.minY + rect.height * 0.315
    let stem = NSBezierPath()
    stem.move(to: NSPoint(x: cx, y: stemTop))
    stem.line(to: NSPoint(x: cx, y: stemBottom))
    stem.lineWidth = lineWidth
    stem.lineCapStyle = .round
    stem.stroke()

    // Base bar, so the mic reads as a mic even when the glyph is dropped at 16px.
    let baseWidth = rect.width * 0.26
    let base = NSBezierPath()
    base.move(to: NSPoint(x: cx - baseWidth / 2, y: stemBottom))
    base.line(to: NSPoint(x: cx + baseWidth / 2, y: stemBottom))
    base.lineWidth = lineWidth
    base.lineCapStyle = .round
    base.stroke()

    // Persian "ف" sits under the mic, marking this as the Farsi tool at a glance.
    // Only drawn at sizes where it stays legible.
    if size >= 64 {
        let glyph = "ف" as NSString
        let fontSize = rect.height * 0.17
        let font = NSFont(name: "Geeza Pro Bold", size: fontSize)
            ?? NSFont(name: "Geeza Pro", size: fontSize)
            ?? NSFont.systemFont(ofSize: fontSize, weight: .bold)

        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor(white: 1.0, alpha: 0.92),
        ]
        let textSize = glyph.size(withAttributes: attributes)
        glyph.draw(
            at: NSPoint(
                x: cx - textSize.width / 2,
                y: rect.minY + rect.height * 0.055
            ),
            withAttributes: attributes
        )
    }

    image.unlockFocus()
    return image
}

func writePNG(_ image: NSImage, pixels: Int, to url: URL) throws {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false,
        colorSpaceName: .calibratedRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    ) else { return }

    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()

    guard let data = rep.representation(using: .png, properties: [:]) else { return }
    try data.write(to: url)
}

// The set of sizes iconutil expects.
let variants: [(name: String, pixels: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

for variant in variants {
    let image = drawIcon(size: CGFloat(variant.pixels))
    let url = iconsetURL.appendingPathComponent(variant.name)
    do {
        try writePNG(image, pixels: variant.pixels, to: url)
    } catch {
        FileHandle.standardError.write(Data("failed \(variant.name): \(error)\n".utf8))
        exit(1)
    }
}

print("wrote \(variants.count) images to \(iconsetURL.path)")
