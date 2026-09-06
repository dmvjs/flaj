import AppKit

/// Line-number gutter for CodeEditorView, drawn directly in the text view's
/// own draw pass rather than via NSRulerView/NSScrollView's ruler mechanism
/// — that combination was found to interfere with keyDown delivery to the
/// text view (typing stopped working entirely once a vertical ruler was
/// attached, confirmed by disabling it and watching typing resume). Drawing
/// the gutter ourselves, reserved via textContainerInset, sidesteps
/// whatever that interaction was without depending on understanding it.
final class LineNumberTextView: NSTextView {
    static let gutterWidth: CGFloat = 34

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawLineNumbers(in: dirtyRect)
    }

    private func drawLineNumbers(in dirtyRect: NSRect) {
        guard let layoutManager, let container = textContainer else { return }

        let visible = enclosingScrollView?.documentVisibleRect ?? bounds
        let gutterRect = NSRect(x: visible.minX, y: dirtyRect.minY, width: Self.gutterWidth, height: dirtyRect.height)
        NSColor.controlBackgroundColor.setFill()
        gutterRect.fill()

        let content = string as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: NSColor.secondaryLabelColor
        ]

        guard content.length > 0, layoutManager.numberOfGlyphs > 0 else {
            let numberString = "1"
            let size = numberString.size(withAttributes: attrs)
            numberString.draw(at: NSPoint(x: gutterRect.maxX - size.width - 6, y: textContainerInset.height),
                               withAttributes: attrs)
            return
        }

        let glyphRange = layoutManager.glyphRange(forBoundingRect: visible, in: container)
        guard glyphRange.location != NSNotFound else { return }
        let firstCharIndex = layoutManager.characterIndexForGlyph(at: glyphRange.location)
        var lineNumber = content.substring(to: min(firstCharIndex, content.length)).components(separatedBy: "\n").count

        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { rectForLine, _, _, glyphRangeForLine, _ in
            let charRange = layoutManager.characterRange(forGlyphRange: glyphRangeForLine, actualGlyphRange: nil)
            let y = rectForLine.minY + self.textContainerInset.height
            let numberString = "\(lineNumber)"
            let size = numberString.size(withAttributes: attrs)
            numberString.draw(
                at: NSPoint(x: gutterRect.maxX - size.width - 6, y: y + (rectForLine.height - size.height) / 2),
                withAttributes: attrs
            )
            let lineText = content.substring(with: charRange)
            if lineText.hasSuffix("\n") || NSMaxRange(charRange) == content.length {
                lineNumber += 1
            }
        }
    }
}
