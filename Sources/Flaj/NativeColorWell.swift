import SwiftUI
import AppKit

/// A native `NSColorWell` in its compact `.minimal` style. Clicking it
/// opens a small popover anchored directly to the well itself — contained
/// within the app window — unlike SwiftUI's own `ColorPicker` (backed by
/// the classic `.default`-style well), whose click target is the shared,
/// system-wide `NSColorPanel`: a separate floating window that opens
/// wherever it last was, potentially anywhere on screen, entirely outside
/// the app. `.minimal` is Apple's own answer to exactly this complaint
/// (added alongside `NSColorWell.Style` in macOS 13) — no custom picker UI
/// to build or maintain.
///
/// Deliberately carries no opacity of its own: `color` is always treated
/// as fully opaque here, since every color this app actually tracks
/// already stores its opacity as an independent `Double` field (see
/// `PlacedShape`/`ColorFilter`/`PlacedText`) shown via a plain `Slider`
/// alongside this well — the same idiom `instanceSection`'s own Opacity
/// row already uses — rather than routing opacity through the well's own
/// alpha handling, which `.minimal`'s compact popover doesn't surface
/// directly anyway (only the full `NSColorPanel`, reached via "..." inside
/// it, does).
struct NativeColorWell: NSViewRepresentable {
    @Binding var color: Color

    func makeNSView(context: Context) -> NSColorWell {
        let well = NSColorWell(style: .minimal)
        well.color = NSColor(color)
        well.target = context.coordinator
        well.action = #selector(Coordinator.colorChanged(_:))
        return well
    }

    func updateNSView(_ nsView: NSColorWell, context: Context) {
        let resolved = NSColor(color)
        if resolved != nsView.color {
            nsView.color = resolved
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(color: $color) }

    final class Coordinator: NSObject {
        var color: Binding<Color>
        init(color: Binding<Color>) { self.color = color }

        @objc func colorChanged(_ sender: NSColorWell) {
            color.wrappedValue = Color(sender.color)
        }
    }
}
