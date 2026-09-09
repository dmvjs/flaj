import AppKit

// Shares the app icon's exact badge (see make_icon.swift) — same pink
// border, same dark near-black interior, same "Fl" wordmark — so the app
// and its documents read as one consistent identity. The only addition is
// a small folded-corner "dog-ear," the standard Mac convention for "this
// is a file produced by that app," not the app itself — without it this
// would be visually identical to AppIcon.icns in a Finder listing.
func makeDocIcon() -> NSImage {
    let size: CGFloat = 1024
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else { fatalError() }

    let flajPink = NSColor(calibratedRed: 1.0, green: 0.35, blue: 0.6, alpha: 1)

    let outerRect = CGRect(x: 0, y: 0, width: size, height: size)
    let cornerRadius = size * 0.225
    let outerPath = CGPath(roundedRect: outerRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -size * 0.015), blur: size * 0.035,
                   color: NSColor.black.withAlphaComponent(0.35).cgColor)
    ctx.setFillColor(flajPink.cgColor)
    ctx.addPath(outerPath)
    ctx.fillPath()
    ctx.restoreGState()

    let borderWidth = size * 0.09
    let innerRect = outerRect.insetBy(dx: borderWidth, dy: borderWidth)
    let innerRadius = max(0, cornerRadius - borderWidth * 0.6)
    let innerPath = CGPath(roundedRect: innerRect, cornerWidth: innerRadius, cornerHeight: innerRadius, transform: nil)
    ctx.setFillColor(NSColor(calibratedRed: 0.10, green: 0.02, blue: 0.07, alpha: 1).cgColor)
    ctx.addPath(innerPath)
    ctx.fillPath()

    let text = "Fl"
    let font = NSFont.systemFont(ofSize: size * 0.52, weight: .heavy)
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    let attrs: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: flajPink,
        .paragraphStyle: paragraph,
        .kern: -size * 0.01
    ]
    let attrString = NSAttributedString(string: text, attributes: attrs)
    let textSize = attrString.size()
    let textOrigin = CGPoint(x: size * 0.5 - textSize.width / 2,
                              y: size * 0.5 - textSize.height / 2 + size * 0.01)
    attrString.draw(at: textOrigin)

    // The dog-ear: a light triangular fold in the top-right corner, as if
    // a page corner were peeled back — clipped to the icon's own rounded
    // outline so it doesn't poke outside the badge shape.
    ctx.saveGState()
    ctx.addPath(outerPath)
    ctx.clip()

    let earSize = size * 0.24
    let earTopRight = CGPoint(x: size, y: size)
    let earPath = CGMutablePath()
    earPath.move(to: CGPoint(x: earTopRight.x - earSize, y: earTopRight.y))
    earPath.addLine(to: earTopRight)
    earPath.addLine(to: CGPoint(x: earTopRight.x, y: earTopRight.y - earSize))
    earPath.closeSubpath()

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: -size * 0.008, height: -size * 0.008), blur: size * 0.015,
                   color: NSColor.black.withAlphaComponent(0.3).cgColor)
    ctx.setFillColor(NSColor.white.withAlphaComponent(0.92).cgColor)
    ctx.addPath(earPath)
    ctx.fillPath()
    ctx.restoreGState()

    // A thin pink crease along the fold's inner edge, echoing the badge's
    // own border color instead of a plain gray line.
    let crease = CGMutablePath()
    crease.move(to: CGPoint(x: earTopRight.x - earSize, y: earTopRight.y))
    crease.addLine(to: CGPoint(x: earTopRight.x, y: earTopRight.y - earSize))
    ctx.setStrokeColor(flajPink.withAlphaComponent(0.7).cgColor)
    ctx.setLineWidth(size * 0.008)
    ctx.addPath(crease)
    ctx.strokePath()

    ctx.restoreGState()

    img.unlockFocus()
    return img
}

func pngData(from image: NSImage, size: CGFloat) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    image.draw(in: CGRect(x: 0, y: 0, width: size, height: size),
               from: .zero, operation: .copy, fraction: 1.0)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let icon = makeDocIcon()
let outDir = CommandLine.arguments[1]
let sizes: [(name: String, px: CGFloat)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for entry in sizes {
    let data = pngData(from: icon, size: entry.px)
    try! data.write(to: URL(fileURLWithPath: "\(outDir)/\(entry.name).png"))
}
print("done")
