import AppKit

// Homage to the Adobe Flash Professional (CS6-era) app icon — thick
// colored border, dark near-black interior, bold "Fl" wordmark — recolored
// to Flaj's own pink (the same one FlajDoc.icns uses for .flaj files, see
// make_doc_icon.swift) instead of Flash's original red-orange.
func makeIcon() -> NSImage {
    let size: CGFloat = 1024
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else { fatalError() }

    let flajPink = NSColor(calibratedRed: 1.0, green: 0.35, blue: 0.6, alpha: 1) // matches FlajDoc.icns

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

    // Dark near-black interior, inset from the pink border — Flash's own
    // badge reads as a thick colored frame around a near-black center.
    let borderWidth = size * 0.09
    let innerRect = outerRect.insetBy(dx: borderWidth, dy: borderWidth)
    let innerRadius = max(0, cornerRadius - borderWidth * 0.6)
    let innerPath = CGPath(roundedRect: innerRect, cornerWidth: innerRadius, cornerHeight: innerRadius, transform: nil)
    ctx.setFillColor(NSColor(calibratedRed: 0.10, green: 0.02, blue: 0.07, alpha: 1).cgColor)
    ctx.addPath(innerPath)
    ctx.fillPath()

    // "Fl" wordmark, bold, in the same pink as the border.
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
