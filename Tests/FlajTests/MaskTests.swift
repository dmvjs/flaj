import XCTest
@testable import Flaj

/// Flash's mask layers — a `.mask`-kind layer's own content is never drawn
/// directly on Stage, only used as a clip stencil for the contiguous run
/// of `masked` layers directly below it in the Timeline list (see
/// `TimelineDocument.maskingLayer(for:)` in TimelineModel.swift).
@MainActor
final class MaskTests: XCTestCase {

    func testMaskingLayerReturnsTheMaskForADirectlyMaskedLayer() {
        let mask = TLLayer(name: "mask", swatch: .gray, kind: .mask, frames: [.empty])
        let content = TLLayer(name: "content", swatch: .green, frames: [.empty])
        content.masked = true
        let doc = TimelineDocument(layers: [mask, content], totalFrames: 1)

        XCTAssertEqual(doc.maskingLayer(for: content)?.id, mask.id)
    }

    func testMaskingLayerCoversAContiguousRunOfMaskedLayers() {
        let mask = TLLayer(name: "mask", swatch: .gray, kind: .mask, frames: [.empty])
        let a = TLLayer(name: "a", swatch: .green, frames: [.empty])
        a.masked = true
        let b = TLLayer(name: "b", swatch: .blue, frames: [.empty])
        b.masked = true
        let doc = TimelineDocument(layers: [mask, a, b], totalFrames: 1)

        XCTAssertEqual(doc.maskingLayer(for: a)?.id, mask.id)
        XCTAssertEqual(doc.maskingLayer(for: b)?.id, mask.id, "a contiguous run of masked layers should share the same mask")
    }

    func testANonMaskedLayerBreaksTheRun() {
        let mask = TLLayer(name: "mask", swatch: .gray, kind: .mask, frames: [.empty])
        let a = TLLayer(name: "a", swatch: .green, frames: [.empty])
        a.masked = true
        let unmasked = TLLayer(name: "unmasked", swatch: .purple, frames: [.empty]) // masked left false
        let afterBreak = TLLayer(name: "afterBreak", swatch: .blue, frames: [.empty])
        afterBreak.masked = true // masked=true but with no mask above it since `unmasked` broke the run
        let doc = TimelineDocument(layers: [mask, a, unmasked, afterBreak], totalFrames: 1)

        XCTAssertEqual(doc.maskingLayer(for: a)?.id, mask.id)
        XCTAssertNil(doc.maskingLayer(for: unmasked))
        XCTAssertNil(doc.maskingLayer(for: afterBreak), "masked=true doesn't matter once the run back to an actual mask layer is broken")
    }

    func testALaterMaskStartsANewRun() {
        let firstMask = TLLayer(name: "mask1", swatch: .gray, kind: .mask, frames: [.empty])
        let a = TLLayer(name: "a", swatch: .green, frames: [.empty])
        a.masked = true
        let secondMask = TLLayer(name: "mask2", swatch: .orange, kind: .mask, frames: [.empty])
        let b = TLLayer(name: "b", swatch: .blue, frames: [.empty])
        b.masked = true
        let doc = TimelineDocument(layers: [firstMask, a, secondMask, b], totalFrames: 1)

        XCTAssertEqual(doc.maskingLayer(for: a)?.id, firstMask.id)
        XCTAssertEqual(doc.maskingLayer(for: b)?.id, secondMask.id)
    }

    func testAMaskLayerIsNeverItselfMasked() {
        let mask = TLLayer(name: "mask", swatch: .gray, kind: .mask, frames: [.empty])
        let doc = TimelineDocument(layers: [mask], totalFrames: 1)

        XCTAssertNil(doc.maskingLayer(for: mask))
    }

    func testUnmaskedLayerWithNoMaskAboveReturnsNil() {
        let layer = TLLayer(name: "plain", swatch: .green, frames: [.empty])
        let doc = TimelineDocument(layers: [layer], totalFrames: 1)

        XCTAssertNil(doc.maskingLayer(for: layer))
    }

    // MARK: - Toggling

    func testToggleLayerMaskConvertsANormalLayerToAMaskAndBack() {
        let layer = TLLayer(name: "l", swatch: .green, frames: [.empty])
        let doc = TimelineDocument(layers: [layer], totalFrames: 1)

        doc.toggleLayerMask(layer)
        XCTAssertEqual(layer.kind, .mask)

        doc.toggleLayerMask(layer)
        XCTAssertEqual(layer.kind, .normal)
    }

    func testToggleLayerMaskIsANoOpOnAnAlreadyMaskedLayer() {
        let layer = TLLayer(name: "l", swatch: .green, frames: [.empty])
        layer.masked = true
        let doc = TimelineDocument(layers: [layer], totalFrames: 1)

        doc.toggleLayerMask(layer)

        XCTAssertEqual(layer.kind, .normal, "a masked layer can't become a mask — same rule Flash itself enforces")
    }

    func testToggleLayerMaskedFlipsTheFlag() {
        let layer = TLLayer(name: "l", swatch: .green, frames: [.empty])
        let doc = TimelineDocument(layers: [layer], totalFrames: 1)

        doc.toggleLayerMasked(layer)
        XCTAssertTrue(layer.masked)

        doc.toggleLayerMasked(layer)
        XCTAssertFalse(layer.masked)
    }

    func testToggleLayerMaskedIsANoOpOnAMaskLayer() {
        let layer = TLLayer(name: "l", swatch: .green, kind: .mask, frames: [.empty])
        let doc = TimelineDocument(layers: [layer], totalFrames: 1)

        doc.toggleLayerMasked(layer)

        XCTAssertFalse(layer.masked, "a mask layer can't itself be masked")
    }

    func testToggleLayerMaskIsUndoable() {
        let layer = TLLayer(name: "l", swatch: .green, frames: [.empty])
        let doc = TimelineDocument(layers: [layer], totalFrames: 1)

        doc.toggleLayerMask(layer)
        XCTAssertEqual(doc.layers[0].kind, .mask)

        doc.undo()

        XCTAssertEqual(doc.layers[0].kind, .normal)
    }

    func testToggleLayerMaskedIsUndoable() {
        let layer = TLLayer(name: "l", swatch: .green, frames: [.empty])
        let doc = TimelineDocument(layers: [layer], totalFrames: 1)

        doc.toggleLayerMasked(layer)
        XCTAssertTrue(doc.layers[0].masked)

        doc.undo()

        XCTAssertFalse(doc.layers[0].masked)
    }
}
