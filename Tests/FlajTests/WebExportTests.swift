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
}
