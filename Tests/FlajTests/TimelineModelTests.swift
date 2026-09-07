import XCTest
@testable import Flaj

/// Direct tests of `TLLayer.interpolatedPlacedText` — the one source of
/// truth shared by live Stage rendering, GIF export, and (ported by hand)
/// the web player. Unlike GIFExportTests/WebExportTests, these don't go
/// through any rendering pipeline — they isolate the interpolation math
/// itself, which is where a color/opacity regression would actually live.
@MainActor
final class TimelineModelTests: XCTestCase {

    func testNudgeSelectedPlacementMovesByGivenDelta() {
        let layer = TLLayer(name: "text", swatch: .green, frames: [.keyframe(hasScript: false)])
        layer.textFrames[1] = PlacedText(text: "Hi", x: 10, y: 10, width: 20, height: 10)
        let doc = TimelineDocument(layers: [layer], totalFrames: 1)
        doc.selectedPlacement = TimelineDocument.TextPlacementRef(layerID: layer.id, keyframe: 1)

        doc.nudgeSelectedPlacement(dx: 0, dy: -1) // up arrow, plain
        XCTAssertEqual(layer.textFrames[1]?.x, 10)
        XCTAssertEqual(layer.textFrames[1]?.y, 9)

        doc.nudgeSelectedPlacement(dx: 10, dy: 0) // right arrow, Shift
        XCTAssertEqual(layer.textFrames[1]?.x, 20)
        XCTAssertEqual(layer.textFrames[1]?.y, 9)
    }

    func testNudgeSelectedPlacementIsANoOpWithNoSelection() {
        let layer = TLLayer(name: "text", swatch: .green, frames: [.keyframe(hasScript: false)])
        layer.textFrames[1] = PlacedText(text: "Hi", x: 10, y: 10, width: 20, height: 10)
        let doc = TimelineDocument(layers: [layer], totalFrames: 1)
        XCTAssertNil(doc.selectedPlacement)

        doc.nudgeSelectedPlacement(dx: 5, dy: 5)
        XCTAssertEqual(layer.textFrames[1]?.x, 10)
        XCTAssertEqual(layer.textFrames[1]?.y, 10)
    }

    func testColorAndOpacityFadeIndependentlyOfPositionAndSize() {
        let doc = DocumentFixtures.colorFadeText()
        let layer = doc.layers[0]

        // Position/size never move in this fixture — only color/opacity
        // are under test, via colorTweenSettings, isolated from tweenSettings.
        for frame in 1...3 {
            let placement = layer.interpolatedPlacedText(at: frame)
            XCTAssertEqual(placement?.x, 10)
            XCTAssertEqual(placement?.width, 100)
        }

        let start = layer.interpolatedPlacedText(at: 1)
        XCTAssertEqual(start?.colorHex, "#000000")
        XCTAssertEqual(start?.opacity, 1)

        // Midpoint: rawT = (2-1)/(3-1) = 0.5 exactly, and `.linear` easing
        // returns that unchanged, so this is an exact expected value, not
        // an approximation.
        let mid = layer.interpolatedPlacedText(at: 2)
        XCTAssertEqual(mid?.colorHex, "#808080")
        XCTAssertEqual(mid?.opacity ?? -1, 0.5, accuracy: 0.0001)

        let end = layer.interpolatedPlacedText(at: 3)
        XCTAssertEqual(end?.colorHex, "#FFFFFF")
        XCTAssertEqual(end?.opacity, 0)
    }

    func testKeyframeInsertedFarPastAnUnextendedKeyframeInheritsItsContent() {
        // Exactly the reported scenario: type text on frame 1, jump straight
        // to frame 10 (never pressing F5 in between, so frames 2...9 are
        // still `.empty`), then F6 — frame 10 should come in with frame 1's
        // text already there, at the same position, the way Flash's own
        // timeline implicitly continues a keyframe forward to wherever you
        // next press F6, not just to wherever an earlier F5 stopped.
        let layer = TLLayer(name: "text", swatch: .green, frames: [.keyframe(hasScript: false)] + Array(repeating: .empty, count: 9))
        layer.textFrames[1] = PlacedText(text: "I love flaj", x: 12, y: 34, width: 90, height: 20, colorHex: "#112233", opacity: 1)

        let doc = TimelineDocument(layers: [layer], totalFrames: 10)
        doc.insertKeyframe(layer: layer, at: 10, blank: false)

        XCTAssertEqual(layer.textFrames[10]?.text, "I love flaj")
        XCTAssertEqual(layer.textFrames[10]?.x, 12)
        XCTAssertEqual(layer.textFrames[10]?.y, 34)
        XCTAssertEqual(layer.textFrames[10]?.colorHex, "#112233")
        XCTAssertTrue(layer.isKeyframe(at: 10))

        // The gap is bridged with plain continuation frames, not left as a
        // dangling, ungoverned keyframe.
        for frame in 2...9 {
            XCTAssertEqual(layer.governingKeyframe(at: frame), 1)
        }
    }

    func testInsertFrameBridgesAGapBackToTheNearestKeyframeToo() {
        let layer = TLLayer(name: "text", swatch: .green, frames: [.keyframe(hasScript: false)] + Array(repeating: .empty, count: 9))
        layer.textFrames[1] = PlacedText(text: "Hi", x: 0, y: 0, width: 20, height: 10)

        let doc = TimelineDocument(layers: [layer], totalFrames: 10)
        doc.insertFrame(layer: layer, at: 10)

        // Frame 10 (and everything back to frame 1) is now governed content,
        // not a dangling `.plain` mark with nothing behind it.
        XCTAssertEqual(layer.governingKeyframe(at: 10), 1)
        XCTAssertEqual(layer.interpolatedPlacedText(at: 10)?.text, "Hi")
    }

    func testColorEasingIsIndependentOfPositionEasing() {
        // Same span, deliberately mismatched curves: position eases out
        // quad (front-loaded motion), color eases in cubic (back-loaded
        // color change) — if these secretly shared one curve, the color
        // and position progress at the same rawT would be equal, or at
        // least trend the same direction relative to linear; they don't.
        let frames: [FrameMark] = [.keyframe(hasScript: false), .tween, .tween, .tween, .keyframe(hasScript: false)]
        let layer = TLLayer(name: "text", swatch: .green, frames: frames)
        layer.textFrames[1] = PlacedText(text: "A", x: 0, y: 0, width: 10, height: 10, colorHex: "#000000", opacity: 0)
        layer.textFrames[5] = PlacedText(text: "A", x: 100, y: 0, width: 10, height: 10, colorHex: "#FFFFFF", opacity: 1)
        layer.tweenSettings[1] = TweenSettings(family: .quad, direction: .easeOut, amount: 100)
        layer.colorTweenSettings[1] = TweenSettings(family: .cubic, direction: .easeIn, amount: 100)

        // rawT at frame 2 = (2-1)/(5-1) = 0.25.
        // Position (quad easeOut): 1 - (1-0.25)^2 = 0.4375 -> x = 43.75.
        // Color (cubic easeIn): 0.25^3 = 0.015625 -> opacity = 0.015625.
        let placement = layer.interpolatedPlacedText(at: 2)
        XCTAssertEqual(placement?.x ?? -1, 43.75, accuracy: 0.01)
        XCTAssertEqual(placement?.opacity ?? -1, 0.015625, accuracy: 0.0001)
    }
}
