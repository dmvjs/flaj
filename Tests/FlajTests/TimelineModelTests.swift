import XCTest
import SwiftUI
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

    /// Drop Shadow/Glow are static per span, same category as bold/italic/
    /// fontName (see `PlacedText.dropShadow`'s own doc comment) — carried
    /// through from the start keyframe for the whole span rather than
    /// eased or swapped partway through, even when the end keyframe sets a
    /// completely different filter (or none at all).
    func testFiltersStayFixedAtTheStartKeyframesValueAcrossATweenSpan() {
        let frames: [FrameMark] = [.keyframe(hasScript: false), .tween, .keyframe(hasScript: false)]
        let layer = TLLayer(name: "text", swatch: .green, frames: frames)
        layer.textFrames[1] = PlacedText(x: 0, y: 0, dropShadow: DropShadowFilter(colorHex: "#000000", blur: 4, offsetX: 2, offsetY: 2, opacity: 0.5))
        layer.textFrames[3] = PlacedText(x: 0, y: 0, glow: GlowFilter(colorHex: "#FFFFFF", blur: 8, opacity: 0.8)) // no dropShadow at all
        layer.tweenSettings[1] = TweenSettings(family: .linear)

        let mid = layer.interpolatedPlacedText(at: 2)
        XCTAssertEqual(mid?.dropShadow, DropShadowFilter(colorHex: "#000000", blur: 4, offsetX: 2, offsetY: 2, opacity: 0.5), "should still be the start keyframe's shadow, not eased toward nil")
        XCTAssertNil(mid?.glow, "the end keyframe's glow shouldn't appear before the span actually reaches it")
    }

    func testMoveKeyframeCarriesItsContentToTheNewFrame() {
        let layer = TLLayer(
            name: "actions", swatch: .yellow,
            frames: [.keyframe(hasScript: true), .plain, .plain, .empty, .empty]
        )
        layer.frameScripts[1] = "trace('hi');"
        layer.textFrames[1] = PlacedText(text: "A", x: 1, y: 2, width: 10, height: 10)
        layer.frameLabels[1] = FrameLabel(text: "start")
        let doc = TimelineDocument(layers: [layer], totalFrames: 5)

        doc.moveKeyframe(layer: layer, from: 1, to: 5)

        XCTAssertEqual(layer.frames[4], .keyframe(hasScript: true))
        XCTAssertEqual(layer.frameScripts[5], "trace('hi');")
        XCTAssertEqual(layer.textFrames[5]?.text, "A")
        XCTAssertEqual(layer.frameLabels[5]?.text, "start")

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

    /// The audit-flagged gap this fills: F5 pressed where there's real
    /// content later on the layer must shift that content forward instead
    /// of silently doing nothing (the old guard required the target cell
    /// to already be `.empty`).
    func testInsertFrameShiftsALaterKeyframeAndItsContentForward() {
        let layer = TLLayer(name: "text", swatch: .green, frames: [.keyframe(hasScript: false), .plain, .keyframe(hasScript: false)])
        layer.textFrames[1] = PlacedText(text: "A", x: 0, y: 0, width: 10, height: 10)
        layer.textFrames[3] = PlacedText(text: "B", x: 0, y: 0, width: 10, height: 10)
        layer.frameLabels[3] = FrameLabel(text: "end")
        let doc = TimelineDocument(layers: [layer], totalFrames: 3)

        doc.insertFrame(layer: layer, at: 2)

        XCTAssertEqual(layer.frames, [.keyframe(hasScript: false), .plain, .plain, .keyframe(hasScript: false)])
        XCTAssertEqual(layer.textFrames[1]?.text, "A", "content before the insertion point stays put")
        XCTAssertNil(layer.textFrames[3], "the old frame 3 content moved to frame 4")
        XCTAssertEqual(layer.textFrames[4]?.text, "B")
        XCTAssertEqual(layer.frameLabels[4]?.text, "end")
        XCTAssertEqual(doc.totalFrames, 4, "the layer grew, so the document's own frame count follows")
    }

    func testInsertFrameShiftingPadsEveryOtherLayerToStayTheSameLength() {
        let a = TLLayer(name: "a", swatch: .green, frames: [.keyframe(hasScript: false), .plain, .keyframe(hasScript: false)])
        let b = TLLayer(name: "b", swatch: .blue, frames: [.keyframe(hasScript: false), .plain, .plain])
        let doc = TimelineDocument(layers: [a, b], totalFrames: 3)

        doc.insertFrame(layer: a, at: 2)

        XCTAssertEqual(a.frames.count, 4)
        XCTAssertEqual(b.frames.count, 4, "every layer stays the same length as the document's own frame count")
        XCTAssertEqual(b.frames[3], .empty, "the padding on an untouched layer is genuinely empty, not a continuation")
    }

    func testRemoveFramesShiftsLaterContentBackAndDropsTheRemovedFramesOwnContent() {
        let layer = TLLayer(name: "text", swatch: .green, frames: [.keyframe(hasScript: false), .plain, .keyframe(hasScript: false)])
        layer.textFrames[1] = PlacedText(text: "A", x: 0, y: 0, width: 10, height: 10)
        layer.textFrames[3] = PlacedText(text: "B", x: 0, y: 0, width: 10, height: 10)
        let doc = TimelineDocument(layers: [layer], totalFrames: 3)

        doc.removeFrames(layer: layer, at: 2)

        XCTAssertEqual(layer.frames, [.keyframe(hasScript: false), .keyframe(hasScript: false), .empty])
        XCTAssertEqual(layer.textFrames[1]?.text, "A")
        XCTAssertEqual(layer.textFrames[2]?.text, "B", "the old frame 3 content moved back to frame 2")
        XCTAssertEqual(layer.frames.count, 3, "removing pads the tail back to the document's frame count rather than shrinking it")
    }

    func testRemoveFramesDropsTheRemovedKeyframesOwnContentEvenThoughNothingIsAfterIt() {
        let layer = TLLayer(name: "text", swatch: .green, frames: [.keyframe(hasScript: false), .keyframe(hasScript: false)])
        layer.textFrames[1] = PlacedText(text: "A", x: 0, y: 0, width: 10, height: 10)
        layer.textFrames[2] = PlacedText(text: "B", x: 0, y: 0, width: 10, height: 10)
        let doc = TimelineDocument(layers: [layer], totalFrames: 2)

        doc.removeFrames(layer: layer, at: 2)

        XCTAssertNil(layer.textFrames[2], "frame 2's own content is gone, not shifted onto itself")
        XCTAssertEqual(layer.textFrames[1]?.text, "A")
    }

    /// `insertFrame` grows the document's own `totalFrames` when this layer
    /// becomes the longest one — `removeFrames` deliberately doesn't shrink
    /// it back (see its own doc comment), so the round trip restores the
    /// original *content* but leaves the document one frame longer, with a
    /// genuinely empty tail rather than shrinking the timeline back down.
    func testInsertFrameThenRemoveFramesRestoresContentButNotTheFrameCount() {
        let layer = TLLayer(name: "text", swatch: .green, frames: [.keyframe(hasScript: false), .plain, .keyframe(hasScript: false)])
        layer.textFrames[1] = PlacedText(text: "A", x: 0, y: 0, width: 10, height: 10)
        layer.textFrames[3] = PlacedText(text: "B", x: 0, y: 0, width: 10, height: 10)
        let doc = TimelineDocument(layers: [layer], totalFrames: 3)

        doc.insertFrame(layer: layer, at: 2)
        doc.removeFrames(layer: layer, at: 2)

        XCTAssertEqual(layer.frames, [.keyframe(hasScript: false), .plain, .keyframe(hasScript: false), .empty])
        XCTAssertEqual(layer.textFrames[1]?.text, "A")
        XCTAssertEqual(layer.textFrames[3]?.text, "B")
        XCTAssertEqual(doc.totalFrames, 4)
    }

    func testSelectAllFramesSelectsTheWholeLayerAsOneRange() {
        let layer = TLLayer(name: "text", swatch: .green, frames: Array(repeating: .empty, count: 5))
        let doc = TimelineDocument(layers: [layer], totalFrames: 5)
        doc.selectedLayerID = layer.id

        doc.selectAllFrames()

        XCTAssertTrue(doc.hasSelectedFrame)
        XCTAssertEqual(doc.selectedFrameRange, 1...5)
    }

    func testReverseFramesMirrorsMarksAndContentAroundTheRangeCenter() {
        let layer = TLLayer(name: "text", swatch: .green, frames: [.keyframe(hasScript: false), .plain, .keyframe(hasScript: false)])
        layer.textFrames[1] = PlacedText(text: "A", x: 0, y: 0, width: 10, height: 10)
        layer.textFrames[3] = PlacedText(text: "B", x: 0, y: 0, width: 10, height: 10)
        let doc = TimelineDocument(layers: [layer], totalFrames: 3)

        doc.reverseFrames(layer: layer, range: 1...3)

        XCTAssertEqual(layer.frames, [.keyframe(hasScript: false), .plain, .keyframe(hasScript: false)], "the mark shape at the middle/ends is symmetric here, so it reads the same reversed")
        XCTAssertEqual(layer.textFrames[1]?.text, "B", "content at the two ends swapped")
        XCTAssertEqual(layer.textFrames[3]?.text, "A")
    }

    /// A tween's easing stays keyed at the span's start position — reversal
    /// only swaps which content sits at each end, so the same curve now
    /// runs from the old end's content to the old start's.
    func testReverseFramesLeavesATweensEasingAtTheSpansStartPosition() {
        let layer = TLLayer(name: "text", swatch: .green, frames: [.keyframe(hasScript: false), .tween, .keyframe(hasScript: false)])
        layer.textFrames[1] = PlacedText(text: "A", x: 0, y: 0, width: 10, height: 10)
        layer.textFrames[3] = PlacedText(text: "B", x: 0, y: 0, width: 10, height: 10)
        layer.tweenSettings[1] = TweenSettings(family: .quad, direction: .easeOut, amount: 100)
        let doc = TimelineDocument(layers: [layer], totalFrames: 3)

        doc.reverseFrames(layer: layer, range: 1...3)

        XCTAssertNil(layer.tweenSettings[3], "the span's start is still frame 1, not wherever its old content moved to")
        XCTAssertEqual(layer.tweenSettings[1]?.family, .quad, "same easing curve, untouched by the content swap")
        XCTAssertEqual(layer.textFrames[1]?.text, "B", "frame 1 now shows what used to be at the end")
        XCTAssertEqual(layer.textFrames[3]?.text, "A")
    }

    func testReverseFramesIsANoOpOnASingleFrameRange() {
        let layer = TLLayer(name: "text", swatch: .green, frames: [.keyframe(hasScript: false)])
        layer.textFrames[1] = PlacedText(text: "A", x: 0, y: 0, width: 10, height: 10)
        let doc = TimelineDocument(layers: [layer], totalFrames: 1)

        doc.reverseFrames(layer: layer, range: 1...1)
        XCTAssertEqual(layer.textFrames[1]?.text, "A")
    }

    func testCutSelectedFramesCopiesThenClearsInPlaceWithoutShifting() {
        let layer = TLLayer(name: "text", swatch: .green, frames: [.keyframe(hasScript: false), .plain, .keyframe(hasScript: false)])
        layer.textFrames[1] = PlacedText(text: "A", x: 0, y: 0, width: 10, height: 10)
        layer.textFrames[3] = PlacedText(text: "B", x: 0, y: 0, width: 10, height: 10)
        let doc = TimelineDocument(layers: [layer], totalFrames: 3)
        doc.selectedLayerID = layer.id
        doc.selectFrame(layer: layer, frame: 1, extend: false)
        doc.selectFrame(layer: layer, frame: 3, extend: true)

        doc.cutSelectedFrames()

        XCTAssertTrue(doc.hasCopiedFrames, "Cut Frames copies before clearing")
        XCTAssertEqual(layer.frames, [.empty, .empty, .empty], "cleared in place, not shifted")
        XCTAssertNil(layer.textFrames[1])
        XCTAssertNil(layer.textFrames[3])

        let dest = TLLayer(name: "dest", swatch: .blue, frames: Array(repeating: .empty, count: 3))
        doc.layers.append(dest)
        doc.pasteFrames(layer: dest, at: 1)
        XCTAssertEqual(dest.textFrames[1]?.text, "A", "the cut content is still pasteable afterward")
        XCTAssertEqual(dest.textFrames[3]?.text, "B")
    }

    // MARK: - Property keyframes

    func testIsPropertyKeyframeTrueOnlyOnATweenFrameWithItsOwnContent() {
        let layer = TLLayer(name: "text", swatch: .green, frames: [.keyframe(hasScript: false), .tween, .keyframe(hasScript: false)])
        XCTAssertFalse(layer.isPropertyKeyframe(at: 2), "a plain .tween frame with no content of its own isn't one")

        layer.textFrames[2] = PlacedText(text: "mid", x: 0, y: 0, width: 10, height: 10)
        XCTAssertTrue(layer.isPropertyKeyframe(at: 2))
        XCTAssertFalse(layer.isPropertyKeyframe(at: 1), "frame 1 is a real keyframe, not a property keyframe")
    }

    /// Adding a property keyframe must be visually seamless — it captures
    /// exactly what was already interpolating there, so nothing appears to
    /// jump the instant you add it.
    func testAddPropertyKeyframeCapturesTheCurrentlyInterpolatedValueExactly() {
        let layer = TLLayer(name: "text", swatch: .green, frames: [.keyframe(hasScript: false), .tween, .tween, .tween, .keyframe(hasScript: false)])
        layer.textFrames[1] = PlacedText(text: "A", x: 0, y: 0, width: 10, height: 10)
        layer.textFrames[5] = PlacedText(text: "A", x: 100, y: 0, width: 10, height: 10)
        layer.tweenSettings[1] = TweenSettings(family: .linear)
        let doc = TimelineDocument(layers: [layer], totalFrames: 5)

        let before = layer.interpolatedPlacedText(at: 3)?.x
        doc.addPropertyKeyframe(layer: layer, at: 3)

        XCTAssertTrue(layer.isPropertyKeyframe(at: 3))
        XCTAssertEqual(layer.textFrames[3]?.x, before)
        XCTAssertEqual(layer.frames[2], .tween, "adding one doesn't change the frame's mark")
    }

    func testAddPropertyKeyframeIsANoOpOutsideALiveTweenSpan() {
        let layer = TLLayer(name: "text", swatch: .green, frames: [.keyframe(hasScript: false), .plain])
        layer.textFrames[1] = PlacedText(text: "A", x: 0, y: 0, width: 10, height: 10)
        let doc = TimelineDocument(layers: [layer], totalFrames: 2)

        doc.addPropertyKeyframe(layer: layer, at: 2)
        XCTAssertNil(layer.textFrames[2], "frame 2 is a plain span, not a tween — nothing to checkpoint")
    }

    /// The actual point of a property keyframe: the eased curve re-targets
    /// through it, so a segment on one side of the checkpoint can look
    /// completely different from the segment on the other side.
    func testPropertyKeyframeSplitsTheSpanIntoTwoIndependentlyEasedSegments() {
        let layer = TLLayer(name: "text", swatch: .green, frames: [.keyframe(hasScript: false), .tween, .tween, .tween, .keyframe(hasScript: false)])
        layer.textFrames[1] = PlacedText(text: "A", x: 0, y: 0, width: 10, height: 10)
        layer.textFrames[5] = PlacedText(text: "A", x: 100, y: 0, width: 10, height: 10)
        layer.tweenSettings[1] = TweenSettings(family: .linear)
        // A property keyframe at frame 3 that overshoots past both
        // endpoints — impossible to produce by simply easing 0->100.
        layer.textFrames[3] = PlacedText(text: "A", x: 200, y: 0, width: 10, height: 10)
        let doc = TimelineDocument(layers: [layer], totalFrames: 5)

        XCTAssertEqual(doc.layers[0].interpolatedPlacedText(at: 2)?.x ?? -1, 100, accuracy: 0.01, "halfway from 0 to the checkpoint's 200")
        XCTAssertEqual(layer.interpolatedPlacedText(at: 3)?.x ?? -1, 200, accuracy: 0.01, "exactly on the checkpoint")
        XCTAssertEqual(layer.interpolatedPlacedText(at: 4)?.x ?? -1, 150, accuracy: 0.01, "halfway from the checkpoint's 200 back down to 100")
        XCTAssertEqual(layer.interpolatedPlacedText(at: 5)?.x ?? -1, 100, accuracy: 0.01)
    }

    func testRemovePropertyKeyframeLetsTheSpanEaseThroughAgain() {
        let layer = TLLayer(name: "text", swatch: .green, frames: [.keyframe(hasScript: false), .tween, .tween, .tween, .keyframe(hasScript: false)])
        layer.textFrames[1] = PlacedText(text: "A", x: 0, y: 0, width: 10, height: 10)
        layer.textFrames[5] = PlacedText(text: "A", x: 100, y: 0, width: 10, height: 10)
        layer.textFrames[3] = PlacedText(text: "A", x: 999, y: 0, width: 10, height: 10)
        layer.tweenSettings[1] = TweenSettings(family: .linear)
        let doc = TimelineDocument(layers: [layer], totalFrames: 5)

        doc.removePropertyKeyframe(layer: layer, at: 3)

        XCTAssertNil(layer.textFrames[3])
        XCTAssertFalse(layer.isPropertyKeyframe(at: 3))
        XCTAssertEqual(layer.interpolatedPlacedText(at: 3)?.x ?? -1, 50, accuracy: 0.01, "back to a plain straight-line ease from 0 to 100")
    }

    func testRemovePropertyKeyframeIsANoOpWhenThereIsntOne() {
        let layer = TLLayer(name: "text", swatch: .green, frames: [.keyframe(hasScript: false), .tween, .keyframe(hasScript: false)])
        layer.textFrames[1] = PlacedText(text: "A", x: 0, y: 0, width: 10, height: 10)
        layer.textFrames[3] = PlacedText(text: "A", x: 100, y: 0, width: 10, height: 10)
        let doc = TimelineDocument(layers: [layer], totalFrames: 3)

        doc.removePropertyKeyframe(layer: layer, at: 2) // shouldn't crash or touch anything
        XCTAssertEqual(layer.textFrames[1]?.x, 0)
        XCTAssertEqual(layer.textFrames[3]?.x, 100)
    }

    func testRemoveTweenAlsoClearsAnyPropertyKeyframesInTheSpan() {
        let layer = TLLayer(name: "text", swatch: .green, frames: [.keyframe(hasScript: false), .tween, .tween, .keyframe(hasScript: false)])
        layer.textFrames[1] = PlacedText(text: "A", x: 0, y: 0, width: 10, height: 10)
        layer.textFrames[4] = PlacedText(text: "A", x: 100, y: 0, width: 10, height: 10)
        layer.textFrames[2] = PlacedText(text: "A", x: 50, y: 0, width: 10, height: 10)
        layer.tweenSettings[1] = TweenSettings(family: .linear)
        let doc = TimelineDocument(layers: [layer], totalFrames: 4)

        doc.removeTween(layer: layer, at: 2)

        XCTAssertNil(layer.textFrames[2], "the mid-span property keyframe shouldn't linger as dead data")
        XCTAssertEqual(layer.frames, [.keyframe(hasScript: false), .plain, .plain, .keyframe(hasScript: false)])
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

    // MARK: - webExportPageBackground split hex/opacity bindings
    //
    // The one piece of genuinely new logic behind swapping ColorPicker for
    // NativeColorWell (see NativeColorWell's own doc comment on why): every
    // other color+opacity pairing in the Properties panel was already two
    // separate model fields (PlacedText.colorHex/.opacity, PlacedShape.
    // fillColorHex/.fillOpacity, etc.) shown via two separate controls now
    // instead of one combined Binding<Color> — no new binding logic there,
    // just less of it. webExportPageBackground is the one exception: it's
    // genuinely a single Color at the model level, so these two bindings
    // are what split it into a hex-only control and an opacity-only
    // control without becoming two separate stored fields.

    func testWebExportPageBackgroundHexBindingPreservesTheExistingOpacity() {
        let doc = TimelineDocument(layers: [TLLayer(name: "l", swatch: .green, frames: [.empty])], totalFrames: 1)
        doc.webExportPageBackground = Color(red: 1, green: 0, blue: 0, opacity: 0.4)

        doc.webExportPageBackgroundHexBinding.wrappedValue = Color(red: 0, green: 0, blue: 1)

        XCTAssertEqual(doc.webExportPageBackground.hexString, "#0000FF")
        XCTAssertEqual(doc.webExportPageBackground.opacityComponent, 0.4, accuracy: 0.01)
    }

    func testWebExportPageBackgroundOpacityBindingPreservesTheExistingHex() {
        let doc = TimelineDocument(layers: [TLLayer(name: "l", swatch: .green, frames: [.empty])], totalFrames: 1)
        doc.webExportPageBackground = Color(red: 1, green: 0, blue: 0, opacity: 1)

        doc.webExportPageBackgroundOpacityBinding.wrappedValue = 0.25

        XCTAssertEqual(doc.webExportPageBackground.hexString, "#FF0000")
        XCTAssertEqual(doc.webExportPageBackground.opacityComponent, 0.25, accuracy: 0.01)
    }

    func testWebExportPageBackgroundHexBindingReadsTheCurrentColorAsOpaque() {
        let doc = TimelineDocument(layers: [TLLayer(name: "l", swatch: .green, frames: [.empty])], totalFrames: 1)
        doc.webExportPageBackground = Color(red: 0, green: 1, blue: 0, opacity: 0.5)

        XCTAssertEqual(doc.webExportPageBackgroundHexBinding.wrappedValue.hexString, "#00FF00")
        XCTAssertEqual(doc.webExportPageBackgroundHexBinding.wrappedValue.opacityComponent, 1, accuracy: 0.01)
    }

    func testWebExportPageBackgroundOpacityBindingReadsTheCurrentOpacity() {
        let doc = TimelineDocument(layers: [TLLayer(name: "l", swatch: .green, frames: [.empty])], totalFrames: 1)
        doc.webExportPageBackground = Color(red: 0, green: 1, blue: 0, opacity: 0.7)

        XCTAssertEqual(doc.webExportPageBackgroundOpacityBinding.wrappedValue, 0.7, accuracy: 0.01)
    }

    func testWebExportPageBackgroundHexAndOpacityEditsAreBothUndoable() {
        let doc = TimelineDocument(layers: [TLLayer(name: "l", swatch: .green, frames: [.empty])], totalFrames: 1)
        doc.webExportPageBackground = Color(red: 1, green: 0, blue: 0, opacity: 1)

        doc.webExportPageBackgroundHexBinding.wrappedValue = Color(red: 0, green: 0, blue: 1)
        doc.undo()
        XCTAssertEqual(doc.webExportPageBackground.hexString, "#FF0000")

        doc.webExportPageBackgroundOpacityBinding.wrappedValue = 0.1
        doc.undo()
        XCTAssertEqual(doc.webExportPageBackground.opacityComponent, 1, accuracy: 0.01)
    }
}
