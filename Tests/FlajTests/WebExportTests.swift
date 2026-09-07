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
}
