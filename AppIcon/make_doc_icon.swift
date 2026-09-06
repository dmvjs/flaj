import AppKit

func makeDocIcon() -> NSImage {
    let size: CGFloat = 1024
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else { fatalError() }

    // Page silhouette (Finder's generic document convention).
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
    ctx.setFillColor(NSColor(calibratedRed: 1.0, green: 0.35, blue: 0.6, alpha: 1).cgColor)
    ctx.addPath(page)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.setStrokeColor(NSColor.black.withAlphaComponent(0.12).cgColor)
    ctx.setLineWidth(size * 0.006)
    ctx.addPath(page)
    ctx.strokePath()

    let foldPath = CGMutablePath()
    foldPath.move(to: CGPoint(x: pageRect.maxX - fold, y: pageRect.minY))
    foldPath.addLine(to: CGPoint(x: pageRect.maxX, y: pageRect.minY + fold))
    foldPath.addLine(to: CGPoint(x: pageRect.maxX - fold, y: pageRect.minY + fold))
    foldPath.closeSubpath()
    ctx.setFillColor(NSColor.black.withAlphaComponent(0.08).cgColor)
    ctx.addPath(foldPath)
    ctx.fillPath()

    // A single furious, glowing red eye at the center of the page.
    let center = CGPoint(x: size * 0.5, y: pageRect.midY + size * 0.05)
    let eyeRadius = size * 0.16
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: size * 0.03, color: NSColor(calibratedRed: 1, green: 0.15, blue: 0.05, alpha: 0.9).cgColor)
    ctx.setFillColor(NSColor(calibratedRed: 1.0, green: 0.85, blue: 0.55, alpha: 1).cgColor)
    ctx.addEllipse(in: CGRect(x: center.x - eyeRadius, y: center.y - eyeRadius, width: eyeRadius * 2, height: eyeRadius * 2))
    ctx.fillPath()
    ctx.restoreGState()

    let pupilWidth = eyeRadius * 0.34
    let pupilHeight = eyeRadius * 1.5
    ctx.setFillColor(NSColor(calibratedRed: 1.0, green: 0.15, blue: 0.05, alpha: 1).cgColor)
    ctx.addEllipse(in: CGRect(x: center.x - pupilWidth / 2, y: center.y - pupilHeight / 2, width: pupilWidth, height: pupilHeight))
    ctx.fillPath()

    // Angry brows — two dark wedges scowling down toward the center.
    for side in [-1.0, 1.0] as [CGFloat] {
        let browOuter = CGPoint(x: center.x + side * eyeRadius * 1.9, y: center.y + eyeRadius * 1.3)
        let browInner = CGPoint(x: center.x + side * eyeRadius * 0.5, y: center.y + eyeRadius * 0.55)
        let brow = CGMutablePath()
        brow.move(to: browOuter)
        brow.addLine(to: browInner)
        brow.addLine(to: CGPoint(x: browOuter.x, y: browOuter.y - eyeRadius * 0.5))
        brow.closeSubpath()
        ctx.setFillColor(NSColor(calibratedRed: 0.25, green: 0.0, blue: 0.08, alpha: 1).cgColor)
        ctx.addPath(brow)
        ctx.fillPath()
    }

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
    let labelOrigin = CGPoint(x: size / 2 - labelSize.width / 2 + size * 0.01, y: pageRect.minY + size * 0.06)
    label.draw(at: labelOrigin)

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
