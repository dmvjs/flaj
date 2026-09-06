import AppKit

func makeDocIcon() -> NSImage {
    let size: CGFloat = 1024
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else { fatalError() }

    // Page silhouette: rounded rect with a folded top-right corner,
    // matching Finder's generic document-icon convention.
    let margin = size * 0.14
    let pageRect = CGRect(x: margin, y: size * 0.04, width: size - margin * 2, height: size - size * 0.10)
    let fold = pageRect.width * 0.28
    let corner = pageRect.width * 0.05

    let page = CGMutablePath()
    page.move(to: CGPoint(x: pageRect.minX + corner, y: pageRect.minY))
    page.addLine(to: CGPoint(x: pageRect.maxX - fold, y: pageRect.minY))
    page.addLine(to: CGPoint(x: pageRect.maxX, y: pageRect.minY + fold))
    page.addLine(to: CGPoint(x: pageRect.maxX, y: pageRect.maxY - corner))
    page.addArc(center: CGPoint(x: pageRect.maxX - corner, y: pageRect.maxY - corner), radius: corner,
                startAngle: 0, endAngle: .pi / 2, clockwise: false)
    page.addLine(to: CGPoint(x: pageRect.minX + corner, y: pageRect.maxY))
    page.addArc(center: CGPoint(x: pageRect.minX + corner, y: pageRect.maxY - corner), radius: corner,
                startAngle: .pi / 2, endAngle: .pi, clockwise: false)
    page.addLine(to: CGPoint(x: pageRect.minX, y: pageRect.minY + corner))
    page.addArc(center: CGPoint(x: pageRect.minX + corner, y: pageRect.minY + corner), radius: corner,
                startAngle: .pi, endAngle: .pi * 1.5, clockwise: false)
    page.closeSubpath()

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -size * 0.015), blur: size * 0.03,
                   color: NSColor.black.withAlphaComponent(0.28).cgColor)
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.addPath(page)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.12).cgColor)
    ctx.setLineWidth(size * 0.006)
    ctx.addPath(page)
    ctx.strokePath()

    // Folded-corner triangle, subtle gray.
    let foldPath = CGMutablePath()
    foldPath.move(to: CGPoint(x: pageRect.maxX - fold, y: pageRect.minY))
    foldPath.addLine(to: CGPoint(x: pageRect.maxX, y: pageRect.minY + fold))
    foldPath.addLine(to: CGPoint(x: pageRect.maxX - fold, y: pageRect.minY + fold))
    foldPath.closeSubpath()
    ctx.setFillColor(NSColor.black.withAlphaComponent(0.08).cgColor)
    ctx.addPath(foldPath)
    ctx.fillPath()

    // The badge: same amber/navy glyph as the app icon, scaled down,
    // centered in the page.
    let badgeCenter = CGPoint(x: size * 0.5, y: pageRect.midY + size * 0.05)
    let badgeRadius = size * 0.225

    let bgColors = [
        NSColor(calibratedRed: 1.00, green: 0.84, blue: 0.04, alpha: 1).cgColor,
        NSColor(calibratedRed: 1.00, green: 0.62, blue: 0.04, alpha: 1).cgColor
    ] as CFArray
    let bgGradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: bgColors, locations: [0, 1])!
    ctx.saveGState()
    let badgeEllipse = CGRect(x: badgeCenter.x - badgeRadius, y: badgeCenter.y - badgeRadius,
                               width: badgeRadius * 2, height: badgeRadius * 2)
    ctx.addEllipse(in: badgeEllipse)
    ctx.clip()
    ctx.drawLinearGradient(bgGradient, start: CGPoint(x: badgeEllipse.minX, y: badgeEllipse.maxY),
                            end: CGPoint(x: badgeEllipse.maxX, y: badgeEllipse.minY), options: [])
    ctx.restoreGState()

    let text = "JS"
    let font = NSFont.systemFont(ofSize: badgeRadius * 0.95, weight: .heavy)
    let textColor = NSColor(calibratedRed: 0.09, green: 0.11, blue: 0.20, alpha: 1)
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: textColor, .paragraphStyle: paragraph]
    let attrString = NSAttributedString(string: text, attributes: attrs)
    let textSize = attrString.size()
    attrString.draw(at: CGPoint(x: badgeCenter.x - textSize.width / 2 - badgeRadius * 0.12,
                                 y: badgeCenter.y - textSize.height / 2 + badgeRadius * 0.06))

    // Small play triangle badge, bottom-right of the circle.
    let playRadius = badgeRadius * 0.42
    let playCenter = CGPoint(x: badgeCenter.x + badgeRadius * 0.72, y: badgeCenter.y - badgeRadius * 0.72)
    ctx.setFillColor(NSColor(calibratedRed: 0.09, green: 0.11, blue: 0.20, alpha: 1).cgColor)
    ctx.addEllipse(in: CGRect(x: playCenter.x - playRadius, y: playCenter.y - playRadius,
                               width: playRadius * 2, height: playRadius * 2))
    ctx.fillPath()
    ctx.setStrokeColor(NSColor.white.cgColor)
    ctx.setLineWidth(size * 0.01)
    ctx.addEllipse(in: CGRect(x: playCenter.x - playRadius, y: playCenter.y - playRadius,
                               width: playRadius * 2, height: playRadius * 2))
    ctx.strokePath()
    let triSize = playRadius * 0.85
    let tri = CGMutablePath()
    tri.move(to: CGPoint(x: playCenter.x - triSize * 0.32, y: playCenter.y + triSize * 0.5))
    tri.addLine(to: CGPoint(x: playCenter.x - triSize * 0.32, y: playCenter.y - triSize * 0.5))
    tri.addLine(to: CGPoint(x: playCenter.x + triSize * 0.58, y: playCenter.y))
    tri.closeSubpath()
    ctx.setFillColor(NSColor(calibratedRed: 1.00, green: 0.84, blue: 0.04, alpha: 1).cgColor)
    ctx.addPath(tri)
    ctx.fillPath()

    // "FLAJ" wordmark near the bottom of the page.
    let labelFont = NSFont.systemFont(ofSize: size * 0.075, weight: .bold)
    let labelColor = NSColor(calibratedRed: 0.35, green: 0.35, blue: 0.37, alpha: 1)
    let labelParagraph = NSMutableParagraphStyle()
    labelParagraph.alignment = .center
    let labelAttrs: [NSAttributedString.Key: Any] = [
        .font: labelFont, .foregroundColor: labelColor, .paragraphStyle: labelParagraph,
        .kern: size * 0.008
    ]
    let label = NSAttributedString(string: "FLAJ", attributes: labelAttrs)
    let labelSize = label.size()
    label.draw(at: CGPoint(x: size / 2 - labelSize.width / 2 + size * 0.01, y: pageRect.minY + size * 0.06))

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
