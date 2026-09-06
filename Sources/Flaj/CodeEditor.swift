import SwiftUI
import AppKit

/// A genuinely native code surface — a wrapped NSTextView, not SwiftUI's
/// TextEditor — so it's straightforward to layer in real syntax highlighting
/// and a debugger gutter later without fighting SwiftUI's text abstraction.
struct CodeEditorView: NSViewRepresentable {
    @Binding var text: String

    func makeNSView(context: Context) -> NSScrollView {
        let textView = LineNumberTextView()
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.allowsUndo = true
        textView.string = text
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainerInset = NSSize(width: LineNumberTextView.gutterWidth, height: 8)
        textView.textContainer?.widthTracksTextView = true
        textView.autoresizingMask = [.width]

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false

        if let storage = textView.textStorage {
            JSHighlighter.highlight(storage)
        }
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }
        context.coordinator.text = $text
        if textView.string != text {
            textView.string = text
            if let storage = textView.textStorage {
                JSHighlighter.highlight(storage)
            }
            textView.needsDisplay = true
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            text.wrappedValue = tv.string
            // Deferred to the next runloop tick: mutating textStorage
            // attributes synchronously from inside textDidChange can make
            // NSTextView's change-notification machinery re-enter itself
            // and stop delivering further keystrokes — a known NSTextView
            // gotcha, not specific to this highlighter.
            DispatchQueue.main.async { [weak tv] in
                guard let tv else { return }
                if let storage = tv.textStorage {
                    JSHighlighter.highlight(storage)
                }
                tv.needsDisplay = true
            }
        }
    }
}

/// Heuristic, regex-based JS/TS highlighting and a same-script static check
/// for reassigning a `const` — not a real parser (see the AST discussion:
/// that's the right long-term answer, this is the pragmatic v0 one).
enum JSHighlighter {
    private static let keywords = [
        "const", "let", "var", "function", "return", "if", "else", "for", "while", "do",
        "break", "continue", "switch", "case", "default", "new", "typeof", "instanceof",
        "true", "false", "null", "undefined", "this", "class", "extends", "try", "catch",
        "finally", "throw", "in", "of", "void", "delete", "async", "await", "import", "export"
    ]

    /// The frame-script runtime API installed by TimelineModel.makeJSContext —
    /// kept in sync by hand since the highlighter can't introspect JSContext.
    private static let globalNames = [
        "bg", "stage", "console", "trace", "stop", "play", "goto", "gotoAndPlay", "gotoAndStop"
    ]
    private static let globalMembers = [
        "color", "size", "addText", "setText", "setTransform", "tween", "log", "warn", "error"
    ]

    static func highlight(_ storage: NSTextStorage) {
        let text = storage.string
        let full = NSRange(location: 0, length: (text as NSString).length)
        guard full.length > 0 else { return }

        let baseFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let baseColor = NSColor.textColor
        let commentColor = NSColor(calibratedRed: 0.45, green: 0.55, blue: 0.48, alpha: 1)
        let stringColor = NSColor(calibratedRed: 0.95, green: 0.45, blue: 0.40, alpha: 1)
        let numberColor = NSColor(calibratedRed: 0.55, green: 0.75, blue: 0.95, alpha: 1)
        let keywordColor = NSColor(calibratedRed: 0.85, green: 0.40, blue: 0.65, alpha: 1)
        let globalColor = NSColor(calibratedRed: 0.30, green: 0.70, blue: 0.75, alpha: 1)

        storage.beginEditing()
        storage.setAttributes([.font: baseFont, .foregroundColor: baseColor], range: full)

        @discardableResult
        func colorMatches(_ pattern: String, _ color: NSColor, excluding: [NSRange] = []) -> [NSRange] {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
            var applied: [NSRange] = []
            for m in regex.matches(in: text, range: full) {
                if excluding.contains(where: { NSIntersectionRange($0, m.range).length > 0 }) { continue }
                storage.addAttribute(.foregroundColor, value: color, range: m.range)
                applied.append(m.range)
            }
            return applied
        }

        // Comments and strings are colored first and then excluded from the
        // keyword/number pass, so a keyword-looking word inside a string
        // (or a `//` inside a string) doesn't get double-colored.
        let commentRanges = colorMatches(#"//[^\n]*"#, commentColor)
            + colorMatches(#"/\*[\s\S]*?\*/"#, commentColor)
        let stringRanges = colorMatches(#""(?:\\.|[^"\\])*""#, stringColor, excluding: commentRanges)
            + colorMatches(#"'(?:\\.|[^'\\])*'"#, stringColor, excluding: commentRanges)
            + colorMatches(#"`(?:\\.|[^`\\])*`"#, stringColor, excluding: commentRanges)
        let claimed = commentRanges + stringRanges

        colorMatches(#"\b\d+(\.\d+)?\b"#, numberColor, excluding: claimed)
        colorMatches("\\b(" + keywords.joined(separator: "|") + ")\\b", keywordColor, excluding: claimed)

        // Recognized frame-script API — `bg`, `stage`, `stop()`, `bg.color(...)`, etc.
        colorMatches("\\b(" + globalNames.joined(separator: "|") + ")\\b", globalColor, excluding: claimed)
        colorMatches("(?<=\\.)(" + globalMembers.joined(separator: "|") + ")\\b", globalColor, excluding: claimed)

        // Warn on a const being reassigned — squiggly underline, computed
        // fresh on every keystroke.
        for diagnostic in constReassignmentDiagnostics(in: text) {
            if claimed.contains(where: { NSIntersectionRange($0, diagnostic).length > 0 }) { continue }
            storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.thick.rawValue, range: diagnostic)
            storage.addAttribute(.underlineColor, value: NSColor.systemOrange, range: diagnostic)
        }

        storage.endEditing()
    }

    /// Finds `NAME = ...` (or `+=`/`-=`/`*=`//=`) where NAME was declared
    /// with `const` somewhere in this same script — a real reassignment,
    /// not the declaration itself (excluded by checking what precedes it).
    private static func constReassignmentDiagnostics(in text: String) -> [NSRange] {
        guard let declRegex = try? NSRegularExpression(pattern: #"\bconst\s+([A-Za-z_$][A-Za-z0-9_$]*)\b"#)
        else { return [] }
        let nsText = text as NSString
        let full = NSRange(location: 0, length: nsText.length)
        let declMatches = declRegex.matches(in: text, range: full)
        guard !declMatches.isEmpty else { return [] }

        var names = Set<String>()
        for m in declMatches where m.range(at: 1).location != NSNotFound {
            names.insert(nsText.substring(with: m.range(at: 1)))
        }

        guard let precededByDecl = try? NSRegularExpression(pattern: #"(const|let|var)\s*$"#) else { return [] }
        var results: [NSRange] = []
        for name in names {
            guard let reassignRegex = try? NSRegularExpression(
                pattern: "\\b\(NSRegularExpression.escapedPattern(for: name))\\s*(?:\\+=|-=|\\*=|/=|=(?!=))"
            ) else { continue }
            for match in reassignRegex.matches(in: text, range: full) {
                let beforeRange = NSRange(location: 0, length: match.range.location)
                let before = nsText.substring(with: beforeRange)
                let beforeFull = NSRange(location: 0, length: (before as NSString).length)
                if precededByDecl.firstMatch(in: before, range: beforeFull) != nil { continue }
                results.append(match.range)
            }
        }
        return results
    }
}

/// The Actions panel — bound to whatever (layer, frame) is currently
/// selected in the timeline. Only keyframes can carry a script, matching
/// Flash's rule that actions attach to keyframes.
struct CodeEditorPanel: View {
    @ObservedObject var doc: TimelineDocument

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(.system(size: 10))
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(Color(nsColor: .controlBackgroundColor))
            Divider()

            if let layer = doc.selectedLayer, layer.isKeyframe(at: doc.selectedFrame) {
                CodeEditorView(text: scriptBinding(for: layer))
            } else {
                VStack {
                    Spacer()
                    Text(doc.selectedLayer == nil
                         ? "Select a layer and frame."
                         : "Frame \(doc.selectedFrame) isn't a keyframe — right-click it and choose Insert Keyframe to attach code.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(24)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private var title: String {
        guard let layer = doc.selectedLayer else { return "Actions" }
        return "Actions — \(layer.name), frame \(doc.selectedFrame)"
    }

    private func scriptBinding(for layer: TLLayer) -> Binding<String> {
        Binding(
            get: { layer.frameScripts[doc.selectedFrame] ?? "" },
            set: { doc.setScript($0, layer: layer, at: doc.selectedFrame) }
        )
    }
}
