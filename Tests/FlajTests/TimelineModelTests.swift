import XCTest
@testable import Flaj

/// Direct tests of `TLLayer.interpolatedPlacedText` — the one source of
/// truth shared by live Stage rendering, GIF export, and (ported by hand)
/// the web player. Unlike GIFExportTests/WebExportTests, these don't go
/// through any rendering pipeline — they isolate the interpolation math
/// itself, which is where a color/opacity regression would actually live.
@MainActor
final class TimelineModelTests: XCTestCase {

    func testFreshDocumentHasNoSelectedFrameUntilAClick() {
        // selectedFrame itself still defaults to 1 (F5/F6-type actions need
        // a sane frame to act on before any click) — hasSelectedFrame is
        // what the frame grid actually gates its highlight on, so a brand
        // new document doesn't look like frame 1 is already selected.
        let doc = TimelineDocument.sample()
        XCTAssertFalse(doc.hasSelectedFrame)

        let layer = doc.layers[0]
        doc.selectFrame(layer: layer, frame: 1, extend: false)
        XCTAssertTrue(doc.hasSelectedFrame)
    }

    func testOpeningADocumentClearsAnyPriorFrameSelection() throws {
        let doc = DocumentFixtures.blackWhiteFlip()
        doc.selectFrame(layer: doc.layers[0], frame: 1, extend: false)
        XCTAssertTrue(doc.hasSelectedFrame)

        let file = try JSONDecoder().decode(FlajDocumentFile.self, from: JSONEncoder().encode(doc.makeSaveFile()))
        doc.load(from: file)

        XCTAssertFalse(doc.hasSelectedFrame)
    }

    func testSelectFrameSelectsPlacedTextOnAKeyframeThatHasIt() {
        let layer = TLLayer(name: "text", swatch: .green, frames: [.keyframe(hasScript: false), .empty])
        layer.textFrames[1] = PlacedText(text: "Hi", x: 0, y: 0, width: 20, height: 10)
        let doc = TimelineDocument(layers: [layer], totalFrames: 2)

        doc.selectFrame(layer: layer, frame: 1, extend: false)
        XCTAssertEqual(doc.selectedPlacement, TimelineDocument.TextPlacementRef(layerID: layer.id, keyframe: 1))
    }

    func testSelectFrameClearsSelectionOnAFrameWithNoPlacedText() {
        let layer = TLLayer(name: "text", swatch: .green, frames: [.keyframe(hasScript: false), .empty])
        layer.textFrames[1] = PlacedText(text: "Hi", x: 0, y: 0, width: 20, height: 10)
        let doc = TimelineDocument(layers: [layer], totalFrames: 2)
        doc.selectedPlacement = TimelineDocument.TextPlacementRef(layerID: layer.id, keyframe: 1)

        doc.selectFrame(layer: layer, frame: 2, extend: false)
        XCTAssertNil(doc.selectedPlacement)
    }

    /// A frame that's merely *inside* a tween (not the governing keyframe
    /// itself) must NOT auto-select — that's what lets `activeTweenRef`
    /// drive the Properties panel's Tweening section for those frames;
    /// selecting a placement there would silently hide it (the panel
    /// treats text/tween as mutually exclusive).
    func testSelectFrameInsideATweenSpanDoesNotAutoSelectThePlacement() {
        let frames: [FrameMark] = [.keyframe(hasScript: false), .tween, .keyframe(hasScript: false)]
        let layer = TLLayer(name: "text", swatch: .green, frames: frames)
        layer.textFrames[1] = PlacedText(text: "A", x: 0, y: 0, width: 10, height: 10)
        layer.textFrames[3] = PlacedText(text: "A", x: 50, y: 0, width: 10, height: 10)
        let doc = TimelineDocument(layers: [layer], totalFrames: 3)

        doc.selectFrame(layer: layer, frame: 2, extend: false)
        XCTAssertNil(doc.selectedPlacement, "frame 2 is inside the span, not the governing keyframe (frame 1)")

        doc.selectFrame(layer: layer, frame: 1, extend: false)
        XCTAssertEqual(doc.selectedPlacement?.keyframe, 1, "but landing exactly on the governing keyframe does select it")
    }

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

    func testScaleAndRotationTweenAlongsidePositionNotColor() {
        // Deliberately mismatched curves on the position/size vs. color
        // tween — if scale/rotation secretly interpolated on colorT instead
        // of t (the position/size group they actually belong to, per
        // PlacedText.rotation's own doc comment), the midpoint values below
        // would land on the color curve's progress instead of position's.
        let frames: [FrameMark] = [.keyframe(hasScript: false), .tween, .keyframe(hasScript: false)]
        let layer = TLLayer(name: "text", swatch: .green, frames: frames)
        layer.textFrames[1] = PlacedText(x: 0, y: 0, width: 10, height: 10, scale: 1, rotation: 0)
        layer.textFrames[3] = PlacedText(x: 0, y: 0, width: 10, height: 10, scale: 3, rotation: 180)
        layer.tweenSettings[1] = TweenSettings(family: .linear)
        layer.colorTweenSettings[1] = TweenSettings(family: .quad, direction: .easeIn, amount: 100)

        // Midpoint, rawT = 0.5. Position/size group is `.linear` -> 0.5
        // exactly. Color group is quad-easeIn -> 0.25 at rawT=0.5 — if
        // scale/rotation used that curve instead, these values would be
        // 1 + (3-1)*0.25 = 1.5 and 0 + 180*0.25 = 45, not the asserted ones.
        let mid = layer.interpolatedPlacedText(at: 2)
        XCTAssertEqual(mid?.scale ?? -1, 2, accuracy: 0.0001)
        XCTAssertEqual(mid?.rotation ?? -1, 90, accuracy: 0.0001)
    }

    func testMoveKeyframeCarriesItsContentToTheNewFrame() {
        let layer = TLLayer(
            name: "actions", swatch: .yellow,
            frames: [.keyframe(hasScript: true), .plain, .plain, .empty, .empty]
        )
        layer.frameScripts[1] = "trace('hi');"
        layer.textFrames[1] = PlacedText(text: "A", x: 1, y: 2, width: 10, height: 10)
        layer.frameLabels[1] = "start"
        let doc = TimelineDocument(layers: [layer], totalFrames: 5)

        doc.moveKeyframe(layer: layer, from: 1, to: 5)

        XCTAssertEqual(layer.frames[4], .keyframe(hasScript: true))
        XCTAssertEqual(layer.frameScripts[5], "trace('hi');")
        XCTAssertEqual(layer.textFrames[5]?.text, "A")
        XCTAssertEqual(layer.frameLabels[5], "start")

        // The old position, and the `.plain` span it used to govern, are
        // both cleared rather than left as dangling/ungoverned marks.
        XCTAssertEqual(layer.frames[0], .empty)
        XCTAssertEqual(layer.frames[1], .empty)
        XCTAssertEqual(layer.frames[2], .empty)
        XCTAssertNil(layer.frameScripts[1])
        XCTAssertNil(layer.textFrames[1])
        XCTAssertNil(layer.frameLabels[1])
    }

    func testMoveKeyframeRefusesATweenStartKeyframe() {
        let frames: [FrameMark] = [.keyframe(hasScript: false), .tween, .keyframe(hasScript: false)]
        let layer = TLLayer(name: "text", swatch: .green, frames: frames)
        layer.textFrames[1] = PlacedText(text: "A", x: 0, y: 0, width: 10, height: 10)
        layer.textFrames[3] = PlacedText(text: "A", x: 50, y: 0, width: 10, height: 10)
        layer.tweenSettings[1] = TweenSettings(family: .quad)
        let doc = TimelineDocument(layers: [layer], totalFrames: 3)

        doc.moveKeyframe(layer: layer, from: 1, to: 10) // must not disturb the tween it anchors
        XCTAssertEqual(layer.frames[0], .keyframe(hasScript: false))
        XCTAssertNotNil(layer.tweenSettings[1])
    }

    func testMoveKeyframeUpdatesSelectedFrameIfItWasTheOneMoved() {
        let layer = TLLayer(name: "actions", swatch: .yellow, frames: [.keyframe(hasScript: false), .empty])
        let doc = TimelineDocument(layers: [layer], totalFrames: 2)
        doc.selectedFrame = 1

        doc.moveKeyframe(layer: layer, from: 1, to: 2)
        XCTAssertEqual(doc.selectedFrame, 2)
    }

    /// Regression: double-clicking a cell that's already a keyframe (the
    /// Timeline's double-click gesture always calls `insertKeyframe(...,
    /// blank: false)` regardless of the frame's current state) used to
    /// crash — `nearestKeyframe(before:)` is actually "at or before", so
    /// when `frame` is already a keyframe it returned `frame` itself, and
    /// extendSpan's `(priorKeyframe + 1)...frame` became an invalid range
    /// (e.g. 2...1) that Swift traps on constructing.
    func testInsertKeyframeOnAnAlreadyExistingKeyframeDoesNotCrash() {
        let layer = TLLayer(name: "actions", swatch: .yellow, frames: [.keyframe(hasScript: false)])
        let doc = TimelineDocument(layers: [layer], totalFrames: 1)

        doc.insertKeyframe(layer: layer, at: 1, blank: false) // must not trap
        XCTAssertTrue(layer.isKeyframe(at: 1))
    }

    /// Same crash, reached through a keyframe that isn't the very first
    /// frame — makes sure the fix isn't accidentally special-casing frame 1.
    func testInsertKeyframeOnALaterExistingKeyframeDoesNotCrash() {
        let layer = TLLayer(
            name: "actions", swatch: .yellow,
            frames: [.keyframe(hasScript: false), .plain, .keyframe(hasScript: false)]
        )
        let doc = TimelineDocument(layers: [layer], totalFrames: 3)

        doc.insertKeyframe(layer: layer, at: 3, blank: false) // must not trap
        XCTAssertTrue(layer.isKeyframe(at: 3))
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
