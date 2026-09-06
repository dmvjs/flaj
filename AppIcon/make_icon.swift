import AppKit

func makeIcon() -> NSImage {
    let size: CGFloat = 1024
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else { fatalError() }

    let rect = CGRect(x: 0, y: 0, width: size, height: size)
    let cornerRadius = size * 0.225
    let clipPath = CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)

    ctx.saveGState()
    ctx.addPath(clipPath)
    ctx.clip()

    // Background: warm amber/gold gradient — instantly reads "JS".
    let bgColors = [
        NSColor(calibratedRed: 1.00, green: 0.84, blue: 0.04, alpha: 1).cgColor, // #FFD60A
        NSColor(calibratedRed: 1.00, green: 0.62, blue: 0.04, alpha: 1).cgColor  // #FF9F0A
    ] as CFArray
    let bgGradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: bgColors, locations: [0, 1])!
    ctx.drawLinearGradient(bgGradient, start: CGPoint(x: 0, y: size), end: CGPoint(x: size, y: 0), options: [])

    // Liquid-glass sheen: soft white glow, upper-left.
    let glowColors = [
        NSColor.white.withAlphaComponent(0.40).cgColor,
        NSColor.white.withAlphaComponent(0.0).cgColor
    ] as CFArray
    let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: glowColors, locations: [0, 1])!
    ctx.drawRadialGradient(
        glow,
        startCenter: CGPoint(x: size * 0.28, y: size * 0.78), startRadius: 0,
        endCenter: CGPoint(x: size * 0.28, y: size * 0.78), endRadius: size * 0.62,
        options: []
    )

    // "JS" glyph, bold, dark navy, shifted slightly up-left to leave room
    // for the play badge.
    let text = "JS"
    let font = NSFont.systemFont(ofSize: size * 0.46, weight: .heavy)
    let textColor = NSColor(calibratedRed: 0.09, green: 0.11, blue: 0.20, alpha: 1) // near-black navy
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    let attrs: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: textColor,
        .paragraphStyle: paragraph,
        .kern: -size * 0.01
    ]
    let attrString = NSAttributedString(string: text, attributes: attrs)
    let textSize = attrString.size()
    let textOrigin = CGPoint(x: size * 0.5 - textSize.width / 2 - size * 0.03,
                              y: size * 0.5 - textSize.height / 2 + size * 0.02)
    attrString.draw(at: textOrigin)

    ctx.restoreGState()

    // Play badge: dark navy circle, bottom-right, with an amber play
    // triangle inside — the "animation" half of the story.
    let badgeRadius = size * 0.205
    let badgeCenter = CGPoint(x: size * 0.775, y: size * 0.225)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -size * 0.01), blur: size * 0.02,
                   color: NSColor.black.withAlphaComponent(0.35).cgColor)
    ctx.setFillColor(NSColor(calibratedRed: 0.09, green: 0.11, blue: 0.20, alpha: 1).cgColor)
    ctx.addEllipse(in: CGRect(x: badgeCenter.x - badgeRadius, y: badgeCenter.y - badgeRadius,
                               width: badgeRadius * 2, height: badgeRadius * 2))
    ctx.fillPath()
    ctx.restoreGState()

    // White ring around the badge for separation against the gold background.
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.9).cgColor)
    ctx.setLineWidth(size * 0.012)
    ctx.addEllipse(in: CGRect(x: badgeCenter.x - badgeRadius, y: badgeCenter.y - badgeRadius,
                               width: badgeRadius * 2, height: badgeRadius * 2))
    ctx.strokePath()

    let triSize = badgeRadius * 0.85
    let tri = CGMutablePath()
    tri.move(to: CGPoint(x: badgeCenter.x - triSize * 0.32, y: badgeCenter.y + triSize * 0.5))
    tri.addLine(to: CGPoint(x: badgeCenter.x - triSize * 0.32, y: badgeCenter.y - triSize * 0.5))
    tri.addLine(to: CGPoint(x: badgeCenter.x + triSize * 0.58, y: badgeCenter.y))
    tri.closeSubpath()
    ctx.setFillColor(NSColor(calibratedRed: 1.00, green: 0.84, blue: 0.04, alpha: 1).cgColor)
    ctx.addPath(tri)
    ctx.fillPath()

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

let icon = makeIcon()
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
