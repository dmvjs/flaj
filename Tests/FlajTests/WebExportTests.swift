import XCTest
import SwiftUI
@testable import Flaj

/// Loads real exported pages into WKWebView (see WebViewHarness) and checks
/// the DOM — the only way to actually verify Resources/player.js, since
/// it's plain JS with no Swift-side equivalent to call directly. Uses the
/// black/white flip fixture (see DocumentFixtures.blackWhiteFlip) as the
/// workhorse for exercising the export *options* — fit, alignment, page
/// background, minify — since its two solid-color frames make "did this
/// option actually take effect" trivial to check via computed style,
/// independent of the tween/text-rendering path GIFExportTests already
/// covers on the Swift side.
@MainActor
final class WebExportTests: XCTestCase {

    private func exportedURL(_ doc: TimelineDocument) -> URL {
        let url = TemporaryFile.url(extension: "html")
        doc.performWebExport(to: url)
        return url
    }

    func testBlackWhiteFlipRunsAndAdvancesFrames() async throws {
        let doc = DocumentFixtures.blackWhiteFlip()
        let url = exportedURL(doc)
        defer { try? FileManager.default.removeItem(at: url) }

        let harness = WebViewHarness()
        try await harness.load(fileURL: url)

        let frame1 = try await harness.evaluate("getComputedStyle(document.getElementById('flaj-stage')).backgroundColor")
        XCTAssertEqual(frame1 as? String, "rgb(0, 0, 0)")

        try await harness.evaluate("gotoAndStop(2)")
        let frame2 = try await harness.evaluate("getComputedStyle(document.getElementById('flaj-stage')).backgroundColor")
        XCTAssertEqual(frame2 as? String, "rgb(255, 255, 255)")
    }

    func testTweenedTextReachesBothEndpoints() async throws {
        let doc = DocumentFixtures.tweenedText()
        let url = exportedURL(doc)
        defer { try? FileManager.default.removeItem(at: url) }

        let harness = WebViewHarness()
        try await harness.load(fileURL: url)

        // The tween span is a real Web Animation now (see player.js), which
        // affects computed style, not the element's inline `style` attribute
        // — so these read getComputedStyle, not `.style.left` directly.
        try await harness.evaluate("gotoAndStop(1)")
        let start = try await harness.evaluate("getComputedStyle(document.querySelector('.flaj-text')).left")
        XCTAssertEqual(start as? String, "4px")

        try await harness.evaluate("gotoAndStop(10)")
        let end = try await harness.evaluate("getComputedStyle(document.querySelector('.flaj-text')).left")
        XCTAssertEqual(end as? String, "40px")
    }

    /// A symbol instance (Library symbol + placed instance, no tween) must
    /// render the exact same text/position player.js already produces for
    /// a plain PlacedText box — proves `resolvePlacement` in player.js
    /// correctly resolves `layer.symbolFrames`/`doc.library` into that same
    /// rendering path, not just the Swift side.
    func testSymbolInstanceRendersTheLibraryContentAtItsOwnPosition() async throws {
        let doc = DocumentFixtures.symbolInstance()
        let url = exportedURL(doc)
        defer { try? FileManager.default.removeItem(at: url) }

        let harness = WebViewHarness()
        try await harness.load(fileURL: url)

        let text = try await harness.evaluate("document.querySelector('.flaj-text').textContent")
        XCTAssertEqual(text as? String, "Flaj")
        let left = try await harness.evaluate("getComputedStyle(document.querySelector('.flaj-text')).left")
        XCTAssertEqual(left as? String, "4px")
    }

    /// Same as `testTweenedTextReachesBothEndpoints`, but through the
    /// Library/instance path (DocumentFixtures.tweenedSymbolInstance) —
    /// proves a tweened symbol span becomes a real Web Animation too, not
    /// just a static instance.
    func testTweenedSymbolInstanceReachesBothEndpoints() async throws {
        let doc = DocumentFixtures.tweenedSymbolInstance()
        let url = exportedURL(doc)
        defer { try? FileManager.default.removeItem(at: url) }

        let harness = WebViewHarness()
        try await harness.load(fileURL: url)

        try await harness.evaluate("gotoAndStop(1)")
        let start = try await harness.evaluate("getComputedStyle(document.querySelector('.flaj-text')).left")
        XCTAssertEqual(start as? String, "4px")

        try await harness.evaluate("gotoAndStop(10)")
        let end = try await harness.evaluate("getComputedStyle(document.querySelector('.flaj-text')).left")
        XCTAssertEqual(end as? String, "40px")
    }

    /// A named symbol instance spawns into the same `stageObjects` a
    /// script-created `stage.addText` object lives in, and becomes movable
    /// through the exact same `stage.setTransform` — no separate API for
    /// Timeline-placed vs. script-created objects (mirrors
    /// SymbolTests.testFrameScriptCanMoveANamedInstanceThroughTheExistingStageAPI
    /// on the Swift side).
    func testNamedSymbolInstanceIsMovableThroughStageSetTransform() async throws {
        let layer = TLLayer(name: "art", swatch: .green, frames: [.keyframe(hasScript: true)])
        let symbol = FlajSymbol(name: "Badge", text: "HELLO")
        layer.symbolFrames[1] = SymbolInstance(symbolID: symbol.id, x: 0, y: 0, width: 40, height: 10, name: "badge1")
        layer.frameScripts[1] = "stage.setTransform('badge1', { x: 200, y: 150 });"
        let doc = TimelineDocument(layers: [layer], totalFrames: 1)
        doc.library = [symbol]
        doc.stageWidth = 400
        doc.stageHeight = 300

        let url = exportedURL(doc)
        defer { try? FileManager.default.removeItem(at: url) }
        let harness = WebViewHarness()
        try await harness.load(fileURL: url)

        // Spawned/script-controlled objects render via .flaj-object (the
        // stageObjects layer), not .flaj-text (the Timeline-authored layer)
        // — confirms the authored rendering was suppressed too, not just
        // that the object moved.
        let authoredCount = try await harness.evaluate("document.querySelectorAll('.flaj-text').length")
        XCTAssertEqual((authoredCount as? NSNumber)?.intValue, 0)

        let left = try await harness.evaluate("document.querySelector('.flaj-object').style.left")
        XCTAssertEqual(left as? String, "200px")
        let top = try await harness.evaluate("document.querySelector('.flaj-object').style.top")
        XCTAssertEqual(top as? String, "150px")
    }

    /// A placed symbol instance plays its own symbol's Timeline
    /// independently of the parent — Flash's real Movie Clip behavior — so
    /// a 3-frame symbol sitting on a single unchanging parent keyframe
    /// still cycles through its own content as the parent frame advances,
    /// looping back to frame 1 on the 4th frame. Mirrors
    /// SymbolTests.testSymbolInstanceLoopsThroughItsOwnFramesAsTheParentFrameAdvances
    /// on the Swift side, through the actual exported page this time.
    func testSymbolInstanceLoopsIndependentlyInTheExportedPage() async throws {
        let art = TLLayer(name: "art", swatch: .green, frames: [.keyframe(hasScript: false), .plain, .plain, .plain])
        let symbolLayer = TLLayer(name: "sym", swatch: .green, frames: [.keyframe(hasScript: false), .keyframe(hasScript: false), .keyframe(hasScript: false)])
        symbolLayer.textFrames[1] = PlacedText(text: "OPEN", x: 0, y: 0)
        symbolLayer.textFrames[2] = PlacedText(text: "MID", x: 0, y: 0)
        symbolLayer.textFrames[3] = PlacedText(text: "SHUT", x: 0, y: 0)
        let symbol = FlajSymbol(id: UUID(), name: "Blink", layers: [symbolLayer], totalFrames: 3)
        art.symbolFrames[1] = SymbolInstance(symbolID: symbol.id, x: 0, y: 0, width: 40, height: 20)

        let doc = TimelineDocument(layers: [art], totalFrames: 4)
        doc.library = [symbol]
        doc.stageWidth = 100
        doc.stageHeight = 60

        let url = exportedURL(doc)
        defer { try? FileManager.default.removeItem(at: url) }
        let harness = WebViewHarness()
        try await harness.load(fileURL: url)

        try await harness.evaluate("gotoAndStop(1)")
        var text = try await harness.evaluate("document.querySelector('.flaj-text').textContent")
        XCTAssertEqual(text as? String, "OPEN")

        try await harness.evaluate("gotoAndStop(2)")
        text = try await harness.evaluate("document.querySelector('.flaj-text').textContent")
        XCTAssertEqual(text as? String, "MID")

        try await harness.evaluate("gotoAndStop(3)")
        text = try await harness.evaluate("document.querySelector('.flaj-text').textContent")
        XCTAssertEqual(text as? String, "SHUT")

        try await harness.evaluate("gotoAndStop(4)")
        text = try await harness.evaluate("document.querySelector('.flaj-text').textContent")
        XCTAssertEqual(text as? String, "OPEN", "loops back to frame 1 on the 4th parent frame")
    }

    /// A regression net for a real bug class found while building this:
    /// a symbol's own internal frame carries opacity/scale/rotation/color/
    /// fontSize, and so does the placed instance — both must apply
    /// *together* (compounded), and a tween authored inside the symbol's
    /// own Timeline must ease smoothly, not jump between keyframes. Uses
    /// an *untweened* instance placement (no competing box/color Web
    /// Animation) so every field is expected to update live —
    /// testSymbolLoopFullyCompoundsEvenWhenTheInstanceItselfIsAlsoTweened
    /// below covers the harder case where the instance is tweened too.
    func testSymbolInstanceContentCompoundsWithInstanceTransformAndEasesInternally() async throws {
        let symbolLayer = TLLayer(name: "art", swatch: .green, frames: [.keyframe(hasScript: false), .tween, .keyframe(hasScript: false)])
        symbolLayer.textFrames[1] = PlacedText(text: "A", x: 0, y: 0, fontSize: 10, colorHex: "#000000", opacity: 0, scale: 1, rotation: 0)
        symbolLayer.textFrames[3] = PlacedText(text: "A", x: 0, y: 0, fontSize: 20, colorHex: "#FFFFFF", opacity: 1, scale: 2, rotation: 90)
        symbolLayer.tweenSettings[1] = TweenSettings(family: .linear)
        symbolLayer.colorTweenSettings[1] = TweenSettings(family: .linear)
        let symbol = FlajSymbol(id: UUID(), name: "Fade", layers: [symbolLayer], totalFrames: 3)

        let root = TLLayer(name: "root", swatch: .blue, frames: [.keyframe(hasScript: false), .plain, .plain])
        root.symbolFrames[1] = SymbolInstance(symbolID: symbol.id, x: 0, y: 0, width: 40, height: 20, opacity: 0.5, scale: 3, rotation: 10)

        let doc = TimelineDocument(layers: [root], totalFrames: 3)
        doc.library = [symbol]
        doc.stageWidth = 100
        doc.stageHeight = 60

        let url = exportedURL(doc)
        defer { try? FileManager.default.removeItem(at: url) }
        let harness = WebViewHarness()
        try await harness.load(fileURL: url)

        func readStyle() async throws -> (opacity: Double, fontSize: Double, color: String, scale: Double, rotationDeg: Double) {
            let js = """
            (() => {
              const el = document.querySelector('.flaj-text');
              const cs = getComputedStyle(el);
              const m = new DOMMatrixReadOnly(cs.transform);
              return [parseFloat(cs.opacity), parseFloat(cs.fontSize), cs.color, Math.hypot(m.a, m.b), Math.atan2(m.b, m.a) * 180 / Math.PI];
            })()
            """
            let result = try await harness.evaluate(js)
            let arr = try XCTUnwrap(result as? [Any])
            return (
                (arr[0] as? NSNumber)?.doubleValue ?? -1, (arr[1] as? NSNumber)?.doubleValue ?? -1,
                arr[2] as? String ?? "", (arr[3] as? NSNumber)?.doubleValue ?? -1, (arr[4] as? NSNumber)?.doubleValue ?? -999
            )
        }

        // Frame 1 (symbol's own frame 1): instance(0.5, scale 3, rot 10) *
        // content(opacity 0, fontSize 10, scale 1, rot 0).
        try await harness.evaluate("gotoAndStop(1)")
        var s = try await readStyle()
        XCTAssertEqual(s.opacity, 0, accuracy: 0.01, "0.5 (instance) * 0 (content) must be 0, not 0.5 from the instance alone")
        XCTAssertEqual(s.fontSize, 10, accuracy: 0.01)
        XCTAssertEqual(s.scale, 3, accuracy: 0.01, "3 (instance) * 1 (content) — content's own scale of 1 must not silently drop the instance's 3")
        XCTAssertEqual(s.rotationDeg, 10, accuracy: 0.5)

        // Frame 2: the *symbol's own* tween at its eased (linear) midpoint —
        // proves internal easing, not a discrete jump straight to frame 3's
        // values.
        try await harness.evaluate("gotoAndStop(2)")
        s = try await readStyle()
        XCTAssertEqual(s.opacity, 0.25, accuracy: 0.01, "0.5 (instance) * 0.5 (content's own eased midpoint)")
        XCTAssertEqual(s.fontSize, 15, accuracy: 0.01)
        XCTAssertEqual(s.color, "rgb(128, 128, 128)", "#000000 -> #FFFFFF at t=0.5")
        XCTAssertEqual(s.scale, 4.5, accuracy: 0.01, "3 (instance) * 1.5 (content eased midpoint)")
        XCTAssertEqual(s.rotationDeg, 55, accuracy: 0.5, "10 (instance) + 45 (content eased midpoint)")

        // Frame 3 (symbol's own frame 3, its loop's last before wrapping).
        try await harness.evaluate("gotoAndStop(3)")
        s = try await readStyle()
        XCTAssertEqual(s.opacity, 0.5, accuracy: 0.01)
        XCTAssertEqual(s.fontSize, 20, accuracy: 0.01)
        XCTAssertEqual(s.scale, 6, accuracy: 0.01)
        XCTAssertEqual(s.rotationDeg, 100, accuracy: 0.5)
    }

    /// Drop Shadow + Glow both render as CSS `text-shadow` (see player.js's
    /// textShadowCSS) — a plain placed text box, the simplest case with no
    /// symbol/loop machinery involved at all.
    func testDropShadowAndGlowRenderAsCSSTextShadow() async throws {
        let layer = TLLayer(name: "text", swatch: .green, frames: [.keyframe(hasScript: false)])
        layer.textFrames[1] = PlacedText(
            text: "Flaj", x: 0, y: 0,
            dropShadow: DropShadowFilter(colorHex: "#000000", blur: 4, offsetX: 2, offsetY: 3, opacity: 0.5),
            glow: GlowFilter(colorHex: "#FFFFFF", blur: 8, opacity: 0.8)
        )
        let doc = TimelineDocument(layers: [layer], totalFrames: 1)
        doc.stageWidth = 100
        doc.stageHeight = 60

        let url = exportedURL(doc)
        defer { try? FileManager.default.removeItem(at: url) }
        let harness = WebViewHarness()
        try await harness.load(fileURL: url)

        let shadow = try await harness.evaluate("getComputedStyle(document.querySelector('.flaj-text')).textShadow")
        let value = try XCTUnwrap(shadow as? String)
        XCTAssertTrue(value.contains("rgba(255, 255, 255, 0.8)"), "expected the glow's color/opacity in \(value)")
        XCTAssertTrue(value.contains("rgba(0, 0, 0, 0.5)"), "expected the drop shadow's color/opacity in \(value)")
        XCTAssertTrue(value.contains("2px 3px"), "expected the drop shadow's own offset in \(value)")
    }

    /// The bug this is a regression test for: `resolvePlacement`'s symbol
    /// branch built its returned placement object field-by-field and
    /// simply forgot dropShadow/glow, so a symbol's filters silently never
    /// reached the exported page at all despite rendering correctly
    /// natively. A 2-frame looping symbol with a *different* filter on
    /// each frame also proves the per-tick loop path (applySymbolLoopFrame)
    /// picks up the change, not just the span's initial static style.
    func testSymbolContentFiltersRenderAndUpdateAsTheLoopAdvances() async throws {
        let symbolLayer = TLLayer(name: "art", swatch: .green, frames: [.keyframe(hasScript: false), .keyframe(hasScript: false)])
        symbolLayer.textFrames[1] = PlacedText(text: "A", x: 0, y: 0, glow: GlowFilter(colorHex: "#FF0000", blur: 6, opacity: 0.9))
        symbolLayer.textFrames[2] = PlacedText(text: "A", x: 0, y: 0, dropShadow: DropShadowFilter(colorHex: "#0000FF", blur: 5, offsetX: 1, offsetY: 1, opacity: 0.6))
        let symbol = FlajSymbol(id: UUID(), name: "Blink", layers: [symbolLayer], totalFrames: 2)

        let root = TLLayer(name: "root", swatch: .blue, frames: [.keyframe(hasScript: false), .plain])
        root.symbolFrames[1] = SymbolInstance(symbolID: symbol.id, x: 0, y: 0, width: 40, height: 20)

        let doc = TimelineDocument(layers: [root], totalFrames: 2)
        doc.library = [symbol]
        doc.stageWidth = 100
        doc.stageHeight = 60

        let url = exportedURL(doc)
        defer { try? FileManager.default.removeItem(at: url) }
        let harness = WebViewHarness()
        try await harness.load(fileURL: url)

        try await harness.evaluate("gotoAndStop(1)")
        var shadow = try await harness.evaluate("getComputedStyle(document.querySelector('.flaj-text')).textShadow")
        XCTAssertTrue(try XCTUnwrap(shadow as? String).contains("rgba(255, 0, 0, 0.9)"), "frame 1's glow")

        try await harness.evaluate("gotoAndStop(2)")
        shadow = try await harness.evaluate("getComputedStyle(document.querySelector('.flaj-text')).textShadow")
        XCTAssertTrue(try XCTUnwrap(shadow as? String).contains("rgba(0, 0, 255, 0.6)"), "frame 2's drop shadow, not still frame 1's glow")
    }

    /// The hard combination: the placed instance is *itself* classic-tweened
    /// (its own box/color Web Animation) at the same time its symbol
    /// independently loops through an *internal* tween of its own — two
    /// differently-timed, differently-eased curves whose combined values
    /// must both come through correctly. This is what
    /// resampleCombinedSymbolLoopKeyframes exists for (see its own doc
    /// comment on why a single two-point Web Animation can't express this,
    /// and why it isn't just left as a known gap).
    func testSymbolLoopFullyCompoundsEvenWhenTheInstanceItselfIsAlsoTweened() async throws {
        let symbolLayer = TLLayer(name: "art", swatch: .green, frames: [.keyframe(hasScript: false), .tween, .keyframe(hasScript: false)])
        symbolLayer.textFrames[1] = PlacedText(text: "A", x: 0, y: 0, fontSize: 10, colorHex: "#000000", opacity: 0, scale: 1, rotation: 0)
        symbolLayer.textFrames[3] = PlacedText(text: "A", x: 0, y: 0, fontSize: 20, colorHex: "#FFFFFF", opacity: 1, scale: 2, rotation: 90)
        symbolLayer.tweenSettings[1] = TweenSettings(family: .linear)
        symbolLayer.colorTweenSettings[1] = TweenSettings(family: .linear)
        let symbol = FlajSymbol(id: UUID(), name: "Fade", layers: [symbolLayer], totalFrames: 3)

        let root = TLLayer(name: "root", swatch: .blue, frames: [.keyframe(hasScript: false), .tween, .keyframe(hasScript: false)])
        root.symbolFrames[1] = SymbolInstance(symbolID: symbol.id, x: 0, y: 0, width: 40, height: 20, opacity: 0.5, scale: 1, rotation: 0)
        root.symbolFrames[3] = SymbolInstance(symbolID: symbol.id, x: 50, y: 0, width: 40, height: 20, opacity: 1.0, scale: 2, rotation: 90)
        root.tweenSettings[1] = TweenSettings(family: .linear)
        root.colorTweenSettings[1] = TweenSettings(family: .linear)

        let doc = TimelineDocument(layers: [root], totalFrames: 3)
        doc.library = [symbol]
        doc.stageWidth = 120
        doc.stageHeight = 60

        let url = exportedURL(doc)
        defer { try? FileManager.default.removeItem(at: url) }
        let harness = WebViewHarness()
        try await harness.load(fileURL: url)

        func readStyle() async throws -> (opacity: Double, fontSize: Double, color: String, scale: Double, rotationDeg: Double) {
            let js = """
            (() => {
              const el = document.querySelector('.flaj-text');
              const cs = getComputedStyle(el);
              const m = new DOMMatrixReadOnly(cs.transform);
              return [parseFloat(cs.opacity), parseFloat(cs.fontSize), cs.color, Math.hypot(m.a, m.b), Math.atan2(m.b, m.a) * 180 / Math.PI];
            })()
            """
            let result = try await harness.evaluate(js)
            let arr = try XCTUnwrap(result as? [Any])
            return (
                (arr[0] as? NSNumber)?.doubleValue ?? -1, (arr[1] as? NSNumber)?.doubleValue ?? -1,
                arr[2] as? String ?? "", (arr[3] as? NSNumber)?.doubleValue ?? -1, (arr[4] as? NSNumber)?.doubleValue ?? -999
            )
        }

        // Frame 1: instance(opacity 0.5, scale 1, rot 0) * symbol frame 1
        // (opacity 0, fontSize 10, scale 1, rot 0).
        try await harness.evaluate("gotoAndStop(1)")
        var s = try await readStyle()
        XCTAssertEqual(s.opacity, 0, accuracy: 0.02)
        XCTAssertEqual(s.fontSize, 10, accuracy: 0.1)
        XCTAssertEqual(s.scale, 1, accuracy: 0.02)
        XCTAssertEqual(s.rotationDeg, 0, accuracy: 1)

        // Frame 2: *both* curves at their own linear midpoint simultaneously
        // — instance eased to (opacity 0.75, scale 1.5, rot 45) times the
        // symbol's own internal midpoint (opacity 0.5, fontSize 15, scale
        // 1.5, rot 45, color halfway #000->#FFF).
        try await harness.evaluate("gotoAndStop(2)")
        s = try await readStyle()
        XCTAssertEqual(s.opacity, 0.375, accuracy: 0.02, "0.75 (instance eased) * 0.5 (content eased) — both curves must survive being combined")
        XCTAssertEqual(s.fontSize, 15, accuracy: 0.5)
        XCTAssertEqual(s.color, "rgb(128, 128, 128)")
        XCTAssertEqual(s.scale, 2.25, accuracy: 0.05, "1.5 (instance eased) * 1.5 (content eased)")
        XCTAssertEqual(s.rotationDeg, 90, accuracy: 1, "45 (instance eased) + 45 (content eased)")
        var text = try await harness.evaluate("document.querySelector('.flaj-text').textContent")
        XCTAssertEqual(text as? String, "A")

        // Frame 3 is itself a keyframe, not mid-tween — so it's
        // self-governing (governingKeyframe(3) == 3, not 1), which resets
        // the symbol's own loop reference point there too, exactly like
        // the native app's equivalent computed property would (a fresh
        // governing keyframe is a fresh span for anything anchored to it,
        // including local-frame counting) — the same consistency this
        // whole rewrite is about preserving between the two. So frame 3
        // combines the *frame-3 instance* (opacity 1.0, scale 2, rot 90)
        // with the symbol's *frame 1* (elapsed 0 from its own new
        // reference point) rather than continuing to frame 3 of the
        // symbol's loop.
        try await harness.evaluate("gotoAndStop(3)")
        s = try await readStyle()
        XCTAssertEqual(s.opacity, 0, accuracy: 0.02, "1.0 (instance) * 0 (symbol's own frame 1, its loop counting restarted here)")
        XCTAssertEqual(s.fontSize, 10, accuracy: 0.1)
        XCTAssertEqual(s.scale, 2, accuracy: 0.05, "2 (instance) * 1 (symbol frame 1)")
        XCTAssertEqual(s.rotationDeg, 90, accuracy: 1, "90 (instance) + 0 (symbol frame 1)")
        text = try await harness.evaluate("document.querySelector('.flaj-text').textContent")
        XCTAssertEqual(text as? String, "A", "text isn't a CSS-animated property, so it independently keeps updating too")
    }

    /// A symbol instance whose `symbolID` doesn't resolve against
    /// `doc.library` (shouldn't happen via the app's own UI — `deleteSymbol`
    /// purges every instance — but the export must not crash on a
    /// hand-edited or otherwise corrupted .flaj file) should just render
    /// nothing at that keyframe rather than throwing.
    func testOrphanedSymbolInstanceRendersNothingInsteadOfCrashing() async throws {
        let layer = TLLayer(name: "art", swatch: .green, frames: [.keyframe(hasScript: false)])
        layer.symbolFrames[1] = SymbolInstance(symbolID: UUID(), x: 0, y: 0)
        let doc = TimelineDocument(layers: [layer], totalFrames: 1)
        doc.stageWidth = 40
        doc.stageHeight = 40
        let url = exportedURL(doc)
        defer { try? FileManager.default.removeItem(at: url) }

        let harness = WebViewHarness()
        try await harness.load(fileURL: url)

        let count = try await harness.evaluate("document.querySelectorAll('.flaj-text').length")
        XCTAssertEqual((count as? NSNumber)?.intValue, 0)
    }

    /// Scale/rotation tween in the exported page — `getComputedStyle`'s
    /// `transform` comes back as a matrix, not a literal "scale(...)
    /// rotate(...)" string, so this decomposes it back into scale/degrees
    /// via DOMMatrixReadOnly rather than string-comparing (which would also
    /// be brittle against float noise like cos(90°) != exactly 0).
    func testScaleAndRotationTweenInTheExportedPage() async throws {
        let totalFrames = 10
        var frames = [FrameMark](repeating: .tween, count: totalFrames)
        frames[0] = .keyframe(hasScript: false)
        frames[totalFrames - 1] = .keyframe(hasScript: false)
        let layer = TLLayer(name: "text", swatch: .green, frames: frames)
        layer.textFrames[1] = PlacedText(text: "Flaj", x: 0, y: 0, width: 40, height: 20, scale: 1, rotation: 0)
        layer.textFrames[totalFrames] = PlacedText(text: "Flaj", x: 0, y: 0, width: 40, height: 20, scale: 2, rotation: 90)
        layer.tweenSettings[1] = TweenSettings(family: .linear)
        let doc = TimelineDocument(layers: [layer], totalFrames: totalFrames)
        doc.stageWidth = 100
        doc.stageHeight = 60
        doc.fps = 10

        let url = exportedURL(doc)
        defer { try? FileManager.default.removeItem(at: url) }
        let harness = WebViewHarness()
        try await harness.load(fileURL: url)

        func scaleAndRotation() async throws -> (scale: Double, rotationDeg: Double) {
            let scale = try await harness.evaluate("""
            (() => { const m = new DOMMatrixReadOnly(getComputedStyle(document.querySelector('.flaj-text')).transform); return Math.hypot(m.a, m.b); })()
            """)
            let rotation = try await harness.evaluate("""
            (() => { const m = new DOMMatrixReadOnly(getComputedStyle(document.querySelector('.flaj-text')).transform); return Math.atan2(m.b, m.a) * 180 / Math.PI; })()
            """)
            return ((scale as? NSNumber)?.doubleValue ?? -1, (rotation as? NSNumber)?.doubleValue ?? -999)
        }

        try await harness.evaluate("gotoAndStop(1)")
        let start = try await scaleAndRotation()
        XCTAssertEqual(start.scale, 1, accuracy: 0.01)
        XCTAssertEqual(start.rotationDeg, 0, accuracy: 0.5)

        try await harness.evaluate("gotoAndStop(\(totalFrames))")
        let end = try await scaleAndRotation()
        XCTAssertEqual(end.scale, 2, accuracy: 0.01)
        XCTAssertEqual(end.rotationDeg, 90, accuracy: 0.5)

        // Midpoint (linear easing, frame 5.5 worth of progress isn't a real
        // frame, so land on the nearest integer frame and accept a wider
        // tolerance for the linear-interpolation slack that introduces).
        try await harness.evaluate("gotoAndStop(5)")
        let mid = try await scaleAndRotation()
        XCTAssertEqual(mid.scale, 1.44, accuracy: 0.05) // 1 + (2-1) * (4/9)
        XCTAssertEqual(mid.rotationDeg, 40, accuracy: 3)
    }

    func testTitleOptionSetsPageTitle() async throws {
        let doc = DocumentFixtures.blackWhiteFlip()
        doc.webExportTitle = "My Great Movie"
        let url = exportedURL(doc)
        defer { try? FileManager.default.removeItem(at: url) }

        let harness = WebViewHarness()
        try await harness.load(fileURL: url)

        let title = try await harness.evaluate("document.title")
        XCTAssertEqual(title as? String, "My Great Movie")
    }

    func testFitAndAlignmentOptionsControlStageLayout() async throws {
        let doc = DocumentFixtures.blackWhiteFlip() // 8x8 Stage
        doc.webExportFit = .cover
        doc.webExportAlignment = .bottomTrailing
        let url = exportedURL(doc)
        defer { try? FileManager.default.removeItem(at: url) }

        let harness = WebViewHarness() // WebViewHarness's WKWebView is 400x300

        try await harness.load(fileURL: url)

        // .cover on an 8x8 Stage in a 400x300 view scales to fill: max(400/8, 300/8) = 50.
        let scale = try await harness.evaluate(
            "new DOMMatrix(getComputedStyle(document.getElementById('flaj-stage')).transform).a"
        ) as? NSNumber
        XCTAssertEqual(scale?.doubleValue ?? -1, 50, accuracy: 0.01)

        let alignItems = try await harness.evaluate("getComputedStyle(document.body).alignItems")
        let justifyContent = try await harness.evaluate("getComputedStyle(document.body).justifyContent")
        XCTAssertEqual(alignItems as? String, "flex-end")
        XCTAssertEqual(justifyContent as? String, "flex-end")
    }

    func testPageBackgroundIsIndependentOfStageBackground() async throws {
        let doc = DocumentFixtures.blackWhiteFlip()
        doc.webExportPageBackground = Color(red: 1, green: 0, blue: 0) // opaque red
        let url = exportedURL(doc)
        defer { try? FileManager.default.removeItem(at: url) }

        let harness = WebViewHarness()
        try await harness.load(fileURL: url)

        let pageBackground = try await harness.evaluate("getComputedStyle(document.body).backgroundColor")
        XCTAssertEqual(pageBackground as? String, "rgb(255, 0, 0)")

        // The Stage's own background (frame 1 is black — see blackWhiteFlip)
        // is unaffected by the page background around it.
        let stageBackground = try await harness.evaluate("getComputedStyle(document.getElementById('flaj-stage')).backgroundColor")
        XCTAssertEqual(stageBackground as? String, "rgb(0, 0, 0)")
    }

    func testDefaultPageBackgroundIsTransparent() async throws {
        let doc = DocumentFixtures.blackWhiteFlip() // webExportPageBackground defaults to .clear
        let url = exportedURL(doc)
        defer { try? FileManager.default.removeItem(at: url) }

        let harness = WebViewHarness()
        try await harness.load(fileURL: url)

        let pageBackground = try await harness.evaluate("getComputedStyle(document.body).backgroundColor")
        XCTAssertEqual(pageBackground as? String, "rgba(0, 0, 0, 0)")
    }

    func testMinifyOptionStripsCommentsWithoutChangingBehavior() async throws {
        let unminified = DocumentFixtures.blackWhiteFlip()
        unminified.webExportMinify = false
        let unminifiedURL = exportedURL(unminified)
        defer { try? FileManager.default.removeItem(at: unminifiedURL) }

        let minified = DocumentFixtures.blackWhiteFlip()
        minified.webExportMinify = true
        let minifiedURL = exportedURL(minified)
        defer { try? FileManager.default.removeItem(at: minifiedURL) }

        let unminifiedHTML = try String(contentsOf: unminifiedURL, encoding: .utf8)
        let minifiedHTML = try String(contentsOf: minifiedURL, encoding: .utf8)
        XCTAssertTrue(unminifiedHTML.contains("Flaj web player"))
        XCTAssertFalse(minifiedHTML.contains("Flaj web player"))
        XCTAssertLessThan(minifiedHTML.count, unminifiedHTML.count)

        // Same functional check as testBlackWhiteFlipRunsAndAdvancesFrames,
        // against the minified build — comment/whitespace stripping must
        // not change what the player actually does.
        let harness = WebViewHarness()
        try await harness.load(fileURL: minifiedURL)
        let frame1 = try await harness.evaluate("getComputedStyle(document.getElementById('flaj-stage')).backgroundColor")
        XCTAssertEqual(frame1 as? String, "rgb(0, 0, 0)")
        try await harness.evaluate("gotoAndStop(2)")
        let frame2 = try await harness.evaluate("getComputedStyle(document.getElementById('flaj-stage')).backgroundColor")
        XCTAssertEqual(frame2 as? String, "rgb(255, 255, 255)")
    }

    func testSingleFrameDocumentRunsScriptOnceAndDoesNotLoop() async throws {
        // A one-content-frame document has nowhere to advance to — it
        // should behave like a hand-authored static page (run its script
        // once, settle), not busy-loop re-running frame 1 forever.
        let layer = TLLayer(name: "actions", swatch: .yellow, frames: [.keyframe(hasScript: true)])
        layer.frameScripts[1] = "window.__runCount = (window.__runCount || 0) + 1;"
        let doc = TimelineDocument(layers: [layer], totalFrames: 1)
        let url = exportedURL(doc)
        defer { try? FileManager.default.removeItem(at: url) }

        let harness = WebViewHarness()
        try await harness.load(fileURL: url)
        // Long enough that a busy-looping player would have re-run the
        // script many times over at any plausible fps.
        try await Task.sleep(nanoseconds: 500_000_000)

        let runCount = try await harness.evaluate("window.__runCount") as? NSNumber
        XCTAssertEqual(runCount?.intValue, 1)
    }

    func testTweenSpanIsARealWebAnimation() async throws {
        let doc = DocumentFixtures.tweenedText()
        let url = exportedURL(doc)
        defer { try? FileManager.default.removeItem(at: url) }

        let harness = WebViewHarness()
        try await harness.load(fileURL: url)
        try await harness.evaluate("gotoAndStop(5)")

        let animationCount = try await harness.evaluate("document.getAnimations().length") as? NSNumber
        XCTAssertGreaterThan(animationCount?.intValue ?? 0, 0)
    }

    func testTweenUsesTheEasingCurveNotLinearInterpolation() async throws {
        let doc = DocumentFixtures.tweenedText() // family: .quad, direction: .easeOut, x: 4 -> 40 over frames 1...10
        let url = exportedURL(doc)
        defer { try? FileManager.default.removeItem(at: url) }

        let harness = WebViewHarness()
        try await harness.load(fileURL: url)
        try await harness.evaluate("gotoAndStop(5)")

        let leftString = try await harness.evaluate("getComputedStyle(document.querySelector('.flaj-text')).left") as? String
        let left = Double((leftString ?? "").replacingOccurrences(of: "px", with: "")) ?? -1

        // rawT = (5-1)/9 ≈ 0.444; quad ease-out gives t ≈ 0.691, so x ≈ 4 + 36*0.691 ≈ 28.9 —
        // well past the ≈20px a *linear* interpolation would land on at this frame,
        // confirming the sampled easing curve (not straight interpolation) drives it.
        XCTAssertEqual(left, 28.9, accuracy: 1.0)
        XCTAssertGreaterThan(left, 24)
    }

    func testColorAndOpacityAnimateIndependentlyOfPosition() async throws {
        let doc = DocumentFixtures.colorFadeText() // black->white, opacity 1->0, over frames 1...3, .linear
        let url = exportedURL(doc)
        defer { try? FileManager.default.removeItem(at: url) }

        let harness = WebViewHarness()
        try await harness.load(fileURL: url)

        try await harness.evaluate("gotoAndStop(1)")
        let startColor = try await harness.evaluate("getComputedStyle(document.querySelector('.flaj-text')).color")
        let startOpacity = try await harness.evaluate("getComputedStyle(document.querySelector('.flaj-text')).opacity") as? String
        XCTAssertEqual(startColor as? String, "rgb(0, 0, 0)")
        XCTAssertEqual(Double(startOpacity ?? "") ?? -1, 1, accuracy: 0.01)

        try await harness.evaluate("gotoAndStop(3)")
        let endColor = try await harness.evaluate("getComputedStyle(document.querySelector('.flaj-text')).color")
        let endOpacity = try await harness.evaluate("getComputedStyle(document.querySelector('.flaj-text')).opacity") as? String
        XCTAssertEqual(endColor as? String, "rgb(255, 255, 255)")
        XCTAssertEqual(Double(endOpacity ?? "") ?? -1, 0, accuracy: 0.01)

        // Midpoint, real WAAPI-driven interpolation (not just endpoint
        // snapping) — confirms color/opacity are actually animated, not
        // just set once at each keyframe.
        try await harness.evaluate("gotoAndStop(2)")
        let midColor = try await harness.evaluate("getComputedStyle(document.querySelector('.flaj-text')).color")
        let midOpacity = try await harness.evaluate("getComputedStyle(document.querySelector('.flaj-text')).opacity") as? String
        XCTAssertEqual(midColor as? String, "rgb(128, 128, 128)")
        XCTAssertEqual(Double(midOpacity ?? "") ?? -1, 0.5, accuracy: 0.02)
    }

    func testFrameWrapperReservesRealLayoutSpaceForTheScaledStage() async throws {
        let doc = DocumentFixtures.blackWhiteFlip() // 8x8 Stage
        doc.webExportFit = .cover
        let url = exportedURL(doc)
        defer { try? FileManager.default.removeItem(at: url) }

        let harness = WebViewHarness() // 400x300 WKWebView
        try await harness.load(fileURL: url)

        // .cover on an 8x8 Stage in 400x300 fills via max(400/8, 300/8) = 50,
        // so the unscaled #flaj-frame wrapper must claim exactly 400x400 of
        // real layout space — not rely on a transform whose visual footprint
        // doesn't match what it actually occupies in the page.
        let rect = try await harness.evaluate(
            "document.getElementById('flaj-frame').getBoundingClientRect().toJSON()"
        ) as? [String: NSNumber]
        XCTAssertEqual(rect?["width"]?.doubleValue ?? -1, 400, accuracy: 0.5)
        XCTAssertEqual(rect?["height"]?.doubleValue ?? -1, 400, accuracy: 0.5)
    }

    func testCornerAlignmentActuallyHugsThatCornerWhenScaled() async throws {
        let doc = DocumentFixtures.blackWhiteFlip() // 8x8 Stage
        doc.webExportFit = .cover
        doc.webExportAlignment = .bottomTrailing
        let url = exportedURL(doc)
        defer { try? FileManager.default.removeItem(at: url) }

        let harness = WebViewHarness() // 400x300 WKWebView

        try await harness.load(fileURL: url)

        // Scaled to 400x400 (see above) inside a 400x300 view, anchored
        // bottom-right: its right/bottom edges should sit flush against the
        // viewport's, not be centered around some fixed midpoint the way a
        // plain `transform: scale()` with a stale center origin would leave it.
        let rect = try await harness.evaluate(
            "document.getElementById('flaj-frame').getBoundingClientRect().toJSON()"
        ) as? [String: NSNumber]
        XCTAssertEqual(rect?["right"]?.doubleValue ?? -1, 400, accuracy: 0.5)
        XCTAssertEqual(rect?["bottom"]?.doubleValue ?? -1, 300, accuracy: 0.5)
    }

    /// Regression: `html` and `body` both had `justify-content: center` in
    /// the export template, but player.js's applyAlignment() only ever
    /// overrides it on `body` — so once `body` shrinks to fit its content
    /// (which is exactly what happens under `.none`/Actual Size, unlike
    /// `.contain`/`.cover` where the frame scales up to nearly fill the
    /// viewport and masks the bug), `html`'s own untouched centering took
    /// over and the frame drifted to the middle regardless of which of the
    /// 9 alignment points was actually selected.
    func testActualSizeRespectsCornerAlignmentInsteadOfCenteringRegardlessOfIt() async throws {
        let doc = DocumentFixtures.blackWhiteFlip() // 8x8 Stage
        doc.webExportFit = .none
        doc.webExportAlignment = .topLeading
        let url = exportedURL(doc)
        defer { try? FileManager.default.removeItem(at: url) }

        let harness = WebViewHarness() // 400x300 WKWebView
        try await harness.load(fileURL: url)

        let rect = try await harness.evaluate(
            "document.getElementById('flaj-frame').getBoundingClientRect().toJSON()"
        ) as? [String: NSNumber]
        XCTAssertEqual(rect?["left"]?.doubleValue ?? -1, 0, accuracy: 0.5)
        XCTAssertEqual(rect?["top"]?.doubleValue ?? -1, 0, accuracy: 0.5)
    }

    func testOversizedTextIsNotClippedByItsOwnBox() async throws {
        // The native app's Stage view never clips a text box's own content
        // either (SwiftUI's .frame() only sets the box for positioning) —
        // text too large for its box is meant to visibly spill past it,
        // not be silently cropped, so a resize gone wrong is obvious rather
        // than hidden.
        let doc = DocumentFixtures.tweenedText()
        let url = exportedURL(doc)
        defer { try? FileManager.default.removeItem(at: url) }

        let harness = WebViewHarness()
        try await harness.load(fileURL: url)

        let overflow = try await harness.evaluate("getComputedStyle(document.querySelector('.flaj-text')).overflow")
        XCTAssertEqual(overflow as? String, "visible")
    }

    func testExportedDocumentJSONRoundTripsThroughTheFlajFormat() throws {
        let doc = DocumentFixtures.tweenedText()
        doc.webExportTitle = "Round Trip"
        let url = exportedURL(doc)
        defer { try? FileManager.default.removeItem(at: url) }

        let html = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(html.contains("__FLAJ_"), "leftover template placeholder wasn't substituted")

        let openTag = "<script id=\"flaj-document\" type=\"application/json\">"
        let jsonStart = try XCTUnwrap(html.range(of: openTag)).upperBound
        let jsonEnd = try XCTUnwrap(html.range(of: "</script>", range: jsonStart..<html.endIndex)).lowerBound
        let json = String(html[jsonStart..<jsonEnd])

        let file = try JSONDecoder().decode(FlajDocumentFile.self, from: Data(json.utf8))
        XCTAssertEqual(file.webExportTitle, "Round Trip")
        XCTAssertEqual(file.totalFrames, doc.totalFrames)
        XCTAssertEqual(file.layers.count, doc.layers.count)
    }

    /// player.js's `gotoAndStop`/`gotoAndPlay` are a hand-ported mirror of
    /// the native JSContext bridge (see resolveFrameArgument in
    /// TimelineModel.swift) — this is what actually proves the exported
    /// page's label lookup works end to end, not just that it type-checks.
    /// Same black/white-flip shape as testBlackWhiteFlipRunsAndAdvancesFrames,
    /// navigating by the frame-2 label instead of the frame number.
    func testGotoAndStopAndGotoAndPlayResolveAFrameLabel() async throws {
        let layer = TLLayer(
            name: "actions", swatch: .yellow,
            frames: [.keyframe(hasScript: true), .keyframe(hasScript: true)]
        )
        layer.frameScripts = [1: "bg.color('black');", 2: "bg.color('white');"]
        layer.frameLabels[2] = "white"
        let doc = TimelineDocument(layers: [layer], totalFrames: 2)
        doc.stageWidth = 8
        doc.stageHeight = 8
        doc.fps = 1

        let url = exportedURL(doc)
        defer { try? FileManager.default.removeItem(at: url) }

        let harness = WebViewHarness()
        try await harness.load(fileURL: url)

        try await harness.evaluate("gotoAndStop('white')")
        let stoppedColor = try await harness.evaluate("getComputedStyle(document.getElementById('flaj-stage')).backgroundColor")
        XCTAssertEqual(stoppedColor as? String, "rgb(255, 255, 255)")

        try await harness.evaluate("gotoAndStop(1)") // back to frame 1 before proving gotoAndPlay independently
        try await harness.evaluate("gotoAndPlay('white')")
        let playedColor = try await harness.evaluate("getComputedStyle(document.getElementById('flaj-stage')).backgroundColor")
        XCTAssertEqual(playedColor as? String, "rgb(255, 255, 255)")
    }

    /// An unrecognized label should be a no-op (playhead stays put), not a
    /// thrown error or a silent jump to frame 0 — mirrors
    /// testGotoAndPlayByLabelLogsAWarningForAnUnknownLabel on the native side.
    func testGotoAndStopIgnoresAnUnknownLabel() async throws {
        let layer = TLLayer(
            name: "actions", swatch: .yellow,
            frames: [.keyframe(hasScript: true), .keyframe(hasScript: true)]
        )
        layer.frameScripts = [1: "bg.color('black');", 2: "bg.color('white');"]
        let doc = TimelineDocument(layers: [layer], totalFrames: 2)
        doc.stageWidth = 8
        doc.stageHeight = 8
        doc.fps = 1

        let url = exportedURL(doc)
        defer { try? FileManager.default.removeItem(at: url) }

        let harness = WebViewHarness()
        try await harness.load(fileURL: url)

        try await harness.evaluate("gotoAndStop('nowhere')")
        let color = try await harness.evaluate("getComputedStyle(document.getElementById('flaj-stage')).backgroundColor")
        XCTAssertEqual(color as? String, "rgb(0, 0, 0)", "an unresolved label shouldn't move off frame 1's black")
    }

    /// Flash's "named anchor" convention — a frame label starting with "#"
    /// updates the page's URL fragment when reached (see updateNamedAnchor
    /// in player.js), making that point in the movie a real bookmarkable/
    /// back-button-navigable location.
    func testLandingOnAHashLabeledFrameUpdatesTheURLFragment() async throws {
        let layer = TLLayer(
            name: "actions", swatch: .yellow,
            frames: [.keyframe(hasScript: false), .keyframe(hasScript: false)]
        )
        layer.frameLabels = [1: "intro", 2: "#chapter-two"]
        let doc = TimelineDocument(layers: [layer], totalFrames: 2)
        doc.stageWidth = 8
        doc.stageHeight = 8
        doc.fps = 1

        let url = exportedURL(doc)
        defer { try? FileManager.default.removeItem(at: url) }

        let harness = WebViewHarness()
        try await harness.load(fileURL: url)

        let initialHash = try await harness.evaluate("location.hash")
        XCTAssertEqual(initialHash as? String, "", "frame 1's label doesn't start with # — shouldn't touch the URL")

        try await harness.evaluate("gotoAndStop(2)")
        let hashAfter = try await harness.evaluate("location.hash")
        XCTAssertEqual(hashAfter as? String, "#chapter-two")
    }

    /// The read side of the same convention: opening the exported page with
    /// a URL fragment matching a named anchor should start the movie there
    /// instead of frame 1.
    func testOpeningWithAMatchingURLFragmentDeepLinksToThatFrame() async throws {
        let layer = TLLayer(
            name: "actions", swatch: .yellow,
            frames: [.keyframe(hasScript: true), .keyframe(hasScript: true)]
        )
        layer.frameScripts = [1: "bg.color('black');", 2: "bg.color('white');"]
        layer.frameLabels[2] = "#chapter-two"
        let doc = TimelineDocument(layers: [layer], totalFrames: 2)
        doc.stageWidth = 8
        doc.stageHeight = 8
        doc.fps = 1

        let url = exportedURL(doc)
        defer { try? FileManager.default.removeItem(at: url) }
        let deepLinkURL = try XCTUnwrap(URL(string: url.absoluteString + "#chapter-two"))

        let harness = WebViewHarness()
        try await harness.load(fileURL: deepLinkURL)

        let color = try await harness.evaluate("getComputedStyle(document.getElementById('flaj-stage')).backgroundColor")
        XCTAssertEqual(color as? String, "rgb(255, 255, 255)", "should have opened straight on frame 2, not frame 1")
    }

    /// The banner-ad clickTag convention (see TimelineDocument.
    /// clickTagURL and player.js's updateClickTag) — a script sets
    /// `stage.clickTag` to a URL and the whole #flaj-frame becomes a
    /// pointer-cursor link that opens it in a new window on click.
    /// `window.open` is stubbed rather than actually invoked — there's no
    /// real "did a new window open" signal to read back from inside a
    /// WKWebView, but capturing the call and its arguments is just as
    /// strong a guarantee that the click handler does the right thing.
    func testClickTagMakesTheWholeStageAPointerCursorLinkThatOpensInANewWindow() async throws {
        let layer = TLLayer(name: "actions", swatch: .yellow, frames: [.keyframe(hasScript: true)])
        layer.frameScripts[1] = "stage.clickTag = 'https://example.com/ad';"
        let doc = TimelineDocument(layers: [layer], totalFrames: 1)
        doc.stageWidth = 8
        doc.stageHeight = 8

        let url = exportedURL(doc)
        defer { try? FileManager.default.removeItem(at: url) }

        let harness = WebViewHarness()
        try await harness.load(fileURL: url)

        let cursor = try await harness.evaluate("getComputedStyle(document.getElementById('flaj-frame')).cursor")
        XCTAssertEqual(cursor as? String, "pointer")

        let openCall = try await harness.evaluate("""
        (() => {
          window.__openedArgs = null;
          window.open = (url, target) => { window.__openedArgs = [url, target]; };
          document.getElementById('flaj-frame').click();
          return window.__openedArgs;
        })()
        """)
        let args = try XCTUnwrap(openCall as? [Any])
        XCTAssertEqual(args[0] as? String, "https://example.com/ad")
        XCTAssertEqual(args[1] as? String, "_blank")
    }

    /// Without a clickTag set, the Stage should behave exactly as before —
    /// no pointer cursor, no click handler installed at all.
    func testNoClickTagLeavesTheStageWithoutAClickHandlerOrPointerCursor() async throws {
        let doc = DocumentFixtures.blackWhiteFlip()
        let url = exportedURL(doc)
        defer { try? FileManager.default.removeItem(at: url) }

        let harness = WebViewHarness()
        try await harness.load(fileURL: url)

        let cursor = try await harness.evaluate("getComputedStyle(document.getElementById('flaj-frame')).cursor")
        XCTAssertNotEqual(cursor as? String, "pointer")

        let onclickIsSet = try await harness.evaluate("document.getElementById('flaj-frame').onclick !== null")
        XCTAssertEqual(onclickIsSet as? Bool, false)
    }

    /// A rectangle and an ellipse (DocumentFixtures.placedShapes) both
    /// render as `.flaj-shape` divs with the position/size/fill/stroke
    /// values `applyShapeStyle` in player.js is supposed to translate them
    /// into — proves the new shape rendering path end to end in a real
    /// browser, not just that the JSON round-trips.
    func testPlacedShapesRenderAsPositionedDivsWithFillAndStroke() async throws {
        let doc = DocumentFixtures.placedShapes()
        let url = exportedURL(doc)
        defer { try? FileManager.default.removeItem(at: url) }

        let harness = WebViewHarness()
        try await harness.load(fileURL: url)

        let shapeCount = try await harness.evaluate("document.querySelectorAll('.flaj-shape').length")
        XCTAssertEqual(shapeCount as? Int, 2)

        let rectStyle = try await harness.evaluate("""
        (() => {
          const el = document.querySelectorAll('.flaj-shape')[0];
          const s = getComputedStyle(el);
          return [s.left, s.top, s.width, s.height, s.backgroundColor, s.borderRadius];
        })()
        """)
        let rect = try XCTUnwrap(rectStyle as? [String])
        XCTAssertEqual(rect[0], "10px")
        XCTAssertEqual(rect[1], "10px")
        XCTAssertEqual(rect[2], "60px")
        XCTAssertEqual(rect[3], "40px")
        XCTAssertEqual(rect[4], "rgb(51, 153, 255)")
        XCTAssertEqual(rect[5], "0px")

        let ellipseStyle = try await harness.evaluate("""
        (() => {
          const el = document.querySelectorAll('.flaj-shape')[1];
          const s = getComputedStyle(el);
          return [s.backgroundColor, s.borderColor, s.borderWidth, s.borderRadius];
        })()
        """)
        let ellipse = try XCTUnwrap(ellipseStyle as? [String])
        XCTAssertEqual(ellipse[0], "rgba(255, 0, 0, 0.5)")
        XCTAssertEqual(ellipse[1], "rgb(0, 255, 0)")
        XCTAssertEqual(ellipse[2], "4px")
        XCTAssertNotEqual(ellipse[3], "0px")
    }

    /// Proves `shapeBorderRadius`/`el.style.borderStyle` in player.js
    /// actually carry a rectangle's `cornerRadius`/`strokeStyle` into the
    /// exported page's CSS, not just the native Stage.
    func testRoundedDashedShapeCarriesCornerRadiusAndStrokeStyleIntoTheExportedPage() async throws {
        let doc = DocumentFixtures.roundedDashedShape()
        let url = exportedURL(doc)
        defer { try? FileManager.default.removeItem(at: url) }

        let harness = WebViewHarness()
        try await harness.load(fileURL: url)

        let style = try await harness.evaluate("""
        (() => {
          const s = getComputedStyle(document.querySelector('.flaj-shape'));
          return [s.borderRadius, s.borderStyle];
        })()
        """)
        let values = try XCTUnwrap(style as? [String])
        XCTAssertEqual(values[0], "12px")
        XCTAssertEqual(values[1], "dashed")
    }

    /// A tweened shape span (DocumentFixtures.tweenedShape) reaches both
    /// its position/size endpoint and its independently-eased fill/stroke
    /// color+opacity endpoint — mirrors testTweenedTextReachesBothEndpoints,
    /// proving player.js's createShapeVisual builds real, correct start/end
    /// Web Animation keyframes for shapes, not just for text.
    func testTweenedShapeReachesBothEndpoints() async throws {
        let doc = DocumentFixtures.tweenedShape()
        let url = exportedURL(doc)
        defer { try? FileManager.default.removeItem(at: url) }

        let harness = WebViewHarness()
        try await harness.load(fileURL: url)

        try await harness.evaluate("gotoAndStop(1)")
        let start = try await harness.evaluate("""
        (() => {
          const s = getComputedStyle(document.querySelector('.flaj-shape'));
          return [s.left, s.borderTopWidth, s.backgroundColor, s.opacity];
        })()
        """)
        let startValues = try XCTUnwrap(start as? [String])
        XCTAssertEqual(startValues[0], "4px")
        XCTAssertEqual(startValues[1], "0px")
        XCTAssertEqual(startValues[2], "rgba(0, 0, 0, 0)")
        XCTAssertEqual(startValues[3], "0")

        try await harness.evaluate("gotoAndStop(10)")
        let end = try await harness.evaluate("""
        (() => {
          const s = getComputedStyle(document.querySelector('.flaj-shape'));
          return [s.left, s.borderTopWidth, s.backgroundColor, s.opacity];
        })()
        """)
        let endValues = try XCTUnwrap(end as? [String])
        XCTAssertEqual(endValues[0], "40px")
        XCTAssertEqual(endValues[1], "10px")
        XCTAssertEqual(endValues[2], "rgb(255, 255, 255)")
        XCTAssertEqual(endValues[3], "1")
    }

    /// Same proof `testTweenSpanIsARealWebAnimation` gives for text, for a
    /// tweened shape span instead — a real, browser-native Web Animation,
    /// not a per-tick JS-recomputed style.
    func testTweenedShapeSpanIsARealWebAnimation() async throws {
        let doc = DocumentFixtures.tweenedShape()
        let url = exportedURL(doc)
        defer { try? FileManager.default.removeItem(at: url) }

        let harness = WebViewHarness()
        try await harness.load(fileURL: url)
        try await harness.evaluate("gotoAndStop(5)")

        let animationCount = try await harness.evaluate("document.getAnimations().length") as? NSNumber
        XCTAssertGreaterThan(animationCount?.intValue ?? 0, 0)
    }

    /// Proves player.js's clip-path masking (maskAwareParent/clipPathFor/
    /// syncMaskWraps) actually wires up in a real page: the masked
    /// content's `.flaj-shape` div lives inside a `.flaj-mask-wrap` with a
    /// real (non-`none`) clip-path, and the mask layer's own shape is
    /// never itself rendered as a second, independently visible
    /// `.flaj-shape` — mirrors the native-side proof in
    /// MaskTests/GIFExportTests, for the web export path instead.
    func testMaskedShapeGetsClipPathAppliedInTheExportedPage() async throws {
        let doc = DocumentFixtures.maskedShape()
        let url = exportedURL(doc)
        defer { try? FileManager.default.removeItem(at: url) }

        let harness = WebViewHarness()
        try await harness.load(fileURL: url)

        let shapeCount = try await harness.evaluate("document.querySelectorAll('.flaj-shape').length")
        XCTAssertEqual(shapeCount as? Int, 1, "the mask layer's own shape should never render as a second, independently visible .flaj-shape")

        let wrapExists = try await harness.evaluate("document.querySelector('.flaj-mask-wrap .flaj-shape') !== null")
        XCTAssertEqual(wrapExists as? Bool, true, "the masked content's shape should live inside the mask wrapper")

        let clipPath = try await harness.evaluate("getComputedStyle(document.querySelector('.flaj-mask-wrap')).clipPath")
        XCTAssertNotEqual(clipPath as? String, "none")
    }

    /// Proves player.js's group rendering (createGroupVisual) actually
    /// wires up in a real page: both bundled shapes render as `.flaj-shape`
    /// children inside one `.flaj-group` wrapper, each at its own
    /// group-relative position.
    func testGroupRendersBothChildrenAtTheirRelativePositionsInTheExportedPage() async throws {
        let doc = DocumentFixtures.groupedShapes()
        let url = exportedURL(doc)
        defer { try? FileManager.default.removeItem(at: url) }

        let harness = WebViewHarness()
        try await harness.load(fileURL: url)

        let groupCount = try await harness.evaluate("document.querySelectorAll('.flaj-group').length")
        XCTAssertEqual(groupCount as? Int, 1)

        let childCount = try await harness.evaluate("document.querySelectorAll('.flaj-group .flaj-shape').length")
        XCTAssertEqual(childCount as? Int, 2, "both bundled shapes should render inside the group wrapper")

        let positions = try await harness.evaluate("""
        (() => {
          const wrap = getComputedStyle(document.querySelector('.flaj-group'));
          const children = Array.from(document.querySelectorAll('.flaj-group .flaj-shape'))
            .map(el => getComputedStyle(el).left);
          return [wrap.left, wrap.top, ...children];
        })()
        """)
        let values = try XCTUnwrap(positions as? [String])
        XCTAssertEqual(values[0], "5px") // group.x
        XCTAssertEqual(values[1], "5px") // group.y
        XCTAssertEqual(Set(values[2...]), ["0px", "10px"], "each child's left should be relative to the group's own origin")
    }
}
