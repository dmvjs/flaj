import SwiftUI
@testable import Flaj

/// Hand-built `TimelineDocument`s for export tests — constructed directly
/// against the model rather than replayed from UI gestures, so a test failure
/// points at the export pipeline, not at some other layer of indirection.
@MainActor
enum DocumentFixtures {

    /// Two keyframes, one script each, no tweening: frame 1 paints the Stage
    /// black, frame 2 paints it white. The simplest possible movie that still
    /// exercises the full export path — frame scripts, simulation, GIF
    /// encoding — with nothing else that could make a failure ambiguous.
    static func blackWhiteFlip() -> TimelineDocument {
        let layer = TLLayer(
            name: "actions", swatch: .yellow,
            frames: [.keyframe(hasScript: true), .keyframe(hasScript: true)]
        )
        layer.frameScripts = [
            1: "bg.color('black');",
            2: "bg.color('white');"
        ]
        let doc = TimelineDocument(layers: [layer], totalFrames: 2)
        doc.stageWidth = 8
        doc.stageHeight = 8
        doc.fps = 1
        return doc
    }

    /// A single placed-text object tweened left-to-right over a 10-frame
    /// span, eased with a non-linear/non-default curve so the golden GIF
    /// this is checked against actually exercises `TweenSettings.
    /// easedProgress`'s family+direction+amount blend, not just a linear
    /// slide.
    static func tweenedText() -> TimelineDocument {
        let totalFrames = 10
        var frames = [FrameMark](repeating: .tween, count: totalFrames)
        frames[0] = .keyframe(hasScript: false)
        frames[totalFrames - 1] = .keyframe(hasScript: false)

        let layer = TLLayer(name: "text", swatch: .green, frames: frames)
        layer.textFrames[1] = PlacedText(
            text: "Flaj", x: 4, y: 4, width: 70, height: 20,
            fontName: "Helvetica", fontSize: 16, colorHex: "#000000"
        )
        layer.textFrames[totalFrames] = PlacedText(
            text: "Flaj", x: 40, y: 4, width: 70, height: 20,
            fontName: "Helvetica", fontSize: 16, colorHex: "#000000"
        )
        layer.tweenSettings[1] = TweenSettings(family: .quad, direction: .easeOut, amount: 100)

        let doc = TimelineDocument(layers: [layer], totalFrames: totalFrames)
        doc.stageWidth = 110
        doc.stageHeight = 32
        doc.stageColor = .white
        doc.fps = 8
        return doc
    }

    /// A 3-frame span (so the midpoint frame lands at an exact rawT of 0.5)
    /// that fades color black->white and opacity 1->0, on `.linear` easing
    /// so the expected midpoint is exact, not just approximately eased —
    /// isolates TLLayer.colorTweenSettings from the position/size tween,
    /// which stays untouched (same x/y/width/height start to end).
    static func colorFadeText() -> TimelineDocument {
        let frames: [FrameMark] = [.keyframe(hasScript: false), .tween, .keyframe(hasScript: false)]
        let layer = TLLayer(name: "text", swatch: .green, frames: frames)
        layer.textFrames[1] = PlacedText(
            text: "Flaj", x: 10, y: 10, width: 100, height: 30, colorHex: "#000000", opacity: 1
        )
        layer.textFrames[3] = PlacedText(
            text: "Flaj", x: 10, y: 10, width: 100, height: 30, colorHex: "#FFFFFF", opacity: 0
        )
        layer.tweenSettings[1] = TweenSettings(family: .linear)
        layer.colorTweenSettings[1] = TweenSettings(family: .linear)

        let doc = TimelineDocument(layers: [layer], totalFrames: 3)
        doc.stageWidth = 120
        doc.stageHeight = 50
        doc.fps = 8
        return doc
    }

    /// A single Library symbol with one placed instance (untweened) — the
    /// minimal case for verifying export resolves `layer.symbolFrames` +
    /// `doc.library` into the same rendered text a plain PlacedText box
    /// would produce. Same stage/text geometry as `tweenedText()`'s first
    /// keyframe so the two are easy to compare against each other.
    static func symbolInstance() -> TimelineDocument {
        let layer = TLLayer(name: "art", swatch: .green, frames: [.keyframe(hasScript: false)])
        let symbol = FlajSymbol(name: "Label", text: "Flaj", fontName: "Helvetica", fontSize: 16, colorHex: "#000000")
        layer.symbolFrames[1] = SymbolInstance(symbolID: symbol.id, x: 4, y: 4, width: 70, height: 20)

        let doc = TimelineDocument(layers: [layer], totalFrames: 1)
        doc.library = [symbol]
        doc.stageWidth = 110
        doc.stageHeight = 32
        doc.stageColor = .white
        doc.fps = 8
        return doc
    }

    /// Two symbol-instance keyframes tweened left-to-right — mirrors
    /// `tweenedText()` but through the Library/instance path, proving the
    /// export handles a tweened symbol span, not just a static one.
    static func tweenedSymbolInstance() -> TimelineDocument {
        let totalFrames = 10
        var frames = [FrameMark](repeating: .tween, count: totalFrames)
        frames[0] = .keyframe(hasScript: false)
        frames[totalFrames - 1] = .keyframe(hasScript: false)

        let layer = TLLayer(name: "art", swatch: .green, frames: frames)
        let symbol = FlajSymbol(name: "Label", text: "Flaj", fontName: "Helvetica", fontSize: 16, colorHex: "#000000")
        layer.symbolFrames[1] = SymbolInstance(symbolID: symbol.id, x: 4, y: 4, width: 70, height: 20)
        layer.symbolFrames[totalFrames] = SymbolInstance(symbolID: symbol.id, x: 40, y: 4, width: 70, height: 20)
        layer.tweenSettings[1] = TweenSettings(family: .linear)

        let doc = TimelineDocument(layers: [layer], totalFrames: totalFrames)
        doc.library = [symbol]
        doc.stageWidth = 110
        doc.stageHeight = 32
        doc.stageColor = .white
        doc.fps = 8
        return doc
    }

    /// Touches every field `FlajDocumentFile`/`FlajLayerFile` persist —
    /// two layers (one a locked/hidden folder), frame scripts, placed text,
    /// and tween settings — so a save/open round-trip test exercises the
    /// whole format, not just whichever fields the export fixtures happen
    /// to use.
    static func richDocumentForPersistence() -> TimelineDocument {
        let actions = TLLayer(
            name: "actions", swatch: .yellow, indent: 0,
            frames: [.keyframe(hasScript: true), .plain, .empty]
        )
        actions.frameScripts = [1: "stop();"]

        let art = TLLayer(
            name: "art", swatch: .blue, kind: .folder, indent: 0,
            locked: true, hidden: true,
            frames: [.keyframe(hasScript: false), .tween, .keyframe(hasScript: false)]
        )
        art.expanded = false
        art.textFrames = [
            1: PlacedText(
                text: "A", x: 1, y: 2, width: 30, height: 12, colorHex: "#112233", opacity: 1, scale: 1, rotation: 0,
                dropShadow: DropShadowFilter(colorHex: "#000000", blur: 4, offsetX: 2, offsetY: 2, opacity: 0.5),
                glow: GlowFilter(colorHex: "#FFFFFF", blur: 8, opacity: 0.8)
            ),
            3: PlacedText(text: "B", x: 10, y: 20, width: 30, height: 12, colorHex: "#445566", opacity: 0.4, scale: 1.5, rotation: 45)
        ]
        art.tweenSettings = [1: TweenSettings(family: .elastic, direction: .easeInOut, amount: 65, rotate: .cw, rotateTimes: 2)]
        art.colorTweenSettings = [1: TweenSettings(family: .sine, direction: .easeIn, amount: 80)]
        art.frameLabels = [1: "start"]

        let props = TLLayer(name: "props", swatch: .purple, indent: 0, frames: [.keyframe(hasScript: false), .empty, .empty])
        let symbol = FlajSymbol(
            name: "Badge", text: "NEW", fontName: "Helvetica", fontSize: 18,
            bold: true, italic: false, colorHex: "#FF3366", alignment: .center
        )
        props.symbolFrames = [1: SymbolInstance(symbolID: symbol.id, x: 50, y: 60, width: 40, height: 18, opacity: 0.9, scale: 1.2, rotation: 15, name: "badge1")]

        let shapes = TLLayer(name: "shapes", swatch: .red, indent: 0, frames: [.keyframe(hasScript: false), .empty, .empty])
        shapes.shapeFrames = [
            1: PlacedShape(
                kind: .ellipse, x: 5, y: 6, width: 44, height: 22,
                fillColorHex: "#3399FF", fillOpacity: 0.75, strokeColorHex: "#112233", strokeOpacity: 0.9,
                strokeWidth: 3, opacity: 0.85
            )
        ]

        let doc = TimelineDocument(layers: [actions, art, props, shapes], totalFrames: 3)
        doc.library = [symbol]
        doc.stageWidth = 320
        doc.stageHeight = 180
        doc.stageColor = .init(red: 0.1, green: 0.2, blue: 0.3)
        doc.fps = 24
        doc.webExportTitle = "My Movie"
        doc.webExportFit = .cover
        doc.webExportAlignment = .bottomTrailing
        doc.webExportPageBackground = Color(red: 0.4, green: 0.1, blue: 0.6, opacity: 0.5)
        doc.webExportMinify = false
        doc.guides = [
            Guide(orientation: .horizontal, position: 50),
            Guide(orientation: .vertical, position: 120)
        ]
        return doc
    }

    /// A rectangle on one layer and an ellipse on another, both static (no
    /// tween — shapes aren't tweenable in v1, see `PlacedShape`'s own doc
    /// comment) — the minimal document exercising player.js's shape
    /// rendering path (`syncShapeVisual`/`applyShapeStyle`) for both kinds
    /// at once.
    static func placedShapes() -> TimelineDocument {
        let rectLayer = TLLayer(name: "rect", swatch: .blue, frames: [.keyframe(hasScript: false)])
        rectLayer.shapeFrames[1] = PlacedShape(
            kind: .rectangle, x: 10, y: 10, width: 60, height: 40,
            fillColorHex: "#3399FF", fillOpacity: 1, strokeColorHex: "#000000", strokeOpacity: 1, strokeWidth: 2
        )
        let ellipseLayer = TLLayer(name: "ellipse", swatch: .green, frames: [.keyframe(hasScript: false)])
        ellipseLayer.shapeFrames[1] = PlacedShape(
            kind: .ellipse, x: 80, y: 20, width: 30, height: 30,
            fillColorHex: "#FF0000", fillOpacity: 0.5, strokeColorHex: "#00FF00", strokeOpacity: 1, strokeWidth: 4
        )
        let doc = TimelineDocument(layers: [rectLayer, ellipseLayer], totalFrames: 1)
        doc.stageWidth = 200
        doc.stageHeight = 100
        doc.stageColor = .white
        doc.fps = 8
        return doc
    }

    /// A single-layer, single-keyframe document whose frame-1 script is
    /// `script` — the minimal document that still exercises the real
    /// JavaScriptCore bridge (`stepSimulationFrame()` -> frame script ->
    /// `console.log` -> `consoleMessages`), with no Stage/tween machinery
    /// in the way of what's actually being tested.
    static func singleScript(_ script: String) -> TimelineDocument {
        let layer = TLLayer(name: "actions", swatch: .yellow, frames: [.keyframe(hasScript: true)])
        layer.frameScripts[1] = script
        return TimelineDocument(layers: [layer], totalFrames: 1)
    }
}
